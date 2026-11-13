import assert from "node:assert/strict";

export async function exerciseRetainedUpdates(browser, baseUrl, snapshot) {
  const page = await browser.newPage({ viewport: { width: 1200, height: 1000 } });
  let revision = 1;
  let current = snapshot;
  const postUpdate = async (model = current) => {
    const next = {
      ...model,
      snapshot_id: `retained-update-${++revision}`,
      display: {
        schema: 3, kind: "translation_patch",
        base_snapshot_id: current.snapshot_id, translations: [],
      },
    };
    await postSnapshot(page, revision, next);
    current = { ...next, display: snapshot.display };
  };
  try {
    await page.goto(`${baseUrl}/index.html`, { waitUntil: "networkidle" });
    await postSnapshot(page, revision, current);
    await page.evaluate(() => {
      document.querySelector('.object-hit[data-object-id="202"]')
        .dispatchEvent(new MouseEvent("click", { bubbles: true }));
      document.querySelector('.sheet-toggle[aria-controls="object-202-bounds"]').click();
      globalThis.__retainedUpdate = {
        viewport: document.querySelector(".viewport"),
        layer: document.querySelector('.page-shell[data-page-id="22"] .interaction-layer'),
        sheet: document.querySelector(".object-sheet"),
        source: document.querySelector('.page-shell[data-page-id="22"] .page-source-button'),
        input: document.querySelector('.object-sheet input[aria-label="Component width"]'),
      };
      __retainedUpdate.source.focus();
    });
    await postUpdate();
    assert.equal(await page.evaluate(() => document.activeElement === __retainedUpdate.source),
      true, "an unchanged snapshot removed page source focus");
    await page.evaluate(() => {
      __retainedUpdate.input.value = "413";
      __retainedUpdate.input.focus();
    });
    await postUpdate();
    assert.equal(await page.evaluate(() => {
      const saved = __retainedUpdate;
      return saved.viewport === document.querySelector(".viewport") &&
        saved.layer === document.querySelector('.page-shell[data-page-id="22"] .interaction-layer') &&
        saved.sheet === document.querySelector(".object-sheet") &&
        saved.source === document.querySelector('.page-shell[data-page-id="22"] .page-source-button') &&
        saved.input === document.activeElement && saved.input.value === "413" &&
        getComputedStyle(saved.sheet).visibility === "visible";
    }), true, "an unchanged snapshot disturbed the selected object's controls");
    await page.evaluate(() => document.querySelector('.object-hit[data-object-id="202"]')
      .dispatchEvent(new MouseEvent("click", { bubbles: true })));
    assert.equal(await page.evaluate(() => __retainedUpdate.sheet === document.querySelector(".object-sheet")),
      true, "selecting the current object recreated its controls");

    const relocated = structuredClone(current);
    const relocatedPage = relocated.layout.pages.find((item) => item.id === 22);
    relocatedPage.location = { ...relocatedPage.location, start: 90, end: 160 };
    relocated.editing.find((item) => item.node_id === 202).minimum_width = 12;
    await postUpdate(relocated);
    assert.equal(await page.evaluate(() => __retainedUpdate.source ===
      document.querySelector('.page-shell[data-page-id="22"] .page-source-button')),
    true, "updating a page source target replaced its button");
    assert.equal(await page.locator('.page-shell[data-page-id="22"] .page-source-button')
      .getAttribute("aria-label"), "Open Details in Editor");
    assert.equal(await page.locator('.object-sheet input[aria-label="Component width"]').getAttribute("min"), "12",
      "an empty display patch ignored changed editing capabilities");
    await page.evaluate(() => __retainedUpdate.source.click());
    assert.deepEqual(await page.evaluate(() => __messages.findLast((item) => item.type === "revealSource")), {
      type: "revealSource", path: "/workspace/slide.ss", start: 90, end: 160,
    }, "a retained page source button used obsolete source offsets");

    await page.locator('.object-sheet input[aria-label="Component width"]').evaluate((input) => {
      input.value = "420";
      input.dispatchEvent(new Event("change", { bubbles: true }));
    });
    await page.waitForSelector("[data-ss-pending-width]");
    await page.evaluate(() => window.postMessage({
      type: "componentWidthEditResult", status: "applied", documentVersion: 1,
      requestId: __messages.findLast((item) => item.type === "resizeComponentWidth").requestId,
    }, "*"));
    await postUpdate();
    assert.equal(await page.locator("[data-ss-pending-width]").count(), 0,
      "an unchanged editing model retained a rejected optimistic width");
    assert.match(await page.locator(".toast--error").textContent(), /did not reproduce/);
  } finally {
    await page.close();
  }
}

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
