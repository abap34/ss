import { setRect, svgElement } from "./dom.js";
import {
  editableAncestorNodeId,
  previewFrame,
  subtreeNodeIds,
  svgPoint,
} from "./geometry.js";
import { renderConstraints } from "./constraints.js";

const minimumPlacementLength = 4;
const minimumEditedLineLength = 0.25;
const defaultLineLength = 160;
const lineSnapAngle = Math.PI / 12;

export class InteractionController {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.drag = null;
    this.placement = null;
    this.lineEndpointDrag = null;
    this.updateDrag = this.updateDrag.bind(this);
    this.finishDrag = this.finishDrag.bind(this);
    this.cancelDrag = this.cancelDrag.bind(this);
    this.updatePlacement = this.updatePlacement.bind(this);
    this.finishPlacement = this.finishPlacement.bind(this);
    this.cancelPlacement = this.cancelPlacement.bind(this);
    this.updateLineEndpoint = this.updateLineEndpoint.bind(this);
    this.finishLineEndpoint = this.finishLineEndpoint.bind(this);
    this.cancelLineEndpoint = this.cancelLineEndpoint.bind(this);
    this.handleKeydown = this.handleKeydown.bind(this);
    window.addEventListener("keydown", this.handleKeydown);
  }

  renderLayer(page) {
    const svg = svgElement("svg", "interaction-layer");
    svg.setAttribute("viewBox", `0 0 ${page.width} ${page.height}`);
    const objects = this.state.snapshot.layout.objects
      .filter((object) => object.page_id === page.id)
      .sort((left, right) =>
        right.width * right.height - left.width * left.height
      );
    if (
      selectedObjectBelongsToPage(
        this.state.snapshot,
        this.state.selectedObjectId,
        page.id,
      )
    ) {
      svg.append(
        renderConstraints(
          this.state.snapshot,
          page,
          this.state.selectedObjectId,
          (nodeId) => this.frameByNode(page, nodeId),
        ),
      );
    }
    for (const object of objects) svg.append(this.hitTarget(page, object));
    const pending = this.actions.shape.pendingInsertion(page.id);
    if (pending) svg.append(this.pendingShape(pending));
    if (this.state.shapeTool !== "select" &&
        this.actions.shape.canInsert(page.id)) {
      svg.append(this.placementTarget(page));
    }
    return svg;
  }

  reset() {
    this.cleanup();
    this.cleanupPlacement();
    this.cleanupLineEndpoint();
  }

  placementTarget(page) {
    const target = svgElement("rect", "shape-placement-hit");
    setRect(target, { x: 0, y: 0, width: page.width, height: page.height });
    target.addEventListener("pointerdown", (event) => {
      if (event.button === 0) this.beginPlacement(event, page, target);
    });
    target.addEventListener("contextmenu", (event) => {
      event.preventDefault();
      this.cleanupPlacement();
      this.actions.shape.cancel();
    });
    return target;
  }

  beginPlacement(event, page, target) {
    if (!this.actions.shape.canInsert(page.id)) return;
    event.preventDefault();
    const svg = target.ownerSVGElement;
    const start = clampPoint(svgPoint(svg, event), page);
    const ghost = this.placementGhost(this.state.shapeTool);
    applyShapeStyle(ghost, this.state.shapeTool, this.state.shapeStyle);
    svg.insertBefore(ghost, target);
    this.placement = {
      pointerId: event.pointerId,
      page,
      target,
      svg,
      start,
      current: start,
      ghost,
      kind: this.state.shapeTool,
    };
    target.setPointerCapture(event.pointerId);
    target.addEventListener("pointermove", this.updatePlacement);
    target.addEventListener("pointerup", this.finishPlacement);
    target.addEventListener("pointercancel", this.cancelPlacement);
    this.updatePlacementGhost();
  }

  updatePlacement(event) {
    const placement = this.placement;
    if (!placement || event.pointerId !== placement.pointerId) return;
    placement.current = placementPoint(placement, event);
    this.updatePlacementGhost();
  }

  finishPlacement(event) {
    const placement = this.placement;
    if (!placement || event.pointerId !== placement.pointerId) return;
    placement.current = placementPoint(placement, event);
    const geometry = placement.kind === "line"
      ? lineGeometry(placement.start, placement.current, placement.page)
      : {
        bounds: shapeBounds(
          placement.start,
          placement.current,
          placement.kind,
          placement.page,
        ),
      };
    const pageId = placement.page.id;
    this.cleanupPlacement();
    this.actions.shape.insert(pageId, geometry);
  }

  cancelPlacement() {
    if (!this.placement) return;
    this.cleanupPlacement();
    this.actions.render();
  }

  cleanupPlacement() {
    const placement = this.placement;
    if (!placement) return;
    placement.target.removeEventListener("pointermove", this.updatePlacement);
    placement.target.removeEventListener("pointerup", this.finishPlacement);
    placement.target.removeEventListener("pointercancel", this.cancelPlacement);
    placement.ghost.remove();
    this.placement = null;
  }

  handleKeydown(event) {
    if (event.key === "Escape") {
      if (this.lineEndpointDrag) {
        event.preventDefault();
        this.cancelLineEndpoint();
        return;
      }
      if (this.placement) {
        event.preventDefault();
        this.cleanupPlacement();
        this.actions.shape.cancel();
        return;
      }
      if (this.actions.shape.cancel()) event.preventDefault();
      return;
    }
    if (event.key.toLowerCase() !== "l" || event.metaKey || event.ctrlKey ||
        event.altKey || this.placement || this.lineEndpointDrag ||
        isTypingTarget(event.target) ||
        !this.actions.shape.canInsert(this.state.currentPageId)) return;
    event.preventDefault();
    this.actions.shape.selectTool("line");
  }

  placementGhost(kind) {
    if (kind === "line") return svgElement("line", "shape-placement-ghost");
    if (kind === "circle") return svgElement("ellipse", "shape-placement-ghost");
    if (kind === "arrow") return svgElement("polygon", "shape-placement-ghost");
    return svgElement("rect", "shape-placement-ghost");
  }

  pendingShape(preview) {
    const shape = this.placementGhost(preview.kind);
    shape.classList.add("shape-placement-preview");
    setShapeGeometry(shape, preview.kind, preview);
    applyShapeStyle(shape, preview.kind, preview);
    return shape;
  }

  updatePlacementGhost() {
    const placement = this.placement;
    if (!placement) return;
    const geometry = placement.kind === "line"
      ? { start: placement.start, end: placement.current }
      : {
        bounds: placementBounds(
          placement.start,
          placement.current,
          placement.kind,
        ),
      };
    setShapeGeometry(placement.ghost, placement.kind, geometry);
  }

  isMovable(nodeId) {
    return Boolean(
      !this.state.snapshot?.stale &&
        !this.actions.objectLocks.isLocked(nodeId) &&
        this.actions.translation.canDrag(nodeId) &&
        this.state.snapshot?.editing.some((target) =>
          target.node_id === nodeId
        ),
    );
  }

  hitTarget(page, object) {
    const frame = this.actions.translation.frame(page, object);
    const editableNodeId = editableAncestorNodeId(
      this.state.snapshot,
      object.id,
    );
    const editableObject = editableNodeId == null
      ? null
      : this.state.snapshot.layout.objects.find((candidate) =>
        candidate.id === editableNodeId
      );
    const target = editableObject || object;
    const selected = target.id === this.state.selectedObjectId;
    const userLocked = editableObject != null &&
      this.actions.objectLocks.isLocked(editableObject.id);
    const movable = editableObject != null && this.isMovable(editableObject.id);
    const shapeTarget = this.actions.shape.styleTarget(target.id);
    const pendingLineGeometry = shapeTarget?.kind === "line"
      ? this.actions.shape.pendingLineGeometry(target.id)
      : null;
    const group = svgElement(
      "g",
      `object-hit${selected ? " is-selected" : ""}${
        movable ? " is-movable" : " is-locked"
      }${userLocked ? " is-user-locked" : ""}`,
    );
    group.dataset.objectId = String(object.id);
    if (userLocked) group.dataset.objectLocked = "true";
    if (shapeTarget?.kind === "line") {
      const targetFrame = this.actions.translation.frame(page, target);
      const segment = pendingLineGeometry ||
        lineTargetSegment(targetFrame, shapeTarget);
      const hit = svgElement("line", "object-hit-line");
      const outline = svgElement("line", "object-hit-line-outline");
      setLine(hit, segment.start, segment.end);
      setLine(outline, segment.start, segment.end);
      group.append(hit, outline);
      if (selected) {
        const geometryEditable = !userLocked &&
          !this.state.snapshot?.stale && !this.actions.shape.isBusy();
        group.classList.toggle(
          "is-line-geometry-pending",
          pendingLineGeometry != null,
        );
        group.append(
          this.lineEndpointHandle(
            "start",
            segment.start,
            geometryEditable,
            page,
            shapeTarget,
            segment,
            hit,
            outline,
          ),
          this.lineEndpointHandle(
            "end",
            segment.end,
            geometryEditable,
            page,
            shapeTarget,
            segment,
            hit,
            outline,
          ),
        );
      }
    } else {
      const rect = svgElement("rect", "object-hit-rect");
      setRect(rect, frame);
      group.append(rect);
    }
    group.addEventListener("click", (event) => {
      event.stopPropagation();
      this.actions.selectObject(target.id, target.page_id);
    });
    group.addEventListener("dblclick", () => this.actions.revealSource(target));
    group.addEventListener(
      "pointerdown",
      (event) => this.beginDrag(
        event,
        page,
        target,
        group,
        this.actions.translation.frame(page, target),
      ),
    );
    return group;
  }

  lineEndpointHandle(
    endpoint,
    point,
    editable,
    page,
    target,
    segment,
    hit,
    outline,
  ) {
    const handle = svgElement(
      "g",
      `line-endpoint-handle${editable ? "" : " is-disabled"}`,
    );
    handle.dataset.endpoint = endpoint;
    handle.setAttribute("aria-label", `Move line ${endpoint} point`);
    handle.setAttribute("aria-disabled", String(!editable));
    const targetCircle = svgElement("circle", "line-endpoint-hit");
    targetCircle.setAttribute("r", "18");
    const marker = svgElement("circle", "line-endpoint-marker");
    marker.setAttribute("r", "8");
    setCirclePoint(targetCircle, point);
    setCirclePoint(marker, point);
    handle.append(targetCircle, marker);
    if (editable) {
      handle.addEventListener("pointerdown", (event) => {
        if (event.button !== 0) return;
        event.stopPropagation();
        this.beginLineEndpoint(
          event,
          endpoint,
          page,
          target,
          segment,
          hit,
          outline,
          handle,
        );
      });
    }
    return handle;
  }

  beginLineEndpoint(
    event,
    endpoint,
    page,
    target,
    segment,
    hit,
    outline,
    handle,
  ) {
    event.preventDefault();
    const svg = handle.ownerSVGElement;
    const group = handle.parentElement;
    this.lineEndpointDrag = {
      pointerId: event.pointerId,
      endpoint,
      page,
      target,
      svg,
      group,
      handle,
      hit,
      outline,
      original: endpoint === "start" ? { ...segment.start } : { ...segment.end },
      start: { ...segment.start },
      end: { ...segment.end },
    };
    group.classList.add("is-editing-line-geometry");
    try {
      handle.setPointerCapture(event.pointerId);
    } catch {
      // Window listeners below keep the drag active when SVG capture is absent.
    }
    window.addEventListener("pointermove", this.updateLineEndpoint);
    window.addEventListener("pointerup", this.finishLineEndpoint);
    window.addEventListener("pointercancel", this.cancelLineEndpoint);
  }

  updateLineEndpoint(event) {
    const drag = this.lineEndpointDrag;
    if (!drag || event.pointerId !== drag.pointerId) return;
    const fixed = drag.endpoint === "start" ? drag.end : drag.start;
    let current = clampPoint(svgPoint(drag.svg, event), drag.page);
    if (event.shiftKey) current = snapLineEnd(fixed, current, drag.page);
    if (drag.endpoint === "start") drag.start = current;
    else drag.end = current;
    setLine(drag.hit, drag.start, drag.end);
    setLine(drag.outline, drag.start, drag.end);
    for (const circle of drag.handle.querySelectorAll("circle")) {
      setCirclePoint(circle, current);
    }
  }

  finishLineEndpoint(event) {
    const drag = this.lineEndpointDrag;
    if (!drag || event.pointerId !== drag.pointerId) return;
    this.updateLineEndpoint(event);
    const current = drag.endpoint === "start" ? drag.start : drag.end;
    const moved = Math.hypot(
      current.x - drag.original.x,
      current.y - drag.original.y,
    );
    const length = Math.hypot(
      drag.end.x - drag.start.x,
      drag.end.y - drag.start.y,
    );
    this.cleanupLineEndpoint();
    if (moved < 0.25 || length < minimumEditedLineLength ||
        !this.actions.shape.editLineGeometry(
          drag.target,
          drag.start,
          drag.end,
        )) {
      this.actions.render();
    }
  }

  cancelLineEndpoint() {
    if (!this.lineEndpointDrag) return;
    this.cleanupLineEndpoint();
    this.actions.render();
  }

  cleanupLineEndpoint() {
    const drag = this.lineEndpointDrag;
    if (!drag) return;
    drag.group.classList.remove("is-editing-line-geometry");
    window.removeEventListener("pointermove", this.updateLineEndpoint);
    window.removeEventListener("pointerup", this.finishLineEndpoint);
    window.removeEventListener("pointercancel", this.cancelLineEndpoint);
    this.lineEndpointDrag = null;
  }

  beginDrag(event, page, object, group, frame) {
    if (event.button !== 0 || this.lineEndpointDrag) return;
    event.preventDefault();
    this.actions.selectObject(object.id, object.page_id, false);
    if (!this.isMovable(object.id)) return;
    const svg = group.ownerSVGElement;
    this.drag = {
      pointerId: event.pointerId,
      page,
      object,
      group,
      svg,
      start: svgPoint(svg, event),
      from: frame,
      base: previewFrame(page, object),
      to: { ...frame },
      relative: event.shiftKey,
      nodeIds: subtreeNodeIds(this.state.snapshot, object.id),
    };
    group.setPointerCapture(event.pointerId);
    group.classList.add("is-dragging");
    group.addEventListener("pointermove", this.updateDrag);
    group.addEventListener("pointerup", this.finishDrag);
    group.addEventListener("pointercancel", this.cancelDrag);
  }

  updateDrag(event) {
    const drag = this.drag;
    if (!drag || event.pointerId !== drag.pointerId) return;
    const point = svgPoint(drag.svg, event);
    const dx = point.x - drag.start.x;
    const dy = point.y - drag.start.y;
    drag.relative = event.shiftKey;
    drag.to = { ...drag.from, x: drag.from.x + dx, y: drag.from.y + dy };
    const preview = drag.svg.previousElementSibling;
    const totalX = drag.to.x - drag.base.x;
    const totalY = drag.to.y - drag.base.y;
    drag.group.setAttribute("transform", `translate(${totalX} ${totalY})`);
    for (const nodeId of drag.nodeIds) {
      for (
        const item of preview.querySelectorAll(`[data-ss-node-id="${nodeId}"]`)
      ) {
        const baseX = Number(item.dataset.ssBaseTranslationX || 0);
        const baseY = Number(item.dataset.ssBaseTranslationY || 0);
        item.style.translate = `${baseX + totalX}pt ${baseY + totalY}pt`;
        item.dataset.ssPendingTranslation = "true";
      }
    }
  }

  finishDrag(event) {
    const drag = this.drag;
    if (!drag || event.pointerId !== drag.pointerId) return;
    this.cleanup();
    const dx = drag.to.x - drag.from.x;
    const dy = drag.to.y - drag.from.y;
    if (Math.abs(dx) < 0.25 && Math.abs(dy) < 0.25) {
      this.actions.render();
      return;
    }
    this.actions.translation.submit({
      snapshotId: this.state.snapshot.snapshot_id,
      nodeId: drag.object.id,
      pageId: drag.object.page_id,
      mode: drag.relative || event.shiftKey ? "relative" : "absolute",
      fromBounds: drag.from,
      toBounds: drag.to,
    });
  }

  cancelDrag() {
    this.cleanup();
    this.actions.render();
  }

  cleanup() {
    const drag = this.drag;
    if (!drag) return;
    drag.group.classList.remove("is-dragging");
    drag.group.removeEventListener("pointermove", this.updateDrag);
    drag.group.removeEventListener("pointerup", this.finishDrag);
    drag.group.removeEventListener("pointercancel", this.cancelDrag);
    this.drag = null;
  }

  frameByNode(page, nodeId) {
    if (nodeId === page.id) {
      return { x: 0, y: 0, width: page.width, height: page.height };
    }
    const object = this.state.snapshot.layout.objects.find((candidate) =>
      candidate.id === nodeId
    );
    return object ? this.actions.translation.frame(page, object) : null;
  }
}

