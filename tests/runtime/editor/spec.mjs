#!/usr/bin/env node
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../harness.mjs";
import {
  applyProtocolEdits,
  assertBounds,
  editingTarget,
  editorSnapshot,
  previewBounds,
  requestEdit,
} from "./support.mjs";

await testSnapshotAndSourceEdits();
await testComponentWidthEdits();
await testPositionEditsAllowReflowAndMoveReturnedGroups();
await testSnapshotHighlightsPythonCode();
await testSnapshotAssetsUseContentAddressedFiles();
await testSnapshotRecoversAfterInvalidEdit();
await testStaleSnapshotAfterTranslationPatchUsesFullDisplay();
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

record Parts {
  root: Object
}

fn movable!() -> Object
  let result = text!("Move me")
  ~ result.left == page.left + left_offset
  ~ result.top == page.top - 96
  return result
end

page demo
let item = movable!()
let parts = Parts {
  root = movable!()
}
movable!()
let automatic = text!("Automatic")
~ item.right == item.left + 220
if true
  let local = text!("Local")
end
end
`;
    await writeFile(slide, source, "utf8");
    await writeFile(position, dependencySource(72), "utf8");

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
      const sourcedConstraint = initial.layout.relations.find((relation) =>
        relation.kind === "explicit" &&
        relation.target?.node_id === initialTarget.node_id &&
        relation.location?.path === slide
      );
      assert(
        Number.isInteger(sourcedConstraint?.location?.line) &&
          sourcedConstraint.location.line > 0,
        `explicit constraint omitted its source line: ${
          JSON.stringify(initial.layout.relations)
        }`,
      );
      editingTarget(initial, "parts.root");
      const unboundTarget = editingTarget(initial, "movable_item");
      assert(
        unboundTarget.binding_required === true,
        `unbound component did not require a binding: ${JSON.stringify(unboundTarget)}`,
      );
      const automaticTarget = editingTarget(initial, "automatic");
      const automaticRelations = initial.layout.relations.filter((relation) =>
        relation.kind === "fallback" &&
        relation.target?.node_id === automaticTarget.node_id
      );
      assert(
        automaticRelations.some((relation) => relation.axis === "horizontal") &&
          automaticRelations.some((relation) => relation.axis === "vertical"),
        `automatic object omitted fallback constraints: ${JSON.stringify(automaticRelations)}`,
      );
      assert(
        initialTarget.page_index === 2,
        `editing target used page ${initialTarget.page_index} instead of page 2`,
      );
      assert(
        !initial.editing.some((item) => item.binding === "local"),
        `branch-local binding was exposed as editable: ${JSON.stringify(initial.editing)}`,
      );
      const initialFrame = previewBounds(initial, initialTarget.node_id);
      assert(
        Math.abs(initialFrame.x - 72) < 0.1,
        `initial dependency offset was ${initialFrame.x}`,
      );

      await writeFile(position, dependencySource(84), "utf8");
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
        updated.includes("~!~ item.left == page.left + 120"),
        `absolute edit did not update left: ${updated}`,
      );
      assert(
        updated.includes("~!~ item.top == page.top - 140"),
        `absolute edit did not update top: ${updated}`,
      );
      assert(
        updated.includes("~ result.left == page.left + left_offset") &&
          updated.includes("~ result.top == page.top - 96"),
        `absolute edit rewrote component constraints: ${updated}`,
      );
      assert(
        updated.includes("~ item.right == item.left + 220"),
        `absolute edit rewrote the size constraint: ${updated}`,
      );

      diagnosticsPromise = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, version: 2, text: updated });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "absolute source edit produced diagnostics",
      );
      const afterAbsolute = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
        baseSnapshotId: dependencyUpdate.snapshot_id,
      });
      assert(
        afterAbsolute.display?.schema === 3 &&
          afterAbsolute.display.kind === "translation_patch" &&
          afterAbsolute.display.base_snapshot_id === dependencyUpdate.snapshot_id &&
          afterAbsolute.display.translations.some((item) =>
            item.node_id === target.node_id
          ),
        `absolute position edit regenerated full HTML: ${JSON.stringify(afterAbsolute.display)}`,
      );
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
        updated.includes("~!~ item.left == page.left + 150"),
        `relative edit did not update left: ${updated}`,
      );
      assert(
        updated.includes("~!~ item.top == page.top - 165"),
        `relative edit did not update top: ${updated}`,
      );
      assert(
        updated.includes("~ item.right == item.left + 220"),
        `relative edit rewrote the size constraint: ${updated}`,
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

      const reboundTarget = editingTarget(afterRelative, "movable_item");
      const reboundFrom = previewBounds(afterRelative, reboundTarget.node_id);
      const reboundTo = { ...reboundFrom, x: 260, y: 210 };
      const rebound = await requestEdit(
        client,
        uri,
        afterRelative,
        reboundTarget,
        reboundFrom,
        reboundTo,
        "absolute",
        reboundTarget.page_id,
      );
      assert(
        rebound.status === "ok",
        `unbound component edit was rejected: ${JSON.stringify(rebound)}`,
      );
      updated = applyProtocolEdits(
        updated,
        rebound.workspaceEdit?.changes?.[uri] ?? [],
      );
      assert(
        updated.includes("let movable_item = movable!()"),
        `unbound component was not bound: ${updated}`,
      );
      assert(
        updated.includes("~!~ movable_item.left == page.left + 260") &&
          updated.includes("~!~ movable_item.top == page.top - 210"),
        `unbound component constraints were not added: ${updated}`,
      );

      diagnosticsPromise = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, version: 4, text: updated });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "binding an unbound component produced diagnostics",
      );
      const afterBinding = await editorSnapshot(client, uri);
      assertBounds(
        previewBounds(
          afterBinding,
          editingTarget(afterBinding, "movable_item").node_id,
        ),
        260,
        210,
        "unbound component edit",
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testComponentWidthEdits() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-width-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    let source = `import std:themes/default as *

