import { pageGeometry, visiblePixelSize } from "@ss/pdf/geometry";

export class PdfPlacementRender {
  constructor(container, page, pdfjs, view, options) {
    this.container = container;
    this.page = page;
    this.pdfjs = pdfjs;
    this.view = view;
    this.options = options;
    this.cancelled = false;
    this.renderTask = null;
    this.textLayer = null;
    this.prepared = null;
  }

  async prepare(isCurrent) {
    this.assertCurrent(isCurrent);
    const geometry = pageGeometry(
      this.page,
      this.container,
      this.view,
      this.options,
    );
    const canvas = this.container.ownerDocument.createElement("canvas");
    canvas.width = geometry.pixelWidth;
    canvas.height = geometry.pixelHeight;
    canvas.setAttribute("aria-hidden", "true");
    const context = canvas.getContext("2d", { alpha: true });
    if (!context) throw new Error("PDF canvas is unavailable");

    const annotationMode = this.pdfjs.AnnotationMode?.DISABLE;
    if (!Number.isSafeInteger(annotationMode)) {
      throw new Error("PDF.js annotation mode API is unavailable");
    }
    const renderTask = this.page.render({
      canvasContext: context,
      viewport: geometry.viewport,
      transform: geometry.rasterTransform,
      background: canvasBackground(this.container),
      annotationMode,
    });
    this.renderTask = renderTask;
    try {
      await renderTask.promise;
      this.assertCurrent(isCurrent);
    } catch (error) {
      if (isPdfRenderCancellation(error)) throw new CancelledRender();
      throw error;
    } finally {
      if (this.renderTask === renderTask) this.renderTask = null;
    }

    const text = this.options.textLayer
      ? await this.prepareTextLayer(geometry, isCurrent)
      : null;
    const annotations = this.options.annotationLayer && annotationPolicy(this.container)
      ? await this.prepareAnnotationLayer(geometry, isCurrent)
      : null;
    this.assertCurrent(isCurrent);
    this.prepared = { canvas, text, annotations };
  }

  commit() {
    if (!this.prepared) throw new Error("PDF placement was not prepared");
    const previousCanvas = this.container.querySelector(":scope > canvas");
    const textLayer = this.container.querySelector(":scope > .ss-pdf-text");
    const annotationLayer = this.container.querySelector(
      ":scope > .ss-pdf-annotations",
    );
    if (!textLayer || !annotationLayer) {
      throw new Error("missing PDF display layer");
    }
    if (previousCanvas) previousCanvas.replaceWith(this.prepared.canvas);
    else textLayer.before(this.prepared.canvas);
    textLayer.replaceChildren(...(this.prepared.text ? [this.prepared.text] : []));
    annotationLayer.replaceChildren(
      ...(this.prepared.annotations ? [this.prepared.annotations] : []),
    );
    this.prepared = null;
    this.textLayer = null;
  }

  cancel() {
    if (this.cancelled) return;
    this.cancelled = true;
    this.renderTask?.cancel();
    this.textLayer?.cancel?.();
    this.renderTask = null;
    this.textLayer = null;
    this.prepared = null;
  }

  async prepareTextLayer(geometry, isCurrent) {
    const layerElement = this.container.ownerDocument.createElement("div");
    layerElement.className = "textLayer";
    const layer = new this.pdfjs.TextLayer({
      textContentSource: this.page.streamTextContent(),
      container: layerElement,
      viewport: geometry.viewport,
    });
    this.textLayer = layer;
    try {
      await layer.render();
      this.assertCurrent(isCurrent);
    } catch (error) {
      if (this.cancelled && error?.name === "AbortException") {
        throw new CancelledRender();
      }
      throw error;
    }
    return transformedLayer(this.container, layerElement, geometry);
  }

  async prepareAnnotationLayer(geometry, isCurrent) {
    const annotations = (await this.page.getAnnotations({ intent: "display" }))
      .filter((annotation) => safeAnnotation(annotation, this.container.ownerDocument));
    this.assertCurrent(isCurrent);
    const layerElement = this.container.ownerDocument.createElement("div");
    layerElement.className = "annotationLayer";
    const layer = new this.pdfjs.AnnotationLayer({
      div: layerElement,
      accessibilityManager: null,
      annotationCanvasMap: null,
      annotationEditorUIManager: null,
      page: this.page,
      viewport: geometry.viewport,
      structTreeLayer: null,
    });
    await layer.render({
      annotations,
      linkService: safeLinkService(this.container.ownerDocument),
      renderForms: false,
    });
    this.assertCurrent(isCurrent);
    prepareAnnotationAccessibility(layerElement, annotations);
    return transformedLayer(this.container, layerElement, geometry);
  }

