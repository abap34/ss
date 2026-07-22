#!/usr/bin/env node
import assert from "node:assert/strict";
import { TranslationController } from "../../../editor/vscode/media/editor/translation.js";

const firstPage = { id: 11, width: 1280, height: 720 };
const secondPage = { id: 22, width: 1280, height: 720 };
const firstObject = object(101, firstPage.id, 100, 120);
const secondObject = object(202, secondPage.id, 240, 180);
const state = {
  snapshot: snapshot("initial", [firstObject, secondObject]),
};
const messages = [];
const translation = new TranslationController(state, {
  post: (message) => messages.push(structuredClone(message)),
  render: () => {},
});

assert.equal(translation.canDrag(firstObject.id), true);
assert.equal(translation.canDrag(secondObject.id), true);

translation.submit(edit(state.snapshot, firstObject, 30, 20));
assert.equal(messages.length, 1);
assert.equal(messages[0].nodeId, firstObject.id);
assert.deepEqual(
  position(translation.frame(firstPage, firstObject)),
  { x: 130, y: 140 },
);

translation.submit(edit(state.snapshot, secondObject, -15, 25));
assert.equal(
  messages.length,
  1,
  "a second local translation was sent with an obsolete snapshot",
);
assert.deepEqual(
  position(translation.frame(secondPage, secondObject)),
  { x: 225, y: 205 },
);

assert.deepEqual(
  translation.acceptResult({
    requestId: messages[0].requestId,
    status: "applied",
    documentVersion: 2,
  }),
  { status: "applied" },
);

const movedFirst = object(firstObject.id, firstPage.id, 130, 140);
state.snapshot = snapshot("after-first", [movedFirst, secondObject]);
assert.equal(translation.reconcile(state.snapshot, 2), null);
assert.equal(messages.length, 2);
assert.equal(messages[1].snapshotId, "after-first");
assert.equal(messages[1].nodeId, secondObject.id);
assert.deepEqual(position(messages[1].toBounds), { x: 225, y: 205 });
assert.deepEqual(
  position(translation.frame(secondPage, secondObject)),
  { x: 225, y: 205 },
  "authoritative reconciliation displaced the queued local translation",
);

assert.deepEqual(
  translation.acceptResult({
    requestId: messages[1].requestId,
    status: "rejected",
    message: "rejected for test",
  }),
  { status: "failed", message: "rejected for test" },
);
assert.deepEqual(
  position(translation.frame(secondPage, secondObject)),
  { x: 240, y: 180 },
);

state.snapshot = snapshot("failed-build", [movedFirst, secondObject]);
state.snapshot.stale = true;
translation.submit(edit(state.snapshot, movedFirst, 18, -12));
assert.equal(messages.length, 2,
  "a translation based on a stale preview was sent before rebuilding");
assert.deepEqual(
  position(translation.frame(firstPage, movedFirst)),
  { x: 148, y: 128 },
  "a queued translation was not reflected in the provisional preview",
);
assert.equal(translation.reconcile(state.snapshot, 3), null);
assert.deepEqual(
  position(translation.frame(firstPage, movedFirst)),
  { x: 148, y: 128 },
  "a repeated stale snapshot discarded the queued translation",
);
state.snapshot = snapshot("recovered-build", [movedFirst, secondObject]);
assert.equal(translation.reconcile(state.snapshot, 3), null);
assert.equal(messages.length, 3);
assert.equal(messages[2].snapshotId, "recovered-build");
assert.equal(messages[2].nodeId, movedFirst.id);
translation.acceptResult({
  requestId: messages[2].requestId,
  status: "applied",
  documentVersion: 4,
});
const failedAfterApply = snapshot("failed-after-apply", [movedFirst, secondObject]);
failedAfterApply.stale = true;
state.snapshot = failedAfterApply;
assert.equal(translation.reconcile(state.snapshot, 4), null);
assert.deepEqual(
  position(translation.frame(firstPage, movedFirst)),
  { x: 148, y: 128 },
  "a failed build discarded an applied provisional translation",
);
const recoveredFirst = object(movedFirst.id, firstPage.id, 148, 128);
state.snapshot = snapshot("recovered-after-apply", [recoveredFirst, secondObject]);
assert.equal(translation.reconcile(state.snapshot, 4), null);
assert.deepEqual(
  position(translation.frame(firstPage, recoveredFirst)),
  { x: 148, y: 128 },
  "an authoritative translation retained the provisional offset twice",
);

state.snapshot = snapshot("cancel-target", [recoveredFirst, secondObject]);
translation.submit(edit(state.snapshot, secondObject, 12, 14));
assert.equal(translation.cancelNode(secondObject.id), true);
assert.deepEqual(
  position(translation.frame(secondPage, secondObject)),
  { x: 240, y: 180 },
  "cancelling a component edit retained its provisional translation",
);

function snapshot(id, objects) {
  return {
    snapshot_id: id,
    layout: { pages: [firstPage, secondPage], objects },
    outline: objects.map((item) => ({
      id: item.id,
      parent_id: item.page_id,
      page_id: item.page_id,
    })),
  };
}

function object(id, pageId, x, top) {
  return {
    id,
    page_id: pageId,
    x,
    y: 720 - top - 40,
    width: 80,
    height: 40,
  };
}

function edit(current, item, dx, dy) {
  const page = current.layout.pages.find((candidate) =>
    candidate.id === item.page_id
  );
  const frame = {
    x: item.x,
    y: page.height - item.y - item.height,
    width: item.width,
    height: item.height,
  };
  return {
    snapshotId: current.snapshot_id,
    nodeId: item.id,
    pageId: item.page_id,
    mode: "absolute",
    fromBounds: frame,
    toBounds: { ...frame, x: frame.x + dx, y: frame.y + dy },
  };
}

function position(value) {
  return { x: value.x, y: value.y };
}