function clampPoint(point, page) {
  return {
    x: Math.min(page.width, Math.max(0, point.x)),
    y: Math.min(page.height, Math.max(0, point.y)),
  };
}

function placementPoint(placement, event) {
  const point = clampPoint(svgPoint(placement.svg, event), placement.page);
  if (placement.kind !== "line" || !event.shiftKey) return point;
  return snapLineEnd(placement.start, point, placement.page);
}

function snapLineEnd(start, current, page) {
  const dx = current.x - start.x;
  const dy = current.y - start.y;
  const length = Math.hypot(dx, dy);
  if (length === 0) return current;
  const angle = Math.round(Math.atan2(dy, dx) / lineSnapAngle) * lineSnapAngle;
  const vector = { x: Math.cos(angle) * length, y: Math.sin(angle) * length };
  const scale = Math.min(1, vectorBoundaryScale(start, vector, page));
  return {
    x: start.x + vector.x * scale,
    y: start.y + vector.y * scale,
  };
}

function vectorBoundaryScale(start, vector, page) {
  let scale = Infinity;
  if (vector.x > 0) scale = Math.min(scale, (page.width - start.x) / vector.x);
  else if (vector.x < 0) scale = Math.min(scale, -start.x / vector.x);
  if (vector.y > 0) scale = Math.min(scale, (page.height - start.y) / vector.y);
  else if (vector.y < 0) scale = Math.min(scale, -start.y / vector.y);
  return Number.isFinite(scale) ? Math.max(0, scale) : 1;
}

