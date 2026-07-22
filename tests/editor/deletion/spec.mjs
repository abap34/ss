#!/usr/bin/env node
import assert from "node:assert/strict";
import { ComponentDeletionController } from "../../../editor/vscode/media/editor/component-deletion.js";
import { InteractionController } from "../../../editor/vscode/media/editor/interaction.js";

const messages = [];
const cancelled = [];
const state = {
  snapshot: snapshot("initial", 10),
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
assert.deepEqual(cancelled, [10]);
assert.deepEqual(messages[0], {
  type: "deleteComponent",
  requestId: 1,
  snapshotId: "initial",
  nodeId: 10,
  pageId: 1,
});
assert.equal(deletion.isDeleting(10), true);
assert.equal(deletion.isDeleting(11), true,
  "deleting a component did not hide its rendered descendants");
const renderedRoot = fakeRoot([10, 11]);
deletion.applyPreview(renderedRoot, 1);
assert.equal(renderedRoot.items.get(10).classes.has(
  "ss-pending-component-deletion",
), true, "deleting a component did not hide its last successful rendering");
assert.equal(renderedRoot.items.get(11).classes.has(
  "ss-pending-component-deletion",
), true, "deleting a component did not hide a rendered descendant");
assert.equal(deletion.reconcile(state.snapshot, 1), null);
deletion.acceptResult({
  type: "componentDeleteResult",
  requestId: 1,
  status: "applied",
  documentVersion: 2,
});
const failedSnapshot = snapshot("failed", 10);
failedSnapshot.stale = true;
assert.equal(deletion.reconcile(failedSnapshot, 2), null);
assert.equal(deletion.isDeleting(10), true,
  "a failed build restored a component whose source deletion is pending");
assert.deepEqual(deletion.reconcile(snapshot("deleted", null), 2), {
  status: "applied",
});
assert.equal(deletion.isDeleting(10), false);

state.snapshot = snapshot("stale", 20);
state.snapshot.stale = true;
state.selectedObjectId = 20;
assert.equal(deletion.deleteSelected(), true);
assert.equal(messages.length, 1,
  "a deletion based on a stale preview was sent before rebuilding");
state.snapshot = snapshot("rebuilt", 30);
assert.equal(deletion.reconcile(state.snapshot, 3), null);
assert.equal(messages.length, 2);
assert.equal(messages[1].snapshotId, "rebuilt");
assert.equal(messages[1].nodeId, 30);
assert.deepEqual(deletion.acceptResult({
  type: "componentDeleteResult",
  requestId: 2,
  status: "rejected",
  message: "dependent source reference",
}), {
  status: "failed",
  message: "dependent source reference",
});

let keydown;
globalThis.window = {
  addEventListener(type, handler) {
    if (type === "keydown") keydown = handler;
  },
};
let deletedByKeyboard = 0;
new InteractionController({
  snapshot: snapshot("keyboard", 40),
  selectedObjectId: 40,
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

function snapshot(id, nodeId) {
  const editing = nodeId == null ? [] : [{
    node_id: nodeId,
    page_id: 1,
    binding: "item",
  }];
  return {
    snapshot_id: id,
    editing,
    outline: nodeId == null ? [] : [
      { id: nodeId, parent_id: null, page_id: 1 },
      { id: nodeId + 1, parent_id: nodeId, page_id: 1 },
    ],
    layout: {
      pages: [{ id: 1 }],
      objects: nodeId == null ? [] : [{ id: nodeId, page_id: 1 }],
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
