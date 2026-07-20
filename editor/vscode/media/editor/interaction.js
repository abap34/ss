import { setRect, svgElement } from "./dom.js";
import {
  editableAncestorNodeId,
  previewFrame,
  subtreeNodeIds,
  svgPoint,
} from "./geometry.js";
import { renderConstraints } from "./constraints.js";

export class InteractionController {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.drag = null;
    this.placement = null;
    this.updateDrag = this.updateDrag.bind(this);
    this.finishDrag = this.finishDrag.bind(this);
    this.cancelDrag = this.cancelDrag.bind(this);
    this.updatePlacement = this.updatePlacement.bind(this);
    this.finishPlacement = this.finishPlacement.bind(this);
    this.cancelPlacement = this.cancelPlacement.bind(this);
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
    placement.current = clampPoint(svgPoint(placement.svg, event), placement.page);
    this.updatePlacementGhost();
  }

  finishPlacement(event) {
    const placement = this.placement;
    if (!placement || event.pointerId !== placement.pointerId) return;
    placement.current = clampPoint(svgPoint(placement.svg, event), placement.page);
    let bounds = placementBounds(
      placement.start,
      placement.current,
      placement.kind,
    );
    if (bounds.width < 4 || bounds.height < 4) {
      bounds = defaultBounds(placement.start, placement.page, placement.kind);
    }
    const pageId = placement.page.id;
    this.cleanupPlacement();
    this.actions.shape.insert(pageId, bounds);
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
    if (event.key !== "Escape") return;
    if (this.placement) {
      event.preventDefault();
      this.cleanupPlacement();
      this.actions.shape.cancel();
      return;
    }
    if (this.actions.shape.cancel()) event.preventDefault();
  }

  placementGhost(kind) {
    if (kind === "circle") return svgElement("ellipse", "shape-placement-ghost");
    if (kind === "arrow") return svgElement("polygon", "shape-placement-ghost");
    return svgElement("rect", "shape-placement-ghost");
  }

  pendingShape(preview) {
    const shape = this.placementGhost(preview.kind);
    shape.classList.add("shape-placement-preview");
    setShapeGeometry(shape, preview.kind, preview.bounds);
    shape.style.fill = preview.fill.enabled ? preview.fill.color : "none";
    shape.style.fillOpacity = String(preview.fill.opacity);
    shape.style.stroke = preview.stroke.enabled ? preview.stroke.color : "none";
    shape.style.strokeWidth = String(preview.stroke.width);
    applyStrokeStyle(shape, preview.stroke);
    return shape;
  }

  updatePlacementGhost() {
    const placement = this.placement;
    if (!placement) return;
    const bounds = placementBounds(
      placement.start,
      placement.current,
      placement.kind,
    );
    setShapeGeometry(placement.ghost, placement.kind, bounds);
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
    const selected = object.id === this.state.selectedObjectId;
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
    const userLocked = editableObject != null &&
      this.actions.objectLocks.isLocked(editableObject.id);
    const movable = editableObject != null && this.isMovable(editableObject.id);
    const group = svgElement(
      "g",
      `object-hit${selected ? " is-selected" : ""}${
        movable ? " is-movable" : " is-locked"
      }${userLocked ? " is-user-locked" : ""}`,
    );
    group.dataset.objectId = String(object.id);
    if (userLocked) group.dataset.objectLocked = "true";
    const rect = svgElement("rect", "object-hit-rect");
    setRect(rect, frame);
    group.append(rect);
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

  beginDrag(event, page, object, group, frame) {
    if (event.button !== 0) return;
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

function setShapeGeometry(shape, kind, bounds) {
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

export function selectedObjectBelongsToPage(snapshot, objectId, pageId) {
  return objectId != null &&
    snapshot.layout.objects.some((object) =>
      object.id === objectId && object.page_id === pageId
    );
}
