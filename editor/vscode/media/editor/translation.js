import { previewFrame, subtreeNodeIds } from "./geometry.js";

const positionTolerance = 0.25;

export class TranslationController {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.pending = new Map();
    this.inFlight = null;
    this.nextRequestId = 1;
  }

  canDrag(_nodeId) {
    return true;
  }

  frame(page, object) {
    const frame = previewFrame(page, object);
    const offset = this.offsetFor(page.id, object.id);
    return { ...frame, x: frame.x + offset.x, y: frame.y + offset.y };
  }

  submit(edit) {
    const existing = this.pending.get(edit.nodeId);
    if (existing) {
      if (existing.pageId !== edit.pageId) return false;
      existing.desired = { ...edit.toBounds };
      existing.mode = edit.mode;
      return true;
    }

    const pending = {
      nodeId: edit.nodeId,
      pageId: edit.pageId,
      nodeIds: new Set(subtreeNodeIds(this.state.snapshot, edit.nodeId)),
      base: { ...edit.fromBounds },
      desired: { ...edit.toBounds },
      mode: edit.mode,
      phase: "queued",
      sent: null,
    };
    this.pending.set(edit.nodeId, pending);
    this.dispatch();
    return true;
  }

  acceptResult(message) {
    const pending = this.inFlight;
    if (!pending || message.requestId !== pending.sent?.requestId) {
      return null;
    }
    if (message.status === "applied") {
      pending.phase = "applied";
      pending.appliedDocumentVersion = message.documentVersion;
      this.inFlight = null;
      return { status: "applied" };
    }
    if (message.status === "stale") {
      pending.phase = "stale";
      this.inFlight = null;
      return null;
    }

    const error = message.message || "The edit could not be applied.";
    this.pending.delete(pending.nodeId);
    this.inFlight = null;
    this.dispatch();
    return { status: "failed", message: error };
  }

  reconcile(snapshot, documentVersion) {
    if (this.pending.size === 0) return null;
    if (snapshot.stale) {
      this.pending.clear();
      this.inFlight = null;
      return null;
    }
    let failure = null;
    for (const pending of [...this.pending.values()]) {
      if (pending.phase === "requested") continue;
      if (
        pending.phase === "applied" &&
        (!Number.isSafeInteger(documentVersion) ||
          documentVersion < pending.appliedDocumentVersion)
      ) continue;

      const page = snapshot.layout.pages.find((candidate) =>
        candidate.id === pending.pageId
      );
      const object = snapshot.layout.objects.find((candidate) =>
        candidate.id === pending.nodeId
      );
      if (!page || !object) {
        this.pending.delete(pending.nodeId);
        failure ??= {
          status: "failed",
          message: "The updated object is no longer present in the preview.",
        };
        continue;
      }

      const authoritative = previewFrame(page, object);
      if (samePosition(authoritative, pending.desired)) {
        this.pending.delete(pending.nodeId);
        continue;
      }
      if (pending.phase === "applied" && samePosition(
        authoritative,
        pending.sent.toBounds,
      )) {
        pending.base = authoritative;
        pending.nodeIds = new Set(subtreeNodeIds(snapshot, pending.nodeId));
        pending.phase = "queued";
        pending.sent = null;
        continue;
      }
      if (pending.phase === "stale" || pending.phase === "queued") {
        pending.base = authoritative;
        pending.nodeIds = new Set(subtreeNodeIds(snapshot, pending.nodeId));
        pending.phase = "queued";
        pending.sent = null;
        continue;
      }

      this.pending.delete(pending.nodeId);
      failure ??= {
        status: "failed",
        message: "The updated source did not reproduce the requested position.",
      };
    }
    this.dispatch();
    return failure;
  }

  cancel() {
    const changed = this.pending.size !== 0;
    this.pending.clear();
    this.inFlight = null;
    return changed;
  }

  applyPreview(root, pageId) {
    for (const item of root.querySelectorAll("[data-ss-pending-translation]")) {
      const base = baseTranslation(item);
      if (base.x === 0 && base.y === 0) item.style.removeProperty("translate");
      else item.style.translate = `${base.x}pt ${base.y}pt`;
      delete item.dataset.ssPendingTranslation;
    }
    for (const pending of this.pending.values()) {
      if (pending.pageId !== pageId) continue;
      const offset = this.offset(pending);
      for (const nodeId of pending.nodeIds) {
        for (
          const item of root.querySelectorAll(`[data-ss-node-id="${nodeId}"]`)
        ) {
          const base = baseTranslation(item);
          item.style.translate = `${base.x + offset.x}pt ${base.y + offset.y}pt`;
          item.dataset.ssPendingTranslation = "true";
        }
      }
    }
  }

  offset(pending) {
    return {
      x: pending.desired.x - pending.base.x,
      y: pending.desired.y - pending.base.y,
    };
  }

  offsetFor(pageId, nodeId) {
    let x = 0;
    let y = 0;
    for (const pending of this.pending.values()) {
      if (pending.pageId !== pageId || !pending.nodeIds.has(nodeId)) continue;
      const offset = this.offset(pending);
      x += offset.x;
      y += offset.y;
    }
    return { x, y };
  }

  dispatch() {
    if (this.inFlight || !this.state.snapshot || this.state.snapshot.stale) {
      return;
    }
    const pending = [...this.pending.values()].find((candidate) =>
      candidate.phase === "queued"
    );
    if (!pending) return;
    const requestId = this.nextRequestId++;
    const message = {
      type: "translate",
      requestId,
      snapshotId: this.state.snapshot.snapshot_id,
      nodeId: pending.nodeId,
      pageId: pending.pageId,
      mode: pending.mode,
      fromBounds: { ...pending.base },
      toBounds: { ...pending.desired },
    };
    pending.phase = "requested";
    pending.sent = message;
    this.inFlight = pending;
    this.actions.post(message);
  }
}

function baseTranslation(item) {
  return {
    x: Number(item.dataset.ssBaseTranslationX || 0),
    y: Number(item.dataset.ssBaseTranslationY || 0),
  };
}

function samePosition(left, right) {
  return Math.abs(left.x - right.x) < positionTolerance &&
    Math.abs(left.y - right.y) < positionTolerance;
}
