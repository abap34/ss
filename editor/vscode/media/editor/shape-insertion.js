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
        !this.state.snapshot.stale &&
        !this.isBusy() &&
        this.state.snapshot.page_editing?.some((target) =>
          target.page_id === pageId && target.insert_shapes
        ),
    );
  }

  selectTool(tool) {
    if (tool !== "select" && !this.canInsert(this.state.currentPageId)) return;
    this.state.shapeTool = tool;
    this.actions.render();
  }

  setDraft(next) {
    this.state.shapeStyle = cloneStyle(next);
    this.actions.render();
  }

  insert(pageId, bounds) {
    if (this.state.shapeTool === "select" || !this.canInsert(pageId)) return false;
    const requestId = this.nextRequestId++;
    const message = {
      type: "insertShape",
      requestId,
      snapshotId: this.state.snapshot.snapshot_id,
      pageId,
      kind: this.state.shapeTool,
      bounds: { ...bounds },
      ...cloneStyle(this.state.shapeStyle),
    };
    this.pending = {
      requestId,
      operation: "insert",
      snapshotId: message.snapshotId,
      selection: null,
      phase: "requested",
      preview: {
        pageId,
        kind: message.kind,
        bounds: { ...message.bounds },
        fill: { ...message.fill },
        stroke: { ...message.stroke },
      },
    };
    this.actions.post(message);
    this.actions.render();
    return true;
  }

  editStyle(target, style) {
    if (!this.state.snapshot || this.state.snapshot.stale || this.isBusy()) {
      return false;
    }
    const requestId = this.nextRequestId++;
    const message = {
      type: "editShapeStyle",
      requestId,
      snapshotId: this.state.snapshot.snapshot_id,
      nodeId: target.node_id,
      pageId: target.page_id,
      ...cloneStyle(style),
    };
    this.pending = {
      requestId,
      operation: "style",
      snapshotId: message.snapshotId,
      selection: { pageId: target.page_id, binding: target.binding },
      phase: "requested",
    };
    this.actions.post(message);
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
    const operation = this.pending.operation;
    this.pending = null;
    if (operation === "insert") this.state.shapeTool = "select";
    this.actions.render();
    if (message.status === "stale") return null;
    return {
      status: "failed",
      message: message.message || "The shape edit could not be applied.",
    };
  }

  reconcile(snapshot) {
    const pending = this.pending;
    if (!pending || pending.phase !== "applied" ||
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
}

function cloneStyle(style) {
  return {
    fill: { ...style.fill },
    stroke: { ...style.stroke },
  };
}