page demo
let item = text!("A component whose width is editable")
~!~ item.left == page.left + 80
~!~ item.top == page.top - 90
let anchored = text!("A component with an anchor-form width update")
~!~ anchored.left == page.left + 500
~!~ anchored.top == page.top - 90
~!~ anchored.right == anchored.left + 180
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      let diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "component width fixture produced diagnostics",
      );

      let snapshot = await editorSnapshot(client, uri);
      let target = editingTarget(snapshot, "item");
      let frame = previewBounds(snapshot, target.node_id);
      const first = await requestEdit(
        client,
        uri,
        snapshot,
        target,
        frame,
        { ...frame, width: 260 },
        "width",
        target.page_id,
      );
      assert(first.status === "ok", `component width edit failed: ${JSON.stringify(first)}`);
      source = applyProtocolEdits(
        source,
        first.workspaceEdit?.changes?.[uri] ?? [],
      );
      assert(
        source.includes("~!~ item.width == 260"),
        `component width edit omitted its dimension update: ${source}`,
      );
      diagnosticsPromise = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, version: 2, text: source });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "component width source edit produced diagnostics",
      );
      snapshot = await editorSnapshot(client, uri);
      target = editingTarget(snapshot, "item");
      frame = previewBounds(snapshot, target.node_id);
      assert(
        Math.abs(frame.width - 260) < 0.1,
        `component width was ${frame.width} instead of 260`,
      );

      target = editingTarget(snapshot, "anchored");
      frame = previewBounds(snapshot, target.node_id);
      assert(
        Math.abs(frame.width - 180) < 0.1,
        `anchor-form component width was ${frame.width} instead of 180`,
      );
      const anchoredEdit = await requestEdit(
        client,
        uri,
        snapshot,
        target,
        frame,
        { ...frame, width: 220 },
        "width",
        target.page_id,
      );
      assert(
        anchoredEdit.status === "ok",
        `anchor-form component width edit failed: ${JSON.stringify(anchoredEdit)}`,
      );
      source = applyProtocolEdits(
        source,
        anchoredEdit.workspaceEdit?.changes?.[uri] ?? [],
      );
      assert(
        source.includes("~!~ anchored.right == anchored.left + 220") &&
          !source.includes("anchored.width"),
        `anchor-form width edit accumulated a second constraint: ${source}`,
      );
      diagnosticsPromise = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, version: 3, text: source });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "anchor-form width source edit produced diagnostics",
      );
      snapshot = await editorSnapshot(client, uri);
      target = editingTarget(snapshot, "item");
      frame = previewBounds(snapshot, target.node_id);

      const second = await requestEdit(
        client,
        uri,
        snapshot,
        target,
        frame,
        { ...frame, width: 300 },
        "width",
        target.page_id,
      );
      assert(second.status === "ok", `second component width edit failed: ${JSON.stringify(second)}`);
      source = applyProtocolEdits(
        source,
        second.workspaceEdit?.changes?.[uri] ?? [],
      );
      assert(
        source.includes("~!~ item.width == 300") &&
          source.match(/item\.width/g)?.length === 1,
        `repeated width edit accumulated dimension updates: ${source}`,
      );

      const outside = await requestEdit(
        client,
        uri,
        snapshot,
        target,
        frame,
        { ...frame, width: 1280 },
        "width",
        target.page_id,
      );
      assert(
        outside.status === "rejected",
        `out-of-page component width was accepted: ${JSON.stringify(outside)}`,
      );
      const tooNarrow = await requestEdit(
        client,
        uri,
        snapshot,
        target,
        frame,
        { ...frame, width: 1 },
        "width",
        target.page_id,
      );
      assert(
        tooNarrow.status === "rejected",
        `a component width below the editor minimum was accepted: ${
          JSON.stringify(tooNarrow)
        }`,
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function dependencySource(offset) {
  return `const left_offset: Number = ${offset}

page dependency
end
`;
}

async function testPositionEditsAllowReflowAndMoveReturnedGroups() {
  const project = await mkdtemp(
    path.join(os.tmpdir(), "ss-lsp-wysiwyg-position-"),
  );
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `import std:themes/default as *

fn/! grouped() -> Object
  let title = text("Grouped title")
  let rule = text("-")
  ~ title.left == page.left + 72
  ~ title.top == page.top - 100
  ~ rule.left == title.left
  ~ rule.top == title.bottom - 30
  return group(title, rule)
end

page demo
text! <<
This line is deliberately wide enough to use the default text width and reflow when it moves toward the right page edge.
>>
grouped!()
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source });
      const initialDiagnostics = (await diagnosticsPromise).params.diagnostics;
      assert(
        initialDiagnostics.length === 0,
        `position validation fixture produced diagnostics: ${JSON.stringify(initialDiagnostics)}`,
      );

      let snapshot = await editorSnapshot(client, uri);
      const textTarget = editingTarget(snapshot, "text_item");
      const textFrom = previewBounds(snapshot, textTarget.node_id);
      const textTo = {
        ...textFrom,
        x: textFrom.x + 140,
        y: textFrom.y + 20,
      };
      const textEdit = await requestEdit(
        client,
        uri,
        snapshot,
        textTarget,
        textFrom,
        textTo,
        "absolute",
        textTarget.page_id,
      );
      assert(
        textEdit.status === "ok",
        `reflowing text edit was rejected: ${JSON.stringify(textEdit)}`,
      );
      let updated = applyProtocolEdits(
        source,
        textEdit.workspaceEdit?.changes?.[uri] ?? [],
      );
      let diagnostics = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, version: 2, text: updated });
      assert(
        (await diagnostics).params.diagnostics.length === 0,
        "reflowing text edit produced diagnostics",
      );
      const beforeReflowSnapshotId = snapshot.snapshot_id;
      snapshot = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
        baseSnapshotId: beforeReflowSnapshotId,
      });
      assert(
        snapshot.display?.schema === 2 &&
          snapshot.display.html.includes("class=\"ss-item ss-text\""),
        `text reflow incorrectly reused translated HTML: ${JSON.stringify(snapshot.display)}`,
      );
      const textAfter = previewBounds(
        snapshot,
        editingTarget(snapshot, "text_item").node_id,
      );
      assertBounds(textAfter, textTo.x, textTo.y, "reflowing text edit");
      assert(
        textAfter.width < textFrom.width,
        `text did not exercise width reflow: ${JSON.stringify({ textFrom, textAfter })}`,
      );

      const groupTarget = editingTarget(snapshot, "grouped_item");
      const groupFrom = previewBounds(snapshot, groupTarget.node_id);
      const groupTo = {
        ...groupFrom,
        x: groupFrom.x + 90,
        y: groupFrom.y + 70,
      };
      const groupEdit = await requestEdit(
        client,
        uri,
        snapshot,
        groupTarget,
        groupFrom,
        groupTo,
        "absolute",
        groupTarget.page_id,
      );
      assert(
        groupEdit.status === "ok",
        `returned group edit was rejected: ${JSON.stringify(groupEdit)}`,
      );
      updated = applyProtocolEdits(
        updated,
        groupEdit.workspaceEdit?.changes?.[uri] ?? [],
      );
      assert(
        updated.includes("let grouped_item = grouped!()") &&
          updated.includes("~!~ grouped_item.left == page.left") &&
          updated.includes("~!~ grouped_item.top == page.top"),
        `returned group edit omitted its caller update: ${updated}`,
      );
      diagnostics = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, version: 3, text: updated });
      assert(
        (await diagnostics).params.diagnostics.length === 0,
        "returned group edit produced diagnostics",
      );
      snapshot = await editorSnapshot(client, uri);
      assertBounds(
        previewBounds(
          snapshot,
          editingTarget(snapshot, "grouped_item").node_id,
        ),
        groupTo.x,
        groupTo.y,
        "returned group edit",
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testSnapshotHighlightsPythonCode() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-code-highlight-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `import std:themes/default as *

page code_sample
let snippet = <<
def f(x):
  return x + 1
>>
code!(snippet, "python")
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source });
      const diagnostics = (await diagnosticsPromise).params.diagnostics;
      assert(
        diagnostics.length === 0,
        `Python code highlight fixture produced diagnostics: ${JSON.stringify(diagnostics)}`,
      );

      const snapshot = await editorSnapshot(client, uri);
      const colors = [...snapshot.display.html.matchAll(/color:rgb\(([^)]+)\)/g)]
        .map((match) => match[1]);
      assert(
        new Set(colors).size > 1,
        `WYSIWYG code snapshot did not include highlighted text colors: ${snapshot.display.html}`,
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testSnapshotAssetsUseContentAddressedFiles() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-assets-"));
  try {
    const slide = path.join(project, "slide.ss");
    const asset = path.join(project, "asset.svg");
    const uri = pathToFileURL(slide).toString();
    const source = `import std:themes/default as *

page asset_preview
let label = text!("Asset preview")
let picture = image!("asset.svg")
~ picture.left == page.left + 72
~ picture.top == page.top - 120
end
`;
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60"><rect width="120" height="60" fill="#2f7f73"/></svg>\n';
    await writeFile(slide, source, "utf8");
    await writeFile(asset, svg, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "asset preview fixture produced diagnostics",
      );
      const first = await editorSnapshot(client, uri);
      const firstItem = first.display.assets.find((item) => item.kind === "svg");
      assert(firstItem, `snapshot omitted SVG resource: ${JSON.stringify(first.display)}`);
      assert(path.isAbsolute(firstItem.path), `snapshot asset path was not absolute: ${firstItem.path}`);
      assert(firstItem.media_type === "image/svg+xml", `snapshot asset media type was wrong: ${JSON.stringify(firstItem)}`);
      assert(/^sha256:[0-9a-f]{64}$/.test(firstItem.digest), `snapshot asset digest was invalid: ${JSON.stringify(firstItem)}`);
      assert(
        first.display.html.includes(firstItem.relative_path),
        `snapshot HTML did not reference its published SVG: ${JSON.stringify(firstItem)}`,
      );
      assert((await readFile(firstItem.path, "utf8")) === svg, "published editor asset did not preserve SVG bytes");

      const firstStat = await stat(firstItem.path);
      const second = await editorSnapshot(client, uri);
      const secondItem = second.display.assets.find((item) => item.kind === "svg");
      assert(secondItem?.path === firstItem.path, "unchanged snapshot published a different editor asset path");
      const secondStat = await stat(firstItem.path);
      assert(secondStat.mtimeMs === firstStat.mtimeMs, "unchanged snapshot rewrote its editor asset");

      await writeFile(firstItem.path, "x".repeat(Buffer.byteLength(svg)), "utf8");
      const repairedSource = `${source}\n`;
      const repairedDiagnostics = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, version: 2, text: repairedSource });
      assert((await repairedDiagnostics).params.diagnostics.length === 0, "repair generation produced diagnostics");
      const third = await editorSnapshot(client, uri);
      const thirdItem = third.display.assets.find((item) => item.kind === "svg");
      assert(thirdItem?.path === firstItem.path, "repair changed a content-addressed asset path");
      assert((await readFile(firstItem.path, "utf8")) === svg, "snapshot did not repair a same-size corrupted editor asset");
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
      assert(
        staleFirst.build_diagnostics?.length > 0 &&
          staleFirst.build_diagnostics.every((item) => item.uri === firstUri),
        `first stale snapshot used another entry's diagnostics: ${JSON.stringify(staleFirst)}`,
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
      assert(
        staleSecond.build_diagnostics?.length > 0 &&
          staleSecond.build_diagnostics.every((item) => item.uri === secondUri),
        `second stale snapshot used another entry's diagnostics: ${JSON.stringify(staleSecond)}`,
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
      assert(
        restoredFirst.build_diagnostics?.length > 0 &&
          restoredFirst.build_diagnostics.every((item) =>
            item.uri === firstUri
          ),
        `restored first snapshot used another entry's diagnostics: ${
          JSON.stringify(restoredFirst)
        }`,
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testSnapshotRecoversAfterInvalidEdit() {
  const project = await mkdtemp(
    path.join(os.tmpdir(), "ss-lsp-wysiwyg-recovery-"),
  );
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const initialSource = simpleSource("initial");
    const invalidSource = "page broken\nlet item =\nend\n";
    const recoveredSource = simpleSource("recovered");
    await writeFile(slide, initialSource, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      let diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: initialSource });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "initial WYSIWYG recovery fixture produced diagnostics",
      );
      const initial = await editorSnapshot(client, uri);
      assert(initial.stale !== true, "initial editor snapshot was stale");

      diagnosticsPromise = client.waitForDiagnostics(
        uri,
        (diagnostics) => diagnostics.length > 0,
      );
      client.changeDocument({ uri, version: 2, text: invalidSource });
      await diagnosticsPromise;
      const stale = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
      });
      assert(
        stale.stale === true && stale.snapshot_id === initial.snapshot_id,
        `invalid source did not retain the last successful snapshot: ${
          JSON.stringify(stale)
        }`,
      );
      assert(
        stale.build_diagnostics?.length > 0 &&
          stale.build_diagnostics.every((diagnostic) =>
            diagnostic.uri === uri &&
            typeof diagnostic.code === "string" &&
            diagnostic.message.length > 0 &&
            Number.isSafeInteger(diagnostic.range?.start?.line)
          ),
        `stale snapshot omitted its build diagnostics: ${JSON.stringify(stale)}`,
      );

      diagnosticsPromise = client.waitForDiagnostics(
        uri,
        (diagnostics) => diagnostics.length === 0,
      );
      client.changeDocument({ uri, version: 3, text: recoveredSource });
      const recoveredDiagnostics = await diagnosticsPromise;
      assert(
        recoveredDiagnostics.params.version === 3,
        `recovery diagnostics used version ${recoveredDiagnostics.params.version}`,
      );
      const recovered = await editorSnapshot(client, uri);
      assert(recovered.stale !== true, "recovered editor snapshot remained stale");
      assert(
        recovered.build_diagnostics == null,
        "recovered editor snapshot retained obsolete build diagnostics",
      );
      assert(
        recovered.generation > stale.generation &&
          recovered.snapshot_id !== initial.snapshot_id,
        `recovered editor snapshot was not rebuilt: ${JSON.stringify(recovered)}`,
      );
      assert(
        recovered.layout.pages.some((page) => page.name === "recovered") &&
          recovered.display.html.includes("recovered"),
        `recovered editor snapshot retained the old output: ${
          JSON.stringify(recovered)
        }`,
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testStaleSnapshotAfterTranslationPatchUsesFullDisplay() {
  const project = await mkdtemp(
    path.join(os.tmpdir(), "ss-lsp-wysiwyg-patch-recovery-"),
  );
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = simpleSource("patch-recovery");
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      let diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "translation patch recovery fixture produced diagnostics",
      );
      const initial = await editorSnapshot(client, uri);
      const target = editingTarget(initial, "item");
      const fromBounds = previewBounds(initial, target.node_id);
      const edit = await requestEdit(
        client,
        uri,
        initial,
        target,
        fromBounds,
        { ...fromBounds, x: fromBounds.x + 24 },
        "absolute",
        target.page_id,
      );
      assert(edit.status === "ok", `translation patch edit failed: ${JSON.stringify(edit)}`);
      const updated = applyProtocolEdits(
        source,
        edit.workspaceEdit?.changes?.[uri] ?? [],
      );
      diagnosticsPromise = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, version: 2, text: updated });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "translation patch source edit produced diagnostics",
      );
      const patch = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
        baseSnapshotId: initial.snapshot_id,
      });
      assert(
        patch.display?.schema === 3 && patch.display.kind === "translation_patch",
        `position edit did not produce a translation patch: ${JSON.stringify(patch.display)}`,
      );

      diagnosticsPromise = client.waitForDiagnostics(
        uri,
        (diagnostics) => diagnostics.length > 0,
      );
      client.changeDocument({
        uri,
        version: 3,
        text: "page broken\nlet item =\nend\n",
      });
      await diagnosticsPromise;
      const stale = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
        baseSnapshotId: patch.snapshot_id,
      });
      assert(
        stale.stale === true && stale.display?.schema === 2 &&
          stale.snapshot_id === initial.snapshot_id,
        `stale translation patch was returned without its base: ${JSON.stringify(stale)}`,
      );
      const refreshed = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
      });
      assert(
        refreshed.stale === true && refreshed.display?.schema === 2,
        `full stale refresh repeated a translation patch: ${JSON.stringify(refreshed)}`,
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
