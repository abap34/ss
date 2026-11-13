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

export async function exerciseContinuousEdits(browser, baseUrl, snapshot) {
  const page = await browser.newPage({ viewport: { width: 1200, height: 1000 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  let current = structuredClone(snapshot);
  let revision = 1;
  try {
    await page.goto(`${baseUrl}/index.html`, { waitUntil: "networkidle" });
    await postSnapshot(page, revision, current);
    await page.evaluate(() => {
      document.querySelector('.object-hit[data-object-id="202"]')
        .dispatchEvent(new MouseEvent("click", { bubbles: true }));
      document.querySelector('.sheet-toggle[aria-controls="object-202-bounds"]').click();
    });
    for (let step = 0; step < 12; step++) {
      const width = 400 + step * 10;
      await page.locator('.object-sheet input[aria-label="Component width"]').evaluate((input, value) => {
        input.value = String(value);
        input.dispatchEvent(new Event("change", { bubbles: true }));
      }, width);
      const request = await page.evaluate(() => __messages.findLast((item) => item.type === "resizeComponentWidth"));
      assert.equal(request.snapshotId, current.snapshot_id,
        "a continuous edit used an obsolete snapshot");
      const result = {
        type: "componentWidthEditResult", requestId: request.requestId,
        status: "applied", documentVersion: step + 2,
      };
      const next = structuredClone(current);
      next.snapshot_id = `continuous-${step}`;
      const previousId = current.editing.find((item) => item.binding === "detail").node_id;
      const nextId = 500 + step;
      const item = next.layout.objects.find((item) => item.id === previousId);
      item.width = width;
      item.id = nextId;
      next.outline.find((item) => item.id === previousId).id = nextId;
      next.editing.find((item) => item.binding === "detail").node_id = nextId;
      const previousWidth = current.layout.objects.find((item) => item.id === previousId).width;
      next.display.html = next.display.html.replace(`width:${previousWidth}pt`, `width:${width}pt`);
      next.display.html = next.display.html.replace(`data-ss-node-id="${previousId}"`, `data-ss-node-id="${nextId}"`);
      if (step % 2 === 0) {
        await postMessage(page, result);
        assert.equal(await page.locator(".toast--error").count(), 0,
          "an acknowledgement was reconciled against its request snapshot");
        await postSnapshot(page, ++revision, next, step + 2);
      } else {
        await postSnapshot(page, ++revision, next, step + 2);
        await page.evaluate(() => { globalThis.__continuousViewport = document.querySelector(".viewport"); });
        await postMessage(page, result);
        await page.waitForFunction(() => !document.querySelector("[data-ss-pending-width]"));
        assert(await page.evaluate(() => __continuousViewport === document.querySelector(".viewport")),
          "a late acknowledgement rebuilt the preview");
      }
      current = next;
      assert.equal(await page.locator(`.object-hit[data-object-id="${nextId}"].is-selected`).count(), 1,
        "a source identifier change lost the selected binding");
      await page.waitForFunction(() => !document.querySelector("[data-ss-pending-width]"));
      assert.equal(await page.locator('.object-sheet input[aria-label="Component width"]').inputValue(), String(width));
      await page.locator('.object-sheet input[aria-label="Component width"]').waitFor({ state: "visible" });
      assert.equal(await page.locator(".toast--error").count(), 0,
        "continuous edits produced a reconciliation failure");
      await postMessage(page, { ...result, status: "rejected", message: "Obsolete duplicate response" });
      assert.equal(await page.locator(".toast--error").count(), 0,
        "a duplicate acknowledgement changed a completed edit");
    }
    await page.locator('.object-sheet input[aria-label="Component width"]').evaluate((input) => {
      input.value = "520";
      input.dispatchEvent(new Event("change", { bubbles: true }));
    });
    const finalRequest = await page.evaluate(() => __messages.findLast((item) => item.type === "resizeComponentWidth"));
    const final = structuredClone(current);
    final.snapshot_id = "continuous-presentation";
    final.layout.objects.find((item) => item.id === 511).width = 520;
    final.display.html = final.display.html.replace("width:510pt", "width:520pt");
    await postSnapshot(page, ++revision, final, 14);
    await page.getByRole("button", { name: "Start presentation from the beginning", exact: true }).click();
    await page.waitForSelector(".presentation-stage");
    await page.evaluate(() => { globalThis.__continuousStage = document.querySelector(".presentation-stage"); });
    await postMessage(page, {
      type: "componentWidthEditResult", requestId: finalRequest.requestId,
      status: "applied", documentVersion: 14,
    });
    assert(await page.evaluate(() => __continuousStage === document.querySelector(".presentation-stage")),
      "a late edit acknowledgement recreated the presentation");
    await postMessage(page, { type: "buildStatus", revision: ++revision, status: "building" });
    assert(await page.evaluate(() => __continuousStage === document.querySelector(".presentation-stage")),
      "a background build status recreated the active presentation");
    await postMessage(page, { type: "error", revision: ++revision, message: "Temporary build failure" });
    assert(await page.evaluate(() => __continuousStage === document.querySelector(".presentation-stage")),
      "a build failure recreated the active presentation");
    assert.deepEqual(errors, []);
  } finally {
    await page.close();
  }
}

async function postMessage(page, message) {
  await page.evaluate((value) => new Promise((resolve) => {
    window.postMessage(value, "*");
    window.addEventListener("message", function observed(event) {
      if (event.data.type !== value.type || event.data.requestId !== value.requestId) return;
      window.removeEventListener("message", observed);
      resolve();
    });
  }), message);
}

async function postSnapshot(page, revision, snapshot, documentVersion = 1) {
  await page.evaluate((message) => window.postMessage(message, "*"), {
    type: "snapshot", revision, documentVersion, snapshot,
  });
  await page.waitForFunction((snapshotId) => __messages.some((message) =>
    message.type === "snapshotResources" && message.observedSnapshotId === snapshotId
  ), snapshot.snapshot_id);
}
