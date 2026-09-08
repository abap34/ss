import { EditQueue } from "./edit-queue.js";

/** @type {import("./edit-types.js").ShapeDraft} */
export const defaultShapeStyle = {
  fill: { enabled: true, color: "#e8f1ff", opacity: 1 },
  stroke: { enabled: true, color: "#2563eb", width: 1.6, style: "solid" },
  arrowStart: false,
  arrowEnd: false,
};

export class ShapeController {
  /** @param {import("./edit-types.js").ShapeState} state
   * @param {import("./edit-types.js").EditActions} actions */
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.nextRequestId = 1;
    /** @type {EditQueue<import("./edit-types.js").ShapeIntent, import("./edit-types.js").ShapeApplied>} */
    this.edits = new EditQueue({
      snapshot: () => this.state.snapshot,
      post: actions.post,
      render: actions.render,
      nextRequestId: () => this.nextRequestId++,
      sameSlot: sameQueueSlot,
      rebase: (snapshot, intent) => this.rebaseQueued(snapshot, intent),
      applied: (snapshot, intent, version) => this.selectApplied(snapshot, intent, version),
      discard: (intent) => {
        if (intent.operation === "insert") this.finishInsertionTool(intent);
      },
      failureMessage: "The shape edit could not be applied.",
    });
  }

  isBusy() {
    return this.edits.isBusy();
  }

  /** @param {import("../../src/editor/protocol.js").ShapeEditingCapability} target */
  canEdit(target) {
    return Boolean(this.state.snapshot?.shape_editing?.some((candidate) =>
      candidate.page_id === target.page_id &&
      candidate.binding === target.binding &&
      candidate.kind === target.kind
    ));
  }

  /** @param {number | null} pageId */
  supportsInsertion(pageId) {
    return Boolean(
      this.state.snapshot?.page_editing?.some((target) =>
        target.page_id === pageId && target.insert_shapes
      ),
    );
  }

  /** @param {number | null} pageId */
  canInsert(pageId) {
    return this.supportsInsertion(pageId);
  }

  /** @param {import("./edit-types.js").ShapeTool} tool */
  selectTool(tool) {
    if (tool !== "select" && !this.supportsInsertion(this.state.currentPageId)) {
      return;
    }
    this.state.pointerMode = "select";
    this.state.shapeTool = tool;
    this.actions.render();
  }

  /** @param {import("./edit-types.js").ShapeDraft} next */
  setDraft(next) {
    this.state.shapeStyle = cloneStyle(next);
    this.actions.render();
  }

  /** @param {number} pageId
   * @param {{ bounds: import("../../src/editor/protocol.js").Rect } | { start: import("../../src/editor/protocol.js").Point, end: import("../../src/editor/protocol.js").Point }} geometry */
  insert(pageId, geometry) {
    const kind = this.state.shapeTool;
    const snapshot = this.state.snapshot;
    if (!snapshot || kind === "select" || kind === "icon" || !this.canInsert(pageId)) return false;
    const common = { requestId: 0, snapshotId: snapshot.snapshot_id, pageId };
    /** @type {Extract<import("./edit-types.js").ShapeRequest, {type: "insertShape"}>} */
    let message;
    if (kind === "line" || kind === "elbow_line") {
      if (!("start" in geometry)) return false;
      message = {
        ...common, type: "insertShape", kind,
        start: { ...geometry.start },
        end: { ...geometry.end },
        arrowStart: this.state.shapeStyle.arrowStart,
        arrowEnd: this.state.shapeStyle.arrowEnd,
        stroke: { ...this.state.shapeStyle.stroke, enabled: true },
      };
    } else {
      if (!("bounds" in geometry)) return false;
      message = {
        ...common, type: "insertShape", kind,
        bounds: { ...geometry.bounds },
        fill: { ...this.state.shapeStyle.fill },
        stroke: { ...this.state.shapeStyle.stroke },
      };
    }
    const { type, requestId, snapshotId, ...preview } = message;
    return this.edits.enqueue({ operation: "insert", message, selection: null, preview });
  }

  /** @param {import("../../src/editor/protocol.js").ShapeEditingCapability} target
   * @param {import("./edit-types.js").ShapeStyleInput} style */
  editStyle(target, style) {
    if (!this.state.snapshot || !this.canEdit(target)) return false;
    this.state.shapeStyle = insertionStyleAfterEdit(
      this.state.shapeStyle,
      target,
      style,
    );
    /** @type {Extract<import("./edit-types.js").ShapeRequest, {type: "editShapeStyle"}>} */
    const message = {
      type: "editShapeStyle",
      requestId: 0,
      snapshotId: this.state.snapshot.snapshot_id,
      nodeId: target.node_id,
      pageId: target.page_id,
      stroke: { ...style.stroke },
      ...(target.kind === "line"
        ? {
          kind: target.kind,
          arrowStart: Boolean(style.arrowStart),
          arrowEnd: Boolean(style.arrowEnd),
        }
        : { kind: target.kind, fill: { ...(style.fill || target.fill) } }),
    };
    return this.edits.enqueue({
      operation: "style",
      message,
      selection: { pageId: target.page_id, binding: target.binding },
    });
  }

  /** @param {import("../../src/editor/protocol.js").ShapeEditingCapability} target
   * @param {import("../../src/editor/protocol.js").Point} start
   * @param {import("../../src/editor/protocol.js").Point} end */
  editLineGeometry(target, start, end) {
    if (!this.state.snapshot || !this.canEdit(target) ||
        target.kind !== "line") return false;
    /** @type {Extract<import("./edit-types.js").ShapeRequest, {type: "editLineGeometry"}>} */
    const message = {
      type: "editLineGeometry",
      requestId: 0,
      snapshotId: this.state.snapshot.snapshot_id,
      nodeId: target.node_id,
      pageId: target.page_id,
      start: { ...start },
      end: { ...end },
    };
    return this.edits.enqueue({
      operation: "geometry",
      message,
      selection: { pageId: target.page_id, binding: target.binding },
      geometry: {
        nodeId: target.node_id,
        pageId: target.page_id,
        start: { ...start },
        end: { ...end },
      },
    });
  }

  /** @param {import("../../src/editor/protocol.js").ShapeEditingCapability} target
   * @param {import("../../src/editor/protocol.js").Rect} bounds */
  editBounds(target, bounds) {
    if (!this.state.snapshot || !this.canEdit(target) ||
        target.kind === "line" || !target.resize) return false;
    /** @type {Extract<import("./edit-types.js").ShapeRequest, {type: "editShapeBounds"}>} */
    const message = {
      type: "editShapeBounds",
      requestId: 0,
      snapshotId: this.state.snapshot.snapshot_id,
      nodeId: target.node_id,
      pageId: target.page_id,
      kind: target.kind,
      bounds: { ...bounds },
    };
    return this.edits.enqueue({
      operation: "resize",
      message,
      selection: { pageId: target.page_id, binding: target.binding },
      bounds: {
        nodeId: target.node_id,
        pageId: target.page_id,
        kind: target.kind,
        bounds: { ...bounds },
        fill: { ...target.fill },
        stroke: { ...target.stroke },
      },
    });
  }

  /** @param {Extract<import("../../src/editor/protocol.js").HostMessage, {type: "shapeEditResult"}>} message */
  acceptResult(message) {
    return this.edits.acceptResult(message);
  }

  /** @param {import("./edit-types.js").Snapshot} snapshot
   * @param {number} [documentVersion] */
  reconcile(snapshot, documentVersion) {
    return this.edits.reconcile(snapshot, documentVersion);
  }

  /** @param {import("./edit-types.js").Snapshot} snapshot
   * @param {import("./edit-types.js").ShapeIntent} pending
   * @param {number} [documentVersion]
   * @returns {import("./edit-types.js").ShapeApplied | import("./edit-types.js").Failure | null} */
  selectApplied(snapshot, pending, documentVersion) {
    const selection = pending.selection;
    let target = null;
    if (selection) {
      target = snapshot.shape_editing?.find((candidate) =>
        candidate.page_id === selection.pageId &&
        candidate.binding === selection.binding
      );
    }
    if (pending.operation === "insert" && selection && !target) {
      if (documentVersion != null ||
          !snapshot.layout.pages.some((page) => page.id === selection.pageId)) {
        return queuedFailure("The inserted shape is no longer present in the rebuilt page.");
      }
      return null;
    }
    const selectAppliedTarget = pending.operation !== "insert" ||
      (!this.hasQueuedInsertion() &&
        this.state.shapeTool === pending.preview.kind);
    if (target && selectAppliedTarget) {
      this.actions.selectObject(target.node_id, target.page_id, false);
    }
    return {
      status: "applied",
      operation: pending.operation,
    };
  }

  cancel() {
    if (this.edits.cancelNewestQueued((intent) => intent.operation === "insert")) {
      return true;
    }
    if (this.state.shapeTool === "select" || this.state.shapeTool === "icon") {
      return false;
    }
    this.state.shapeTool = "select";
    this.actions.render();
    return true;
  }

  /** @param {{page_id: number, binding: string}} target */
  cancelTarget(target) {
    const selection = { pageId: target.page_id, binding: target.binding };
    return this.edits.cancelWhere((intent) => sameSelection(intent.selection, selection));
  }

  /** @param {number} nodeId */
  styleTarget(nodeId) {
    const target = this.state.snapshot?.shape_editing?.find((candidate) =>
      candidate.node_id === nodeId
    );
    if (!target) return null;
    const result = structuredClone(target);
    for (const intent of this.intentsFor(target)) {
      if (intent.operation === "style") {
        result.stroke = { ...intent.message.stroke };
        if (result.kind === "line" && intent.message.kind === "line") {
          result.arrow_start = intent.message.arrowStart;
          result.arrow_end = intent.message.arrowEnd;
        } else if (result.kind !== "line" && intent.message.kind !== "line") {
          result.fill = { ...intent.message.fill };
        }
      } else if (intent.operation === "geometry" && result.kind === "line") {
        result.start = { ...intent.message.start };
        result.end = { ...intent.message.end };
      }
    }
    return result;
  }

  /** @param {number} nodeId */
  hasPendingEdit(nodeId) {
    const target = this.baseTarget(nodeId);
    return target != null && this.intentsFor(target).some((intent) =>
      intent.operation !== "insert"
    );
  }

  /** @param {Element} root
   * @param {number} pageId */
  applyPreview(root, pageId) {
    for (const item of root.querySelectorAll(".ss-pending-shape-source")) {
      item.classList.remove("ss-pending-shape-source");
    }
    for (const target of this.state.snapshot?.shape_editing || []) {
      if (target.page_id !== pageId || !this.hasPendingEdit(target.node_id)) {
        continue;
      }
      for (
        const item of root.querySelectorAll(
          `[data-ss-node-id="${target.node_id}"]`,
        )
      ) {
        item.classList.add("ss-pending-shape-source");
      }
    }
  }

  /** @param {number} pageId */
  pendingInsertion(pageId) {
    return this.pendingInsertions(pageId)[0] || null;
  }

  /** @param {number} pageId */
  pendingInsertions(pageId) {
    return this.edits.intents()
      .filter((intent) => intent.operation === "insert")
      .filter((intent) => intent.preview.pageId === pageId)
      .map((intent) => intent.preview);
  }

  /** @param {number} nodeId */
  pendingLineGeometry(nodeId) {
    const target = this.baseTarget(nodeId);
    if (!target) return null;
    const geometry = this.intentsFor(target).findLast((intent) =>
      intent.operation === "geometry"
    )?.geometry;
    return geometry ? { ...geometry, nodeId, pageId: target.page_id } : null;
  }

  /** @param {number} nodeId */
  pendingBounds(nodeId) {
    const target = this.baseTarget(nodeId);
    if (!target) return null;
    const bounds = this.intentsFor(target).findLast((intent) =>
      intent.operation === "resize"
    )?.bounds;
    return bounds ? { ...bounds, nodeId, pageId: target.page_id } : null;
  }

  /** @param {number} nodeId */
  baseTarget(nodeId) {
    return this.state.snapshot?.shape_editing?.find((target) =>
      target.node_id === nodeId
    ) || null;
  }

  /** @param {{page_id: number, binding: string}} target */
  intentsFor(target) {
    return this.edits.intents().filter((intent) =>
      intent?.selection?.pageId === target.page_id &&
      intent.selection.binding === target.binding
    );
  }

  /** @param {import("./edit-types.js").Snapshot} snapshot
   * @param {import("./edit-types.js").ShapeIntent} pending */
  rebaseQueued(snapshot, pending) {
    if (pending.operation === "insert") {
      const editable = snapshot.page_editing?.some((target) =>
        target.page_id === pending.preview.pageId && target.insert_shapes
      );
      return editable
        ? null
        : queuedFailure("The target page no longer supports shape insertion.");
    }
    const target = snapshot.shape_editing?.find((candidate) =>
      candidate.page_id === pending.selection?.pageId &&
      candidate.binding === pending.selection?.binding
    );
    const expectedKind = pending.operation === "geometry"
      ? "line"
      : pending.message.kind ?? target?.kind;
    if (!target || target.kind !== expectedKind) {
      return queuedFailure("The target shape changed before the edit could be applied.");
    }
    if (pending.operation === "resize" && (target.kind === "line" || !target.resize)) {
      return queuedFailure("The target shape no longer supports resizing.");
    }
    pending.message.nodeId = target.node_id;
    pending.message.pageId = target.page_id;
    if (pending.operation === "geometry") {
      pending.geometry.nodeId = target.node_id;
      pending.geometry.pageId = target.page_id;
    }
    if (pending.operation === "resize" && target.kind !== "line") {
      pending.bounds.nodeId = target.node_id;
      pending.bounds.pageId = target.page_id;
      pending.bounds.fill = { ...target.fill };
      pending.bounds.stroke = { ...target.stroke };
    }
    return null;
  }

  /** @param {Extract<import("./edit-types.js").ShapeIntent, {operation: "insert"}>} pending */
  finishInsertionTool(pending) {
    if (!this.hasQueuedInsertion() &&
        this.state.shapeTool === pending.preview.kind) {
      this.state.shapeTool = "select";
    }
  }

  hasQueuedInsertion() {
    return this.edits.followups.some((intent) => intent.operation === "insert");
  }
}

