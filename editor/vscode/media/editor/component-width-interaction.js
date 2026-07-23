import { setRect } from "./dom.js";
import { clampPoint, svgPoint } from "./geometry.js";
import { componentWidthPolicy } from "./component-width.js";
import {
  createResizeHandle,
  setResizeHandlePosition,
} from "./resize-handle.js";

const resizeDirection = "right";

export class ComponentWidthInteraction {
  constructor(controller, actions) {
    this.controller = controller;
    this.actions = actions;
    this.drag = null;
    this.update = this.update.bind(this);
    this.finish = this.finish.bind(this);
    this.cancel = this.cancel.bind(this);
  }

  isActive() {
    return this.drag != null;
  }

  handle(bounds, editable, page, target, outline, previewRoot) {
    const handle = createResizeHandle(
      "component-width",
      "Resize component width",
      resizeDirection,
      bounds,
      editable,
    );
    if (editable) {
      handle.addEventListener("pointerdown", (event) => {
        if (event.button !== 0) return;
        event.stopPropagation();
        this.begin(
          event,
          page,
          target,
          bounds,
          outline,
          handle,
          previewRoot,
        );
      });
    }
    return handle;
  }

  begin(event, page, target, bounds, outline, handle, previewRoot) {
    const minimumWidth = this.controller.minimum(target.id);
    if (minimumWidth == null) return;
    event.preventDefault();
    const group = handle.parentElement;
    this.drag = {
      pointerId: event.pointerId,
      page,
      target,
      svg: handle.ownerSVGElement,
      group,
      handle,
      outline,
      previewRoot,
      minimumWidth,
      original: { ...bounds },
      bounds: { ...bounds },
    };
    group.classList.add("is-editing-component-width");
    try {
      handle.setPointerCapture(event.pointerId);
    } catch {
      // Window listeners keep the width drag active when SVG capture is absent.
    }
    window.addEventListener("pointermove", this.update);
    window.addEventListener("pointerup", this.finish);
    window.addEventListener("pointercancel", this.cancel);
  }

  update(event) {
    const drag = this.drag;
    if (!drag || event.pointerId !== drag.pointerId) return;
    const point = clampPoint(svgPoint(drag.svg, event), drag.page);
    drag.bounds = {
      ...drag.original,
      width: Math.max(
        drag.minimumWidth,
        point.x - drag.original.x,
      ),
    };
    setRect(drag.outline, drag.bounds);
    setResizeHandlePosition(drag.handle, resizeDirection, drag.bounds);
    this.controller.applyNodeWidth(
      drag.previewRoot,
      drag.target.id,
      drag.bounds.width,
    );
  }

  finish(event) {
    const drag = this.drag;
    if (!drag || event.pointerId !== drag.pointerId) return;
    this.update(event);
    const changed = Math.abs(drag.bounds.width - drag.original.width) >=
      componentWidthPolicy.changeTolerance;
    this.cleanup();
    if (!changed || !this.controller.submit({
      nodeId: drag.target.id,
      pageId: drag.target.page_id,
      fromBounds: drag.original,
      toBounds: drag.bounds,
    })) {
      this.actions.render();
    }
    this.actions.finish();
  }

  cancel() {
    if (!this.drag) return false;
    this.cleanup();
    this.actions.render();
    this.actions.finish();
    return true;
  }

  cleanup() {
    const drag = this.drag;
    if (!drag) return;
    drag.group.classList.remove("is-editing-component-width");
    window.removeEventListener("pointermove", this.update);
    window.removeEventListener("pointerup", this.finish);
    window.removeEventListener("pointercancel", this.cancel);
    this.drag = null;
  }
}