function lineGeometry(start, end, page) {
  if (Math.hypot(end.x - start.x, end.y - start.y) >= minimumPlacementLength) {
    return { start: { ...start }, end: { ...end } };
  }
  const availableRight = page.width - start.x;
  const availableLeft = start.x;
  const direction = availableRight >= defaultLineLength ||
      availableRight >= availableLeft
    ? 1
    : -1;
  const available = direction > 0 ? availableRight : availableLeft;
  const offset = direction * Math.min(defaultLineLength, available);
  return {
    start: { ...start },
    end: { x: start.x + offset, y: start.y },
  };
}

function shapeBounds(start, current, kind, page) {
  const bounds = placementBounds(start, current, kind);
  if (bounds.width >= minimumPlacementLength &&
      bounds.height >= minimumPlacementLength) return bounds;
  return defaultBounds(start, page, kind);
}

function placementBounds(start, current, kind) {
  const dx = current.x - start.x;
  const dy = current.y - start.y;
  if (kind === "circle") {
    const size = Math.min(Math.abs(dx), Math.abs(dy));
    return {
      x: dx < 0 ? start.x - size : start.x,
      y: dy < 0 ? start.y - size : start.y,
      width: size,
      height: size,
    };
  }
  return {
    x: Math.min(start.x, current.x),
    y: Math.min(start.y, current.y),
    width: Math.abs(dx),
    height: Math.abs(dy),
  };
}

