#!/usr/bin/env node
import assert from "node:assert/strict";
import { ComponentDeletionController } from "../../../editor/vscode/media/editor/component-deletion.js";
import { InteractionController } from "../../../editor/vscode/media/editor/interaction.js";

const messages = [];
const cancelled = [];
const state = {
  snapshot: snapshot("initial", [
    { nodeId: 10, binding: "first" },
    { nodeId: 20, binding: "second" },
  ]),
  selectedObjectId: 10,
  currentPageId: 1,
  shapeTool: "select",
};
const deletion = new ComponentDeletionController(state, {
  post: (message) => messages.push(structuredClone(message)),
  render() {},
  cancelEdits: (target) => cancelled.push(target.node_id),
});

assert.equal(deletion.deleteSelected(), true);
assert.equal(state.selectedObjectId, null);
assert.deepEqual(messages[0], {
  type: "deleteComponent",
  requestId: 1,
  snapshotId: "initial",
  nodeId: 10,
  pageId: 1,
});
state.selectedObjectId = 20;
assert.equal(deletion.deleteSelected(), true,
  "an in-flight deletion prevented queuing another component");
assert.equal(messages.length, 1,
  "continuous deletion sent two source edits against the same snapshot");
assert.deepEqual(cancelled, [10, 20]);
for (const nodeId of [10, 11, 20, 21]) {
  assert.equal(deletion.isDeleting(nodeId), true,
    `queued deletion did not hide node ${nodeId}`);
}

const renderedRoot = fakeRoot([10, 11, 20, 21]);
deletion.applyPreview(renderedRoot, 1);
for (const nodeId of [10, 11, 20, 21]) {
  assert.equal(renderedRoot.items.get(nodeId).classes.has(
    "ss-pending-component-deletion",
  ), true, `queued deletion did not hide rendered node ${nodeId}`);
}

deletion.acceptResult({
  type: "componentDeleteResult",
  requestId: 1,
  status: "applied",
  documentVersion: 2,
});
const failedSnapshot = snapshot("failed", [
  { nodeId: 10, binding: "first" },
  { nodeId: 20, binding: "second" },
]);
failedSnapshot.stale = true;
state.snapshot = failedSnapshot;
assert.equal(deletion.reconcile(failedSnapshot, 2), null);
assert.equal(deletion.isDeleting(10), true,
  "a failed build restored an applied provisional deletion");
assert.equal(deletion.isDeleting(20), true,
  "a failed build restored a queued provisional deletion");

const afterFirst = snapshot("after-first", [
  { nodeId: 30, binding: "second" },
]);
state.snapshot = afterFirst;
assert.deepEqual(deletion.reconcile(afterFirst, 2), { status: "applied" });
assert.equal(messages.length, 2,
  "the next queued deletion was not sent after rebuilding");
assert.deepEqual(messages[1], {
  type: "deleteComponent",
  requestId: 2,
  snapshotId: "after-first",
  nodeId: 30,
  pageId: 1,
});
assert.equal(deletion.isDeleting(10), false);
assert.equal(deletion.isDeleting(30), true);
assert.deepEqual(deletion.acceptResult({
  type: "componentDeleteResult",
  requestId: 2,
  status: "rejected",
  message: "dependent source reference",
}), {
  status: "failed",
  message: "dependent source reference",
});
assert.equal(deletion.isDeleting(30), false,
  "a rejected queued deletion remained hidden");

state.snapshot = snapshot("stale", [{ nodeId: 40, binding: "third" }]);
state.snapshot.stale = true;
state.selectedObjectId = 40;
assert.equal(deletion.deleteSelected(), true);
assert.equal(messages.length, 2,
  "a deletion based on a stale preview was sent before rebuilding");
state.snapshot = snapshot("rebuilt", [{ nodeId: 50, binding: "third" }]);
assert.equal(deletion.reconcile(state.snapshot, 3), null);
assert.equal(messages.length, 3);
assert.equal(messages[2].snapshotId, "rebuilt");
assert.equal(messages[2].nodeId, 50);
assert.deepEqual(deletion.acceptResult({
  type: "componentDeleteResult",
  requestId: 3,
  status: "rejected",
  message: "rejected after rebase",
}), {
  status: "failed",
  message: "rejected after rebase",
});

let keydown;
globalThis.window = {
  addEventListener(type, handler) {
    if (type === "keydown") keydown = handler;
  },
};
let deletedByKeyboard = 0;
new InteractionController({
  snapshot: snapshot("keyboard", [{ nodeId: 60, binding: "keyboard" }]),
  selectedObjectId: 60,
  currentPageId: 1,
  shapeTool: "select",
}, {
  componentDeletion: {
    deleteSelected() {
      deletedByKeyboard += 1;
      return true;
    },
  },
  objectLocks: { isLocked: () => false },
  shape: { supportsInsertion: () => false },
});
const deleteEvent = keyboardEvent("Delete");
keydown(deleteEvent);
assert.equal(deleteEvent.prevented, true);
assert.equal(deletedByKeyboard, 1);
const typingBackspace = keyboardEvent("Backspace", {
  closest: () => ({ tagName: "INPUT" }),
});
keydown(typingBackspace);
assert.equal(typingBackspace.prevented, false);
assert.equal(deletedByKeyboard, 1,
  "Backspace in an input deleted the selected component");

function snapshot(id, targets) {
  return {
    snapshot_id: id,
    editing: targets.map((target) => ({
      node_id: target.nodeId,
      page_id: 1,
      binding: target.binding,
    })),
    outline: targets.flatMap((target) => [
      { id: target.nodeId, parent_id: null, page_id: 1 },
      { id: target.nodeId + 1, parent_id: target.nodeId, page_id: 1 },
    ]),
    layout: {
      pages: [{ id: 1 }],
      objects: targets.map((target) => ({
        id: target.nodeId,
        page_id: 1,
      })),
    },
  };
}

function keyboardEvent(key, target = {}) {
  return {
    key,
    target,
    defaultPrevented: false,
    metaKey: false,
    ctrlKey: false,
    altKey: false,
    shiftKey: false,
    prevented: false,
    preventDefault() {
      this.defaultPrevented = true;
      this.prevented = true;
    },
  };
}

function fakeRoot(nodeIds) {
  const items = new Map(nodeIds.map((nodeId) => [nodeId, fakeClassItem()]));
  return {
    items,
    querySelectorAll(selector) {
      if (selector === ".ss-pending-component-deletion") return [];
      const match = selector.match(/data-ss-node-id="(\d+)"/);
      return match && items.has(Number(match[1]))
        ? [items.get(Number(match[1]))]
        : [];
    },
  };
}

function fakeClassItem() {
  const classes = new Set();
  return {
    classes,
    classList: {
      add: (name) => classes.add(name),
      remove: (name) => classes.delete(name),
    },
  };
}
