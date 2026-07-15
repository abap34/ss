export function previewFrame(page, object) {
  return {
    x: object.x,
    y: page.height - object.y - object.height,
    width: object.width,
    height: object.height,
  };
}

export function frameByNode(snapshot, page, nodeId) {
  if (nodeId === page.id) {
    return { x: 0, y: 0, width: page.width, height: page.height };
  }
  const object = snapshot.layout.objects.find((candidate) =>
    candidate.id === nodeId
  );
  return object ? previewFrame(page, object) : null;
}

export function anchorSegment(frame, anchor) {
  if (anchor === "left") {
    return segment(frame.x, frame.y, frame.x, frame.y + frame.height);
  }
  if (anchor === "right") {
    return segment(
      frame.x + frame.width,
      frame.y,
      frame.x + frame.width,
      frame.y + frame.height,
    );
  }
  if (anchor === "center_x") {
    return segment(
      frame.x + frame.width / 2,
      frame.y,
      frame.x + frame.width / 2,
      frame.y + frame.height,
    );
  }
  if (anchor === "top") {
    return segment(frame.x, frame.y, frame.x + frame.width, frame.y);
  }
  if (anchor === "bottom") {
    return segment(
      frame.x,
      frame.y + frame.height,
      frame.x + frame.width,
      frame.y + frame.height,
    );
  }
  return segment(
    frame.x,
    frame.y + frame.height / 2,
    frame.x + frame.width,
    frame.y + frame.height / 2,
  );
}

export function constraintGeometry(source, target, axis) {
  if (axis === "vertical") {
    const x = sharedCoordinate(source.x1, source.x2, target.x1, target.x2);
    const connector = segment(x, source.cy, x, target.cy);
    return {
      source: segment(
        Math.min(source.x1, x),
        source.cy,
        Math.max(source.x2, x),
        source.cy,
      ),
      target: segment(
        Math.min(target.x1, x),
        target.cy,
        Math.max(target.x2, x),
        target.cy,
      ),
      connector,
      label: { x: connector.cx + 9, y: connector.cy - 2 },
    };
  }

  const y = sharedCoordinate(source.y1, source.y2, target.y1, target.y2);
  const connector = segment(source.cx, y, target.cx, y);
  return {
    source: segment(
      source.cx,
      Math.min(source.y1, y),
      source.cx,
      Math.max(source.y2, y),
    ),
    target: segment(
      target.cx,
      Math.min(target.y1, y),
      target.cx,
      Math.max(target.y2, y),
    ),
    connector,
    label: { x: connector.cx, y: connector.cy - 7 },
  };
}

export function svgPoint(svg, event) {
  const rect = svg.getBoundingClientRect();
  const viewBox = svg.viewBox.baseVal;
  return {
    x: viewBox.x + ((event.clientX - rect.left) / rect.width) * viewBox.width,
    y: viewBox.y + ((event.clientY - rect.top) / rect.height) * viewBox.height,
  };
}

export function signed(value) {
  const number = formatNumber(value);
  return value > 0 ? `+${number}` : number;
}

export function formatNumber(value) {
  return Number(value.toFixed(2)).toString();
}

export function subtreeNodeIds(snapshot, rootId) {
  const children = new Map();
  for (const item of snapshot?.outline || []) {
    if (item.parent_id == null) continue;
    if (!children.has(item.parent_id)) children.set(item.parent_id, []);
    children.get(item.parent_id).push(item.id);
  }
  const result = [];
  const pending = [rootId];
  const seen = new Set();
  while (pending.length > 0) {
    const nodeId = pending.pop();
    if (seen.has(nodeId)) continue;
    seen.add(nodeId);
    result.push(nodeId);
    for (const childId of children.get(nodeId) || []) pending.push(childId);
  }
  return result;
}

export function editableAncestorNodeId(snapshot, nodeId) {
  const editable = new Set(
    (snapshot?.editing || []).map((target) => target.node_id),
  );
  const parents = new Map();
  for (const item of snapshot?.outline || []) {
    if (item.parent_id != null) parents.set(item.id, item.parent_id);
  }
  const seen = new Set();
  let current = nodeId;
  while (current != null && !seen.has(current)) {
    if (editable.has(current)) return current;
    seen.add(current);
    current = parents.get(current);
  }
  return null;
}

function segment(x1, y1, x2, y2) {
  return { x1, y1, x2, y2, cx: (x1 + x2) / 2, cy: (y1 + y2) / 2 };
}

function sharedCoordinate(firstStart, firstEnd, secondStart, secondEnd) {
  const firstMin = Math.min(firstStart, firstEnd);
  const firstMax = Math.max(firstStart, firstEnd);
  const secondMin = Math.min(secondStart, secondEnd);
  const secondMax = Math.max(secondStart, secondEnd);
  const overlapStart = Math.max(firstMin, secondMin);
  const overlapEnd = Math.min(firstMax, secondMax);
  if (overlapStart <= overlapEnd) return (overlapStart + overlapEnd) / 2;
  if (firstMax < secondMin) return (firstMax + secondMin) / 2;
  return (secondMax + firstMin) / 2;
}
