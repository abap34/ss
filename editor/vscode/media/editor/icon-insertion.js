import { EditQueue } from "./edit-queue.js";
import { editingTargetByBinding } from "./editing-target.js";

export const iconCatalogPolicy = Object.freeze({
  queryMaxLength: 128,
  searchDebounceMs: 120,
  requestTimeoutMs: 8000,
  prefetchDistancePx: 120,
});

export const defaultIconColor = "#374151";

/** @type {import("./edit-types.js").IconDraft} */
export const defaultIconDraft = {
  source: null,
  name: null,
  style: null,
  svg: null,
  color: defaultIconColor,
};

export class IconController {
  /** @param {import("./edit-types.js").IconState} state
   * @param {import("./edit-types.js").EditActions} actions */
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.nextRequestId = 1;
    this.latestCatalogRequestId = 0;
    this.latestCatalogAppend = false;
    /** @type {ReturnType<typeof setTimeout> | null} */
    this.catalogTimer = null;
    /** @type {ReturnType<typeof setTimeout> | null} */
    this.catalogRequestTimer = null;
    /** @type {EditQueue<import("./edit-types.js").IconIntent, import("./edit-types.js").Applied>} */
    this.edits = new EditQueue({
      snapshot: () => this.state.snapshot,
      post: actions.post,
      render: actions.render,
      nextRequestId: () => this.nextRequestId++,
      rebase: (snapshot, intent) => snapshot.page_editing?.some((target) =>
        target.page_id === intent.preview.pageId && target.insert_icons
      ) ? null : {
        status: "failed",
        message: "The target page no longer supports icon insertion.",
      },
      applied: (snapshot, intent, version) => this.selectApplied(snapshot, intent, version),
      discard: () => this.finishInsertionTool(),
      failureMessage: "The icon could not be inserted.",
    });
  }

  isBusy() {
    return this.edits.isBusy();
  }

  /** @param {number | null} pageId */
  supportsInsertion(pageId) {
    return Boolean(
      this.state.snapshot && this.state.iconDraft.source &&
        this.state.snapshot.page_editing?.some((target) =>
          target.page_id === pageId && target.insert_icons
        ),
    );
  }

  /** @param {number | null} pageId */
  canInsert(pageId) {
    return this.supportsInsertion(pageId);
  }

  /** @param {boolean} open */
  setPickerOpen(open) {
    if (this.state.iconPickerOpen === open) return;
    this.state.iconPickerOpen = open;
    if (open && !this.state.iconCatalog) this.queryNow();
    this.actions.render();
  }

  /** @param {string} query */
  setQuery(query) {
    this.state.iconQuery = query;
    this.state.iconCatalog = null;
    if (this.catalogTimer != null) clearTimeout(this.catalogTimer);
    this.catalogTimer = setTimeout(() => {
      this.catalogTimer = null;
      this.queryNow();
    }, iconCatalogPolicy.searchDebounceMs);
  }

  /** @param {import("../../src/editor/protocol.js").IconStyle} style */
  setStyle(style) {
    if (this.state.iconStyle === style) return;
    this.state.iconStyle = style;
    this.state.iconCatalog = null;
    this.queryNow();
    this.actions.render();
  }

  /** @param {string} category */
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

  /** @param {Extract<import("../../src/editor/protocol.js").HostMessage, {type: "iconCatalog" | "iconCatalogError"}>} message */
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

  /** @param {number} requestId */
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

  /** @param {import("../../src/editor/protocol.js").IconCatalogEntry} entry */
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

  /** @param {string} color */
  setColor(color) {
    this.state.iconDraft = { ...this.state.iconDraft, color };
    this.actions.render();
  }

  /** @param {number} pageId
   * @param {{bounds: import("../../src/editor/protocol.js").Rect}} geometry */
  insert(pageId, geometry) {
    const snapshot = this.state.snapshot;
    const source = this.state.iconDraft.source;
    if (!snapshot || !source || !this.canInsert(pageId)) return false;
    /** @type {import("./edit-types.js").IconRequest} */
    const message = {
      type: "insertIcon",
      requestId: 0,
      snapshotId: snapshot.snapshot_id,
      pageId,
      source,
      bounds: { ...geometry.bounds },
      color: this.state.iconDraft.color,
    };
    return this.edits.enqueue({
      message,
      selection: null,
      preview: {
        pageId,
        kind: "icon",
        bounds: { ...message.bounds },
        svg: this.state.iconDraft.svg,
        color: message.color,
      },
    });
  }

  /** @param {Extract<import("../../src/editor/protocol.js").HostMessage, {type: "iconEditResult"}>} message */
  acceptResult(message) {
    return this.edits.acceptResult(message);
  }

  /** @param {import("./edit-types.js").Snapshot} snapshot
   * @param {number} [documentVersion] */
  reconcile(snapshot, documentVersion) {
    return this.edits.reconcile(snapshot, documentVersion);
  }

  /** @param {import("./edit-types.js").Snapshot} snapshot
   * @param {import("./edit-types.js").IconIntent} pending
   * @param {number} [documentVersion]
   * @returns {import("./edit-types.js").Applied | import("./edit-types.js").Failure | null} */
  selectApplied(snapshot, pending, documentVersion) {
    const selection = pending.selection;
    const target = selection
      ? editingTargetByBinding(
        snapshot,
        selection.pageId,
        selection.binding,
      )
      : null;
    if (selection && !target) {
      if (documentVersion != null ||
          !snapshot.layout.pages.some((page) => page.id === selection.pageId)) {
        return { status: "failed", message: "The inserted icon is no longer present in the rebuilt page." };
      }
      return null;
    }
    const selectInsertedTarget = this.edits.followups.length === 0 &&
      this.state.shapeTool === "icon";
    if (target && selectInsertedTarget) {
      this.actions.selectObject(target.node_id, target.page_id, false);
    }
    return { status: "applied" };
  }

  cancel() {
    if (this.edits.cancelNewestQueued(() => true)) return true;
    if (this.state.shapeTool !== "icon") return false;
    this.state.shapeTool = "select";
    this.actions.render();
    return true;
  }

  /** @param {number} pageId */
  pendingInsertion(pageId) {
    return this.pendingInsertions(pageId)[0] || null;
  }

  /** @param {number} pageId */
  pendingInsertions(pageId) {
    return this.edits.intents()
      .filter((intent) => intent?.preview.pageId === pageId)
      .map((intent) => intent.preview);
  }

  finishInsertionTool() {
    if (this.edits.followups.length === 0 && this.state.shapeTool === "icon") {
      this.state.shapeTool = "select";
    }
  }

}

/** @param {Pick<Element, "scrollHeight" | "scrollTop" | "clientHeight"> | null} scroller */
export function shouldLoadMoreIcons(scroller) {
  if (!scroller) return false;
  const remaining = scroller.scrollHeight - scroller.scrollTop -
    scroller.clientHeight;
  return remaining <= iconCatalogPolicy.prefetchDistancePx;
}
