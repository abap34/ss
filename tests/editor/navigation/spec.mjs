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
  mode: "continuous",
  currentPageId: secondPage.id,
  selectedObjectId: null,
};
const navigation = new EditorNavigation(state);

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
