#!/usr/bin/env node
import assert from "node:assert/strict";
import {
  defaultIconDraft,
  IconController,
} from "../../../editor/vscode/media/editor/icon-insertion.js";

const state = {
  snapshot: snapshot("initial", []),
  currentPageId: 11,
  selectedObjectId: null,
  shapeTool: "select",
  iconPickerOpen: false,
  iconQuery: "",
  iconStyle: "all",
  iconCatalog: null,
  iconCatalogPending: false,
  iconDraft: structuredClone(defaultIconDraft),
};
const messages = [];
const selections = [];
const icons = new IconController(state, {
  post: (message) => messages.push(structuredClone(message)),
  render: () => {},
  selectObject: (nodeId, pageId) => {
    state.selectedObjectId = nodeId;
    selections.push({ nodeId, pageId });
  },
});

icons.setPickerOpen(true);
assert.equal(messages[0].type, "queryIcons");
assert.equal(messages[0].style, "all");
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

const star = {
  id: "fa-solid:star",
  name: "star",
  style: "solid",
  svg: "<svg viewBox=\"0 0 512 512\"><path fill=\"currentColor\"/></svg>",
};
icons.acceptCatalog({
  type: "iconCatalog",
  requestId: secondRequestId,
  result: catalog([star]),
});
assert.equal(state.iconCatalog.icons[0].id, star.id);
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
assert.equal(icons.canInsert(11), false);

function catalog(entries) {
  return {
    schema: 1,
    collection: "fontawesome-free",
    version: "7.2.0",
    query: "",
    style: "all",
    total_available: 2141,
    total_matches: entries.length,
    has_more: false,
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
