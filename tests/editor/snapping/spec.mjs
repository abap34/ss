#!/usr/bin/env node
import assert from "node:assert/strict";
import { collectSnapTargets, snapBounds } from "../../../editor/vscode/media/editor/snapping.js";

const target = { nodeId: 2, frame: { x: 500, y: 600, width: 300, height: 300 } };
for (const zoom of [0.25, 1, 4]) {
  const scale = { x: zoom, y: zoom };
  for (let sourceAnchor = 0; sourceAnchor < 3; sourceAnchor += 1) {
    for (let targetAnchor = 0; targetAnchor < 3; targetAnchor += 1) {
      const alignedX = target.frame.x + targetAnchor * 150 - sourceAnchor * 100;
      const alignedY = target.frame.y + targetAnchor * 150 - sourceAnchor * 100;
      const raw = { x: alignedX + 3 / zoom, y: alignedY - 4 / zoom, width: 200, height: 200 };
      const snapped = snapBounds(raw, [target], scale);
      assert.equal(snapped.bounds.x, alignedX, "an edge or center did not align horizontally");
      assert.equal(snapped.bounds.y, alignedY, "an edge or center did not align vertically");
      assert.equal(snapped.guides.length, 2);
      assert.equal(snapped.guides[0].coordinate, target.frame.x + targetAnchor * 150);
      assert.equal(snapped.guides[1].coordinate, target.frame.y + targetAnchor * 150);
      assert.deepEqual(raw, {
        x: alignedX + 3 / zoom, y: alignedY - 4 / zoom, width: 200, height: 200,
      }, "snapping modified the uncorrected pointer bounds");
    }
  }

  const raw = { x: 500 + 4 / zoom, y: 20, width: 200, height: 200 };
  const isolated = { ...target, frame: { ...target.frame, width: 200 } };
  const captured = snapBounds(raw, [isolated], scale);
  assert.equal(captured.bounds.x, 500, "the capture boundary was excluded");
  assert.equal(captured.bounds.y, 20, "horizontal snapping restricted vertical motion");
  assert.equal(snapBounds({ ...raw, x: 500 + 5 / zoom }, [isolated], scale).snaps.x, null,
    "capture distance changed with zoom");
  const retained = snapBounds({ ...raw, x: 500 + 6 / zoom }, [isolated], scale, captured.snaps);
  assert.equal(retained.bounds.x, 500, "an active snap did not survive to the release boundary");
  const released = snapBounds({ ...raw, x: 500 + 7 / zoom }, [isolated], scale, retained.snaps);
  assert.equal(released.snaps.x, null, "a snap did not release beyond six screen pixels");
  assert.equal(released.bounds.x, 500 + 7 / zoom);

  // Reverse direction after release without accumulating previous corrections.
  const returned = snapBounds({ ...raw, x: 500 - 3 / zoom }, [isolated], scale, released.snaps);
  assert.equal(returned.bounds.x, 500);
}

const raw = { x: 503, y: 20, width: 200, height: 200 };
const scale = { x: 1, y: 1 };
const first = snapBounds(raw, [target], scale);
const closer = { nodeId: 3, frame: { ...target.frame, x: 505 } };
const retained = snapBounds({ ...raw, x: 506 }, [target, closer], scale, first.snaps);
assert.equal(retained.snaps.x.target.nodeId, target.nodeId,
  "a closer candidate replaced a snap before its release distance");
assert.equal(retained.bounds.x, 500);
const switched = snapBounds({ ...raw, x: 507 }, [target, closer], scale, retained.snaps);
assert.equal(switched.snaps.x.target.nodeId, closer.nodeId);
assert.equal(switched.bounds.x, 505);

const nearest = snapBounds(raw, [target, closer], scale);
assert.equal(nearest.bounds.x, 505, "the nearest candidate was not chosen");
const sameEdge = { nodeId: 4, frame: { ...target.frame, x: 700, width: 100 } };
const differentEdge = { nodeId: 5, frame: { ...target.frame, x: 100, width: 600 } };
assert.equal(snapBounds({ ...raw, x: 700 }, [differentEdge, sameEdge], scale).snaps.x.target.nodeId, 4,
  "equally close candidates did not prefer corresponding edges");

const nonuniform = snapBounds({ ...raw, x: 502, y: 608 }, [target], { x: 2, y: 0.5 });
assert.equal(nonuniform.bounds.x, 500);
assert.equal(nonuniform.bounds.y, 600);
assert.deepEqual(nonuniform.guides[0], {
  axis: "x", coordinate: 500, start: 600, end: 900, points: [700, 750],
});
assert.deepEqual(snapBounds(raw, [], scale).bounds, raw);
assert.equal(snapBounds(raw, [target], { x: 0, y: Infinity }).guides.length, 0);

const page = { id: 1, width: 1280, height: 720 };
const objects = [
  { id: 10, page_id: 1 }, { id: 11, page_id: 1 }, { id: 12, page_id: 1 },
  { id: 13, page_id: 1 }, { id: 14, page_id: 1 }, { id: 20, page_id: 2 },
];
const snapshot = {
  layout: { objects },
  outline: [
    { id: 1, parent_id: null }, { id: 10, parent_id: 1 },
    { id: 11, parent_id: 10 }, { id: 12, parent_id: 11 },
    { id: 13, parent_id: 10 }, { id: 14, parent_id: 1 },
  ],
};
const currentFrame = { x: 340, y: 200, width: 80, height: 60 };
const targets = collectSnapTargets(snapshot, page, 11, () => currentFrame, (id) => id === 14);
assert.deepEqual(targets.map((item) => item.nodeId), [1, 13],
  "snap targets included another page, deleted objects, or moving relatives");
assert.deepEqual(targets[1].frame, currentFrame,
  "targets did not use the current provisional frame");
currentFrame.x = 900;
assert.equal(targets[1].frame.x, 340, "target bounds changed during a drag");
const groupTargets = collectSnapTargets(snapshot, page, 10, () => currentFrame, () => false);
assert.deepEqual(groupTargets.map((item) => item.nodeId), [1, 14],
  "a group snapped to its own descendants");
for (const frame of [
  { x: 3, y: 3, width: 80, height: 60 },
  { x: 603, y: 333, width: 80, height: 60 },
  { x: 1203, y: 663, width: 80, height: 60 },
]) {
  const result = snapBounds(frame, [targets[0]], scale);
  assert.equal(result.bounds.x, frame.x - 3, "page edge or center did not snap");
  assert.equal(result.bounds.y, frame.y - 3, "page edge or center did not snap");
}
console.log("WYSIWYG snapping checks passed.");