  assertCurrent(isCurrent) {
    if (this.cancelled || !isCurrent()) throw new CancelledRender();
  }

}

export function placementRequestKey(container, view, options) {
  if (!container.isConnected) return null;
  const bounds = container.getBoundingClientRect();
  if (bounds.width <= 0 || bounds.height <= 0) return null;
  const pixelSize = visiblePixelSize(
    container,
    view,
    options.maximumCanvasPixels,
  );
  const style = view.getComputedStyle(container);
  return [
    container.dataset.pdfSrc,
    container.dataset.page,
    container.dataset.viewBox,
    container.dataset.rotation,
    container.dataset.canvasBackground,
    container.dataset.copyAnnotations,
    style.width,
    style.height,
    pixelSize.width,
    pixelSize.height,
    options.textLayer,
    options.annotationLayer,
  ].join("|");
}

export function placementPageNumber(container) {
  const value = Number(container.dataset.page);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error("invalid PDF page number");
  }
  return value;
}

export function clearPdfPlacement(container) {
  container.querySelector(":scope > canvas")?.remove();
  container.querySelector(":scope > .ss-pdf-text")?.replaceChildren();
  container.querySelector(":scope > .ss-pdf-annotations")?.replaceChildren();
  delete container.dataset.ssPdfRendered;
}

export function isPdfRenderCancellation(error) {
  return error instanceof CancelledRender ||
    error?.name === "RenderingCancelledException";
}

class CancelledRender extends Error {
  constructor() {
    super("PDF rendering was cancelled");
    this.name = "RenderingCancelledException";
  }
}

function canvasBackground(container) {
  const value = container.dataset.canvasBackground;
  if (value === "transparent") return "rgba(0, 0, 0, 0)";
  throw new Error("invalid PDF canvas background");
}

function annotationPolicy(container) {
  const value = container.dataset.copyAnnotations;
  if (value !== "true" && value !== "false") {
    throw new Error("invalid PDF annotation policy");
  }
  return value === "true";
}

function transformedLayer(container, layer, geometry) {
  const content = container.ownerDocument.createElement("div");
  content.className = "ss-pdf-layer-content";
  content.style.setProperty("--scale-factor", String(geometry.viewport.scale));
  content.style.width = geometry.viewport.width + "px";
  content.style.height = geometry.viewport.height + "px";
  const scaleX = geometry.logicalWidth / geometry.selection.width;
  const scaleY = geometry.logicalHeight / geometry.selection.height;
  content.style.transform =
    "matrix(" + scaleX + ",0,0," + scaleY + "," +
    (-geometry.selection.left * scaleX) + "," +
    (-geometry.selection.top * scaleY) + ")";
  content.append(layer);
  return content;
}

function safeAnnotation(annotation, ownerDocument) {
  return typeof annotation.url === "string" && safeUrl(annotation.url, ownerDocument);
}

function prepareAnnotationAccessibility(layer, annotations) {
  const annotationsById = new Map(
    annotations.map((annotation) => [String(annotation.id), annotation]),
  );
  for (const section of layer.querySelectorAll(":scope > section")) {
    section.removeAttribute("tabindex");
    const link = section.querySelector(":scope > a");
    if (!link || link.getAttribute("aria-label")?.trim()) continue;
    const annotation = annotationsById.get(section.dataset.annotationId);
    link.setAttribute("aria-label", annotationLabel(annotation));
  }
}

function annotationLabel(annotation) {
  const values = [
    annotation?.alternativeText,
    annotation?.contentsObj?.str,
    annotation?.titleObj?.str,
    annotation?.url,
  ];
  return values.find((value) => typeof value === "string" && value.trim()) ??
    "PDF link";
}

function safeLinkService(ownerDocument) {
  return {
    addLinkAttributes(link, url, newWindow) {
      if (!safeUrl(url, ownerDocument)) return;
      link.href = url;
      link.rel = "noopener noreferrer nofollow";
      if (newWindow) link.target = "_blank";
    },
  };
}

function safeUrl(value, ownerDocument) {
  try {
    const url = new URL(value, ownerDocument.baseURI);
    const location = ownerDocument.defaultView?.location;
    if (["http:", "https:", "mailto:"].includes(url.protocol)) return true;
    if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(value) ||
        !location || location.protocol === "file:") return false;
    return location.origin !== "null" && url.origin === location.origin;
  } catch {
    return false;
  }
}
