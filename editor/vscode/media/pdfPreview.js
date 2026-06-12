(async function () {
  "use strict";

  const vscode = createHostApi();
  const body = document.body;
  const scroll = document.getElementById("scroll");
  const pages = document.getElementById("pages");
  const status = document.getElementById("status");
  const pageNumber = document.getElementById("pageNumber");
  const pageCount = document.getElementById("pageCount");
  const zoomValue = document.getElementById("zoomValue");
  const zoomOut = document.getElementById("zoomOut");
  const fitWidth = document.getElementById("fitWidth");
  const zoomIn = document.getElementById("zoomIn");

  const minScale = 0.2;
  const maxScale = 4;
  const fetchTimeoutMs = 15000;
  const loadTimeoutMs = 20000;

  installPromiseWithResolvers();

  let pdfDocument = undefined;
  let pendingRefresh = undefined;
  let refreshRunning = false;
  let activeFileName = "";
  let currentPage = 1;
  let scale = 1;
  let lastRenderedScale = 1;
  let useFitWidth = true;
  let renderToken = 0;
  let resizeTimer = undefined;

  let pdfjs = undefined;
  setStatus("Loading PDF.js");
  try {
    pdfjs = await import(body.dataset.pdfjsUri);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    reportError(message);
    setStatus("PDF.js did not load");
    setEmpty("PDF.js did not load.");
    return;
  }

  pdfjs.GlobalWorkerOptions.workerSrc = "";
  pdfjs.GlobalWorkerOptions.workerPort = createPdfWorker(body.dataset.workerUri);
  reportLog("PDF.js loaded");

  window.addEventListener("message", (event) => {
    const message = event.data;
    if (message && message.type === "refresh") {
      queueRefresh(message);
    }
  });

  window.addEventListener("resize", () => {
    if (!pdfDocument || !useFitWidth) {
      return;
    }
    if (resizeTimer) {
      clearTimeout(resizeTimer);
    }
    resizeTimer = setTimeout(() => {
      resizeTimer = undefined;
      void renderDocument(captureView());
    }, 120);
  });

  scroll.addEventListener("scroll", updateCurrentPageFromScroll, { passive: true });
  pageNumber.addEventListener("change", () => {
    const requested = Number.parseInt(pageNumber.value, 10);
    if (Number.isFinite(requested)) {
      scrollToPage(requested);
    }
  });
  zoomOut.addEventListener("click", () => zoomBy(1 / 1.2));
  zoomIn.addEventListener("click", () => zoomBy(1.2));
  fitWidth.addEventListener("click", () => {
    if (!pdfDocument) {
      return;
    }
    useFitWidth = true;
    void renderDocument(captureView());
  });

  setControls(false);
  const initialRefresh = initialRefreshMessage();
  if (initialRefresh) {
    queueRefresh(initialRefresh);
  }
  vscode.postMessage({ type: "ready" });

  function initialRefreshMessage() {
    if (!body.dataset.initialPdfUri) {
      return undefined;
    }
    reportLog("initial " + body.dataset.initialFileName);
    return {
      type: "refresh",
      pdfUri: body.dataset.initialPdfUri,
      version: Number.parseInt(body.dataset.initialVersion || "0", 10) || 0,
      fileName: body.dataset.initialFileName || "preview.pdf",
    };
  }

  function queueRefresh(message) {
    pendingRefresh = message;
    void drainRefreshQueue();
  }

  async function drainRefreshQueue() {
    if (refreshRunning) {
      return;
    }
    refreshRunning = true;
    try {
      while (pendingRefresh) {
        const next = pendingRefresh;
        pendingRefresh = undefined;
        await loadPdf(next);
      }
    } finally {
      refreshRunning = false;
      setControls(Boolean(pdfDocument));
    }
  }

  async function loadPdf(message) {
    const previousView = captureView();
    activeFileName = message.fileName || "preview.pdf";
    setStatus("Fetching " + activeFileName);
    setControls(false);

    try {
      const pdfData = await fetchPdfData(message.pdfUri);
      setStatus("Loading " + activeFileName);
      const loadingTask = pdfjs.getDocument({
        data: pdfData,
        cMapUrl: body.dataset.cmapUri,
        cMapPacked: true,
        standardFontDataUrl: body.dataset.standardFontUri,
        useWorkerFetch: false,
      });
      loadingTask.onProgress = (progress) => {
        if (progress.total > 0) {
          const percent = Math.min(100, Math.round((progress.loaded / progress.total) * 100));
          setStatus("Loading " + activeFileName + " " + percent + "%");
        }
      };
      const nextDocument = await withTimeout(loadingTask.promise, loadTimeoutMs, () => {
        void loadingTask.destroy().catch(function () { return undefined; });
      });
      const previousDocument = pdfDocument;
      pdfDocument = nextDocument;
      currentPage = clamp(previousView.page, 1, pdfDocument.numPages);
      await renderDocument(previousView);
      if (previousDocument && previousDocument !== nextDocument) {
        await previousDocument.destroy().catch(function () { return undefined; });
      }
      setStatus(activeFileName);
    } catch (error) {
      const messageText = error instanceof Error ? error.message : String(error);
      reportError(messageText);
      setStatus("Failed to load PDF");
      setEmpty(messageText);
    }
  }

  async function fetchPdfData(pdfUri) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), fetchTimeoutMs);
    try {
      reportLog("fetch " + pdfUri);
      const response = await fetch(pdfUri, {
        cache: "no-store",
        signal: controller.signal,
      });
      if (!response.ok) {
        throw new Error("PDF fetch failed with status " + response.status);
      }
      const buffer = await response.arrayBuffer();
      reportLog("fetched " + buffer.byteLength + " bytes");
      return new Uint8Array(buffer);
    } finally {
      clearTimeout(timer);
    }
  }

  function withTimeout(promise, timeoutMs, onTimeout) {
    let timer = undefined;
    const timeout = new Promise(function (_, reject) {
      timer = setTimeout(function () {
        onTimeout();
        reject(new Error("PDF loading timed out after " + timeoutMs + "ms"));
      }, timeoutMs);
    });
    return Promise.race([promise, timeout]).finally(function () {
      clearTimeout(timer);
    });
  }

  async function renderDocument(previousView) {
    if (!pdfDocument) {
      return;
    }
    const token = renderToken + 1;
    renderToken = token;
    const documentToRender = pdfDocument;
    const renderedPages = [];
    setStatus("Rendering " + activeFileName);
    pageCount.textContent = "/ " + documentToRender.numPages;
    pageNumber.max = String(documentToRender.numPages);

    try {
      const firstPage = await documentToRender.getPage(1);
      if (token !== renderToken || documentToRender !== pdfDocument) {
        return;
      }
      const baseViewport = firstPage.getViewport({ scale: 1 });
      const targetScale = useFitWidth ? fitScale(baseViewport.width) : scale;
      lastRenderedScale = targetScale;
      updateZoomValue();

      for (let index = 1; index <= documentToRender.numPages; index += 1) {
        if (token !== renderToken || documentToRender !== pdfDocument) {
          return;
        }
        const page = index === 1 ? firstPage : await documentToRender.getPage(index);
        if (token !== renderToken || documentToRender !== pdfDocument) {
          return;
        }
        renderedPages.push(await renderPage(page, index, targetScale));
      }
      if (token !== renderToken || documentToRender !== pdfDocument) {
        return;
      }

      pages.replaceChildren(...renderedPages);
      restoreView(previousView);
      updateCurrentPageFromScroll();
      setStatus(activeFileName);
    } catch (error) {
      const messageText = error instanceof Error ? error.message : String(error);
      reportError(messageText);
      setStatus("Failed to render PDF");
      setEmpty(messageText);
    }
  }

  async function renderPage(page, index, targetScale) {
    const viewport = page.getViewport({ scale: targetScale });
    const holder = document.createElement("section");
    holder.className = "page";
    holder.dataset.page = String(index);
    holder.style.width = Math.floor(viewport.width) + "px";

    const canvas = document.createElement("canvas");
    const context = canvas.getContext("2d");
    if (!context) {
      throw new Error("Canvas is not available.");
    }
    const outputScale = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.floor(viewport.width * outputScale);
    canvas.height = Math.floor(viewport.height * outputScale);
    canvas.style.width = Math.floor(viewport.width) + "px";
    canvas.style.height = Math.floor(viewport.height) + "px";
    holder.appendChild(canvas);

    const transform = outputScale === 1 ? undefined : [outputScale, 0, 0, outputScale, 0, 0];
    await page.render({ canvasContext: context, viewport, transform }).promise;
    page.cleanup();
    return holder;
  }

  function captureView() {
    if (!pdfDocument) {
      return { page: 1, offset: 0 };
    }
    const top = scroll.scrollTop;
    const holders = pages.querySelectorAll(".page");
    for (const holder of holders) {
      if (holder.offsetTop + holder.offsetHeight >= top + 8) {
        return {
          page: Number.parseInt(holder.dataset.page || "1", 10),
          offset: top - holder.offsetTop,
        };
      }
    }
    return { page: currentPage, offset: 0 };
  }

  function restoreView(previousView) {
    const targetPage = clamp(previousView.page || currentPage, 1, pdfDocument.numPages);
    const holder = pageHolder(targetPage);
    if (!holder) {
      scroll.scrollTop = 0;
      return;
    }
    const offset = clamp(previousView.offset || 0, 0, Math.max(0, holder.offsetHeight - 1));
    scroll.scrollTop = Math.max(0, holder.offsetTop + offset);
  }

  function updateCurrentPageFromScroll() {
    if (!pdfDocument) {
      return;
    }
    const top = scroll.scrollTop + 8;
    const holders = pages.querySelectorAll(".page");
    let nextPage = 1;
    for (const holder of holders) {
      nextPage = Number.parseInt(holder.dataset.page || "1", 10);
      if (holder.offsetTop + holder.offsetHeight >= top) {
        break;
      }
    }
    currentPage = clamp(nextPage, 1, pdfDocument.numPages);
    pageNumber.value = String(currentPage);
    setControls(true);
  }

  function scrollToPage(page) {
    if (!pdfDocument) {
      return;
    }
    const targetPage = clamp(page, 1, pdfDocument.numPages);
    const holder = pageHolder(targetPage);
    if (holder) {
      scroll.scrollTo({ top: holder.offsetTop, behavior: "smooth" });
    }
    currentPage = targetPage;
    pageNumber.value = String(targetPage);
    setControls(true);
  }

  function pageHolder(page) {
    return pages.querySelector('.page[data-page="' + page + '"]');
  }

  function zoomBy(factor) {
    if (!pdfDocument) {
      return;
    }
    useFitWidth = false;
    scale = clamp(lastRenderedScale * factor, minScale, maxScale);
    void renderDocument(captureView());
  }

  function fitScale(pageWidth) {
    const availableWidth = Math.max(160, scroll.clientWidth - 40);
    return clamp(availableWidth / pageWidth, minScale, maxScale);
  }

  function updateZoomValue() {
    zoomValue.textContent = Math.round(lastRenderedScale * 100) + "%";
  }

  function setControls(enabled) {
    const hasDocument = enabled && Boolean(pdfDocument);
    pageNumber.disabled = !hasDocument;
    zoomOut.disabled = !hasDocument;
    fitWidth.disabled = !hasDocument;
    zoomIn.disabled = !hasDocument;
  }

  function setStatus(text) {
    if (status) {
      status.textContent = text;
    }
  }

  function setEmpty(text) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = text;
    pages.replaceChildren(empty);
    pageCount.textContent = "/ 0";
    pageNumber.value = "1";
    pageNumber.max = "1";
    setControls(false);
  }

  function reportError(message) {
    vscode.postMessage({ type: "error", message });
  }

  function reportLog(message) {
    vscode.postMessage({ type: "log", message });
  }

  function createHostApi() {
    if (typeof acquireVsCodeApi === "function") {
      return acquireVsCodeApi();
    }
    return {
      postMessage(message) {
        window.parent.postMessage({ source: "ss-pdf-viewer", message }, "*");
      },
    };
  }

  function createPdfWorker(workerUri) {
    const worker = new Worker(workerUri, { type: "module" });
    worker.addEventListener("error", (event) => {
      reportError("PDF worker error: " + (event.message || "unknown worker error"));
    });
    reportLog("PDF worker created");
    return worker;
  }

  function installPromiseWithResolvers() {
    if (typeof Promise.withResolvers === "function") {
      return;
    }
    Promise.withResolvers = function () {
      let resolve;
      let reject;
      const promise = new Promise(function (resolvePromise, rejectPromise) {
        resolve = resolvePromise;
        reject = rejectPromise;
      });
      return { promise, resolve, reject };
    };
  }

  function clamp(value, min, max) {
    return Math.min(Math.max(value, min), max);
  }
}());
