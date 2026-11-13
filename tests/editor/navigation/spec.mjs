#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { selectedObjectBelongsToPage } from "../../../editor/vscode/media/editor/interaction.js";
import { editableAncestorNodeId } from "../../../editor/vscode/media/editor/geometry.js";
import { EditorNavigation } from "../../../editor/vscode/media/editor/navigation.js";

const firstPage = { id: 11 };
const secondPage = { id: 29 };
const selectedObject = { id: 41, page_id: secondPage.id };
const state = {
  snapshot: {
    layout: {
      pages: [firstPage, secondPage],
      objects: [selectedObject],
    },
  },
  currentPageId: secondPage.id,
  selectedObjectId: null,
};
const navigation = new EditorNavigation(state);

state.revision = 1;
state.snapshot.snapshot_id = "initial";
navigation.requestPageReveal({ snapshotId: "initial", revision: 1, pageId: firstPage.id });
assert.equal(navigation.takePageReveal(), firstPage.id);
assert.equal(navigation.takePageReveal(), null, "navigation must be consumed once");
navigation.requestPageReveal({ snapshotId: "next", revision: 2, pageId: secondPage.id });
assert.equal(navigation.takePageReveal(), null, "navigation must wait for a deferred snapshot");
state.revision = 2;
state.snapshot.snapshot_id = "next";
assert.equal(navigation.takePageReveal(), secondPage.id);
navigation.requestPageReveal({ snapshotId: "initial", revision: 1, pageId: firstPage.id });
assert.equal(navigation.takePageReveal(), null, "old navigation must not change a newer preview");
navigation.requestPageReveal({ snapshotId: "wrong", revision: 2, pageId: firstPage.id });
assert.equal(navigation.takePageReveal(), null, "navigation must match the snapshot identity");
navigation.requestPageReveal({ snapshotId: "next", revision: 2, pageId: 1000 });
assert.equal(navigation.takePageReveal(), null, "missing pages must not be revealed");

const beforeRender = { scrollLeft: 7, scrollTop: 860 };
navigation.rememberViewport(beforeRender);
const selection = navigation.selectObject(selectedObject.id, secondPage.id);
assert.deepEqual(selection, { selected: true, pageChanged: false });

const afterRender = { scrollLeft: 0, scrollTop: 0 };
navigation.restoreViewport(afterRender);
assert.deepEqual(afterRender, beforeRender);
assert.equal(state.currentPageId, secondPage.id);

state.currentPageId = firstPage.id;
assert.deepEqual(
  navigation.selectObject(selectedObject.id, secondPage.id),
  { selected: true, pageChanged: true },
);
assert.equal(state.currentPageId, secondPage.id);

assert.deepEqual(
  navigation.selectObject(selectedObject.id, firstPage.id),
  { selected: false, pageChanged: false },
);
assert.equal(state.currentPageId, secondPage.id);

state.selectedObjectId = selectedObject.id;
state.currentPageId = secondPage.id;
navigation.reconcile(state.snapshot);
assert.equal(state.currentPageId, secondPage.id);

assert.equal(
  selectedObjectBelongsToPage(
    state.snapshot,
    selectedObject.id,
    secondPage.id,
  ),
  true,
);
assert.equal(
  selectedObjectBelongsToPage(
    state.snapshot,
    selectedObject.id,
    firstPage.id,
  ),
  false,
);

const groupedSnapshot = {
  editing: [{ node_id: 50 }],
  outline: [
    { id: 50, parent_id: secondPage.id },
    { id: 51, parent_id: 50 },
    { id: 52, parent_id: 51 },
    { id: 60, parent_id: secondPage.id },
  ],
};
assert.equal(editableAncestorNodeId(groupedSnapshot, 50), 50);
assert.equal(editableAncestorNodeId(groupedSnapshot, 52), 50);
assert.equal(editableAncestorNodeId(groupedSnapshot, 60), null);

const previous = { ...state.snapshot,
  editing: [{ node_id: selectedObject.id, page_id: secondPage.id, binding: "selected" }],
};
state.selectedObjectId = selectedObject.id;
state.snapshot = {
  layout: { pages: [firstPage, secondPage], objects: [
    { id: 100, page_id: secondPage.id }, selectedObject,
  ] },
  editing: [
    { node_id: 100, page_id: secondPage.id, binding: "selected" },
    { node_id: selectedObject.id, page_id: secondPage.id, binding: "other" },
  ],
};
navigation.reconcile(state.snapshot, previous);
assert.equal(state.selectedObjectId, 100,
  "a changed node identifier selected a different source binding");
const beforeRemoval = state.snapshot;
state.snapshot = {
  layout: { pages: [firstPage, secondPage], objects: [{ id: 100, page_id: secondPage.id }] },
  editing: [{ node_id: 100, page_id: secondPage.id, binding: "replacement" }],
};
navigation.reconcile(state.snapshot, beforeRemoval);
assert.equal(state.selectedObjectId, null,
  "removing a binding left another object selected under its reused identifier");
