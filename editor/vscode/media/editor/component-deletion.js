import { subtreeNodeIds } from "./geometry.js";

export class ComponentDeletionController {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.pending = new Map();
    this.inFlight = null;
    this.nextRequestId = 1;
  }

  deleteSelected() {
    if (!this.state.snapshot || this.state.selectedObjectId == null) return false;
    const target = this.state.snapshot.editing?.find((candidate) =>
      candidate.node_id === this.state.selectedObjectId
    );
    if (!target) return false;
    const key = deletionKey(target.page_id, target.binding);
    if (this.pending.has(key)) return false;

    this.actions.cancelEdits(target);
    this.pending.set(key, {
      key,
      phase: "queued",
      requestId: this.nextRequestId++,
      snapshotId: null,
      pageId: target.page_id,
      binding: target.binding,
      nodeId: target.node_id,
      nodeIds: new Set(subtreeNodeIds(this.state.snapshot, target.node_id)),
    });
    this.state.selectedObjectId = null;
    this.dispatch();
    this.actions.render();
    return true;
  }

  acceptResult(message) {
    const pending = this.inFlight;
    if (!pending || message.requestId !== pending.requestId) return null;
    this.inFlight = null;
    if (message.status === "applied") {
      pending.phase = "applied";
      pending.appliedDocumentVersion = message.documentVersion;
      return null;
    }
    if (message.status === "stale") {
      pending.phase = "stale";
      return null;
    }

    this.pending.delete(pending.key);
    this.dispatch();
    this.actions.render();
    return {
      status: "failed",
      message: message.message || "The component could not be deleted.",
    };
  }

  reconcile(snapshot, documentVersion) {
    if (this.pending.size === 0 || snapshot.stale) return null;
    let applied = false;
    let failure = null;

    for (const pending of [...this.pending.values()]) {
      if (pending.phase === "requested") continue;
      if (pending.phase === "applied") {
        if (snapshot.snapshot_id === pending.snapshotId ||
            !Number.isSafeInteger(documentVersion) ||
            documentVersion < pending.appliedDocumentVersion) continue;
        if (this.findTarget(snapshot, pending)) {
          this.pending.delete(pending.key);
          failure ??= {
            status: "failed",
            message: "The rebuilt source still contains a component that was deleted.",
          };
        } else {
          this.pending.delete(pending.key);
          applied = true;
        }
        continue;
      }

      const target = this.findTarget(snapshot, pending);
      if (!target) {
        this.pending.delete(pending.key);
        applied = true;
        continue;
      }
      this.updateTarget(snapshot, pending, target);
      pending.phase = "queued";
    }

    this.dispatch();
    return failure || (applied ? { status: "applied" } : null);
  }

  isDeleting(nodeId) {
    for (const pending of this.pending.values()) {
      if (pending.nodeIds.has(nodeId)) return true;
    }
    return false;
  }

  applyPreview(root, pageId) {
    for (const item of root.querySelectorAll(".ss-pending-component-deletion")) {
      item.classList.remove("ss-pending-component-deletion");
    }
    for (const pending of this.pending.values()) {
      if (pending.pageId !== pageId) continue;
      for (const nodeId of pending.nodeIds) {
        for (
          const item of root.querySelectorAll(`[data-ss-node-id="${nodeId}"]`)
        ) {
          item.classList.add("ss-pending-component-deletion");
        }
      }
    }
  }

  dispatch() {
    if (this.inFlight || !this.state.snapshot || this.state.snapshot.stale ||
        [...this.pending.values()].some((candidate) =>
          candidate.phase === "applied" || candidate.phase === "stale"
        )) return;
    const pending = [...this.pending.values()].find((candidate) =>
      candidate.phase === "queued"
    );
    if (!pending) return;
    const target = this.findTarget(this.state.snapshot, pending);
    if (!target) return;
    this.updateTarget(this.state.snapshot, pending, target);
    pending.phase = "requested";
    pending.snapshotId = this.state.snapshot.snapshot_id;
    this.inFlight = pending;
    this.actions.post({
      type: "deleteComponent",
      requestId: pending.requestId,
      snapshotId: pending.snapshotId,
      nodeId: pending.nodeId,
      pageId: pending.pageId,
    });
  }

  updateTarget(snapshot, pending, target) {
    pending.pageId = target.page_id;
    pending.nodeId = target.node_id;
    pending.nodeIds = new Set(subtreeNodeIds(snapshot, target.node_id));
  }

  findTarget(snapshot, pending) {
    return snapshot.editing?.find((candidate) =>
      candidate.page_id === pending.pageId &&
      candidate.binding === pending.binding
    ) || null;
  }
}

function deletionKey(pageId, binding) {
  return JSON.stringify([pageId, binding]);
}
