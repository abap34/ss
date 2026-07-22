import { subtreeNodeIds } from "./geometry.js";

export class ComponentDeletionController {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.pending = null;
    this.nextRequestId = 1;
  }

  deleteSelected() {
    if (this.pending || !this.state.snapshot ||
        this.state.selectedObjectId == null) return false;
    const target = this.state.snapshot.editing?.find((candidate) =>
      candidate.node_id === this.state.selectedObjectId
    );
    if (!target) return false;
    this.actions.cancelEdits(target);
    const message = {
      type: "deleteComponent",
      requestId: this.nextRequestId++,
      snapshotId: this.state.snapshot.snapshot_id,
      nodeId: target.node_id,
      pageId: target.page_id,
    };
    this.pending = {
      phase: this.state.snapshot.stale ? "queued" : "requested",
      snapshotId: message.snapshotId,
      message,
      pageId: target.page_id,
      binding: target.binding,
      nodeIds: new Set(subtreeNodeIds(this.state.snapshot, target.node_id)),
    };
    this.state.selectedObjectId = null;
    if (this.pending.phase === "requested") this.actions.post(message);
    this.actions.render();
    return true;
  }

  acceptResult(message) {
    const pending = this.pending;
    if (!pending || message.requestId !== pending.message.requestId) return null;
    if (message.status === "applied") {
      pending.phase = "applied";
      pending.appliedDocumentVersion = message.documentVersion;
      return null;
    }
    if (message.status === "stale") {
      pending.phase = "queued";
      return null;
    }
    this.pending = null;
    this.actions.render();
    return {
      status: "failed",
      message: message.message || "The component could not be deleted.",
    };
  }

  reconcile(snapshot, documentVersion) {
    const pending = this.pending;
    if (!pending || snapshot.stale) return null;
    if (pending.phase === "queued") {
      const target = this.findTarget(snapshot, pending);
      if (!target) {
        this.pending = null;
        return {
          status: "failed",
          message: "The component changed before it could be deleted.",
        };
      }
      pending.snapshotId = snapshot.snapshot_id;
      pending.message.snapshotId = snapshot.snapshot_id;
      pending.message.nodeId = target.node_id;
      pending.message.pageId = target.page_id;
      pending.nodeIds = new Set(subtreeNodeIds(snapshot, target.node_id));
      pending.phase = "requested";
      this.actions.post(pending.message);
      return null;
    }
    if (pending.phase !== "applied" ||
        snapshot.snapshot_id === pending.snapshotId ||
        !Number.isSafeInteger(documentVersion) ||
        documentVersion < pending.appliedDocumentVersion) return null;
    if (this.findTarget(snapshot, pending)) {
      this.pending = null;
      return {
        status: "failed",
        message: "The rebuilt source still contains the component that was deleted.",
      };
    }
    this.pending = null;
    return { status: "applied" };
  }

  isDeleting(nodeId) {
    return this.pending?.nodeIds.has(nodeId) || false;
  }

  applyPreview(root, pageId) {
    for (const item of root.querySelectorAll(".ss-pending-component-deletion")) {
      item.classList.remove("ss-pending-component-deletion");
    }
    if (!this.pending || this.pending.pageId !== pageId) return;
    for (const nodeId of this.pending.nodeIds) {
      for (
        const item of root.querySelectorAll(`[data-ss-node-id="${nodeId}"]`)
      ) {
        item.classList.add("ss-pending-component-deletion");
      }
    }
  }

  findTarget(snapshot, pending) {
    return snapshot.editing?.find((candidate) =>
      candidate.page_id === pending.pageId &&
      candidate.binding === pending.binding
    ) || null;
  }
}