/** @param {import("./edit-types.js").ShapeDraft} previous
 * @param {import("../../src/editor/protocol.js").ShapeEditingCapability} target
 * @param {import("./edit-types.js").ShapeStyleInput} style */
function insertionStyleAfterEdit(previous, target, style) {
  if (target.kind === "line") {
    return cloneStyle({
      fill: { ...previous.fill },
      stroke: {
        ...style.stroke,
        enabled: previous.stroke.enabled,
      },
      arrowStart: Boolean(style.arrowStart),
      arrowEnd: Boolean(style.arrowEnd),
    });
  }
  return cloneStyle({
    fill: { ...(style.fill || target.fill) },
    stroke: { ...style.stroke },
    arrowStart: previous.arrowStart,
    arrowEnd: previous.arrowEnd,
  });
}

/** @param {import("./edit-types.js").ShapeDraft} style */
function cloneStyle(style) {
  return {
    fill: { ...style.fill },
    stroke: { ...style.stroke },
    arrowStart: Boolean(style.arrowStart),
    arrowEnd: Boolean(style.arrowEnd),
  };
}

/** @param {import("./edit-types.js").Selection | null | undefined} left
 * @param {import("./edit-types.js").Selection | null | undefined} right */
function sameSelection(left, right) {
  return left?.pageId === right?.pageId && left?.binding === right?.binding;
}

/** @param {import("./edit-types.js").ShapeIntent} left
 * @param {import("./edit-types.js").ShapeIntent} right */
function sameQueueSlot(left, right) {
  return left.operation !== "insert" && right.operation !== "insert" &&
    left.operation === right.operation &&
    sameSelection(left.selection, right.selection);
}

/** @param {string} message
 * @returns {import("./edit-types.js").Failure} */
function queuedFailure(message) {
  return { status: "failed", message };
}
