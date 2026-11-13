import assert from "node:assert/strict";

export async function exercisePdfUpdates(browser, baseUrl, snapshot) {
  const page = await browser.newPage({ viewport: { width: 1200, height: 1000 } });
  try {
    await page.goto(`${baseUrl}/index.html`, { waitUntil: "networkidle" });
    await postSnapshot(page, 1, snapshot);
    await page.waitForSelector('.preview .ss-pdf[data-ss-pdf-rendered="true"]');
    await page.waitForSelector('.thumbnail-preview .ss-pdf > img');
    assert.deepEqual(await page.evaluate(() => {
      const main = document.querySelector(".preview .ss-pdf");
      const thumbnail = document.querySelector(".thumbnail-preview .ss-pdf");
      return {
        mainLayers: main.querySelectorAll(":scope > .ss-pdf-layer").length,
        thumbnailLayers: thumbnail.querySelectorAll(":scope > .ss-pdf-layer").length,
        errors: __messages.filter((message) => message.type === "pdfPreviewError"),
      };
    }), { mainLayers: 2, thumbnailLayers: 0, errors: [] },
    "normal and thumbnail PDF rendering used incompatible placement structures");
    await page.evaluate(() => {
      document.querySelector('.object-hit[data-object-id="101"]')
        .dispatchEvent(new MouseEvent("click", { bubbles: true }));
      globalThis.__pdfErrorViewport = document.querySelector(".viewport");
      globalThis.__pdfErrorSheet = document.querySelector(".object-sheet");
      globalThis.__pdfErrorCount = 0;
      document.getElementById("app").addEventListener("ss-pdf-error", () => __pdfErrorCount++);
      // Check that diagnostics distinguish a later mutation from invalid input.
      const pdf = document.querySelector(".preview .ss-pdf");
      pdf.querySelector(":scope > .ss-pdf-annotations").remove();
      pdf.dataset.rotation = "90";
      window.dispatchEvent(new Event("resize"));
    });
    await page.waitForSelector(".toast--error");
    assert.equal(await page.locator(".toast--error").textContent(), "missing PDF display layer");
    const diagnostic = await page.evaluate(() =>
      __messages.findLast((message) => message.type === "pdfPreviewError")?.diagnostics
    );
    assert.equal(diagnostic.snapshotId, snapshot.snapshot_id);
    assert.equal(diagnostic.thumbnail, false);
    assert.equal(diagnostic.template[0].annotationLayers, 1,
      "PDF diagnostics lost the source template's structure");
    assert.equal(diagnostic.beforeMount[0].annotationLayers, 1,
      "PDF diagnostics did not retain the placement's original structure");
    assert.equal(diagnostic.atError[0].annotationLayers, 0,
      "PDF diagnostics did not identify the missing annotation layer");
    assert.equal(diagnostic.rootContainsPlacement, true);
    assert.match(diagnostic.rendererSource, /\/out\/(render\/pdf|editor\/main)\.js$/);
    assert.equal(await page.evaluate(() => __pdfErrorViewport === document.querySelector(".viewport") &&
      __pdfErrorSheet === document.querySelector(".object-sheet")), true,
    "a PDF error recreated the viewport and retried its own failed render");
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    assert.equal(await page.evaluate(() => __pdfErrorCount), 1,
      "a background PDF failure repeatedly notified the editor");
    assert.equal(await page.locator('.object-hit[data-object-id="101"].is-selected').count(), 1,
      "a PDF error changed the object selection");

    await page.getByRole("button", { name: "Start presentation from the beginning", exact: true }).click();
    await page.waitForSelector(".presentation-stage");
    assert.equal(await page.evaluate(() => {
      const stage = document.querySelector(".presentation-stage");
      stage.dispatchEvent(new CustomEvent("ss-pdf-error", {
        bubbles: true, detail: { message: "PDF preview rendering failed." },
      }));
      return stage === document.querySelector(".presentation-stage");
    }), true, "a PDF error rebuilt the presentation and retried its failed render");
  } finally {
    await page.close();
  }
}

async function postSnapshot(page, revision, snapshot, documentVersion = 1) {
  await page.evaluate((message) => window.postMessage(message, "*"), {
    type: "snapshot", revision, documentVersion, snapshot,
  });
  await page.waitForFunction((snapshotId) => __messages.some((message) =>
    message.type === "snapshotResources" && message.observedSnapshotId === snapshotId
  ), snapshot.snapshot_id);
}