function defaultBounds(point, page, kind) {
  const size = kind === "circle"
    ? { width: 120, height: 120 }
    : kind === "arrow"
    ? { width: 170, height: 90 }
    : { width: 160, height: 100 };
  return {
    x: Math.min(page.width - size.width, Math.max(0, point.x - size.width / 2)),
    y: Math.min(page.height - size.height, Math.max(0, point.y - size.height / 2)),
    ...size,
  };
}

function arrowPoints(bounds) {
  const x = bounds.x;
  const y = bounds.y;
  const width = bounds.width;
  const height = bounds.height;
  return [
    [x, y + height * 0.25],
    [x + width * 0.66, y + height * 0.25],
    [x + width * 0.66, y],
    [x + width, y + height * 0.5],
    [x + width * 0.66, y + height],
    [x + width * 0.66, y + height * 0.75],
    [x, y + height * 0.75],
  ].map((point) => point.join(",")).join(" ");
}

function setShapeGeometry(shape, kind, geometry) {
  if (kind === "line") {
    setLine(shape, geometry.start, geometry.end);
    return;
  }
  const bounds = geometry.bounds;
  if (kind === "circle") {
    shape.setAttribute("cx", String(bounds.x + bounds.width / 2));
    shape.setAttribute("cy", String(bounds.y + bounds.height / 2));
    shape.setAttribute("rx", String(bounds.width / 2));
    shape.setAttribute("ry", String(bounds.height / 2));
  } else if (kind === "arrow") {
    shape.setAttribute("points", arrowPoints(bounds));
  } else {
    setRect(shape, bounds);
  }
}

