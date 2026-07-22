export const iconCatalogPolicy = Object.freeze({
  queryMaxLength: 128,
  searchDebounceMs: 120,
  requestTimeoutMs: 8000,
  prefetchDistancePx: 120,
});

export const defaultIconColor = "#374151";

export const defaultIconDraft = {
  source: null,
  name: null,
  style: null,
  svg: null,
  color: defaultIconColor,
};

export class IconController {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.nextRequestId = 1;
    this.latestCatalogRequestId = 0;
    this.latestCatalogAppend = false;
    this.catalogTimer = null;
    this.catalogRequestTimer = null;
    this.pending = null;
  }

  isBusy() {
    return this.pending != null;
  }

  canInsert(pageId) {
    return Boolean(
      this.state.snapshot &&
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
    this.state.iconCatalog = null;
    if (this.catalogTimer != null) clearTimeout(this.catalogTimer);
    this.catalogTimer = setTimeout(() => {
      this.catalogTimer = null;
      this.queryNow();
    }, iconCatalogPolicy.searchDebounceMs);
  }

  setStyle(style) {
    if (this.state.iconStyle === style) return;
    this.state.iconStyle = style;
    this.state.iconCatalog = null;
    this.queryNow();
    this.actions.render();
  }

  setCategory(category) {
    if (this.state.iconCategory === category) return;
    this.state.iconCategory = category;
    this.state.iconCatalog = null;
    this.queryNow();
    this.actions.render();
  }

  queryNow({ append = false } = {}) {
    if (this.catalogTimer != null) clearTimeout(this.catalogTimer);
    if (this.catalogRequestTimer != null) clearTimeout(this.catalogRequestTimer);
    this.catalogTimer = null;
    this.catalogRequestTimer = null;
    const requestId = this.nextRequestId++;
    const offset = append ? this.state.iconCatalog?.icons.length || 0 : 0;
    this.latestCatalogRequestId = requestId;
    this.latestCatalogAppend = append;
    this.state.iconCatalogPending = true;
    this.state.iconCatalogError = null;
    this.actions.post({
      type: "queryIcons",
      requestId,
      query: this.state.iconQuery,
      style: this.state.iconStyle,
      category: this.state.iconCategory,
      offset,
    });
    this.catalogRequestTimer = setTimeout(() => {
      this.catalogRequestTimer = null;
      this.expireCatalogRequest(requestId);
    }, iconCatalogPolicy.requestTimeoutMs);
  }

  acceptCatalog(message) {
    if (message.requestId !== this.latestCatalogRequestId) return null;
    if (this.catalogRequestTimer != null) clearTimeout(this.catalogRequestTimer);
    this.catalogRequestTimer = null;
    this.state.iconCatalogPending = false;
    if (message.type === "iconCatalogError") {
      this.state.iconCatalogError = message.message;
      this.actions.render();
      return { status: "failed", message: message.message };
    }
    this.state.iconCatalogError = null;
    if (Array.isArray(message.result.categories)) {
      this.state.iconCategories = message.result.categories;
    }
    const previous = this.state.iconCatalog;
    const appends = this.latestCatalogAppend && previous &&
      previous.query === message.result.query &&
      previous.style === message.result.style &&
      previous.category === message.result.category &&
      message.result.offset === previous.icons.length;
    this.state.iconCatalog = appends
      ? { ...message.result, icons: [...previous.icons, ...message.result.icons] }
      : message.result;
    this.actions.render();
    return null;
  }

  expireCatalogRequest(requestId) {
    if (requestId !== this.latestCatalogRequestId ||
        !this.state.iconCatalogPending) return false;
    const message = "Icon catalog request timed out. Reload the VS Code window if retrying does not help.";
    this.state.iconCatalogPending = false;
    this.state.iconCatalogError = message;
    if (typeof this.actions.reportError === "function") {
      this.actions.reportError(message);
    } else {
      this.actions.render();
    }
    return true;
  }

  retryCatalog() {
    this.queryNow({ append: this.latestCatalogAppend && Boolean(this.state.iconCatalog) });
    this.actions.render();
  }

  loadMore() {
    if (this.state.iconCatalogPending || !this.state.iconCatalog?.has_more) {
      return false;
    }
    this.queryNow({ append: true });
    return true;
  }

  select(entry) {
    if (!this.state.snapshot) return false;
    this.state.iconDraft = {
      ...this.state.iconDraft,
      source: entry.id,
      name: entry.name,
      style: entry.style,
      svg: entry.svg,
    };
    this.state.iconPickerOpen = false;
    this.state.pointerMode = "select";
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
      message,
      selection: null,
      phase: this.state.snapshot.stale ? "queued" : "requested",
      preview: {
        pageId,
        kind: "icon",
        bounds: { ...message.bounds },
        svg: this.state.iconDraft.svg,
        color: message.color,
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
    this.pending = null;
    this.state.shapeTool = "select";
    this.actions.render();
    return {
      status: "failed",
      message: message.message || "The icon could not be inserted.",
    };
  }

  reconcile(snapshot) {
    const pending = this.pending;
    if (!pending) return null;
    if (pending.phase === "queued") {
      if (snapshot.stale) return null;
      const editable = snapshot.page_editing?.some((target) =>
        target.page_id === pending.preview.pageId && target.insert_icons
      );
      if (!editable) {
        this.pending = null;
        this.state.shapeTool = "select";
        return {
          status: "failed",
          message: "The target page no longer supports icon insertion.",
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
    if (this.pending?.phase === "queued") {
      this.pending = null;
      this.state.shapeTool = "select";
      this.actions.render();
      return true;
    }
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

export function shouldLoadMoreIcons(scroller) {
  if (!scroller) return false;
  const remaining = scroller.scrollHeight - scroller.scrollTop -
    scroller.clientHeight;
  return remaining <= iconCatalogPolicy.prefetchDistancePx;
}
