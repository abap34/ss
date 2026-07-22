export const defaultIconDraft = {
  source: null,
  name: null,
  style: null,
  svg: null,
  color: "#2563eb",
};

export class IconController {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.nextRequestId = 1;
    this.latestCatalogRequestId = 0;
    this.catalogTimer = null;
    this.pending = null;
  }

  isBusy() {
    return this.pending != null;
  }

  canInsert(pageId) {
    return Boolean(
      this.state.snapshot &&
        !this.state.snapshot.stale &&
        !this.isBusy() &&
        this.state.iconDraft.source &&
        this.state.snapshot.page_editing?.some((target) =>
          target.page_id === pageId && target.insert_icons
        ),
    );
  }

  setPickerOpen(open) {
    if (this.state.iconPickerOpen === open) return;
    this.state.iconPickerOpen = open;
    if (open && !this.state.iconCatalog) this.queryNow();
    this.actions.render();
  }

  setQuery(query) {
    this.state.iconQuery = query;
    if (this.catalogTimer != null) clearTimeout(this.catalogTimer);
    this.catalogTimer = setTimeout(() => {
      this.catalogTimer = null;
      this.queryNow();
    }, 120);
  }

  setStyle(style) {
    if (this.state.iconStyle === style) return;
    this.state.iconStyle = style;
    this.state.iconCatalog = null;
    this.queryNow();
    this.actions.render();
  }

  queryNow() {
    if (this.catalogTimer != null) clearTimeout(this.catalogTimer);
    this.catalogTimer = null;
    const requestId = this.nextRequestId++;
    this.latestCatalogRequestId = requestId;
    this.state.iconCatalogPending = true;
    this.actions.post({
      type: "queryIcons",
      requestId,
      query: this.state.iconQuery,
      style: this.state.iconStyle,
    });
  }

  acceptCatalog(message) {
    if (message.requestId !== this.latestCatalogRequestId) return null;
    this.state.iconCatalogPending = false;
    if (message.type === "iconCatalogError") {
      this.actions.render();
      return { status: "failed", message: message.message };
    }
    this.state.iconCatalog = message.result;
    this.actions.render();
    return null;
  }

  select(entry) {
    if (!this.state.snapshot || this.state.snapshot.stale) return false;
    this.state.iconDraft = {
      ...this.state.iconDraft,
      source: entry.id,
      name: entry.name,
      style: entry.style,
      svg: entry.svg,
    };
    this.state.iconPickerOpen = false;
    this.state.shapeTool = "icon";
    this.actions.render();
    return true;
  }

  setColor(color) {
    this.state.iconDraft = { ...this.state.iconDraft, color };
    this.actions.render();
  }

  insert(pageId, geometry) {
    if (!this.canInsert(pageId)) return false;
    const requestId = this.nextRequestId++;
    const message = {
      type: "insertIcon",
      requestId,
      snapshotId: this.state.snapshot.snapshot_id,
      pageId,
      source: this.state.iconDraft.source,
      bounds: { ...geometry.bounds },
      color: this.state.iconDraft.color,
    };
    this.pending = {
      requestId,
      snapshotId: message.snapshotId,
      selection: null,
      phase: "requested",
      preview: {
        pageId,
        kind: "icon",
        bounds: { ...message.bounds },
        svg: this.state.iconDraft.svg,
        color: message.color,
      },
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
    this.pending = null;
    this.state.shapeTool = "select";
    this.actions.render();
    if (message.status === "stale") return null;
    return {
      status: "failed",
      message: message.message || "The icon could not be inserted.",
    };
  }

  reconcile(snapshot) {
    const pending = this.pending;
    if (!pending || pending.phase !== "applied" ||
        snapshot.snapshot_id === pending.snapshotId) return null;
    const selection = pending.selection;
    const target = selection
      ? snapshot.editing?.find((candidate) =>
        candidate.page_id === selection.pageId &&
        candidate.binding === selection.binding
      )
      : null;
    if (selection && !target) return null;
    this.pending = null;
    this.state.shapeTool = "select";
    if (target) this.actions.selectObject(target.node_id, target.page_id, false);
    return { status: "applied" };
  }

  cancel() {
    if (this.pending || this.state.shapeTool !== "icon") return false;
    this.state.shapeTool = "select";
    this.actions.render();
    return true;
  }

  pendingInsertion(pageId) {
    const preview = this.pending?.preview;
    return preview?.pageId === pageId ? preview : null;
  }
}