function setLine(line, start, end) {
  line.setAttribute("x1", String(start.x));
  line.setAttribute("y1", String(start.y));
  line.setAttribute("x2", String(end.x));
  line.setAttribute("y2", String(end.y));
}

function setCirclePoint(circle, point) {
  circle.setAttribute("cx", String(point.x));
  circle.setAttribute("cy", String(point.y));
}

function applyShapeStyle(shape, kind, style) {
  if (kind === "line") {
    shape.style.fill = "none";
  } else {
    shape.style.fill = style.fill.enabled ? style.fill.color : "none";
    shape.style.fillOpacity = String(style.fill.opacity);
  }
  shape.style.stroke = kind === "line" || style.stroke.enabled
    ? style.stroke.color
    : "none";
  shape.style.strokeWidth = String(style.stroke.width);
  applyStrokeStyle(shape, style.stroke);
}

function lineTargetSegment(frame, target) {
  return {
    start: {
      x: frame.x + target.start.x * frame.width,
      y: frame.y + target.start.y * frame.height,
    },
    end: {
      x: frame.x + target.end.x * frame.width,
      y: frame.y + target.end.y * frame.height,
    },
  };
}

function applyStrokeStyle(shape, stroke) {
  shape.style.strokeLinecap = stroke.style === "dotted" ||
      stroke.style === "dash_dot"
    ? "round"
    : "butt";
  if (stroke.style === "dashed") {
    shape.style.strokeDasharray = "8 5";
  } else if (stroke.style === "dotted") {
    shape.style.strokeDasharray = `${stroke.width} 4`;
  } else if (stroke.style === "dash_dot") {
    shape.style.strokeDasharray = `8 4 ${stroke.width} 4`;
  } else {
    shape.style.strokeDasharray = "none";
  }
}

function isTypingTarget(target) {
  return Boolean(target?.closest?.(
    "input, textarea, select, [contenteditable]:not([contenteditable='false'])",
  ));
}

export function selectedObjectBelongsToPage(snapshot, objectId, pageId) {
  return objectId != null &&
    snapshot.layout.objects.some((object) =>
      object.id === objectId && object.page_id === pageId
    );
}
