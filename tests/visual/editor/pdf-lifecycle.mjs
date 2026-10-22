import assert from "node:assert/strict";

export async function exercisePdfViewportLifecycle(browser, baseUrl, snapshot) {
  const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  try {
    await page.goto(`${baseUrl}/thumbnails.html`);
    await page.evaluate(async (snapshot) => {
      const { renderPage } = await import("./document.js");
      const style = document.createElement("style");
      style.textContent = snapshot.display.css;
      document.head.append(style);
      const viewport = document.createElement("div");
      viewport.className = "viewport";
      viewport.style.cssText = "position:relative;width:800px;height:500px;overflow:auto";
      const spacer = document.createElement("div");
      spacer.style.height = "5000px";
      const surface = document.createElement("div");
      surface.style.cssText = "position:relative;width:800px;height:500px";
      const preview = renderPage(snapshot, snapshot.layout.pages[0].id);
      surface.append(preview);
      viewport.append(spacer, surface);
      document.body.replaceChildren(viewport);
      globalThis.__snapshot = snapshot;
      const { renderPdfItems } = await import("./pdf.js");
      await renderPdfItems(preview, { textLayer: false, annotationLayer: false });
    }, snapshot);
    assert.equal(await page.locator(".ss-pdf > canvas").count(), 0,
      "offscreen PDF was rendered before entering the prefetch region");
    await page.evaluate(async () => {
      const { renderPage } = await import("./document.js");
      const previous = document.querySelector(".viewport");
      const next = previous.cloneNode(false);
      previous.replaceWith(next);
      const surface = document.createElement("div");
      surface.style.cssText = "position:relative;width:800px;height:500px";
      surface.append(renderPage(__snapshot, __snapshot.layout.pages[0].id));
      next.append(surface);
    });
    await page.waitForSelector(".ss-pdf > canvas", { timeout: 8000 });
    assert.deepEqual(await page.locator("[data-error]").evaluateAll((nodes) =>
      nodes.map((node) => node.dataset.error)), []);
    assert.deepEqual(errors, []);
  } finally {
    await page.close();
  }
}
