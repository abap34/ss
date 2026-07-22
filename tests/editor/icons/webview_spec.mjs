#!/usr/bin/env node
import assert from "node:assert/strict";
import {
  defaultIconColor,
  defaultIconDraft,
  IconController,
  shouldLoadMoreIcons,
} from "../../../editor/vscode/media/editor/icon-insertion.js";

assert.equal(defaultIconDraft.color, defaultIconColor);
assert.equal(defaultIconColor, "#374151");

const state = {
  snapshot: snapshot("initial", []),
  currentPageId: 11,
  selectedObjectId: null,
  pointerMode: "select",
  shapeTool: "select",
  iconPickerOpen: false,
  iconQuery: "",
  iconStyle: "all",
  iconCategory: "all",
  iconCategories: [],
  iconCatalog: null,
  iconCatalogPending: false,
  iconCatalogError: null,
  iconDraft: structuredClone(defaultIconDraft),
};
const messages = [];
const selections = [];
const reportedErrors = [];
const icons = new IconController(state, {
  post: (message) => messages.push(structuredClone(message)),
  reportError: (message) => reportedErrors.push(message),
  render: () => {},
  selectObject: (nodeId, pageId) => {
    state.selectedObjectId = nodeId;
    selections.push({ nodeId, pageId });
  },
});

icons.setPickerOpen(true);
assert.equal(messages[0].type, "queryIcons");
assert.equal(messages[0].style, "all");
assert.equal(messages[0].category, "all");
assert.equal(messages[0].offset, 0);
assert.equal(state.iconCatalogPending, true);
const firstRequestId = messages[0].requestId;
icons.queryNow();
const secondRequestId = messages[1].requestId;
assert(secondRequestId > firstRequestId);
icons.acceptCatalog({
  type: "iconCatalog",
  requestId: firstRequestId,
  result: catalog([]),
});
assert.equal(state.iconCatalog, null, "an obsolete icon response replaced the current search");
assert.equal(icons.expireCatalogRequest(firstRequestId), false,
  "an obsolete timeout replaced the current search");
assert.equal(icons.expireCatalogRequest(secondRequestId), true);
assert.equal(state.iconCatalogPending, false);
assert.match(state.iconCatalogError, /timed out/);
assert.equal(reportedErrors.length, 1);
icons.retryCatalog();
assert.equal(state.iconCatalogPending, true);
assert.equal(state.iconCatalogError, null);
const retryRequestId = messages.at(-1).requestId;

const star = {
  id: "fa-solid:star",
  name: "star",
  style: "solid",
  svg: "<svg viewBox=\"0 0 512 512\"><path fill=\"currentColor\"/></svg>",
};
icons.acceptCatalog({
  type: "iconCatalog",
  requestId: retryRequestId,
  result: catalog([star], { totalMatches: 2, hasMore: true }),
});
assert.equal(state.iconCatalog.icons[0].id, star.id);
assert.equal(icons.loadMore(), true);
const loadMoreRequest = messages.at(-1);
assert.equal(loadMoreRequest.offset, 1);
const circle = {
  id: "fa-regular:circle",
  name: "circle",
  style: "regular",
  svg: "<svg viewBox=\"0 0 512 512\"><path fill=\"currentColor\"/></svg>",
};
icons.acceptCatalog({
  type: "iconCatalog",
  requestId: loadMoreRequest.requestId,
  result: catalog([circle], { offset: 1, totalMatches: 2 }),
});
assert.deepEqual(state.iconCatalog.icons.map((entry) => entry.id), [star.id, circle.id]);
assert.deepEqual(state.iconCategories, [{ id: "shapes", label: "Shapes" }]);
assert.equal(shouldLoadMoreIcons({
  scrollHeight: 600,
  scrollTop: 370,
  clientHeight: 120,
}), true);
assert.equal(shouldLoadMoreIcons({
  scrollHeight: 600,
  scrollTop: 200,
  clientHeight: 120,
}), false);
assert.equal(icons.select(star), true);
assert.equal(state.shapeTool, "icon");
assert.equal(state.iconPickerOpen, false);
assert.equal(icons.canInsert(11), true);

icons.setColor("#f59e0b");
assert.equal(icons.insert(11, {
  bounds: { x: 120, y: 140, width: 72, height: 80 },
}), true);
const insertion = messages.at(-1);
assert.deepEqual(insertion, {
  type: "insertIcon",
  requestId: insertion.requestId,
  snapshotId: "initial",
  pageId: 11,
  source: "fa-solid:star",
  bounds: { x: 120, y: 140, width: 72, height: 80 },
  color: "#f59e0b",
});
assert.deepEqual(icons.pendingInsertion(11), {
  pageId: 11,
  kind: "icon",
  bounds: { x: 120, y: 140, width: 72, height: 80 },
  svg: star.svg,
  color: "#f59e0b",
});
icons.acceptResult({
  type: "iconEditResult",
  requestId: insertion.requestId,
  status: "applied",
  documentVersion: 2,
  selection: { path: "/tmp/slide.ss", pageId: 11, binding: "icon_item" },
});
assert(icons.pendingInsertion(11), "the provisional icon disappeared before reconciliation");
state.snapshot = snapshot("after-insert", [{
  node_id: 101,
  page_id: 11,
  binding: "icon_item",
}]);
assert.deepEqual(icons.reconcile(state.snapshot), { status: "applied" });
assert.equal(state.shapeTool, "select");
assert.equal(icons.pendingInsertion(11), null);
assert.deepEqual(selections, [{ nodeId: 101, pageId: 11 }]);

state.snapshot.stale = true;
assert.equal(icons.canInsert(11), true);
assert.equal(icons.select(circle), true);
const messageCountBeforeQueuedInsert = messages.length;
assert.equal(icons.insert(11, {
  bounds: { x: 240, y: 180, width: 64, height: 64 },
}), true);
assert.equal(messages.length, messageCountBeforeQueuedInsert,
  "an icon based on a stale preview was sent before rebuilding");
assert(icons.pendingInsertion(11),
  "an icon based on a stale preview was not retained locally");
assert.equal(icons.reconcile(state.snapshot), null);
assert(icons.pendingInsertion(11),
  "a repeated stale snapshot discarded the provisional icon");
delete state.snapshot.stale;
state.snapshot.snapshot_id = "queued-icon-rebased";
assert.equal(icons.reconcile(state.snapshot), null);
assert.equal(messages.length, messageCountBeforeQueuedInsert + 1);
assert.equal(messages.at(-1).snapshotId, "queued-icon-rebased");

function catalog(entries, {
  category = "all",
  offset = 0,
  totalMatches = entries.length,
  hasMore = false,
} = {}) {
  return {
    schema: 1,
    collection: "fontawesome-free",
    version: "7.2.0",
    query: "",
    style: "all",
    category,
    offset,
    total_available: 2141,
    total_matches: totalMatches,
    has_more: hasMore,
    categories: [{ id: "shapes", label: "Shapes" }],
    icons: entries,
  };
}

function snapshot(id, editing) {
  return {
    snapshot_id: id,
    layout: { pages: [{ id: 11, width: 1280, height: 720 }], objects: [] },
    editing,
    page_editing: [{ page_id: 11, insert_shapes: true, insert_icons: true }],
  };
}
