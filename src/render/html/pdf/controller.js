import {
  clearPdfPlacement,
  isPdfRenderCancellation,
  PdfPlacementRender,
  placementPageNumber,
  placementRequestKey,
} from "@ss/pdf/placement";
import { aborted, waitForAbort } from "@ss/pdf/queue";

const maximumCanvasPixels = 16 * 1024 * 1024;
const visibilityMargin = "160px";
const visibilityDistance = 160;

export class PdfRenderController {
  constructor(root, service, options, onDestroy = () => {}) {
    this.root = root;
    this.service = service;
    this.options = {
      resolveSource: (source) => source,
      textLayer: true,
      annotationLayer: true,
      thumbnail: false,
      maximumCanvasPixels,
      ...options,
    };
    this.states = new Map();
    this.disposed = false;
    this.onDestroy = onDestroy;
    this.intersectionObserver = null;
    this.resizeObserver = null;
    this.ready = Promise.resolve();
    this.view = root.defaultView ||
      root.ownerDocument?.defaultView || globalThis.window;
    this.onResize = () => this.refreshVisible();
  }

  async start() {
    const containers = this.containers();
    for (const container of containers) {
      this.states.set(container, {
        visible: false,
        generation: 0,
        requestKey: null,
        renderedKey: null,
        promise: null,
        activePlacement: null,
        abortController: null,
        forced: false,
      });
    }
    if (containers.length === 0) return;

    await nextFrame(this.view);
    if (this.disposed) return;

    if (typeof this.view?.IntersectionObserver === "function") {
      this.intersectionObserver = new this.view.IntersectionObserver(
        (entries) => this.intersections(entries),
        { root: null, rootMargin: visibilityMargin },
      );
      for (const container of containers) {
        this.intersectionObserver.observe(container);
      }
    }
    if (typeof this.view?.ResizeObserver === "function") {
      this.resizeObserver = new this.view.ResizeObserver(() =>
        this.refreshVisible()
      );
      for (const container of containers) this.resizeObserver.observe(container);
      if (this.root.nodeType === 1) this.resizeObserver.observe(this.root);
    }
    this.view?.addEventListener?.("resize", this.onResize);
    this.view?.visualViewport?.addEventListener?.("resize", this.onResize);

    const initial = [];
    for (const [container, state] of this.states) {
      state.visible = isVisible(container, this.view);
      if (state.visible) initial.push(this.schedule(container, state));
    }
    await Promise.all(initial);
  }

  refreshVisible() {
    if (this.disposed) return;
    for (const [container, state] of this.states) {
      const visible = isVisible(container, this.view);
      state.visible = visible;
      if (visible) {
        this.scheduleInBackground(container, state);
      } else if (!state.forced && (state.promise || state.activePlacement)) {
        this.cancel(state);
      }
    }
  }

  async renderAll() {
    if (this.disposed) return;
    await Promise.all([...this.states].map(([container, state]) =>
      this.schedule(container, state, true)
    ));
  }

  restoreAfterPrint() {
    if (this.disposed) return;
    for (const [container, state] of this.states) {
      state.visible = isVisible(container, this.view);
      if (state.visible) {
        this.scheduleInBackground(container, state);
        continue;
      }
      this.cancel(state);
      clearPdfPlacement(container);
      state.renderedKey = null;
    }
  }

  destroy() {
    if (this.disposed) return;
    this.disposed = true;
    this.intersectionObserver?.disconnect();
    this.resizeObserver?.disconnect();
    this.view?.removeEventListener?.("resize", this.onResize);
    this.view?.visualViewport?.removeEventListener?.("resize", this.onResize);
    for (const state of this.states.values()) this.cancel(state);
    this.states.clear();
    this.onDestroy();
  }

  containers() {
    const descendants = [...this.root.querySelectorAll(".ss-pdf")];
    if (this.root.matches?.(".ss-pdf")) descendants.unshift(this.root);
    return descendants;
  }

  intersections(entries) {
    if (this.disposed) return;
    for (const entry of entries) {
      const state = this.states.get(entry.target);
      if (!state) continue;
      state.visible = entry.isIntersecting && entry.intersectionRect.width > 0 &&
        entry.intersectionRect.height > 0;
      if (state.visible) {
        this.scheduleInBackground(entry.target, state);
      } else if (!state.forced && (state.promise || state.activePlacement)) {
        this.cancel(state);
      }
    }
  }

