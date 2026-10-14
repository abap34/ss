import { subtreeNodeIds } from "./geometry.js";

const captureDistance = 4;
const releaseDistance = 6;
const screenDistanceTolerance = 1e-7;

export function collectSnapTargets(snapshot, page, nodeId, resolveFrame, isDeleting) {
  const excluded = new Set(subtreeNodeIds(snapshot, nodeId));
  const parents = new Map(snapshot.outline.map((item) => [item.id, item.parent_id]));
  // Ancestor bounds also change when their child moves.
  let parent = parents.get(nodeId);
  while (parent != null && parent !== page.id && !excluded.has(parent)) {
    excluded.add(parent);
    parent = parents.get(parent);
  }
  const targets = [{
    nodeId: page.id,
    frame: { x: 0, y: 0, width: page.width, height: page.height },
  }];
  for (const object of snapshot.layout.objects) {
    if (object.page_id !== page.id || excluded.has(object.id) ||
        isDeleting(object.id)) continue;
    const frame = resolveFrame(object.id);
    if (frame) targets.push({ nodeId: object.id, frame: { ...frame } });
  }
  return targets;
}

// Always pass the uncorrected bounds derived from the original pointer position.
export function snapBounds(bounds, targets, scale, previous = {}) {
  const snaps = {
    x: snapAxis(bounds, targets, "x", scale.x, previous.x),
    y: snapAxis(bounds, targets, "y", scale.y, previous.y),
  };
  const corrected = {
    ...bounds,
    x: bounds.x + (snaps.x?.offset ?? 0),
    y: bounds.y + (snaps.y?.offset ?? 0),
  };
  const guides = [];
  for (const axis of ["x", "y"]) {
    const snap = snaps[axis];
    if (!snap) continue;
    const perpendicular = axis === "x" ? "y" : "x";
    const extent = axis === "x" ? "height" : "width";
    const target = snap.target.frame;
    guides.push({
      axis,
      coordinate: snap.coordinate,
      start: Math.min(corrected[perpendicular], target[perpendicular]),
      end: Math.max(
        corrected[perpendicular] + corrected[extent],
        target[perpendicular] + target[extent],
      ),
      points: [...new Set([
        corrected[perpendicular] + corrected[extent] / 2,
        target[perpendicular] + target[extent] / 2,
      ])],
    });
  }
  return { bounds: corrected, snaps, guides };
}

function snapAxis(bounds, targets, axis, scale, previous) {
  if (!(scale > 0) || !Number.isFinite(scale)) return null;
  const values = anchors(bounds, axis);
  if (previous) {
    const offset = previous.coordinate - values[previous.anchor];
    if (Math.abs(offset) * scale <= releaseDistance + screenDistanceTolerance) {
      return { ...previous, offset };
    }
  }
  let best = null;
  for (const target of targets) {
    const targetValues = anchors(target.frame, axis);
    for (let anchor = 0; anchor < values.length; anchor += 1) {
      for (let targetAnchor = 0; targetAnchor < targetValues.length; targetAnchor += 1) {
        const coordinate = targetValues[targetAnchor];
        const offset = coordinate - values[anchor];
        const distance = Math.abs(offset) * scale;
        if (distance > captureDistance + screenDistanceTolerance) continue;
        if (best && distance > best.distance + screenDistanceTolerance) continue;
        // Prefer matching edges or centers when candidates are equally close.
        if (best && Math.abs(distance - best.distance) <= screenDistanceTolerance &&
            (anchor !== targetAnchor || best.anchor === best.targetAnchor)) continue;
        best = { target, anchor, targetAnchor, coordinate, offset, distance };
      }
    }
  }
  return best;
}

function anchors(frame, axis) {
  const extent = axis === "x" ? frame.width : frame.height;
  return [frame[axis], frame[axis] + extent / 2, frame[axis] + extent];
}
