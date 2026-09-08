#!/usr/bin/env node
import assert from "node:assert/strict";
import { ShapeController, defaultShapeStyle } from "../../../editor/vscode/media/editor/shape-insertion.js";
import { IconController, defaultIconDraft } from "../../../editor/vscode/media/editor/icon-insertion.js";

for (const kind of ["shape", "icon"]) {
  const state = {
    snapshot: snapshot("initial"),
    shapeTool: kind === "shape" ? "rectangle" : "icon",
    shapeStyle: structuredClone(defaultShapeStyle),
    iconDraft: { ...defaultIconDraft, source: "fa-solid:star", svg: "<svg/>" },
  };
  const messages = [];
  const selections = [];
  const controller = new (kind === "shape" ? ShapeController : IconController)(state, {
    post: (message) => messages.push(structuredClone(message)),
    render: () => {},
    selectObject: (nodeId) => selections.push(nodeId),
  });
  const result = (request, status, extra = {}) => ({
    type: kind === "shape" ? "shapeEditResult" : "iconEditResult",
    operation: "insert",
    requestId: request.requestId,
    status,
    ...extra,
  });
  const insert = (pageId = 11) => controller.insert(pageId, {
    bounds: { x: 10, y: 20, width: 100, height: 100 },
  });

  assert(insert());
  const original = messages.at(-1);
  controller.acceptResult(result(original, "stale"));
  assert.equal(controller.acceptResult(result(original, "rejected")), null,
    `${kind}: a duplicate response discarded a queued retry`);
  state.snapshot = snapshot("rebased");
  controller.reconcile(state.snapshot, 2);
  const retried = messages.at(-1);
  assert.notEqual(retried.requestId, original.requestId);
  assert.equal(controller.acceptResult(result(original, "applied", { documentVersion: 3 })), null);
  assert(controller.isBusy());
  assert(insert(12));
  controller.acceptResult(result(retried, "applied", {
    documentVersion: 4,
    selection: { pageId: 11, binding: "inserted" },
  }));
  assert.equal(controller.acceptResult(result(retried, "stale")), null,
    `${kind}: a duplicate response restarted an applied edit`);
  state.snapshot = snapshot("before-edit-version");
  assert.equal(controller.reconcile(state.snapshot, 3), null);
  assert.equal(messages.length, 2, `${kind}: the next edit started before the applied version`);
  state.snapshot = snapshot("failed-build", [12]);
  state.snapshot.stale = true;
  assert.equal(controller.reconcile(state.snapshot, 5), null);
  assert.equal(messages.length, 2, `${kind}: a stale preview completed an edit`);
  state.snapshot = snapshot("deleted-page", [12]);
  assert.equal(controller.reconcile(state.snapshot, 5)?.status, "failed");
  assert.equal(messages.length, 3, `${kind}: deleting the first page blocked the next insertion`);
  assert.equal(messages.at(-1).pageId, 12);
  assert.equal(selections.length, 0);
  controller.acceptResult(result(messages.at(-1), "rejected"));
  assert.equal(controller.isBusy(), false);
  assert.equal(state.shapeTool, "select");

  state.shapeTool = kind === "shape" ? "rectangle" : "icon";
  state.snapshot = snapshot("queue-deletion");
  assert(insert(11));
  assert(insert(11));
  assert(insert(12));
  state.snapshot = snapshot("second-page-only", [12]);
  const failed = controller.acceptResult(result(messages.at(-1), "rejected", { message: "First request failed." }));
  assert.match(failed.message, /First request failed/);
  assert.match(failed.message, /no longer supports/);
  assert.equal(messages.at(-1).pageId, 12);
  controller.acceptResult(result(messages.at(-1), "rejected"));
  assert.equal(controller.isBusy(), false);
  assert.equal(state.shapeTool, "select");

  state.shapeTool = kind === "shape" ? "rectangle" : "icon";
  state.snapshot = snapshot("queued-all-deleted");
  state.snapshot.stale = true;
  assert(insert());
  assert(insert());
  state.snapshot = snapshot("empty", []);
  assert.equal(controller.reconcile(state.snapshot, 6)?.status, "failed");
  assert.equal(controller.isBusy(), false);
  assert.equal(state.shapeTool, "select", `${kind}: skipped insertions left the insertion tool active`);
}

function snapshot(id, pageIds = [11, 12]) {
  return {
    snapshot_id: id,
    layout: { pages: pageIds.map((id) => ({ id })) },
    page_editing: pageIds.map((page_id) => ({ page_id, insert_shapes: true, insert_icons: true })),
    shape_editing: [],
    editing: [],
  };
}
