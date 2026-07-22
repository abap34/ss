#!/usr/bin/env node
import assert from "node:assert/strict";
import {
  defaultShapeStyle,
  ShapeController,
} from "../../../editor/vscode/media/editor/shape-insertion.js";

const state = {
  snapshot: snapshot("initial", []),
  currentPageId: 11,
  selectedObjectId: null,
  shapeTool: "select",
  shapeStyle: structuredClone(defaultShapeStyle),
};
const messages = [];
const selections = [];
const shape = new ShapeController(state, {
  post: (message) => messages.push(structuredClone(message)),
  render: () => {},
  selectObject: (nodeId, pageId) => {
    state.selectedObjectId = nodeId;
    selections.push({ nodeId, pageId });
  },
});

assert.equal(shape.canInsert(11), true);
shape.selectTool("rectangle");
assert.equal(state.shapeTool, "rectangle");
assert.equal(
  shape.insert(11, {
    bounds: { x: 120, y: 140, width: 180, height: 110 },
  }),
  true,
);
assert.equal(messages.length, 1);
assert.equal(messages[0].type, "insertShape");
assert.equal(messages[0].kind, "rectangle");
assert.deepEqual(messages[0].fill, defaultShapeStyle.fill);
assert.equal(shape.isBusy(), true);
assert.deepEqual(shape.pendingInsertion(11), {
  pageId: 11,
  kind: "rectangle",
  bounds: { x: 120, y: 140, width: 180, height: 110 },
  fill: { ...defaultShapeStyle.fill },
  stroke: { ...defaultShapeStyle.stroke },
});

shape.acceptResult({
  type: "shapeEditResult",
  requestId: messages[0].requestId,
  operation: "insert",
  status: "applied",
  documentVersion: 2,
  selection: { path: "/tmp/slide.ss", pageId: 11, binding: "rectangle_item" },
});
assert(shape.pendingInsertion(11), "applied insertion lost its provisional shape before the next snapshot");
state.snapshot = snapshot("after-insert", [{
  node_id: 101,
  page_id: 11,
  binding: "rectangle_item",
  kind: "rectangle",
  fill: { ...defaultShapeStyle.fill },
  stroke: { ...defaultShapeStyle.stroke },
}]);
assert.deepEqual(shape.reconcile(state.snapshot), {
  status: "applied",
  operation: "insert",
});
assert.equal(state.shapeTool, "select");
assert.equal(shape.pendingInsertion(11), null);
assert.deepEqual(selections, [{ nodeId: 101, pageId: 11 }]);

const target = shape.styleTarget(101);
assert(target);
assert.equal(shape.editStyle(target, {
  fill: { enabled: true, color: "#f59e0b", opacity: 0.5 },
  stroke: { enabled: false, color: "#2563eb", width: 1.6, style: "dotted" },
}), true);
assert.equal(messages.length, 2);
assert.equal(messages[1].type, "editShapeStyle");
assert.equal(messages[1].nodeId, 101);
assert.equal(messages[1].fill.color, "#f59e0b");

assert.deepEqual(shape.acceptResult({
  type: "shapeEditResult",
  requestId: messages[1].requestId,
  operation: "style",
  status: "rejected",
  message: "rejected for test",
}), { status: "failed", message: "rejected for test" });
assert.equal(shape.isBusy(), false);

shape.setDraft({
  fill: { ...defaultShapeStyle.fill },
  stroke: { ...defaultShapeStyle.stroke, enabled: false, style: "dash_dot" },
});
shape.selectTool("line");
assert.equal(state.shapeTool, "line");
assert.equal(state.shapeStyle.stroke.enabled, false,
  "selecting the line tool changed the closed-shape stroke preference");
