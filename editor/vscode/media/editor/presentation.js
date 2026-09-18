import { element, svgElement } from "./dom.js";
import { svgPoint } from "./geometry.js";
import { renderPage } from "./document.js";

const minimumScale = 1;
const maximumScale = 6;
const pinchSensitivity = 0.004;
const wheelDeltaModeLine = 1;
const wheelDeltaModePage = 2;
const wheelLinePixels = 16;
const scrollNavigationThreshold = 180;
const scrollGestureIdleMs = 220;
const navigationCooldownMs = 450;
const fitMarginRatio = 0.02;
const defaultPenColor = "#ff3b30";

export class PresentationController {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.scale = minimumScale;
    this.pan = { x: 0, y: 0 };
    this.fit = null;
    this.dragPan = null;
    this.touches = new Map();
    this.touchPan = null;
    this.stroke = null;
    this.lastNavAt = 0;
    this.lastWheelAt = 0;
    this.scrollAccumulator = 0;
    this.pageEl = null;
    this.inkSvg = null;
    this.laserDot = null;
    this.controlsVisible = false;
    this.focusedControlKind = null;
    this.handleKeydown = this.handleKeydown.bind(this);
    this.handleResize = this.handleResize.bind(this);
    this.handleWheel = this.handleWheel.bind(this);
    this.handlePointerDown = this.handlePointerDown.bind(this);
    this.handlePointerMove = this.handlePointerMove.bind(this);
    this.handlePointerUp = this.handlePointerUp.bind(this);
    this.handleContextMenu = this.handleContextMenu.bind(this);
    window.addEventListener("keydown", this.handleKeydown);
    window.addEventListener("resize", this.handleResize);
  }

  start(pageId = null) {
    const pages = this.state.snapshot?.layout.pages || [];
    if (pages.length === 0) return;
    const resolved = pageId != null && pages.some((page) => page.id === pageId)
      ? pageId
      : pages[0].id;
    this.state.presentation.active = true;
    this.state.presentation.pageId = resolved;
    this.state.presentation.tool = "none";
    this.resetView();
    this.actions.render();
  }

  exit() {
    if (!this.state.presentation.active) return;
    this.state.presentation.active = false;
    this.state.presentation.tool = "none";
    this.state.presentation.strokes = new Map();
    this.cleanupGestures();
    this.actions.render();
  }

  next() {
    this.step(1);
  }

  previous() {
    this.step(-1);
  }

  step(offset) {
    if (!this.state.presentation.active) return;
    const pages = this.state.snapshot?.layout.pages || [];
    const index = pageIndex(pages, this.state.presentation.pageId);
    if (index < 0) return;
    const next = index + offset;
    if (next < 0 || next >= pages.length) return;
    this.goToIndex(next);
  }

  // A negative index (as passed by the "End" key handler) means "last page";
  // step() above clamps its own range and never forwards a negative index.
  goToIndex(index) {
    const pages = this.state.snapshot?.layout.pages || [];
    if (pages.length === 0) return;
    const resolvedIndex = index < 0
      ? pages.length - 1
      : Math.min(pages.length - 1, index);
    const page = pages[resolvedIndex];
    if (!page || page.id === this.state.presentation.pageId) return;
    this.state.presentation.pageId = page.id;
    this.resetView();
    this.actions.render();
  }

  setTool(tool) {
    if (!this.state.presentation.active) return;
    this.cancelStroke();
    this.state.presentation.tool = this.state.presentation.tool === tool
      ? "none"
      : tool;
    this.actions.render();
  }

  clearInk() {
    const pageId = this.state.presentation.pageId;
    if (pageId == null) return;
    this.state.presentation.strokes.delete(pageId);
    this.actions.render();
  }

  undoStroke() {
    const pageId = this.state.presentation.pageId;
    const list = this.state.presentation.strokes.get(pageId);
    if (!list || list.length === 0) return;
    list.pop();
    if (list.length === 0) this.state.presentation.strokes.delete(pageId);
    this.actions.render();
  }

  resetView() {
    this.scale = minimumScale;
    this.pan = { x: 0, y: 0 };
    this.scrollAccumulator = 0;
  }

  render() {
    this.cleanupGestures();
    const overlay = element("div", "presentation-overlay");
    const pages = this.state.snapshot?.layout.pages || [];
    const page = findPage(pages, this.state.presentation.pageId) || pages[0] || null;
    const stage = element("div", "presentation-stage");
    stage.tabIndex = -1;
    stage.classList.toggle(
      "presentation-stage--laser",
      this.state.presentation.tool === "laser",
    );
    stage.classList.toggle(
      "presentation-stage--pen",
      this.state.presentation.tool === "pen",
    );
    stage.addEventListener("wheel", this.handleWheel, { passive: false });
    stage.addEventListener("pointerdown", this.handlePointerDown);
    stage.addEventListener("pointermove", this.handlePointerMove);
    stage.addEventListener("pointerup", this.handlePointerUp);
    stage.addEventListener("pointercancel", this.handlePointerUp);
    stage.addEventListener("contextmenu", this.handleContextMenu);
    stage.addEventListener("pointerleave", () => {
      if (this.laserDot) this.laserDot.hidden = true;
    });

    if (page) {
      this.fit = fitDimensions(page, viewportSize());
      const pageBox = element("div", "presentation-page");
      const surface = element("div", "presentation-page-surface");
      surface.append(renderPage(this.state.snapshot, page.id));
      const ink = svgElement("svg", "presentation-ink-layer");
      ink.setAttribute("viewBox", `0 0 ${page.width} ${page.height}`);
      for (const stroke of this.state.presentation.strokes.get(page.id) || []) {
        ink.append(this.strokeElement(stroke));
      }
      surface.append(ink);
      pageBox.append(surface);
      stage.append(pageBox);
      this.pageEl = pageBox;
      this.inkSvg = ink;
      this.applyTransform();
    } else {
      this.fit = null;
      this.pageEl = null;
      this.inkSvg = null;
    }

    const laser = element("div", "presentation-laser-dot");
    laser.hidden = true;
    this.laserDot = laser;
    const controls = this.controls(page, pages);
    overlay.append(stage, laser, controls);
    // The control bar's visibility (hover/focus) and focused button live on
    // this JS-tracked state rather than pure CSS :hover/:focus-within,
    // because every navigation click rebuilds the whole overlay: without
    // this, the freshly created bar would start unhovered/unfocused and
    // flash hidden for a frame even though the pointer never left it.
    if (this.focusedControlKind) {
      const kind = this.focusedControlKind;
      requestAnimationFrame(() => {
        if (!controls.isConnected) return;
        const target = controls.querySelector(`[data-control-kind="${kind}"]`);
        if (target && !target.disabled) target.focus();
      });
    }
    return overlay;
  }

  controls(page, pages) {
    const bar = element("div", "presentation-controls");
    bar.classList.toggle("is-visible", this.controlsVisible);
    bar.setAttribute("role", "toolbar");
    bar.setAttribute("aria-label", "Presentation controls");
    const syncVisible = () => {
      this.controlsVisible = bar.matches(":hover") || bar.contains(document.activeElement);
      bar.classList.toggle("is-visible", this.controlsVisible);
    };
    bar.addEventListener("pointerenter", syncVisible);
    bar.addEventListener("pointerleave", syncVisible);
    bar.addEventListener("focusin", (event) => {
      this.focusedControlKind = event.target.dataset.controlKind || null;
      syncVisible();
    });
    bar.addEventListener("focusout", () => {
      this.focusedControlKind = null;
      syncVisible();
    });
    const index = page ? pageIndex(pages, page.id) : -1;

    const previous = this.controlButton("prev", "Previous slide", () => this.previous());
    previous.disabled = index <= 0;
    const next = this.controlButton("next", "Next slide", () => this.next());
    next.disabled = index < 0 || index >= pages.length - 1;

    const laser = this.controlButton("laser", "Laser pointer", () => this.setTool("laser"));
    laser.setAttribute("aria-pressed", String(this.state.presentation.tool === "laser"));
    laser.classList.toggle("is-active", this.state.presentation.tool === "laser");

    const pen = this.controlButton("pen", "Pen", () => this.setTool("pen"));
    pen.setAttribute("aria-pressed", String(this.state.presentation.tool === "pen"));
    pen.classList.toggle("is-active", this.state.presentation.tool === "pen");

    const hasInk = Boolean(page && this.state.presentation.strokes.get(page.id)?.length);
    const clear = this.controlButton("clear", "Clear ink on this slide", () => this.clearInk());
    clear.disabled = !hasInk;

    const counter = element("span", "presentation-counter");
    counter.textContent = index >= 0 ? `${index + 1} / ${pages.length}` : "";

    const exit = this.controlButton("exit", "Exit presentation", () => this.exit());

    bar.append(previous, next, laser, pen, clear, counter, exit);
    return bar;
  }

  controlButton(kind, label, handler) {
    const button = element("button", "presentation-control");
    button.type = "button";
    button.title = label;
    button.setAttribute("aria-label", label);
    button.dataset.controlKind = kind;
    button.append(element("span", `presentation-icon presentation-icon--${kind}`));
    button.addEventListener("click", handler);
    return button;
  }

  strokeElement(points) {
    const polyline = svgElement("polyline", "presentation-ink-stroke");
    polyline.style.stroke = this.state.presentation.penColor || defaultPenColor;
    polyline.setAttribute("points", pointsAttribute(points));
    return polyline;
  }

  cleanupGestures() {
    this.dragPan = null;
    this.touchPan = null;
    this.touches.clear();
    this.stroke = null;
  }

  handleResize() {
    if (!this.state.presentation.active || !this.pageEl) return;
    const pages = this.state.snapshot?.layout.pages || [];
    const page = findPage(pages, this.state.presentation.pageId);
    if (!page) return;
    this.fit = fitDimensions(page, viewportSize());
    this.applyTransform();
  }

  handleKeydown(event) {
    if (!this.state.presentation.active) return;
    if (
      (event.ctrlKey || event.metaKey) && !event.shiftKey && !event.altKey &&
      event.key.toLowerCase() === "z"
    ) {
      event.preventDefault();
      this.undoStroke();
      return;
    }
    switch (event.key) {
    case "Escape":
      event.preventDefault();
      this.exit();
      return;
    case "ArrowRight":
    case "ArrowDown":
    case "PageDown":
    case " ":
      event.preventDefault();
      this.next();
      return;
    case "ArrowLeft":
    case "ArrowUp":
    case "PageUp":
      event.preventDefault();
      this.previous();
      return;
    case "Home":
      event.preventDefault();
      this.goToIndex(0);
      return;
    case "End":
      event.preventDefault();
      this.goToIndex(-1);
      return;
    default:
      return;
    }
  }

  handleContextMenu(event) {
    if (!this.state.presentation.active) return;
    event.preventDefault();
  }

  handleWheel(event) {
    if (!this.state.presentation.active) return;
    event.preventDefault();
    if (event.ctrlKey) {
      const delta = normalizedWheelDelta(event);
      const factor = Math.exp(-delta * pinchSensitivity);
      this.zoomAt(event.clientX, event.clientY, factor);
      this.scrollAccumulator = 0;
      return;
    }
    const now = performance.now();
    if (now - this.lastNavAt < navigationCooldownMs) return;
    // Require a sustained scroll rather than reacting to a single wheel
    // tick: accumulate delta across the gesture and only advance once it
    // passes a real threshold. A pause resets the accumulator, so it
    // reflects one continuous gesture rather than scroll drift over time.
    if (now - this.lastWheelAt > scrollGestureIdleMs) this.scrollAccumulator = 0;
    this.lastWheelAt = now;
    this.scrollAccumulator += normalizedWheelDelta(event);
    if (this.scrollAccumulator > scrollNavigationThreshold) {
      this.scrollAccumulator = 0;
      this.lastNavAt = now;
      this.next();
    } else if (this.scrollAccumulator < -scrollNavigationThreshold) {
      this.scrollAccumulator = 0;
      this.lastNavAt = now;
      this.previous();
    }
  }

  handlePointerDown(event) {
    if (!this.state.presentation.active) return;
    if (event.pointerType === "touch") {
      this.touches.set(event.pointerId, { x: event.clientX, y: event.clientY });
      if (this.touches.size === 2) {
        this.cancelStroke();
        this.beginTouchPan();
      }
      return;
    }
    if (event.button === 2) {
      event.preventDefault();
      this.beginMousePan(event);
      return;
    }
    if (event.button !== 0 || this.dragPan || this.touchPan) return;
    if (this.state.presentation.tool === "pen") {
      event.preventDefault();
      this.beginStroke(event);
    }
  }

  handlePointerMove(event) {
    if (!this.state.presentation.active) return;
    if (event.pointerType === "touch" && this.touches.has(event.pointerId)) {
      this.touches.set(event.pointerId, { x: event.clientX, y: event.clientY });
      this.updateTouchPan();
      return;
    }
    if (this.dragPan && event.pointerId === this.dragPan.pointerId) {
      this.updateMousePan(event);
      return;
    }
    if (this.stroke && event.pointerId === this.stroke.pointerId) {
      this.updateStroke(event);
      return;
    }
    if (this.state.presentation.tool === "laser" && event.pointerType !== "touch") {
      this.updateLaser(event);
    }
  }

  handlePointerUp(event) {
    if (!this.state.presentation.active) return;
    if (event.pointerType === "touch" && this.touches.has(event.pointerId)) {
      this.touches.delete(event.pointerId);
      if (this.touches.size < 2) this.touchPan = null;
      return;
    }
    if (this.dragPan && event.pointerId === this.dragPan.pointerId) {
      this.dragPan = null;
      return;
    }
    if (this.stroke && event.pointerId === this.stroke.pointerId) {
      this.commitStroke();
    }
  }

  beginMousePan(event) {
    this.dragPan = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      originX: this.pan.x,
      originY: this.pan.y,
    };
  }

  updateMousePan(event) {
    const drag = this.dragPan;
    this.pan = {
      x: drag.originX + (event.clientX - drag.startX),
      y: drag.originY + (event.clientY - drag.startY),
    };
    this.applyTransform();
  }

  beginTouchPan() {
    const centroid = averageCentroid(this.touches);
    this.touchPan = {
      originX: this.pan.x,
      originY: this.pan.y,
      startX: centroid.x,
      startY: centroid.y,
    };
  }

  updateTouchPan() {
    if (!this.touchPan || this.touches.size < 2) return;
    const centroid = averageCentroid(this.touches);
    this.pan = {
      x: this.touchPan.originX + (centroid.x - this.touchPan.startX),
      y: this.touchPan.originY + (centroid.y - this.touchPan.startY),
    };
    this.applyTransform();
  }

  zoomAt(clientX, clientY, factor) {
    if (!this.pageEl || !this.fit) return;
    const nextScale = clamp(this.scale * factor, minimumScale, maximumScale);
    if (nextScale === this.scale) return;
    const rect = this.pageEl.getBoundingClientRect();
    if (rect.width > 0 && rect.height > 0) {
      // Recompute pan so the point under the cursor stays under the cursor
      // as the box grows/shrinks to its new (real, laid-out) size — see
      // applyTransform() for why this must be a real size change rather
      // than an extra transform: scale().
      const fractionX = (clientX - rect.left) / rect.width;
      const fractionY = (clientY - rect.top) / rect.height;
      const viewport = viewportSize();
      const nextWidth = this.fit.width * nextScale;
      const nextHeight = this.fit.height * nextScale;
      this.pan = {
        x: clientX - viewport.width / 2 + nextWidth * (0.5 - fractionX),
        y: clientY - viewport.height / 2 + nextHeight * (0.5 - fractionY),
      };
    }
    this.scale = nextScale;
    this.applyTransform();
  }

  applyTransform() {
    if (!this.pageEl || !this.fit) return;
    // Zoom is expressed as a real box resize (--page-width/--page-height,
    // which the shared page CSS turns into an actual --preview-scale
    // content transform), not an extra transform: scale() on this element.
    // A plain CSS scale would just stretch an already-rasterized layer —
    // blurry text/vectors, and stale-resolution embedded PDF/LaTeX canvases,
    // since their ResizeObserver-driven re-render never fires for a pure
    // transform. Only panning is a transform here, and it has no scale
    // component, so it stays pixel-exact at any zoom level.
    this.pageEl.style.setProperty("--page-width", `${this.fit.width * this.scale}px`);
    this.pageEl.style.setProperty("--page-height", `${this.fit.height * this.scale}px`);
    this.pageEl.style.setProperty("--preview-scale", String(this.fit.scale * this.scale));
    this.pageEl.style.transform = `translate(${this.pan.x}px, ${this.pan.y}px)`;
  }

  beginStroke(event) {
    if (!this.inkSvg) return;
    const point = svgPoint(this.inkSvg, event);
    const polyline = this.strokeElement([point]);
    this.inkSvg.append(polyline);
    this.stroke = { pointerId: event.pointerId, points: [point], polyline };
  }

  updateStroke(event) {
    const stroke = this.stroke;
    if (!stroke) return;
    stroke.points.push(svgPoint(this.inkSvg, event));
    stroke.polyline.setAttribute("points", pointsAttribute(stroke.points));
  }

  commitStroke() {
    const stroke = this.stroke;
    if (!stroke) return;
    this.stroke = null;
    if (stroke.points.length <= 1) {
      stroke.polyline.remove();
      return;
    }
    const pageId = this.state.presentation.pageId;
    const list = this.state.presentation.strokes.get(pageId) || [];
    list.push(stroke.points);
    this.state.presentation.strokes.set(pageId, list);
    // Re-render so the control bar's Clear/Undo affordances (computed from
    // strokes at render time) reflect the ink that was just drawn — drawing
    // itself mutates the SVG directly for performance, without a render().
    this.actions.render();
  }

  cancelStroke() {
    if (!this.stroke) return;
    this.stroke.polyline.remove();
    this.stroke = null;
  }

  updateLaser(event) {
    if (!this.laserDot) return;
    this.laserDot.hidden = false;
    this.laserDot.style.left = `${event.clientX}px`;
    this.laserDot.style.top = `${event.clientY}px`;
  }
}

