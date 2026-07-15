export async function renderPdfPages(root, pdfjs, workerSource) {
  pdfjs.GlobalWorkerOptions.workerSrc = workerSource;
  await Promise.all([...root.querySelectorAll(".ss-pdf")].map(async (container) => {
    try {
      await renderPdfPage(container, pdfjs);
    } catch (error) {
      container.dataset.error = error instanceof Error ? error.message : String(error);
      throw error;
    }
  }));
}

async function renderPdfPage(container, pdfjs) {
  const documentTask = pdfjs.getDocument({
    url: container.dataset.pdfSrc,
    isEvalSupported: false,
    disableAutoFetch: true,
    disableStream: true,
  });
  const pdf = await documentTask.promise;
  const page = await pdf.getPage(Number(container.dataset.page));
  applySelectedPageBox(page, container);
  const unscaled = page.getViewport({ scale: 1 });
  const scale = container.clientWidth / unscaled.width;
  const viewport = page.getViewport({ scale });
  const outputScale = window.devicePixelRatio || 1;
  const canvas = container.querySelector("canvas");
  canvas.width = Math.ceil(viewport.width * outputScale);
  canvas.height = Math.ceil(viewport.height * outputScale);
  const context = canvas.getContext("2d", { alpha: true });
  await page.render({
    canvasContext: context,
    viewport,
    transform: outputScale === 1 ? null : [outputScale, 0, 0, outputScale, 0, 0],
  }).promise;

  const textLayer = container.querySelector(".textLayer");
  const textContent = await page.getTextContent();
  const layer = new pdfjs.TextLayer({ textContentSource: textContent, container: textLayer, viewport });
  await layer.render();

  const annotations = (await page.getAnnotations({ intent: "display" })).filter(safeAnnotation);
  const annotationLayer = container.querySelector(".annotationLayer");
  await pdfjs.AnnotationLayer.render({
    annotations,
    div: annotationLayer,
    page,
    viewport,
    linkService: {
      getDestinationHash: () => "",
      getAnchorUrl: (value) => value,
      goToDestination() {},
      executeNamedAction() {},
      addLinkAttributes(link, url, newWindow) {
        if (!safeUrl(url)) return;
        link.href = url;
        link.rel = "noopener noreferrer nofollow";
        if (newWindow) link.target = "_blank";
      },
    },
    renderForms: false,
  });
}

function applySelectedPageBox(page, container) {
  const values = container.dataset.viewBox?.split(",").map(Number);
  const rotation = Number(container.dataset.rotation);
  if (!values || values.length !== 4 || values.some((value) => !Number.isFinite(value))) {
    throw new Error("invalid PDF page box metadata");
  }
  if (![0, 90, 180, 270].includes(rotation)) throw new Error("invalid PDF page rotation metadata");
  if (!page._pageInfo || !Array.isArray(page._pageInfo.view)) {
    throw new Error("bundled PDF.js page metadata API changed");
  }
  page._pageInfo.view = values;
  page._pageInfo.rotate = rotation;
}

function safeAnnotation(annotation) {
  if (annotation.dest !== undefined && annotation.dest !== null) return true;
  return typeof annotation.url === "string" && safeUrl(annotation.url);
}

function safeUrl(value) {
  try {
    const url = new URL(value, document.baseURI);
    return ["http:", "https:", "mailto:"].includes(url.protocol) ||
      (!/^[A-Za-z][A-Za-z0-9+.-]*:/.test(value) && url.origin === location.origin);
  } catch {
    return false;
  }
}
