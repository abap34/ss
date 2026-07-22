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
const minimumResizedShapeExtent = 4;
const defaultLineLength = 160;
const lineSnapAngle = Math.PI / 12;
const resizeDirections = [
  "top-left",
  "top",
  "top-right",
  "right",
  "bottom-right",
  "bottom",
  "bottom-left",
  "left",
];

export class InteractionController {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.drag = null;
    this.placement = null;
    this.lineEndpointDrag = null;
    this.shapeResizeDrag = null;
    this.updateDrag = this.updateDrag.bind(this);
    this.finishDrag = this.finishDrag.bind(this);
    this.cancelDrag = this.cancelDrag.bind(this);
    this.updatePlacement = this.updatePlacement.bind(this);
    this.finishPlacement = this.finishPlacement.bind(this);
    this.cancelPlacement = this.cancelPlacement.bind(this);
    this.updateLineEndpoint = this.updateLineEndpoint.bind(this);
    this.finishLineEndpoint = this.finishLineEndpoint.bind(this);
    this.cancelLineEndpoint = this.cancelLineEndpoint.bind(this);
    this.updateShapeResize = this.updateShapeResize.bind(this);
    this.finishShapeResize = this.finishShapeResize.bind(this);
    this.cancelShapeResize = this.cancelShapeResize.bind(this);
    this.handleKeydown = this.handleKeydown.bind(this);
    window.addEventListener("keydown", this.handleKeydown);
  }

  renderLayer(page) {
    const svg = svgElement("svg", "interaction-layer");
    svg.setAttribute("viewBox", `0 0 ${page.width} ${page.height}`);
    if (this.state.pointerMode === "pan") return svg;
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
    const pending = this.state.shapeTool === "icon"
      ? this.actions.icon.pendingInsertion(page.id)
      : this.actions.shape.pendingInsertion(page.id);
    if (pending) svg.append(this.pendingShape(pending));
    if (this.state.shapeTool !== "select" &&
        this.canInsert(page.id)) {
      svg.append(this.placementTarget(page));
    }
    return svg;
  }

  reset() {
    this.cleanup();
    this.cleanupPlacement();
    this.cleanupLineEndpoint();
    this.cleanupShapeResize();
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
      this.activeInsertionController().cancel();
    });
    return target;
  }

  beginPlacement(event, page, target) {
    if (!this.canInsert(page.id)) return;
    event.preventDefault();
    const svg = target.ownerSVGElement;
    const start = clampPoint(svgPoint(svg, event), page);
    const ghost = this.placementGhost(this.state.shapeTool);
    if (this.state.shapeTool === "icon") {
      applyIconPreview(ghost, this.state.iconDraft.svg, this.state.iconDraft.color);
    } else {
      applyShapeStyle(ghost, this.state.shapeTool, this.state.shapeStyle);
    }
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
    this.activeInsertionController().insert(pageId, geometry);
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
      if (this.shapeResizeDrag) {
        event.preventDefault();
        this.cancelShapeResize();
        return;
      }
      if (this.placement) {
        event.preventDefault();
        this.cleanupPlacement();
        this.activeInsertionController().cancel();
        return;
      }
      if (this.activeInsertionController().cancel()) event.preventDefault();
      return;
    }
    if (this.navigatePageFromKey(event)) return;
    if (event.key.toLowerCase() !== "l" || event.metaKey || event.ctrlKey ||
        event.altKey || this.placement || this.lineEndpointDrag ||
        isTypingTarget(event.target) ||
        this.state.shapeTool === "icon" ||
        !this.actions.shape.canInsert(this.state.currentPageId)) return;
    event.preventDefault();
    this.actions.shape.selectTool("line");
  }

  navigatePageFromKey(event) {
    const offset = event.key === "ArrowUp"
      ? -1
      : event.key === "ArrowDown"
      ? 1
      : 0;
    if (offset === 0 || event.defaultPrevented || event.metaKey ||
        event.ctrlKey || event.altKey || event.shiftKey || this.drag ||
        this.placement || this.lineEndpointDrag || this.shapeResizeDrag ||
        (this.actions.shape.isBusy() || this.actions.icon.isBusy()) ||
        isTypingTarget(event.target)) {
      return false;
    }
    const pages = this.state.snapshot?.layout.pages || [];
    const current = pages.findIndex((page) =>
      page.id === this.state.currentPageId
    );
    if (current < 0) return false;
    event.preventDefault();
    const next = pages[current + offset];
    if (next) this.actions.navigatePage(next.id);
    return true;
  }

  placementGhost(kind) {
    if (kind === "icon") return svgElement("image", "icon-placement-ghost");
    if (kind === "line") return svgElement("line", "shape-placement-ghost");
    if (kind === "circle") return svgElement("ellipse", "shape-placement-ghost");
    if (kind === "arrow") return svgElement("polygon", "shape-placement-ghost");
    if (kind === "speech_bubble") return svgElement("path", "shape-placement-ghost");
    return svgElement("rect", "shape-placement-ghost");
  }

  pendingShape(preview) {
    const shape = this.placementGhost(preview.kind);
    shape.classList.add("shape-placement-preview");
    setShapeGeometry(shape, preview.kind, preview);
    if (preview.kind === "icon") {
      applyIconPreview(shape, preview.svg, preview.color);
    } else {
      applyShapeStyle(shape, preview.kind, preview);
    }
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
      !this.actions.objectLocks.isLocked(nodeId) &&
        this.actions.translation.canDrag(nodeId) &&
        this.state.snapshot?.editing.some((target) =>
          target.node_id === nodeId
        ),
    );
  }

  hitTarget(page, object) {
    const translatedFrame = this.actions.translation.frame(page, object);
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
    const pendingBounds = shapeTarget?.kind !== "line"
      ? this.actions.shape.pendingBounds(target.id)
      : null;
    const frame = pendingBounds?.bounds || translatedFrame;
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
          !this.actions.shape.isBusy();
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
      if (pendingBounds) {
        const preview = this.pendingShape(pendingBounds);
        preview.classList.add("shape-resize-preview");
        group.append(preview);
      }
      const rect = svgElement("rect", "object-hit-rect");
      setRect(rect, frame);
      group.append(rect);
      if (selected && shapeTarget?.resize) {
        const resizeEditable = !userLocked && !this.actions.shape.isBusy();
        group.classList.toggle("is-shape-resize-pending", pendingBounds != null);
        for (const direction of resizeDirections) {
          group.append(this.shapeResizeHandle(
            direction,
            frame,
            resizeEditable,
            page,
            shapeTarget,
            rect,
          ));
        }
      }
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

  shapeResizeHandle(direction, bounds, editable, page, target, outline) {
    const handle = svgElement(
      "g",
      `shape-resize-handle${editable ? "" : " is-disabled"}`,
    );
    handle.dataset.direction = direction;
    handle.setAttribute("aria-label", `Resize shape ${direction}`);
    handle.setAttribute("aria-disabled", String(!editable));
    const hit = svgElement("rect", "shape-resize-hit");
    setCenteredSquare(hit, 20);
    const marker = svgElement("rect", "shape-resize-marker");
    setCenteredSquare(marker, 7);
    setResizeHandlePosition(handle, direction, bounds);
    handle.append(hit, marker);
    handle.addEventListener("click", (event) => event.stopPropagation());
    if (editable) {
      handle.addEventListener("pointerdown", (event) => {
        if (event.button !== 0) return;
        event.stopPropagation();
        this.beginShapeResize(
          event,
          direction,
          page,
          target,
          bounds,
          outline,
          handle,
        );
      });
    }
    return handle;
  }

  beginShapeResize(event, direction, page, target, bounds, outline, handle) {
    event.preventDefault();
    const svg = handle.ownerSVGElement;
    const group = handle.parentElement;
    const ghost = this.placementGhost(target.kind);
    ghost.classList.add("shape-resize-preview");
    applyShapeStyle(ghost, target.kind, target);
    setShapeGeometry(ghost, target.kind, { bounds });
    group.insertBefore(ghost, outline);
    this.shapeResizeDrag = {
      pointerId: event.pointerId,
      direction,
      page,
      target,
      svg,
      group,
      handle,
      outline,
      ghost,
      original: { ...bounds },
      bounds: { ...bounds },
    };
    group.classList.add("is-editing-shape-bounds");
    try {
      handle.setPointerCapture(event.pointerId);
    } catch {
      // Window listeners below keep the drag active when SVG capture is absent.
    }
    window.addEventListener("pointermove", this.updateShapeResize);
    window.addEventListener("pointerup", this.finishShapeResize);
    window.addEventListener("pointercancel", this.cancelShapeResize);
  }

  updateShapeResize(event) {
    const drag = this.shapeResizeDrag;
    if (!drag || event.pointerId !== drag.pointerId) return;
    drag.bounds = resizedBounds(
      drag.original,
      drag.direction,
      clampPoint(svgPoint(drag.svg, event), drag.page),
      drag.page,
    );
    setRect(drag.outline, drag.bounds);
    setShapeGeometry(drag.ghost, drag.target.kind, { bounds: drag.bounds });
    for (const handle of drag.group.querySelectorAll(".shape-resize-handle")) {
      setResizeHandlePosition(handle, handle.dataset.direction, drag.bounds);
    }
  }

  finishShapeResize(event) {
    const drag = this.shapeResizeDrag;
    if (!drag || event.pointerId !== drag.pointerId) return;
    this.updateShapeResize(event);
    const changed = boundsDistance(drag.original, drag.bounds) >= 0.25;
    this.cleanupShapeResize();
    if (!changed || !this.actions.shape.editBounds(drag.target, drag.bounds)) {
      this.actions.render();
    }
  }

  cancelShapeResize() {
    if (!this.shapeResizeDrag) return;
    this.cleanupShapeResize();
    this.actions.render();
  }

  cleanupShapeResize() {
    const drag = this.shapeResizeDrag;
    if (!drag) return;
    drag.group.classList.remove("is-editing-shape-bounds");
    drag.ghost.remove();
    window.removeEventListener("pointermove", this.updateShapeResize);
    window.removeEventListener("pointerup", this.finishShapeResize);
    window.removeEventListener("pointercancel", this.cancelShapeResize);
    this.shapeResizeDrag = null;
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
    if (event.button !== 0 || this.lineEndpointDrag || this.shapeResizeDrag) return;
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

  activeInsertionController() {
    return this.state.shapeTool === "icon" ? this.actions.icon : this.actions.shape;
  }

  canInsert(pageId) {
    return this.activeInsertionController().canInsert(pageId);
  }
}

function clampPoint(point, page) {
  return {
    x: Math.min(page.width, Math.max(0, point.x)),
    y: Math.min(page.height, Math.max(0, point.y)),
  };
}

export function resizedBounds(original, direction, point, page) {
  let left = original.x;
  let right = original.x + original.width;
  let top = original.y;
  let bottom = original.y + original.height;
  if (direction.includes("left")) {
    left = Math.min(right - minimumResizedShapeExtent, point.x);
  }
  if (direction.includes("right")) {
    right = Math.max(left + minimumResizedShapeExtent, point.x);
  }
  if (direction.includes("top")) {
    top = Math.min(bottom - minimumResizedShapeExtent, point.y);
  }
  if (direction.includes("bottom")) {
    bottom = Math.max(top + minimumResizedShapeExtent, point.y);
  }
  left = Math.max(0, left);
  top = Math.max(0, top);
  right = Math.min(page.width, right);
  bottom = Math.min(page.height, bottom);
  return {
    x: left,
    y: top,
    width: right - left,
    height: bottom - top,
  };
}

function resizeHandlePoint(direction, bounds) {
  const horizontal = direction.includes("left")
    ? bounds.x
    : direction.includes("right")
    ? bounds.x + bounds.width
    : bounds.x + bounds.width / 2;
  const vertical = direction.includes("top")
    ? bounds.y
    : direction.includes("bottom")
    ? bounds.y + bounds.height
    : bounds.y + bounds.height / 2;
  return { x: horizontal, y: vertical };
}

function setResizeHandlePosition(handle, direction, bounds) {
  const point = resizeHandlePoint(direction, bounds);
  handle.setAttribute("transform", `translate(${point.x} ${point.y})`);
}

function setCenteredSquare(rect, size) {
  const offset = -size / 2;
  setRect(rect, { x: offset, y: offset, width: size, height: size });
}

function boundsDistance(left, right) {
  return Math.max(
    Math.abs(left.x - right.x),
    Math.abs(left.y - right.y),
    Math.abs(left.width - right.width),
    Math.abs(left.height - right.height),
  );
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
  const size = kind === "icon"
    ? { width: 72, height: 72 }
    : kind === "circle"
    ? { width: 120, height: 120 }
    : kind === "arrow"
    ? { width: 170, height: 90 }
    : kind === "speech_bubble"
    ? { width: 180, height: 120 }
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

function speechBubblePath(bounds) {
  const x = bounds.x;
  const y = bounds.y;
  const width = bounds.width;
  const height = bounds.height;
  return [
    `M ${x + width * 0.12} ${y + height * 0.05}`,
    `L ${x + width * 0.88} ${y + height * 0.05}`,
    `A ${width * 0.1} ${height * 0.1} 0 0 1 ${x + width * 0.98} ${y + height * 0.15}`,
    `L ${x + width * 0.98} ${y + height * 0.68}`,
    `A ${width * 0.1} ${height * 0.1} 0 0 1 ${x + width * 0.88} ${y + height * 0.78}`,
    `L ${x + width * 0.48} ${y + height * 0.78}`,
    `L ${x + width * 0.28} ${y + height * 0.98}`,
    `L ${x + width * 0.31} ${y + height * 0.78}`,
    `L ${x + width * 0.12} ${y + height * 0.78}`,
    `A ${width * 0.1} ${height * 0.1} 0 0 1 ${x + width * 0.02} ${y + height * 0.68}`,
    `L ${x + width * 0.02} ${y + height * 0.15}`,
    `A ${width * 0.1} ${height * 0.1} 0 0 1 ${x + width * 0.12} ${y + height * 0.05}`,
    "Z",
  ].join(" ");
}

function setShapeGeometry(shape, kind, geometry) {
  if (kind === "line") {
    setLine(shape, geometry.start, geometry.end);
    return;
  }
  const bounds = geometry.bounds;
  if (kind === "icon") {
    setRect(shape, bounds);
  } else if (kind === "circle") {
    shape.setAttribute("cx", String(bounds.x + bounds.width / 2));
    shape.setAttribute("cy", String(bounds.y + bounds.height / 2));
    shape.setAttribute("rx", String(bounds.width / 2));
    shape.setAttribute("ry", String(bounds.height / 2));
  } else if (kind === "arrow") {
    shape.setAttribute("points", arrowPoints(bounds));
  } else if (kind === "speech_bubble") {
    shape.setAttribute("d", speechBubblePath(bounds));
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

function applyIconPreview(image, svg, color) {
  if (!svg) return;
  const source = svg.split("currentColor").join(color);
  image.setAttribute("href", `data:image/svg+xml,${encodeURIComponent(source)}`);
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
