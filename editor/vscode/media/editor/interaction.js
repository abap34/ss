import { setRect, svgElement } from "./dom.js";
import { previewFrame, subtreeNodeIds, svgPoint } from "./geometry.js";
import { renderConstraints } from "./scene.js";

export class InteractionController {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.drag = null;
    this.updateDrag = this.updateDrag.bind(this);
    this.finishDrag = this.finishDrag.bind(this);
    this.cancelDrag = this.cancelDrag.bind(this);
  }

  renderLayer(page) {
    const svg = svgElement("svg", "interaction-layer");
    svg.setAttribute("viewBox", `0 0 ${page.width} ${page.height}`);
    const objects = this.state.snapshot.layout.objects
      .filter((object) => object.page_id === page.id)
      .sort((left, right) =>
        right.width * right.height - left.width * left.height
      );
    if (this.state.constraints && this.state.selectedObjectId != null) {
      svg.append(
        renderConstraints(
          this.state.snapshot,
          page,
          this.state.selectedObjectId,
        ),
      );
    }
    for (const object of objects) svg.append(this.hitTarget(page, object));
    return svg;
  }

  reset() {
    this.cleanup();
  }

  isMovable(nodeId) {
    return Boolean(
      !this.state.snapshot?.stale &&
        this.state.snapshot?.editing.some((target) =>
          target.node_id === nodeId
        ),
    );
  }

  hitTarget(page, object) {
    const frame = previewFrame(page, object);
    const selected = object.id === this.state.selectedObjectId;
    const movable = this.isMovable(object.id);
    const group = svgElement(
      "g",
      `object-hit${selected ? " is-selected" : ""}${
        movable ? " is-movable" : " is-locked"
      }`,
    );
    group.dataset.objectId = String(object.id);
    const rect = svgElement("rect", "object-hit-rect");
    setRect(rect, frame);
    group.append(rect);
    group.addEventListener("click", (event) => {
      event.stopPropagation();
      this.actions.selectObject(object.id, object.page_id);
    });
    group.addEventListener("dblclick", () => this.actions.revealSource(object));
    group.addEventListener(
      "pointerdown",
      (event) => this.beginDrag(event, page, object, group, frame),
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
    drag.group.setAttribute("transform", `translate(${dx} ${dy})`);
    const scene = drag.svg.previousElementSibling;
    for (const nodeId of drag.nodeIds) {
      for (const item of scene.querySelectorAll(`[data-node-id="${nodeId}"]`)) {
        item.setAttribute("transform", `translate(${dx} ${dy})`);
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
    this.state.sync = { state: "working", label: "Applying edit…" };
    this.actions.updateSync();
    this.actions.post({
      type: "translate",
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
}
