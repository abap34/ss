import { editableAncestorNodeId } from "./geometry.js";
import { editingTargetByNode } from "./editing-target.js";

const schema = 1;

export class ObjectLockController {
  constructor(state, actions, persisted) {
    this.state = state;
    this.actions = actions;
    this.persisted = validPersistedLocks(persisted) ? persisted : null;
    this.entryPath = null;
    this.lockedKeys = new Set();
  }

  reconcile(snapshot) {
    if (!snapshot || snapshot.entry_path === this.entryPath) return;
    this.entryPath = snapshot.entry_path;
    this.lockedKeys = new Set(
      this.persisted?.entryPath === this.entryPath
        ? this.persisted.keys
        : [],
    );
  }

  canLock(nodeId) {
    return this.target(nodeId) != null;
  }

  isLocked(nodeId) {
    const target = this.target(nodeId);
    return target != null && this.lockedKeys.has(objectLockKey(target));
  }

  toggle(nodeId) {
    const target = this.target(nodeId);
    if (!target) return false;
    const key = objectLockKey(target);
    if (this.lockedKeys.has(key)) this.lockedKeys.delete(key);
    else this.lockedKeys.add(key);
    this.persisted = this.serialized();
    this.actions.persist(this.persisted);
    this.actions.render();
    return true;
  }

  serialized() {
    return {
      schema,
      entryPath: this.entryPath,
      keys: [...this.lockedKeys].sort(),
    };
  }

  target(nodeId) {
    const snapshot = this.state.snapshot;
    if (!snapshot) return null;
    const targetNodeId = editableAncestorNodeId(snapshot, nodeId);
    if (targetNodeId == null) return null;
    return editingTargetByNode(snapshot, targetNodeId);
  }
}

export function objectLockKey(target) {
  const page = target.page_name || `#${target.page_index}`;
  const binding = target.binding || `@${target.statement_start}`;
  return JSON.stringify([target.path, page, binding]);
}

function validPersistedLocks(value) {
  return value?.schema === schema && typeof value.entryPath === "string" &&
    Array.isArray(value.keys) && value.keys.every((key) =>
      typeof key === "string"
    );
}
