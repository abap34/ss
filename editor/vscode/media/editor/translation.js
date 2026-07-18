import { previewFrame, subtreeNodeIds } from "./geometry.js";

const positionTolerance = 0.25;

export class TranslationController {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.pending = null;
    this.nextRequestId = 1;
  }

  canDrag(nodeId) {
    return this.pending == null || this.pending.nodeId === nodeId;
  }

  frame(page, object) {
    const frame = previewFrame(page, object);
    if (!this.affects(page.id, object.id)) return frame;
    const offset = this.offset();
    return { ...frame, x: frame.x + offset.x, y: frame.y + offset.y };
  }

  submit(edit) {
    if (this.pending) {
      if (
        this.pending.nodeId !== edit.nodeId ||
        this.pending.pageId !== edit.pageId
      ) return false;
      this.pending.desired = { ...edit.toBounds };
      this.pending.mode = edit.mode;
      this.pending.changedAfterRequest = !samePosition(
        this.pending.sent.toBounds,
        this.pending.desired,
      );
      this.actions.render();
      return true;
    }

    this.pending = {
      nodeId: edit.nodeId,
      pageId: edit.pageId,
      nodeIds: new Set(subtreeNodeIds(this.state.snapshot, edit.nodeId)),
      desired: { ...edit.toBounds },
      mode: edit.mode,
      phase: "requested",
      changedAfterRequest: false,
      sent: this.send(edit),
    };
    this.actions.render();
    return true;
  }

  acceptResult(message) {
    if (!this.pending || message.requestId !== this.pending.sent.requestId) {
      return null;
    }
    if (message.status === "applied") {
      this.pending.phase = "applied";
      this.pending.appliedDocumentVersion = message.documentVersion;
      return null;
    }
    if (message.status === "stale") {
      this.pending.phase = "stale";
      return null;
    }

    const error = message.message || "The edit could not be applied.";
    this.pending = null;
    return error;
  }

  reconcile(snapshot, documentVersion) {
    const pending = this.pending;
    if (!pending) return null;
    if (snapshot.stale) {
      this.pending = null;
      return null;
    }
    if (pending.phase === "requested") return null;
    if (
      pending.phase === "applied" &&
      (!Number.isSafeInteger(documentVersion) ||
        documentVersion < pending.appliedDocumentVersion)
    ) return null;

    const page = snapshot.layout.pages.find((candidate) =>
      candidate.id === pending.pageId
    );
    const object = snapshot.layout.objects.find((candidate) =>
      candidate.id === pending.nodeId
    );
    if (!page || !object) {
      this.pending = null;
      return {
        status: "failed",
        message: "The updated object is no longer present in the preview.",
      };
    }

    const authoritative = previewFrame(page, object);
    if (samePosition(authoritative, pending.desired)) {
      this.pending = null;
      return { status: "updated" };
    }
    const needsFollowUp = pending.phase === "stale" ||
      pending.changedAfterRequest;
    if (!needsFollowUp) {
      this.pending = null;
      return {
        status: "failed",
        message: "The updated source did not reproduce the requested position.",
      };
    }

    const toBounds = {
      ...authoritative,
      x: pending.desired.x,
      y: pending.desired.y,
    };
    pending.nodeIds = new Set(subtreeNodeIds(snapshot, pending.nodeId));
    pending.phase = "requested";
    pending.changedAfterRequest = false;
    pending.sent = this.send({
      snapshotId: snapshot.snapshot_id,
      nodeId: pending.nodeId,
      pageId: pending.pageId,
      mode: pending.mode,
      fromBounds: authoritative,
      toBounds,
    });
    return null;
  }

  cancel() {
    const changed = this.pending != null;
    this.pending = null;
    return changed;
  }

  applyPreview(root, pageId) {
    for (const item of root.querySelectorAll("[data-ss-pending-translation]")) {
      item.style.removeProperty("translate");
      delete item.dataset.ssPendingTranslation;
    }
    if (!this.pending || this.pending.pageId !== pageId) return;
    const offset = this.offset();
    for (const nodeId of this.pending.nodeIds) {
      for (
        const item of root.querySelectorAll(`[data-ss-node-id="${nodeId}"]`)
      ) {
        item.style.translate = `${offset.x}pt ${offset.y}pt`;
        item.dataset.ssPendingTranslation = "true";
      }
    }
  }

  offset() {
    const pending = this.pending;
    if (!pending) return { x: 0, y: 0 };
    return {
      x: pending.desired.x - pending.sent.fromBounds.x,
      y: pending.desired.y - pending.sent.fromBounds.y,
    };
  }

  affects(pageId, nodeId) {
    return Boolean(
      this.pending?.pageId === pageId && this.pending.nodeIds.has(nodeId),
    );
  }

  send(edit) {
    const requestId = this.nextRequestId++;
    const message = {
      type: "translate",
      requestId,
      snapshotId: edit.snapshotId,
      nodeId: edit.nodeId,
      pageId: edit.pageId,
      mode: edit.mode,
      fromBounds: { ...edit.fromBounds },
      toBounds: { ...edit.toBounds },
    };
    this.actions.post(message);
    return message;
  }
}

function samePosition(left, right) {
  return Math.abs(left.x - right.x) < positionTolerance &&
    Math.abs(left.y - right.y) < positionTolerance;
}
