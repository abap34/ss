#!/usr/bin/env node
import assert from "node:assert/strict";
import { ComponentWidthController } from "../../../editor/vscode/media/editor/component-width.js";

const page = { id: 11, width: 1280, height: 720 };
const initialObject = object(101, 320);
const state = { snapshot: snapshot("initial", initialObject) };
const messages = [];
const controller = new ComponentWidthController(state, {
  post: (message) => messages.push(structuredClone(message)),
  render: () => {},
});

assert.equal(controller.canEdit(initialObject.id), true);
assert.equal(controller.minimum(initialObject.id), 6);
const initialFrame = frame(initialObject);
assert.equal(controller.submit({
  nodeId: initialObject.id,
  pageId: page.id,
  fromBounds: initialFrame,
  toBounds: { ...initialFrame, width: 420 },
}), true);
assert.equal(messages.length, 1);
assert.equal(messages[0].type, "resizeComponentWidth");
assert.equal(messages[0].snapshotId, "initial");
assert.equal(controller.frame(page, initialObject).width, 420);

controller.acceptResult({
  type: "componentWidthEditResult",
  requestId: messages[0].requestId,
  status: "applied",
  documentVersion: 2,
});
const stale = snapshot("failed", initialObject);
stale.stale = true;
state.snapshot = stale;
assert.equal(controller.reconcile(stale, 2), null);
assert.equal(controller.frame(page, initialObject).width, 420,
  "a failed build discarded the provisional component width");

const resizedObject = object(101, 420);
state.snapshot = snapshot("resized", resizedObject);
assert.deepEqual(
  controller.reconcile(state.snapshot, 2),
  { status: "applied" },
);
assert.equal(controller.frame(page, resizedObject).width, 420);

state.snapshot = snapshot("queued-stale", resizedObject);
state.snapshot.stale = true;
const queuedFrame = frame(resizedObject);
controller.submit({
  nodeId: resizedObject.id,
  pageId: page.id,
  fromBounds: queuedFrame,
  toBounds: { ...queuedFrame, width: 500 },
});
assert.equal(messages.length, 1,
  "a width edit based on a stale snapshot was sent before rebuilding");
assert.equal(controller.frame(page, resizedObject).width, 500);

const reboundObject = object(303, 420);
state.snapshot = snapshot("recovered", reboundObject);
assert.equal(controller.reconcile(state.snapshot, 3), null);
assert.equal(messages.length, 2);
assert.equal(messages[1].nodeId, reboundObject.id);
assert.equal(messages[1].snapshotId, "recovered");
assert.equal(messages[1].toBounds.width, 500);

assert.deepEqual(controller.acceptResult({
  type: "componentWidthEditResult",
  requestId: messages[1].requestId,
  status: "rejected",
  message: "rejected for test",
}), {
  status: "failed",
  message: "rejected for test",
});
assert.equal(controller.frame(page, reboundObject).width, 420);

state.snapshot = snapshot("continuous-initial", initialObject);
let currentObject = initialObject;
for (let step = 0; step < 30; step++) {
  const start = messages.length;
  const currentFrame = frame(currentObject);
  controller.submit({ nodeId: currentObject.id, pageId: page.id,
    fromBounds: currentFrame, toBounds: { ...currentFrame, width: currentObject.width + 10 } });
  const request = messages.at(-1);
  controller.acceptResult({ requestId: request.requestId, status: "stale" });
  controller.reconcile(state.snapshot, step + 20);
  assert.equal(messages.length, start + 1, "a stale width edit retried the same snapshot");
  state.snapshot = snapshot(`continuous-rebase-${step}`, currentObject);
  controller.reconcile(state.snapshot, step + 20);
  const retry = messages.at(-1);
  assert.notEqual(retry.requestId, request.requestId);
  controller.acceptResult({ requestId: request.requestId, status: "rejected" });
  assert.equal(controller.inFlight.sent.requestId, retry.requestId);
  controller.submit({ nodeId: currentObject.id, pageId: page.id,
    fromBounds: currentFrame, toBounds: { ...currentFrame, width: currentObject.width + 20 } });
  controller.acceptResult({ requestId: retry.requestId, status: "applied", documentVersion: step + 21 });
  controller.reconcile(state.snapshot, step + 21);
  assert.equal(messages.length, start + 2, "an applied width edit reused its request snapshot");
  currentObject = object(400 + step, currentObject.width + 10);
  state.snapshot = snapshot(`continuous-applied-${step}`, currentObject);
  controller.reconcile(state.snapshot, step + 20);
  assert.equal(messages.length, start + 2, "an older document version released a width edit");
  controller.reconcile(state.snapshot, step + 21);
  const followup = messages.at(-1);
  assert.equal(messages.length, start + 3);
  assert.equal(followup.nodeId, currentObject.id);
  assert.equal(followup.toBounds.width, currentObject.width + 10);
  controller.acceptResult({ requestId: followup.requestId, status: "applied", documentVersion: step + 22 });
  currentObject = object(currentObject.id, currentObject.width + 10);
  state.snapshot = snapshot(`continuous-final-${step}`, currentObject);
  controller.reconcile(state.snapshot, step + 22);
  assert.equal(controller.pending.size, 0);
}

function snapshot(id, item) {
  return {
    snapshot_id: id,
    layout: { pages: [page], objects: [item] },
    editing: [{
      node_id: item.id,
      page_id: page.id,
      binding: "item",
      binding_required: false,
      minimum_width: 6,
    }],
  };
}

function object(id, width) {
  return {
    id,
    page_id: page.id,
    x: 80,
    y: 520,
    width,
    height: 100,
  };
}

function frame(item) {
  return {
    x: item.x,
    y: page.height - item.y - item.height,
    width: item.width,
    height: item.height,
  };
}
