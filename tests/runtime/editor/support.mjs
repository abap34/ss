import { assert } from "../harness.mjs";

export async function editorSnapshot(client, uri) {
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
    snapshot.display?.schema === 2 &&
      snapshot.display.html.includes("class=\"ss-item ss-text\"") &&
      snapshot.display.css.includes(".ss-text"),
    `snapshot omitted shared HTML text output: ${JSON.stringify(snapshot)}`,
  );
  return snapshot;
}

export function editingTarget(snapshot, binding) {
  const target = snapshot.editing.find((item) => item.binding === binding);
  assert(
    target,
    `snapshot omitted editing target ${binding}: ${
      JSON.stringify(snapshot.editing)
    }`,
  );
  return target;
}

export function previewBounds(snapshot, nodeId) {
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

export function requestEdit(
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

export function assertBounds(bounds, x, y, label) {
  assert(
    Math.abs(bounds.x - x) < 0.1,
    `${label} x was ${bounds.x}, expected ${x}`,
  );
  assert(
    Math.abs(bounds.y - y) < 0.1,
    `${label} y was ${bounds.y}, expected ${y}`,
  );
}

export function applyProtocolEdits(source, edits) {
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