  schedule(container, state, force = false) {
    if (this.disposed || !container.isConnected || (!force && !state.visible)) {
      return Promise.resolve();
    }
    const requestKey = placementRequestKey(container, this.view, this.options);
    if (!requestKey || state.renderedKey === requestKey) return Promise.resolve();
    if (state.requestKey === requestKey && state.promise) {
      if (!force || state.forced) return state.promise;
    }

    this.cancel(state);
    const generation = state.generation;
    state.requestKey = requestKey;
    state.forced = force;
    const abortController = new AbortController();
    state.abortController = abortController;
    const priority = force ? 50 : this.options.thumbnail ? 10 : 100;
    const promise = this.service.schedule(priority, async (jobSignal) => {
      const cancelPlacement = () => state.activePlacement?.cancel();
      jobSignal.addEventListener("abort", cancelPlacement);
      try {
        if (jobSignal.aborted ||
            !this.current(container, state, generation, force)) return;
        const unresolvedSource = container.dataset.pdfSrc;
        if (!unresolvedSource) throw new Error("missing PDF resource");
        const source = await waitForAbort(
          Promise.resolve(this.options.resolveSource(unresolvedSource)),
          jobSignal,
        );
        if (source === aborted ||
            !this.current(container, state, generation, force)) return;
        if (typeof source !== "string" || source.length === 0) {
          throw new Error("invalid PDF resource URL");
        }
        const pageWork = this.service.usePage(
          source,
          placementPageNumber(container),
          async (page, pdfjs) => {
            if (!this.current(container, state, generation, force)) return;
            const placement = new PdfPlacementRender(
              container,
              page,
              pdfjs,
              this.view,
              this.options,
            );
            state.activePlacement = placement;
            try {
              await placement.prepare(() =>
                this.current(container, state, generation, force)
              );
              if (!this.current(container, state, generation, force)) return;
              placement.commit();
              delete container.dataset.error;
              container.dataset.ssPdfRendered = "true";
              state.renderedKey = requestKey;
            } finally {
              if (state.activePlacement === placement) {
                state.activePlacement = null;
              }
            }
          },
          jobSignal,
        );
        await pageWork;
      } finally {
        jobSignal.removeEventListener("abort", cancelPlacement);
      }
    }, abortController.signal).catch((error) => {
      if (state.generation !== generation ||
          isPdfRenderCancellation(error)) return;
      container.dataset.error = error instanceof Error
        ? error.message
        : String(error);
      try {
        this.options.onError?.(error, container);
      } catch {}
      throw error;
    }).finally(() => {
      if (state.generation !== generation) return;
      state.promise = null;
      state.requestKey = null;
      state.activePlacement = null;
      state.abortController = null;
      state.forced = false;
    });
    state.promise = promise;
    return promise;
  }

  current(container, state, generation, force) {
    return !this.disposed && container.isConnected &&
      state.generation === generation && (force || state.visible);
  }

  scheduleInBackground(container, state) {
    void this.schedule(container, state).catch(() => {});
  }

  cancel(state) {
    state.generation += 1;
    state.abortController?.abort();
    state.activePlacement?.cancel();
    state.activePlacement = null;
    state.promise = null;
    state.requestKey = null;
    state.abortController = null;
    state.forced = false;
  }
}

function isVisible(element, view) {
  if (!element.isConnected) return false;
  const style = view.getComputedStyle(element);
  if (style.display === "none" || style.visibility === "hidden") return false;
  const bounds = element.getBoundingClientRect();
  if (bounds.width <= 0 || bounds.height <= 0) return false;
  return bounds.right >= -visibilityDistance &&
    bounds.bottom >= -visibilityDistance &&
    bounds.left <= view.innerWidth + visibilityDistance &&
    bounds.top <= view.innerHeight + visibilityDistance;
}

function nextFrame(view) {
  return new Promise((resolve) => {
    if (typeof view?.requestAnimationFrame === "function") {
      view.requestAnimationFrame(() => resolve());
    } else {
      resolve();
    }
  });
}
