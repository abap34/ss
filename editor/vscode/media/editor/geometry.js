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

function segment(x1, y1, x2, y2) {
  return { x1, y1, x2, y2, cx: (x1 + x2) / 2, cy: (y1 + y2) / 2 };
}
