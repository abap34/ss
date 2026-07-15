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

  const annotations = await page.getAnnotations({ intent: "display" });
  const annotationLayer = container.querySelector(".annotationLayer");
  await pdfjs.AnnotationLayer.render({
    annotations,
    div: annotationLayer,
    page,
    viewport,
    linkService: { getDestinationHash: () => "", getAnchorUrl: (value) => value, addLinkAttributes() {} },
    renderForms: false,
  });
}