assert.equal(shape.insert(11, {
  start: { x: 440, y: 120 },
  end: { x: 210, y: 350 },
}), true);
assert.equal(messages.length, 3);
assert.deepEqual(messages[2].start, { x: 440, y: 120 });
assert.deepEqual(messages[2].end, { x: 210, y: 350 });
assert.equal(messages[2].stroke.style, "dash_dot");
assert.equal(messages[2].stroke.enabled, true);
assert.equal(Object.hasOwn(messages[2], "bounds"), false);
assert.equal(Object.hasOwn(messages[2], "fill"), false);
assert.deepEqual(shape.pendingInsertion(11), {
  pageId: 11,
  kind: "line",
  start: { x: 440, y: 120 },
  end: { x: 210, y: 350 },
  stroke: { ...state.shapeStyle.stroke, enabled: true },
});
shape.acceptResult({
  type: "shapeEditResult",
  requestId: messages[2].requestId,
  operation: "insert",
  status: "stale",
});
assert.equal(state.shapeTool, "line");
assert(shape.pendingInsertion(11),
  "a stale insertion response discarded its provisional shape");
state.snapshot = snapshot("line-rebased", []);
assert.equal(shape.reconcile(state.snapshot), null);
assert.equal(messages.length, 4);
assert.equal(messages[3].snapshotId, "line-rebased");
assert.equal(messages[3].kind, "line");
shape.acceptResult({
  type: "shapeEditResult",
  requestId: messages[3].requestId,
  operation: "insert",
  status: "rejected",
  message: "rejected rebased insertion for test",
});
assert.equal(state.shapeTool, "select");

const lineTarget = {
  node_id: 102,
  page_id: 11,
  binding: "line_item",
  kind: "line",
  start: { x: 1, y: 0 },
  end: { x: 0, y: 1 },
  stroke: { ...defaultShapeStyle.stroke },
};
assert.equal(shape.editStyle(lineTarget, {
  stroke: { ...lineTarget.stroke, width: 3, style: "dashed" },
}), true);
assert.equal(messages.length, 5);
assert.equal(messages[4].kind, "line");
assert.equal(messages[4].stroke.width, 3);
assert.equal(Object.hasOwn(messages[4], "fill"), false);
shape.acceptResult({
  type: "shapeEditResult",
  requestId: messages[4].requestId,
  operation: "style",
  status: "rejected",
});

assert.equal(shape.editLineGeometry(
  lineTarget,
  { x: 760, y: 170 },
  { x: 480, y: 310 },
), true);
assert.equal(messages.length, 6);
assert.deepEqual(messages[5], {
  type: "editLineGeometry",
  requestId: messages[5].requestId,
  snapshotId: state.snapshot.snapshot_id,
  nodeId: 102,
  pageId: 11,
  start: { x: 760, y: 170 },
  end: { x: 480, y: 310 },
});
assert.deepEqual(shape.pendingLineGeometry(102), {
  nodeId: 102,
  pageId: 11,
  start: { x: 760, y: 170 },
  end: { x: 480, y: 310 },
});
shape.acceptResult({
  type: "shapeEditResult",
  requestId: messages[5].requestId,
  operation: "geometry",
  status: "rejected",
});
assert.equal(shape.pendingLineGeometry(102), null);

state.snapshot.stale = true;
assert.equal(shape.canInsert(11), true);
shape.selectTool("rectangle");
const messageCountBeforeQueuedInsert = messages.length;
assert.equal(shape.insert(11, {
  bounds: { x: 180, y: 210, width: 120, height: 80 },
}), true);
assert.equal(messages.length, messageCountBeforeQueuedInsert,
  "an insertion based on a stale preview was sent before rebuilding");
assert(shape.pendingInsertion(11),
  "an insertion based on a stale preview was not retained locally");
assert.equal(shape.reconcile(state.snapshot), null);
assert(shape.pendingInsertion(11),
  "a repeated stale snapshot discarded the provisional shape");
delete state.snapshot.stale;
state.snapshot.snapshot_id = "queued-insert-rebased";
assert.equal(shape.reconcile(state.snapshot), null);
assert.equal(messages.length, messageCountBeforeQueuedInsert + 1);
assert.equal(messages.at(-1).snapshotId, "queued-insert-rebased");

function snapshot(id, shapes) {
  return {
    snapshot_id: id,
    layout: { pages: [{ id: 11, width: 1280, height: 720 }], objects: [] },
    editing: [],
    page_editing: [{ page_id: 11, insert_shapes: true }],
    shape_editing: shapes,
  };
}
