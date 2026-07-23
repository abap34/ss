import { previewFrame } from "./geometry.js";

export const componentWidthPolicy = Object.freeze({
  minimum: 4,
  changeTolerance: 0.25,
});

export class ComponentWidthController {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.pending = new Map();
    this.inFlight = null;
    this.nextRequestId = 1;
  }

  canEdit(nodeId) {
    return this.target(nodeId) != null;
  }

  target(nodeId) {
    return this.state.snapshot?.editing?.find((candidate) =>
      candidate.node_id === nodeId
    ) || null;
  }

  frame(page, object, base = previewFrame(page, object)) {
    const pending = this.pendingForNode(object.id);
    return pending ? { ...base, width: pending.desired.width } : base;
  }

  submit(edit) {
    const target = this.target(edit.nodeId);
    if (!target || target.page_id !== edit.pageId) return false;
    const key = selectionKey(target.page_id, target.binding);
    const existing = this.pending.get(key);
    if (existing) {
      existing.desired = { ...edit.toBounds };
      this.actions.render();
      return true;
    }
    this.pending.set(key, {
      key,
      nodeId: target.node_id,
      pageId: target.page_id,
      binding: target.binding,
      base: { ...edit.fromBounds },
      desired: { ...edit.toBounds },
      phase: "queued",
      sent: null,
    });
    this.dispatch();
    this.actions.render();
    return true;
  }

  acceptResult(message) {
    const pending = this.inFlight;
    if (!pending || message.requestId !== pending.sent?.requestId) return null;
    if (message.status === "applied") {
      pending.phase = "applied";
      pending.appliedDocumentVersion = message.documentVersion;
      this.inFlight = null;
      return null;
    }
    if (message.status === "stale") {
      pending.phase = "queued";
      pending.sent = null;
      this.inFlight = null;
      return null;
    }
    this.pending.delete(pending.key);
    this.inFlight = null;
    this.dispatch();
    this.actions.render();
    return {
      status: "failed",
      message: message.message || "The component width could not be applied.",
    };
  }

  reconcile(snapshot, documentVersion) {
    if (this.pending.size === 0 || snapshot.stale) return null;
    let failure = null;
    let applied = false;
    for (const pending of [...this.pending.values()]) {
      if (pending.phase === "requested") continue;
      if (pending.phase === "applied" &&
          (!Number.isSafeInteger(documentVersion) ||
            documentVersion < pending.appliedDocumentVersion)) continue;

      const target = snapshot.editing?.find((candidate) =>
        candidate.page_id === pending.pageId &&
        candidate.binding === pending.binding
      );
      const page = snapshot.layout.pages.find((candidate) =>
        candidate.id === pending.pageId
      );
      const object = target && snapshot.layout.objects.find((candidate) =>
        candidate.id === target.node_id
      );
      if (!target || !page || !object) {
        this.pending.delete(pending.key);
        failure ??= {
          status: "failed",
          message: "The resized component is no longer present in the preview.",
        };
        continue;
      }

      pending.nodeId = target.node_id;
      const authoritative = previewFrame(page, object);
      if (sameWidth(authoritative, pending.desired)) {
        if (pending.phase === "applied") applied = true;
        this.pending.delete(pending.key);
        continue;
      }
      if (pending.phase === "applied" && sameWidth(
        authoritative,
        pending.sent.toBounds,
      )) {
        pending.base = authoritative;
        pending.phase = "queued";
        pending.sent = null;
        continue;
      }
      if (pending.phase === "queued") {
        pending.base = authoritative;
        pending.sent = null;
        continue;
      }

      this.pending.delete(pending.key);
      failure ??= {
        status: "failed",
        message: "The updated source did not reproduce the requested component width.",
      };
    }
    this.dispatch();
    return failure || (applied ? { status: "applied" } : null);
  }

  isPending(nodeId) {
    return this.pendingForNode(nodeId) != null;
  }

  cancelTarget(target) {
    const key = selectionKey(target.page_id, target.binding);
    const pending = this.pending.get(key);
    if (!pending) return false;
    this.pending.delete(key);
    if (this.inFlight === pending) this.inFlight = null;
    this.dispatch();
    return true;
  }

  applyPreview(root, pageId) {
    for (const item of root.querySelectorAll("[data-ss-pending-width]")) {
      item.style.width = item.dataset.ssBaseWidth;
      delete item.dataset.ssBaseWidth;
      delete item.dataset.ssPendingWidth;
    }
    for (const pending of this.pending.values()) {
      if (pending.pageId !== pageId) continue;
      this.applyNodeWidth(root, pending.nodeId, pending.desired.width);
    }
  }

  applyNodeWidth(root, nodeId, width) {
    for (const item of root.querySelectorAll(`[data-ss-node-id="${nodeId}"]`)) {
      if (!item.dataset.ssPendingWidth) {
        item.dataset.ssBaseWidth = item.style.width;
      }
      item.style.width = `${width}pt`;
      item.dataset.ssPendingWidth = "true";
    }
  }

  pendingForNode(nodeId) {
    for (const pending of this.pending.values()) {
      if (pending.nodeId === nodeId) return pending;
    }
    return null;
  }

  dispatch() {
    if (this.inFlight || !this.state.snapshot || this.state.snapshot.stale) return;
    const pending = [...this.pending.values()].find((candidate) =>
      candidate.phase === "queued"
    );
    if (!pending) return;
    const target = this.state.snapshot.editing?.find((candidate) =>
      candidate.page_id === pending.pageId &&
      candidate.binding === pending.binding
    );
    if (!target) return;
    pending.nodeId = target.node_id;
    const requestId = this.nextRequestId++;
    pending.sent = {
      type: "resizeComponentWidth",
      requestId,
      snapshotId: this.state.snapshot.snapshot_id,
      nodeId: pending.nodeId,
      pageId: pending.pageId,
      fromBounds: { ...pending.base },
      toBounds: { ...pending.desired },
    };
    pending.phase = "requested";
    this.inFlight = pending;
    this.actions.post(pending.sent);
  }
}

function selectionKey(pageId, binding) {
  return `${pageId}:${binding}`;
}

function sameWidth(left, right) {
  return Math.abs(left.width - right.width) <
    componentWidthPolicy.changeTolerance;
}
