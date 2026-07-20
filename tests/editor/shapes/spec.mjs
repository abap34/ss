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
  shape.insert(11, { x: 120, y: 140, width: 180, height: 110 }),
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

state.snapshot.stale = true;
assert.equal(shape.canInsert(11), false);
assert.equal(shape.editStyle(target, target), false);

function snapshot(id, shapes) {
  return {
    snapshot_id: id,
    layout: { pages: [{ id: 11, width: 1280, height: 720 }], objects: [] },
    editing: [],
    page_editing: [{ page_id: 11, insert_shapes: true }],
    shape_editing: shapes,
  };
}