function findPage(pages, pageId) {
  return pages.find((page) => page.id === pageId) || null;
}

function pageIndex(pages, pageId) {
  return pages.findIndex((page) => page.id === pageId);
}

function fitDimensions(page, viewport) {
  const marginX = viewport.width * fitMarginRatio;
  const marginY = viewport.height * fitMarginRatio;
  const availableWidth = Math.max(80, viewport.width - marginX * 2);
  const availableHeight = Math.max(60, viewport.height - marginY * 2);
  const scale = Math.min(
    availableWidth / page.width,
    availableHeight / page.height,
  );
  return { width: page.width * scale, height: page.height * scale, scale };
}

function viewportSize() {
  return { width: window.innerWidth, height: window.innerHeight };
}

function averageCentroid(pointsMap) {
  let x = 0;
  let y = 0;
  for (const point of pointsMap.values()) {
    x += point.x;
    y += point.y;
  }
  const count = pointsMap.size || 1;
  return { x: x / count, y: y / count };
}

function pointsAttribute(points) {
  return points.map((point) => `${point.x},${point.y}`).join(" ");
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function normalizedWheelDelta(event) {
  if (event.deltaMode === wheelDeltaModeLine) return event.deltaY * wheelLinePixels;
  if (event.deltaMode === wheelDeltaModePage) return event.deltaY * window.innerHeight;
  return event.deltaY;
}
