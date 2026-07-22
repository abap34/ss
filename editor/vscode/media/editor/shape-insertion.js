export const defaultShapeStyle = {
  fill: { enabled: true, color: "#e8f1ff", opacity: 1 },
  stroke: { enabled: true, color: "#2563eb", width: 1.6, style: "solid" },
};

export class ShapeController {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.pending = null;
    this.nextRequestId = 1;
  }

  isBusy() {
    return this.pending != null;
  }

  canInsert(pageId) {
    return Boolean(
      this.state.snapshot &&
        !this.isBusy() &&
        this.state.snapshot.page_editing?.some((target) =>
          target.page_id === pageId && target.insert_shapes
        ),
    );
  }

  selectTool(tool) {
    if (tool !== "select" && !this.canInsert(this.state.currentPageId)) return;
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
    const message = this.state.shapeTool === "line"
      ? {
        ...common,
        start: { ...geometry.start },
        end: { ...geometry.end },
        stroke: { ...this.state.shapeStyle.stroke, enabled: true },
      }
      : {
        ...common,
        bounds: { ...geometry.bounds },
        ...cloneStyle(this.state.shapeStyle),
      };
    this.pending = {
      requestId,
      operation: "insert",
      snapshotId: message.snapshotId,
      message,
      selection: null,
      phase: this.state.snapshot.stale ? "queued" : "requested",
      preview: {
        pageId,
        kind: message.kind,
        stroke: { ...message.stroke },
        ...(message.kind === "line"
          ? {
            start: { ...message.start },
            end: { ...message.end },
          }
          : {
            bounds: { ...message.bounds },
            fill: { ...message.fill },
          }),
      },
    };
    if (this.pending.phase === "requested") this.actions.post(message);
    this.actions.render();
    return true;
  }

  editStyle(target, style) {
    if (!this.state.snapshot || this.isBusy()) {
      return false;
    }
    const requestId = this.nextRequestId++;
    const message = {
      type: "editShapeStyle",
      requestId,
      snapshotId: this.state.snapshot.snapshot_id,
      nodeId: target.node_id,
      pageId: target.page_id,
      kind: target.kind,
      stroke: { ...style.stroke },
      ...(target.kind === "line" ? {} : { fill: { ...style.fill } }),
    };
    this.pending = {
      requestId,
      operation: "style",
      snapshotId: message.snapshotId,
      message,
      selection: { pageId: target.page_id, binding: target.binding },
      phase: this.state.snapshot.stale ? "queued" : "requested",
    };
    if (this.pending.phase === "requested") this.actions.post(message);
    this.actions.render();
    return true;
  }

  editLineGeometry(target, start, end) {
    if (!this.state.snapshot || this.isBusy() ||
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
    this.pending = {
      requestId,
      operation: "geometry",
      snapshotId: message.snapshotId,
      message,
      selection: { pageId: target.page_id, binding: target.binding },
      phase: this.state.snapshot.stale ? "queued" : "requested",
      geometry: {
        nodeId: target.node_id,
        pageId: target.page_id,
        start: { ...start },
        end: { ...end },
      },
    };
    if (this.pending.phase === "requested") this.actions.post(message);
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
    const operation = this.pending.operation;
    this.pending = null;
    if (operation === "insert") this.state.shapeTool = "select";
    this.actions.render();
    return {
      status: "failed",
      message: message.message || "The shape edit could not be applied.",
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
        if (pending.operation === "insert") this.state.shapeTool = "select";
        return failure;
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
    this.pending = null;
    if (pending.operation === "insert") this.state.shapeTool = "select";
    if (target) {
      this.actions.selectObject(target.node_id, target.page_id, false);
    }
    return {
      status: "applied",
      operation: pending.operation,
    };
  }

  cancel() {
    if (this.pending?.phase === "queued") {
      const insertion = this.pending.operation === "insert";
      this.pending = null;
      if (insertion) this.state.shapeTool = "select";
      this.actions.render();
      return true;
    }
    if (this.pending) return false;
    if (this.state.shapeTool === "select") return false;
    this.state.shapeTool = "select";
    this.actions.render();
    return true;
  }

  styleTarget(nodeId) {
    return this.state.snapshot?.shape_editing?.find((target) =>
      target.node_id === nodeId
    ) || null;
  }

  pendingInsertion(pageId) {
    const preview = this.pending?.operation === "insert"
      ? this.pending.preview
      : null;
    return preview?.pageId === pageId ? preview : null;
  }

  pendingLineGeometry(nodeId) {
    const geometry = this.pending?.operation === "geometry"
      ? this.pending.geometry
      : null;
    return geometry?.nodeId === nodeId ? geometry : null;
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
      : pending.message.kind;
    if (!target || target.kind !== expectedKind) {
      return queuedFailure("The target shape changed before the edit could be applied.");
    }
    pending.message.nodeId = target.node_id;
    pending.message.pageId = target.page_id;
    if (pending.geometry) {
      pending.geometry.nodeId = target.node_id;
      pending.geometry.pageId = target.page_id;
    }
    return null;
  }
}

function cloneStyle(style) {
  return {
    fill: { ...style.fill },
    stroke: { ...style.stroke },
  };
}

function queuedFailure(message) {
  return { status: "failed", message };
}
