#!/usr/bin/env node
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../harness.mjs";

await testSnapshotAndSourceEdits();
await testLastGoodSnapshotsAreKeptPerEntry();

async function testSnapshotAndSourceEdits() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-"));
  try {
    const slide = path.join(project, "slide.ss");
    const position = path.join(project, "position.ss");
    const uri = pathToFileURL(slide).toString();
    const positionUri = pathToFileURL(position).toString();
    const source = `import std:themes/default as *
import "./position" as *

fn movable!() -> Object
  let result = text!("Move me")
  ~ result.left == page.left + left_offset
  ~ result.top == page.top - 96
  return result
end

page demo
let item = movable!()
end
`;
    await writeFile(slide, source, "utf8");
    await writeFile(position, "const left_offset: Number = 72\n", "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      let diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "WYSIWYG fixture produced diagnostics",
      );

      const initial = await editorSnapshot(client, uri);
      assert(
        initial.source_paths.includes(position),
        `snapshot omitted dependency path: ${
          JSON.stringify(initial.source_paths)
        }`,
      );
      const initialTarget = editingTarget(initial, "item");
      const initialFrame = previewBounds(initial, initialTarget.node_id);
      assert(
        Math.abs(initialFrame.x - 72) < 0.1,
        `initial dependency offset was ${initialFrame.x}`,
      );

      await writeFile(position, "const left_offset: Number = 84\n", "utf8");
      client.notify("workspace/didChangeWatchedFiles", {
        changes: [{ uri: positionUri, type: 2 }],
      });
      const dependencyUpdate = await editorSnapshot(client, uri);
      const dependencyFrame = previewBounds(
        dependencyUpdate,
        editingTarget(dependencyUpdate, "item").node_id,
      );
      assert(
        dependencyUpdate.snapshot_id !== initial.snapshot_id,
        "dependency-only layout change retained the snapshot id",
      );
      assert(
        Math.abs(dependencyFrame.x - 84) < 0.1,
        `dependency update left x at ${dependencyFrame.x}`,
      );

      const target = editingTarget(dependencyUpdate, "item");
      const fromBounds = previewBounds(dependencyUpdate, target.node_id);
      const toBounds = { ...fromBounds, x: 120, y: 140 };
      const wrongPage = await requestEdit(
        client,
        uri,
        dependencyUpdate,
        target,
        fromBounds,
        toBounds,
        "absolute",
        target.page_id + 1,
      );
      assert(
        wrongPage.status === "stale",
        `mismatched page was accepted: ${JSON.stringify(wrongPage)}`,
      );
      const unknownMode = await requestEdit(
        client,
        uri,
        dependencyUpdate,
        target,
        fromBounds,
        toBounds,
        "unknown",
        target.page_id,
      );
      assert(
        unknownMode.status === "unsupported",
        `unknown edit mode was accepted: ${JSON.stringify(unknownMode)}`,
      );
      const invalidBounds = await client.request("ss/layoutEdit", {
        textDocument: { uri },
        snapshotId: dependencyUpdate.snapshot_id,
        nodeId: target.node_id,
        pageId: target.page_id,
        mode: "absolute",
        fromBounds,
        toBounds: { x: 120, y: 140 },
      });
      assert(
        invalidBounds.status === "unsupported",
        `incomplete bounds were accepted: ${JSON.stringify(invalidBounds)}`,
      );

      const absolute = await requestEdit(
        client,
        uri,
        dependencyUpdate,
        target,
        fromBounds,
        toBounds,
        "absolute",
        target.page_id,
      );
      assert(
        absolute.status === "ok",
        `absolute edit was rejected: ${JSON.stringify(absolute)}`,
      );
      let updated = applyProtocolEdits(
        source,
        absolute.workspaceEdit?.changes?.[uri] ?? [],
      );
      assert(
        updated.includes("~!~item.left == page.left + 120"),
        `absolute edit did not update left: ${updated}`,
      );
      assert(
        updated.includes("~!~item.top == page.top - 140"),
        `absolute edit did not update top: ${updated}`,
      );
      assert(
        updated.includes("~ result.left == page.left + left_offset") &&
          updated.includes("~ result.top == page.top - 96"),
        `absolute edit rewrote component constraints: ${updated}`,
      );

      diagnosticsPromise = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, version: 2, text: updated });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "absolute source edit produced diagnostics",
      );
      const afterAbsolute = await editorSnapshot(client, uri);
      const absoluteTarget = editingTarget(afterAbsolute, "item");
      const absoluteFrame = previewBounds(
        afterAbsolute,
        absoluteTarget.node_id,
      );
      assertBounds(absoluteFrame, 120, 140, "absolute edit");

      const stale = await requestEdit(
        client,
        uri,
        dependencyUpdate,
        target,
        fromBounds,
        toBounds,
        "absolute",
        target.page_id,
      );
      assert(
        stale.status === "stale",
        `stale edit was accepted: ${JSON.stringify(stale)}`,
      );

      const relativeBounds = { ...absoluteFrame, x: 150, y: 165 };
      const relative = await requestEdit(
        client,
        uri,
        afterAbsolute,
        absoluteTarget,
        absoluteFrame,
        relativeBounds,
        "relative",
        absoluteTarget.page_id,
      );
      assert(
        relative.status === "ok",
        `relative edit was rejected: ${JSON.stringify(relative)}`,
      );
      updated = applyProtocolEdits(
        updated,
        relative.workspaceEdit?.changes?.[uri] ?? [],
      );
      assert(
        updated.includes("~!~item.left == page.left + 150"),
        `relative edit did not update left: ${updated}`,
      );
      assert(
        updated.includes("~!~item.top == page.top - 165"),
        `relative edit did not update top: ${updated}`,
      );

      diagnosticsPromise = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, version: 3, text: updated });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "relative source edit produced diagnostics",
      );
      const afterRelative = await editorSnapshot(client, uri);
      assertBounds(
        previewBounds(
          afterRelative,
          editingTarget(afterRelative, "item").node_id,
        ),
        150,
        165,
        "relative edit",
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testLastGoodSnapshotsAreKeptPerEntry() {
  const project = await mkdtemp(
    path.join(os.tmpdir(), "ss-lsp-wysiwyg-store-"),
  );
  try {
    const first = path.join(project, "first.ss");
    const second = path.join(project, "second.ss");
    const firstUri = pathToFileURL(first).toString();
    const secondUri = pathToFileURL(second).toString();
    const firstSource = simpleSource("first");
    const secondSource = simpleSource("second");
    await writeFile(first, firstSource, "utf8");
    await writeFile(second, secondSource, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      let diagnosticsPromise = client.waitForDiagnostics(firstUri);
      client.openDocument({ uri: firstUri, text: firstSource });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "first editor fixture produced diagnostics",
      );
      await editorSnapshot(client, firstUri);

      diagnosticsPromise = client.waitForDiagnostics(secondUri);
      client.openDocument({ uri: secondUri, text: secondSource });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "second editor fixture produced diagnostics",
      );
      await editorSnapshot(client, secondUri);

      const invalid = "page broken\nlet item =\nend\n";
      diagnosticsPromise = client.waitForDiagnostics(
        firstUri,
        (diagnostics) => diagnostics.length > 0,
      );
      client.changeDocument({ uri: firstUri, version: 2, text: invalid });
      await diagnosticsPromise;
      const staleFirst = await client.request("ss/editorSnapshot", {
        textDocument: { uri: firstUri },
      });
      assert(
        staleFirst.stale === true && staleFirst.entry_path === first,
        `first stale snapshot was lost: ${JSON.stringify(staleFirst)}`,
      );

      diagnosticsPromise = client.waitForDiagnostics(
        secondUri,
        (diagnostics) => diagnostics.length > 0,
      );
      client.changeDocument({ uri: secondUri, version: 2, text: invalid });
      await diagnosticsPromise;
      const staleSecond = await client.request("ss/editorSnapshot", {
        textDocument: { uri: secondUri },
      });
      assert(
        staleSecond.stale === true && staleSecond.entry_path === second,
        `second stale snapshot was lost: ${JSON.stringify(staleSecond)}`,
      );

      const restoredFirst = await client.request("ss/editorSnapshot", {
        textDocument: { uri: firstUri },
      });
      assert(
        restoredFirst.stale === true && restoredFirst.entry_path === first,
        `first cached snapshot was replaced by the second: ${
          JSON.stringify(restoredFirst)
        }`,
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function simpleSource(name) {
  return `import std:themes/default as *

page ${name}
let item = text!("${name}")
~ item.left == page.left + 72
~ item.top == page.top - 96
end
`;
}

async function editorSnapshot(client, uri) {
  const snapshot = await client.request("ss/editorSnapshot", {
    textDocument: { uri },
  });
  assert(
    snapshot.kind === "ss-editor-snapshot",
    `unexpected snapshot: ${JSON.stringify(snapshot)}`,
  );
  assert(
    snapshot.coordinate_space?.origin === "page-top-left",
    `unexpected coordinates: ${JSON.stringify(snapshot.coordinate_space)}`,
  );
  assert(
    snapshot.display?.pages?.some((page) =>
      page.items.some((item) => item.type === "text")
    ),
    "snapshot omitted text drawing commands",
  );
  return snapshot;
}

function editingTarget(snapshot, binding) {
  const target = snapshot.editing.find((item) => item.binding === binding);
  assert(
    target,
    `snapshot omitted editing target ${binding}: ${
      JSON.stringify(snapshot.editing)
    }`,
  );
  return target;
}

function previewBounds(snapshot, nodeId) {
  const object = snapshot.layout.objects.find((item) => item.id === nodeId);
  const page = snapshot.layout.pages.find((item) =>
    item.id === object?.page_id
  );
  assert(object && page, `snapshot omitted frame for node ${nodeId}`);
  return {
    x: object.x,
    y: page.height - object.y - object.height,
    width: object.width,
    height: object.height,
  };
}

function requestEdit(
  client,
  uri,
  snapshot,
  target,
  fromBounds,
  toBounds,
  mode,
  pageId,
) {
  return client.request("ss/layoutEdit", {
    textDocument: { uri },
    snapshotId: snapshot.snapshot_id,
    nodeId: target.node_id,
    pageId,
    mode,
    fromBounds,
    toBounds,
  });
}

function assertBounds(bounds, x, y, label) {
  assert(
    Math.abs(bounds.x - x) < 0.1,
    `${label} x was ${bounds.x}, expected ${x}`,
  );
  assert(
    Math.abs(bounds.y - y) < 0.1,
    `${label} y was ${bounds.y}, expected ${y}`,
  );
}

function applyProtocolEdits(source, edits) {
  const offsets = edits.map((edit) => ({
    start: protocolOffset(source, edit.range.start),
    end: protocolOffset(source, edit.range.end),
    text: edit.newText,
  })).sort((left, right) => right.start - left.start);
  let result = source;
  for (const edit of offsets) {
    result = result.slice(0, edit.start) + edit.text + result.slice(edit.end);
  }
  return result;
}

function protocolOffset(source, position) {
  let offset = 0;
  let line = 0;
  while (line < position.line && offset < source.length) {
    const next = source.indexOf("\n", offset);
    if (next < 0) return source.length;
    offset = next + 1;
    line += 1;
  }
  return Math.min(source.length, offset + position.character);
}
