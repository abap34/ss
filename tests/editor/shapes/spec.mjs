#!/usr/bin/env node
import assert from "node:assert/strict";
import {
  defaultShapeStyle,
  ShapeController,
} from "../../../editor/vscode/media/editor/shape-insertion.js";
import { resizedBounds } from "../../../editor/vscode/media/editor/interaction.js";

const state = {
  snapshot: snapshot("initial", []),
  currentPageId: 11,
  selectedObjectId: null,
  shapeTool: "select",
  shapeStyle: structuredClone(defaultShapeStyle),
};
assert.equal(defaultShapeStyle.arrowStart, false);
assert.equal(defaultShapeStyle.arrowEnd, false);
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
  arrowStart: false,
  arrowEnd: false,
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
  route: "straight",
  start: { x: 1, y: 0 },
  end: { x: 0, y: 1 },
  arrow_start: false,
  arrow_end: false,
  stroke: { ...defaultShapeStyle.stroke },
};
state.snapshot = snapshot("line-target", [lineTarget]);
assert.equal(shape.editStyle(lineTarget, {
  stroke: { ...lineTarget.stroke, width: 3, style: "dashed" },
  arrowStart: true,
  arrowEnd: false,
}), true);
assert.equal(messages.length, 5);
assert.equal(messages[4].kind, "line");
assert.equal(messages[4].stroke.width, 3);
assert.equal(messages[4].arrowStart, true);
assert.equal(messages[4].arrowEnd, false);
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

state.snapshot = snapshot("continuous-base", [lineTarget]);
const continuousTarget = shape.styleTarget(102);
const continuousMessageCount = messages.length;
assert.equal(shape.editStyle(continuousTarget, {
  stroke: { ...continuousTarget.stroke, color: "#dc2626" },
  arrowStart: true,
  arrowEnd: false,
}), true);
assert.equal(messages.length, continuousMessageCount + 1);
const continuousStyleRequest = messages.at(-1);
assert.equal(shape.editLineGeometry(
  continuousTarget,
  { x: 720, y: 140 },
  { x: 500, y: 330 },
), true);
assert.equal(messages.length, continuousMessageCount + 1,
  "a follow-up edit was sent before the first source edit rebuilt");
assert.equal(shape.canEdit(continuousTarget), true,
  "an in-flight edit disabled the same shape");
shape.acceptResult({
  type: "shapeEditResult",
  requestId: continuousStyleRequest.requestId,
  operation: "style",
  status: "applied",
});
const failedBuild = snapshot("continuous-failed", [lineTarget]);
failedBuild.stale = true;
state.snapshot = failedBuild;
shape.reconcile(failedBuild);
assert.equal(shape.isBusy(), true,
  "a failed build discarded the queued follow-up edit");
assert.equal(shape.canEdit(continuousTarget), true,
  "a failed build disabled editing of the retained shape");
assert.deepEqual(shape.pendingLineGeometry(102), {
  nodeId: 102,
  pageId: 11,
  start: { x: 720, y: 140 },
  end: { x: 500, y: 330 },
});
const rebuiltLineTarget = { ...lineTarget, node_id: 202 };
state.snapshot = snapshot("continuous-rebuilt", [rebuiltLineTarget]);
shape.reconcile(state.snapshot);
assert.equal(messages.length, continuousMessageCount + 2);
assert.equal(messages.at(-1).snapshotId, "continuous-rebuilt");
assert.equal(messages.at(-1).nodeId, 202);
shape.acceptResult({
  type: "shapeEditResult",
  requestId: messages.at(-1).requestId,
  operation: "geometry",
  status: "rejected",
});

const rectangleTarget = {
  node_id: 101,
  page_id: 11,
  binding: "rectangle_item",
  kind: "rectangle",
  resize: true,
  fill: { ...defaultShapeStyle.fill },
  stroke: { ...defaultShapeStyle.stroke },
};
state.snapshot = snapshot("rectangle-target", [rectangleTarget]);
assert.equal(shape.editBounds(
  rectangleTarget,
  { x: 80, y: 90, width: 240, height: 64 },
), true);
assert.deepEqual(messages.at(-1), {
  type: "editShapeBounds",
  requestId: messages.at(-1).requestId,
  snapshotId: state.snapshot.snapshot_id,
  nodeId: 101,
  pageId: 11,
  kind: "rectangle",
  bounds: { x: 80, y: 90, width: 240, height: 64 },
});
assert.deepEqual(shape.pendingBounds(101)?.bounds, {
  x: 80,
  y: 90,
  width: 240,
  height: 64,
});
shape.acceptResult({
  type: "shapeEditResult",
  requestId: messages.at(-1).requestId,
  operation: "resize",
  status: "rejected",
});
assert.equal(shape.pendingBounds(101), null);
assert.equal(shape.editBounds({ ...rectangleTarget, resize: false }, {
  x: 80,
  y: 90,
  width: 240,
  height: 64,
}), false);

assert.deepEqual(
  resizedBounds(
    { x: 100, y: 100, width: 160, height: 100 },
    "top",
    { x: 180, y: 60 },
    { width: 1280, height: 720 },
  ),
  { x: 100, y: 60, width: 160, height: 140 },
);
assert.deepEqual(
  resizedBounds(
    { x: 100, y: 100, width: 160, height: 100 },
    "bottom-right",
    { x: 320, y: 260 },
    { width: 1280, height: 720 },
  ),
  { x: 100, y: 100, width: 220, height: 160 },
);
assert.deepEqual(
  resizedBounds(
    { x: 100, y: 100, width: 160, height: 100 },
    "left",
    { x: 500, y: 150 },
    { width: 1280, height: 720 },
  ),
  { x: 256, y: 100, width: 4, height: 100 },
);

state.snapshot.stale = true;
const messageCountBeforeQueuedResize = messages.length;
assert.equal(shape.editBounds(
  rectangleTarget,
  { x: 72, y: 84, width: 260, height: 72 },
), true);
assert.equal(messages.length, messageCountBeforeQueuedResize,
  "a resize based on a stale preview was sent before rebuilding");
state.snapshot = snapshot("queued-resize-rebased", [{
  ...rectangleTarget,
  node_id: 111,
}]);
assert.equal(shape.reconcile(state.snapshot), null);
assert.equal(messages.length, messageCountBeforeQueuedResize + 1);
assert.equal(messages.at(-1).nodeId, 111);
assert.deepEqual(shape.pendingBounds(111)?.bounds, {
  x: 72,
  y: 84,
  width: 260,
  height: 72,
});
shape.acceptResult({
  type: "shapeEditResult",
  requestId: messages.at(-1).requestId,
  operation: "resize",
  status: "rejected",
});

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
shape.acceptResult({
  type: "shapeEditResult",
  requestId: messages.at(-1).requestId,
  operation: "insert",
  status: "rejected",
});
shape.selectTool("elbow_line");
shape.setDraft({
  ...state.shapeStyle,
  arrowStart: true,
  arrowEnd: true,
});
assert.equal(shape.insert(11, {
  start: { x: 120, y: 180 },
  end: { x: 360, y: 320 },
}), true);
assert.equal(messages.at(-1).kind, "elbow_line");
assert.equal(messages.at(-1).arrowStart, true);
assert.equal(messages.at(-1).arrowEnd, true);
assert.equal(Object.hasOwn(messages.at(-1), "bounds"), false);

function snapshot(id, shapes) {
  return {
    snapshot_id: id,
    layout: { pages: [{ id: 11, width: 1280, height: 720 }], objects: [] },
    editing: [],
    page_editing: [{ page_id: 11, insert_shapes: true }],
    shape_editing: shapes,
  };
}
