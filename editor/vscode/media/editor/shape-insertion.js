import { combineFailureMessages } from "./diagnostics.js";

export const defaultShapeStyle = {
  fill: { enabled: true, color: "#e8f1ff", opacity: 1 },
  stroke: { enabled: true, color: "#2563eb", width: 1.6, style: "solid" },
  arrowStart: false,
  arrowEnd: false,
};

export class ShapeController {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.pending = null;
    this.followups = [];
    this.nextRequestId = 1;
  }

  isBusy() {
    return this.pending != null || this.followups.length > 0;
  }

  canEdit(target) {
    return Boolean(this.state.snapshot?.shape_editing?.some((candidate) =>
      candidate.page_id === target.page_id &&
      candidate.binding === target.binding &&
      candidate.kind === target.kind
    ));
  }

  supportsInsertion(pageId) {
    return Boolean(
      this.state.snapshot?.page_editing?.some((target) =>
        target.page_id === pageId && target.insert_shapes
      ),
    );
  }

  canInsert(pageId) {
    return this.supportsInsertion(pageId);
  }

  selectTool(tool) {
    if (tool !== "select" && !this.supportsInsertion(this.state.currentPageId)) {
      return;
    }
    this.state.pointerMode = "select";
    this.state.shapeTool = tool;
    this.actions.render();
  }

  setDraft(next) {
    this.state.shapeStyle = cloneStyle(next);
    this.actions.render();
  }

  insert(pageId, geometry) {
    if (this.state.shapeTool === "select" || !this.canInsert(pageId)) return false;
    const requestId = this.nextRequestId++;
    const common = {
      type: "insertShape",
      requestId,
      snapshotId: this.state.snapshot.snapshot_id,
      pageId,
      kind: this.state.shapeTool,
    };
    const line = this.state.shapeTool === "line" ||
      this.state.shapeTool === "elbow_line";
    const message = line
      ? {
        ...common,
        start: { ...geometry.start },
        end: { ...geometry.end },
        arrowStart: this.state.shapeStyle.arrowStart,
        arrowEnd: this.state.shapeStyle.arrowEnd,
        stroke: { ...this.state.shapeStyle.stroke, enabled: true },
      }
      : {
        ...common,
        bounds: { ...geometry.bounds },
        fill: { ...this.state.shapeStyle.fill },
        stroke: { ...this.state.shapeStyle.stroke },
      };
    return this.startOrQueue({
      requestId,
      operation: "insert",
      snapshotId: message.snapshotId,
      message,
      selection: null,
      preview: {
        pageId,
        kind: message.kind,
        stroke: { ...message.stroke },
        ...(line
          ? {
            start: { ...message.start },
            end: { ...message.end },
            arrowStart: message.arrowStart,
            arrowEnd: message.arrowEnd,
          }
          : {
            bounds: { ...message.bounds },
            fill: { ...message.fill },
          }),
      },
    });
  }

  editStyle(target, style) {
    if (!this.state.snapshot || !this.canEdit(target)) return false;
    this.state.shapeStyle = insertionStyleAfterEdit(
      this.state.shapeStyle,
      target,
      style,
    );
    const requestId = this.nextRequestId++;
    const message = {
      type: "editShapeStyle",
      requestId,
      snapshotId: this.state.snapshot.snapshot_id,
      nodeId: target.node_id,
      pageId: target.page_id,
      kind: target.kind,
      stroke: { ...style.stroke },
      ...(target.kind === "line"
        ? {
          arrowStart: style.arrowStart,
          arrowEnd: style.arrowEnd,
        }
        : { fill: { ...style.fill } }),
    };
    return this.startOrQueue({
      requestId,
      operation: "style",
      snapshotId: message.snapshotId,
      message,
      selection: { pageId: target.page_id, binding: target.binding },
    });
  }

  editLineGeometry(target, start, end) {
    if (!this.state.snapshot || !this.canEdit(target) ||
        target.kind !== "line") return false;
    const requestId = this.nextRequestId++;
    const message = {
      type: "editLineGeometry",
      requestId,
      snapshotId: this.state.snapshot.snapshot_id,
      nodeId: target.node_id,
      pageId: target.page_id,
      start: { ...start },
      end: { ...end },
    };
    return this.startOrQueue({
      requestId,
      operation: "geometry",
      snapshotId: message.snapshotId,
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

  editBounds(target, bounds) {
    if (!this.state.snapshot || !this.canEdit(target) ||
        target.kind === "line" || !target.resize) return false;
    const requestId = this.nextRequestId++;
    const message = {
      type: "editShapeBounds",
      requestId,
      snapshotId: this.state.snapshot.snapshot_id,
      nodeId: target.node_id,
      pageId: target.page_id,
      kind: target.kind,
      bounds: { ...bounds },
    };
    return this.startOrQueue({
      requestId,
      operation: "resize",
      snapshotId: message.snapshotId,
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

  startOrQueue(intent) {
    if (this.pending) {
      intent.phase = "queued";
      if (this.pending.phase === "queued" && sameQueueSlot(this.pending, intent)) {
        this.pending = intent;
      } else {
        const replace = this.followups.findIndex((candidate) =>
          sameQueueSlot(candidate, intent)
        );
        if (replace >= 0) this.followups[replace] = intent;
        else this.followups.push(intent);
      }
      this.actions.render();
      return true;
    }
    intent.phase = this.state.snapshot.stale ? "queued" : "requested";
    this.pending = intent;
    if (intent.phase === "requested") this.actions.post(intent.message);
    this.actions.render();
    return true;
  }

  acceptResult(message) {
    if (!this.pending || message.requestId !== this.pending.requestId) return null;
    if (message.status === "applied") {
      this.pending.phase = "applied";
      if (message.selection) this.pending.selection = message.selection;
      return null;
    }
    if (message.status === "stale") {
      this.pending.phase = "queued";
      return null;
    }
    const pending = this.pending;
    const operation = pending.operation;
    this.pending = null;
    if (operation === "insert") this.finishInsertionTool(pending);
    const queuedFailureResult = this.promoteFollowup(this.state.snapshot);
    this.actions.render();
    return {
      status: "failed",
      message: combineFailureMessages(
        message.message || "The shape edit could not be applied.",
        queuedFailureResult?.message,
      ),
    };
  }

  reconcile(snapshot) {
    const pending = this.pending;
    if (!pending) return null;
    if (pending.phase === "queued") {
      if (snapshot.stale) return null;
      const failure = this.rebaseQueued(snapshot, pending);
      if (failure) {
        this.pending = null;
        if (pending.operation === "insert") this.finishInsertionTool(pending);
        const queuedFailureResult = this.promoteFollowup(snapshot);
        return {
          status: "failed",
          message: combineFailureMessages(
            failure.message,
            queuedFailureResult?.message,
          ),
        };
      }
      pending.snapshotId = snapshot.snapshot_id;
      pending.message.snapshotId = snapshot.snapshot_id;
      pending.phase = "requested";
      this.actions.post(pending.message);
      return null;
    }
    if (pending.phase !== "applied" ||
        snapshot.snapshot_id === pending.snapshotId) return null;
    const selection = pending.selection;
    let target = null;
    if (selection) {
      target = snapshot.shape_editing?.find((candidate) =>
        candidate.page_id === selection.pageId &&
        candidate.binding === selection.binding
      );
    }
    if (pending.operation === "insert" && selection && !target) {
      return null;
    }
    const selectAppliedTarget = pending.operation !== "insert" ||
      (!this.hasQueuedInsertion() &&
        this.state.shapeTool === pending.preview.kind);
    this.pending = null;
    if (pending.operation === "insert") this.finishInsertionTool(pending);
    if (target && selectAppliedTarget) {
      this.actions.selectObject(target.node_id, target.page_id, false);
    }
    const queuedFailureResult = this.promoteFollowup(snapshot);
    if (queuedFailureResult) return queuedFailureResult;
    return {
      status: "applied",
      operation: pending.operation,
    };
  }

  cancel() {
    const queuedInsertion = this.followups.findLastIndex((intent) =>
      intent.operation === "insert" && intent.phase === "queued"
    );
    if (queuedInsertion >= 0) {
      this.followups.splice(queuedInsertion, 1);
      this.actions.render();
      return true;
    }
    if (this.pending?.operation === "insert" &&
        this.pending.phase === "queued") {
      const pending = this.pending;
      this.pending = null;
      this.finishInsertionTool(pending);
      this.promoteFollowup(this.state.snapshot);
      this.actions.render();
      return true;
    }
    if (this.state.shapeTool === "select" || this.state.shapeTool === "icon") {
      return false;
    }
    this.state.shapeTool = "select";
    this.actions.render();
    return true;
  }

  styleTarget(nodeId) {
    const target = this.state.snapshot?.shape_editing?.find((candidate) =>
      candidate.node_id === nodeId
    );
    if (!target) return null;
    const result = {
      ...target,
      ...(target.fill ? { fill: { ...target.fill } } : {}),
      stroke: { ...target.stroke },
      ...(target.start ? { start: { ...target.start } } : {}),
      ...(target.end ? { end: { ...target.end } } : {}),
    };
    for (const intent of this.intentsFor(target)) {
      if (intent.operation === "style") {
        result.stroke = { ...intent.message.stroke };
        if (result.kind === "line") {
          result.arrow_start = intent.message.arrowStart;
          result.arrow_end = intent.message.arrowEnd;
        } else {
          result.fill = { ...intent.message.fill };
        }
      } else if (intent.operation === "geometry") {
        result.start = { ...intent.message.start };
        result.end = { ...intent.message.end };
      }
    }
    return result;
  }

  pendingInsertion(pageId) {
    return this.pendingInsertions(pageId)[0] || null;
  }

  pendingInsertions(pageId) {
    return [this.pending, ...this.followups]
      .filter((intent) =>
        intent?.operation === "insert" && intent.preview.pageId === pageId
      )
      .map((intent) => intent.preview);
  }

  pendingLineGeometry(nodeId) {
    const target = this.baseTarget(nodeId);
    if (!target) return null;
    const geometry = this.intentsFor(target).findLast((intent) =>
      intent.operation === "geometry"
    )?.geometry;
    return geometry ? { ...geometry, nodeId, pageId: target.page_id } : null;
  }

  pendingBounds(nodeId) {
    const target = this.baseTarget(nodeId);
    if (!target) return null;
    const bounds = this.intentsFor(target).findLast((intent) =>
      intent.operation === "resize"
    )?.bounds;
    return bounds ? { ...bounds, nodeId, pageId: target.page_id } : null;
  }

  baseTarget(nodeId) {
    return this.state.snapshot?.shape_editing?.find((target) =>
      target.node_id === nodeId
    ) || null;
  }

  intentsFor(target) {
    return [this.pending, ...this.followups].filter((intent) =>
      intent?.selection?.pageId === target.page_id &&
      intent.selection.binding === target.binding
    );
  }

  promoteFollowup(snapshot) {
    if (this.pending || this.followups.length === 0) return null;
    let firstFailure = null;
    while (!this.pending && this.followups.length > 0) {
      const next = this.followups.shift();
      this.pending = next;
      if (snapshot?.stale) {
        next.phase = "queued";
        return firstFailure;
      }
      const failure = this.rebaseQueued(snapshot, next);
      if (failure) {
        this.pending = null;
        firstFailure ??= failure;
        continue;
      }
      next.snapshotId = snapshot.snapshot_id;
      next.message.snapshotId = snapshot.snapshot_id;
      next.phase = "requested";
      this.actions.post(next.message);
    }
    return firstFailure;
  }

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
      candidate.page_id === pending.selection.pageId &&
      candidate.binding === pending.selection.binding
    );
    const expectedKind = pending.operation === "geometry"
      ? "line"
      : pending.message.kind ?? target?.kind;
    if (!target || target.kind !== expectedKind) {
      return queuedFailure("The target shape changed before the edit could be applied.");
    }
    if (pending.operation === "resize" && !target.resize) {
      return queuedFailure("The target shape no longer supports resizing.");
    }
    pending.message.nodeId = target.node_id;
    pending.message.pageId = target.page_id;
    if (pending.geometry) {
      pending.geometry.nodeId = target.node_id;
      pending.geometry.pageId = target.page_id;
    }
    if (pending.bounds) {
      pending.bounds.nodeId = target.node_id;
      pending.bounds.pageId = target.page_id;
      pending.bounds.fill = { ...target.fill };
      pending.bounds.stroke = { ...target.stroke };
    }
    return null;
  }

  finishInsertionTool(pending) {
    if (!this.hasQueuedInsertion() &&
        this.state.shapeTool === pending.preview.kind) {
      this.state.shapeTool = "select";
    }
  }

  hasQueuedInsertion() {
    return this.followups.some((intent) => intent.operation === "insert");
  }
}

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
    fill: { ...style.fill },
    stroke: { ...style.stroke },
    arrowStart: previous.arrowStart,
    arrowEnd: previous.arrowEnd,
  });
}

function cloneStyle(style) {
  return {
    fill: { ...style.fill },
    stroke: { ...style.stroke },
    arrowStart: Boolean(style.arrowStart),
    arrowEnd: Boolean(style.arrowEnd),
  };
}

function sameSelection(left, right) {
  return left?.pageId === right?.pageId && left?.binding === right?.binding;
}

function sameQueueSlot(left, right) {
  return left.operation !== "insert" && right.operation !== "insert" &&
    left.operation === right.operation &&
    sameSelection(left.selection, right.selection);
}

function queuedFailure(message) {
  return { status: "failed", message };
}
