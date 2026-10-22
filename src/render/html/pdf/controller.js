import {
  clearPdfPlacement,
  copyPdfRaster,
  createPdfImage,
  isPdfRenderCancellation,
  PdfPlacementRender,
  placementPageNumber,
  placementRequestKey,
  rasterKey,
  thumbnailSource,
} from "@ss/pdf/placement";
import { aborted, waitForAbort } from "@ss/pdf/queue";
import { thumbnailPixelSize, visiblePixelSize } from "@ss/pdf/geometry";

const maximumCanvasPixels = 16 * 1024 * 1024;
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
      cacheRaster: false,
      visibilityRoot: null,
      prefetchScreens: 0,
      maximumCanvasPixels,
      ...options,
    };
    this.states = new Map();
    this.disposed = false;
    this.onDestroy = onDestroy;
    this.intersectionObserver = null;
    this.observationMargin = null;
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

    this.observeIntersections();
    if (typeof this.view?.ResizeObserver === "function") {
      this.resizeObserver = new this.view.ResizeObserver(() =>
        this.refreshVisible()
      );
      for (const container of containers) this.resizeObserver.observe(container);
      if (this.root.nodeType === 1) this.resizeObserver.observe(this.root);
      if (this.options.visibilityRoot) {
        this.resizeObserver.observe(this.options.visibilityRoot);
      }
    }
    this.view?.addEventListener?.("resize", this.onResize);
    this.view?.visualViewport?.addEventListener?.("resize", this.onResize);

    const initial = [];
    for (const [container, state] of this.states) {
      state.visible = this.isVisible(container);
      if (state.visible) initial.push(this.schedule(container, state));
    }
    await Promise.all(initial);
  }

  setVisibilityRoot(root) {
    if (this.disposed) return;
    const previous = this.options.visibilityRoot;
    if (previous !== root) {
      if (previous) this.resizeObserver?.unobserve(previous);
      this.options.visibilityRoot = root;
      if (root) this.resizeObserver?.observe(root);
      this.observationMargin = null;
    }
    this.refreshVisible();
  }

  refreshVisible() {
    if (this.disposed) return;
    this.observeIntersections();
    for (const [container, state] of this.states) {
      const visible = this.isVisible(container);
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
      state.visible = this.isVisible(container);
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

  visibilityDistance() {
    return this.options.prefetchScreens > 0
      ? Math.round((this.options.visibilityRoot?.clientHeight ??
        this.view.innerHeight) * this.options.prefetchScreens)
      : visibilityDistance;
  }

  isVisible(container, distance = this.visibilityDistance()) {
    return isVisible(container, this.view, this.options.visibilityRoot, distance);
  }

  observeIntersections() {
    if (typeof this.view?.IntersectionObserver !== "function") return;
    const distance = this.visibilityDistance();
    const margin = this.options.visibilityRoot
      ? `${distance}px 0px` : `${distance}px`;
    if (this.observationMargin === margin) return;
    this.intersectionObserver?.disconnect();
    this.observationMargin = margin;
    this.intersectionObserver = new this.view.IntersectionObserver(
      (entries) => this.intersections(entries),
      { root: this.options.visibilityRoot, rootMargin: margin },
    );
    for (const container of this.states.keys()) {
      this.intersectionObserver.observe(container);
    }
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
    const priority = () => force ? 50 : this.isVisible(container, 0) ? 100 : 20;
    const work = this.options.thumbnail
      ? this.renderThumbnail(container, () =>
        this.current(container, state, generation, force), abortController.signal
      ).then((rendered) => {
        if (rendered && this.current(container, state, generation, force)) {
          this.markRendered(container, state, requestKey);
        }
      })
      : this.renderPlacement(
        container, state, generation, force, requestKey, priority, abortController.signal,
      );
    const promise = work.catch((error) => {
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

  async renderPlacement(container, state, generation, force, requestKey, priority, signal) {
    const source = await this.resolveSource(container, signal);
    if (source === aborted ||
        !this.current(container, state, generation, force)) return;
    const cacheRaster = this.options.cacheRaster &&
      !this.options.textLayer && !this.options.annotationLayer;
    const key = cacheRaster ? rasterKey(container, source) : null;
    if (key) {
      const cached = this.service.cachedRaster(key);
      if (cached) {
        const size = visiblePixelSize(
          container, this.view, this.options.maximumCanvasPixels,
        );
        if (cached.width >= size.width && cached.height >= size.height) {
          copyPdfRaster(container, cached, size);
          this.markRendered(container, state, requestKey);
          return;
        }
      }
    }
    return this.service.schedule(priority, async (jobSignal) => {
      const cancelPlacement = () => state.activePlacement?.cancel();
      jobSignal.addEventListener("abort", cancelPlacement);
      try {
        if (jobSignal.aborted ||
            !this.current(container, state, generation, force)) return;
        await this.service.usePage(
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
              const canvas = placement.commit();
              if (key) this.service.rememberRaster(key, canvas);
              this.markRendered(container, state, requestKey);
            } finally {
              if (state.activePlacement === placement) {
                state.activePlacement = null;
              }
            }
          },
          jobSignal,
        );
      } finally {
        jobSignal.removeEventListener("abort", cancelPlacement);
      }
    }, signal);
  }

  async renderThumbnail(container, isCurrent, signal) {
    const source = await this.resolveSource(container, signal);
    if (source === aborted || !isCurrent()) return false;
    const metadata = container.cloneNode(false);
    const key = rasterKey(metadata, source);
    const pending = this.service.thumbnail(key, () =>
      this.service.schedule(10, async (jobSignal) => {
        const cached = this.service.cachedRaster(key);
        const size = thumbnailPixelSize(metadata);
        if (cached && cached.width >= size.width && cached.height >= size.height) {
          return thumbnailSource(metadata, cached);
        }
        return this.service.usePage(source, placementPageNumber(metadata), async (page, pdfjs) => {
          const placement = new PdfPlacementRender(metadata, page, pdfjs, this.view, {
            ...this.options, textLayer: false, annotationLayer: false,
          });
          const cancel = () => placement.cancel();
          jobSignal.addEventListener("abort", cancel);
          try {
            const { canvas } = await placement.prepare(() => !jobSignal.aborted);
            return canvas.toDataURL("image/png");
          } finally {
            jobSignal.removeEventListener("abort", cancel);
            placement.cancel();
          }
        }, jobSignal);
      })
    );
    const imageSource = await waitForAbort(pending, signal);
    if (imageSource === aborted || !isCurrent()) return false;
    const image = await createPdfImage(container, imageSource);
    if (!isCurrent()) return false;
    const previous = container.querySelector(":scope > img");
    if (previous) previous.replaceWith(image);
    else container.prepend(image);
    return true;
  }

  async resolveSource(container, signal) {
    const unresolved = container.dataset.pdfSrc;
    if (!unresolved) throw new Error("missing PDF resource");
    const source = await waitForAbort(
      Promise.resolve(this.options.resolveSource(unresolved)), signal,
    );
    if (source !== aborted && (typeof source !== "string" || source.length === 0)) {
      throw new Error("invalid PDF resource URL");
    }
    return source;
  }

  current(container, state, generation, force) {
    return !this.disposed && container.isConnected &&
      state.generation === generation && (force || state.visible);
  }

  markRendered(container, state, requestKey) {
    delete container.dataset.error;
    container.dataset.ssPdfRendered = "true";
    state.renderedKey = requestKey;
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

function isVisible(element, view, root, distance) {
  if (!element.isConnected) return false;
  const style = view.getComputedStyle(element);
  if (style.display === "none" || style.visibility === "hidden") return false;
  const bounds = element.getBoundingClientRect();
  if (bounds.width <= 0 || bounds.height <= 0) return false;
  const viewport = root?.getBoundingClientRect() ?? {
    left: 0, top: 0, right: view.innerWidth, bottom: view.innerHeight,
  };
  if (viewport.right <= viewport.left || viewport.bottom <= viewport.top) {
    return false;
  }
  const horizontalDistance = root ? 0 : distance;
  return bounds.right >= viewport.left - horizontalDistance &&
    bounds.left <= viewport.right + horizontalDistance &&
    bounds.bottom >= viewport.top - distance &&
    bounds.top <= viewport.bottom + distance;
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
