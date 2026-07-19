#!/usr/bin/env node
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../../harness.mjs";

const project = await mkdtemp(path.join(os.tmpdir(), "ss-editor-names-"));
try {
  const slide = path.join(project, "slide.ss");
  const dependency = path.join(project, "dependency.ss");
  const uri = pathToFileURL(slide).toString();
  const source = `import std:themes/default as *
import "./dependency" as *

const movable_item: Number = 1

fn movable_item_2() -> Number
  return 2
end

fn movable!() -> Object
  return text!("Move me")
end

page names
  let movable_item_3 = 3
  if true
    let movable_item_4 = 4
  end
  let keep = (movable_item_5: Number) |-> movable_item_5
  movable!()
  movable!()
  let from_const = movable_item
  let from_function = movable_item_2()
  let from_import = imported_value
end
`;
  await writeFile(
    dependency,
    "const movable_item_6: Number = 6\nconst imported_value: Number = 7\n",
    "utf8",
  );
  await writeFile(slide, source, "utf8");

  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    let diagnosticsPromise = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source });
    assert(
      (await diagnosticsPromise).params.diagnostics.length === 0,
      "name collision fixture produced diagnostics",
    );

    const initial = await editorSnapshot(client, uri);
    const generated = initial.editing.filter((target) =>
      target.binding_required
    ).map((target) => target.binding).sort();
    assert(
      JSON.stringify(generated) ===
        JSON.stringify(["movable_item_7", "movable_item_8"]),
      `unexpected generated names: ${JSON.stringify(initial.editing)}`,
    );

    const target = initial.editing.find((item) =>
      item.binding === "movable_item_7"
    );
    const frame = previewBounds(initial, target.node_id);
    const edit = await client.request("ss/layoutEdit", {
      textDocument: { uri },
      snapshotId: initial.snapshot_id,
      nodeId: target.node_id,
      pageId: target.page_id,
      mode: "absolute",
      fromBounds: frame,
      toBounds: { ...frame, x: 180, y: 160 },
    });
    assert(edit.status === "ok", `generated binding was rejected: ${JSON.stringify(edit)}`);
    const updated = applyProtocolEdits(
      source,
      edit.workspaceEdit?.changes?.[uri] ?? [],
    );
    assert(
      updated.includes("let movable_item_7 = movable!()"),
      `generated binding was not introduced: ${updated}`,
    );

    diagnosticsPromise = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 2, text: updated });
    assert(
      (await diagnosticsPromise).params.diagnostics.length === 0,
      "generated binding changed name resolution",
    );
    const afterEdit = await editorSnapshot(client, uri);
    assert(
      afterEdit.editing.some((item) =>
        item.binding === "movable_item_8" && item.binding_required
      ),
      `remaining generated name was unstable: ${JSON.stringify(afterEdit.editing)}`,
    );
  });
} finally {
  await rm(project, { recursive: true, force: true });
}

async function editorSnapshot(client, uri) {
  return client.request("ss/editorSnapshot", {
    textDocument: { uri },
  });
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
