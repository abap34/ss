let modules;

export async function renderPdfItems(root) {
  if (!root.querySelector(".ss-pdf")) return;
  modules ??= Promise.all([
    import("../../out/render/pdf.js"),
    import("../../out/pdfjs/pdf.mjs"),
  ]);
  const [renderer, pdfjs] = await modules;
  const worker = new URL("../../out/pdfjs/pdf.worker.mjs", import.meta.url).href;
  await renderer.renderPdfPages(root, pdfjs, worker);
}
