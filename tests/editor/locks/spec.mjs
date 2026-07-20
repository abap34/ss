#!/usr/bin/env node
import assert from "node:assert/strict";
import { ObjectLockController } from "../../../editor/vscode/media/editor/object-locks.js";

const state = { snapshot: snapshot(50, 51) };
let persisted = null;
let renders = 0;
const locks = new ObjectLockController(state, {
  persist: (value) => persisted = structuredClone(value),
  render: () => renders += 1,
});

locks.reconcile(state.snapshot);
assert.equal(locks.canLock(50), true);
assert.equal(locks.canLock(51), true, "a child did not inherit its editable ancestor lock");
assert.equal(locks.canLock(60), false);
assert.equal(locks.toggle(51), true);
assert.equal(locks.isLocked(50), true);
assert.equal(locks.isLocked(51), true);
assert.equal(renders, 1);
assert.equal(persisted.entryPath, "/workspace/slide.ss");
assert.equal(persisted.keys.length, 1);

state.snapshot = snapshot(150, 151);
locks.reconcile(state.snapshot);
assert.equal(
  locks.isLocked(150),
  true,
  "a full rebuild with new node ids lost a source-identified lock",
);

const restored = new ObjectLockController(state, {
  persist: () => {},
  render: () => {},
}, persisted);
restored.reconcile(state.snapshot);
assert.equal(restored.isLocked(151), true, "a restored webview lost its locks");

const other = snapshot(250, 251);
other.entry_path = "/workspace/other.ss";
state.snapshot = other;
restored.reconcile(other);
assert.equal(restored.isLocked(250), false, "locks leaked into another entry file");

function snapshot(rootId, childId) {
  return {
    entry_path: "/workspace/slide.ss",
    editing: [{
      node_id: rootId,
      page_id: 22,
      page_index: 2,
      page_name: "Details",
      binding: "background",
      statement_start: 40,
      path: "/workspace/slide.ss",
    }],
    outline: [
      { id: rootId, parent_id: 22 },
      { id: childId, parent_id: rootId },
      { id: 60, parent_id: 22 },
    ],
  };
}
