#!/usr/bin/env node
import assert from "node:assert/strict";
import { cp, mkdir, readdir, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { pdfAsset } from "../render/assets.mjs";
import { withBrowser } from "../render/capture.mjs";
import { exerciseBuildDiagnosticMessages } from "./diagnostics.mjs";
import { editorSnapshot, testDocument } from "./fixture.mjs";
import { exerciseTranslationLifecycle } from "./translation.mjs";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const source = path.join(repository, "editor/vscode/media/editor");
const output = path.join(repository, ".ss-cache/editor-ui-test");
const require = createRequire(import.meta.url);
const esbuild = require(path.join(repository, "editor/vscode/node_modules/esbuild"));

await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
for (const entry of await readdir(source, { withFileTypes: true })) {
  await cp(path.join(source, entry.name), path.join(output, entry.name), { recursive: entry.isDirectory() });
}
await mkdir(path.join(output, "out/render"), { recursive: true });
await mkdir(path.join(output, "out/pdfjs"), { recursive: true });
const pdfSourceRoot = path.join(repository, "src/render/html/pdf");
await esbuild.build({
  entryPoints: [path.join(pdfSourceRoot, "index.js")],
  bundle: true,
  outfile: path.join(output, "out/render/pdf.js"),
  format: "esm",
  platform: "browser",
  target: "chrome120",
  plugins: [{
    name: "ss-pdf-runtime-imports",
    setup(build) {
      build.onResolve({ filter: /^@ss\/pdf\/[^/]+$/ }, (args) => ({
        path: path.join(pdfSourceRoot, `${args.path.slice("@ss/pdf/".length)}.js`),
      }));
    },
  }],
});
await cp(path.join(repository, "src/render/html/text.js"), path.join(output, "out/render/text.js"));
await cp(path.join(repository, "third_party/pdfjs/pdf.mjs"), path.join(output, "out/pdfjs/pdf.mjs"));
await cp(path.join(repository, "third_party/pdfjs/pdf.worker.mjs"), path.join(output, "out/pdfjs/pdf.worker.mjs"));
await writeFile(path.join(output, "asset.pdf"), pdfAsset());
await writeFile(path.join(output, "index.html"), testDocument(), "utf8");

await withBrowser(output, async (browser, baseUrl) => {
  await exerciseBuildDiagnosticMessages(browser, baseUrl, editorSnapshot());
  const page = await browser.newPage({ viewport: { width: 560, height: 920 } });
  let releasePdfRequest;
  try {
    let pdfRequests = 0;
    const pdfRequestGate = new Promise((resolve) => {
      releasePdfRequest = resolve;
    });
    await page.route("**/asset.pdf", async (route) => {
      await pdfRequestGate;
      await route.continue();
    });
    page.on("request", (request) => {
      if (new URL(request.url()).pathname.endsWith("/asset.pdf")) pdfRequests += 1;
    });
    await page.goto(`${baseUrl}/index.html`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => globalThis.__messages?.some((message) => message.type === "ready"));
    await expectBuildStatus(page, "starting", "Starting…");
    await postBuildStatus(page, 100, "building");
    await expectBuildStatus(page, "building", "Building…");
    const current = editorSnapshot();
    await postSnapshot(page, 100, current);
    await expectBuildStatus(page, "complete", "Build complete");
    await page.waitForSelector('.page-shell[data-page-id="11"]');
    await page.waitForFunction(() => document.getElementById("app")?.dataset.ssTextAligned === "true");
    assert.match(
      await page.locator(".ss-text-run[data-ss-baseline-y]").first().getAttribute("style"),
      /top:\s*calc\(/,
      "editor preview did not align an HTML text run to its IR baseline",
    );
    assert.equal(await page.locator(".ss-pdf > canvas").count(), 0,
      "editor exposed an empty PDF canvas while the source was loading");
    releasePdfRequest();
    await page.waitForFunction(() => {
      const placements = [...document.querySelectorAll(".ss-pdf")];
      return placements.length === 2 && placements.every((placement) =>
        placement.dataset.ssPdfRendered === "true" || placement.dataset.error
      );
    });
    const pdfErrors = await page.locator(".ss-pdf[data-error]").evaluateAll((placements) =>
      placements.map((placement) => placement.dataset.error)
    );
    assert.deepEqual(pdfErrors, [], `editor PDF rendering failed: ${pdfErrors.join("; ")}`);
    assert.equal(await page.locator(".ss-pdf[data-ss-pdf-rendered='true']").count(), 2,
      "editor PDF rendering did not complete");

    assert.equal(await page.locator(".page-entry").count(), 2, "page sidebar omitted a page");
    assert.equal(await page.locator(".page-thumbnail .ss-page").count(), 2, "page thumbnails did not reuse shared HTML pages");
    assert.equal(await page.locator(".page-shell").count(), 1, "single-page mode displayed more than one page");
    assert.equal(await page.locator('.page-shell[data-page-id="11"] .ss-item[data-ss-node-id="101"]').count(), 1,
      "central preview did not reuse the shared HTML item");
    assert.equal(pdfRequests, 1, "central preview and thumbnail loaded the same PDF more than once");
    assert.equal(await page.locator(".page-thumbnail .ss-pdf .textLayer").count(), 0,
      "PDF thumbnail created a text layer");
    assert.equal(await page.locator('.page-shell[data-page-id="11"] .ss-pdf .textLayer').count(), 0,
      "central editor preview created an unreachable PDF text layer");
    const mainCanvasWidth = await page.locator('.page-shell[data-page-id="11"] .ss-pdf > canvas').evaluate((canvas) => canvas.width);
    const thumbnailCanvasWidth = await page.locator('.page-thumbnail .ss-pdf > canvas').evaluate((canvas) => canvas.width);
    assert(thumbnailCanvasWidth < mainCanvasWidth, "PDF thumbnail rendered at the central preview resolution");
    assert(!((await page.locator(".ruler-tick small").allTextContents()).includes("0")), "rulers displayed a zero label");
    await page.evaluate(() => {
      globalThis.__retiringPdfRoots = [
        ...document.querySelectorAll("[data-ss-pdf-render-root='true']"),
      ];
    });

    await page.locator(".page-entry").nth(1).click();
    await page.waitForSelector('.page-shell[data-page-id="22"]');
    assert.equal(await page.locator('.page-entry.is-active small').textContent(), "Details");

    await page.locator("select.page-mode").selectOption("continuous");
    await page.waitForFunction(() => document.querySelectorAll(".page-shell").length === 2);
    assert.deepEqual(await page.locator(".page-caption").allTextContents(), ["Overview", "Details"]);
    await page.waitForFunction(() => {
      const shells = [...document.querySelectorAll(".page-shell")];
      if (shells.length !== 2) return false;
      const first = shells[0].getBoundingClientRect();
      const second = shells[1].getBoundingClientRect();
      return second.top - first.bottom >= 45;
    });
    await page.waitForTimeout(100);
    await page.locator('.page-shell[data-page-id="11"] .ss-pdf > canvas').evaluate((canvas) => {
      canvas.dataset.identity = "retained";
    });

    await page.locator('.page-shell[data-page-id="22"] .object-hit[data-object-id="201"]').click();
    await page.waitForSelector(".object-sheet");
    assert.equal(
      await page.locator(".sheet-heading strong").textContent(),
      "label",
      "an object without a source edit target could not be selected",
    );
    await page.locator(".close-button").click();

    await page.locator('.page-shell[data-page-id="22"] .object-hit[data-object-id="202"]').click();
    await page.waitForSelector(".object-sheet");
    assert.equal(
      await page.locator('.page-shell[data-page-id="11"] .ss-pdf > canvas').getAttribute("data-identity"),
      "retained",
      "object selection recreated an unrelated PDF canvas",
    );
    assert.equal(await page.locator(".relation-row").count(), 3, "object details omitted explicit or fallback constraints");
    assert.equal(await page.locator(".relation-row--fallback").count(), 1, "fallback constraint was not marked");
    assert.equal(await page.locator(".relation-icon--absolute").count(), 2, "absolute constraints did not use their icon");
    assert.equal(await page.locator(".relation-icon--relative").count(), 1, "relative constraint did not use its icon");
    assert.equal(await page.locator('.page-shell[data-page-id="11"] .constraint').count(), 0,
      "selected-page constraints leaked onto another page");
    assert.equal(await page.locator('.page-shell[data-page-id="22"] .constraint').count(), 3,
      "selected-page constraints were not drawn");

    await page.locator(".source-button").click();
    const reveal = await lastMessage(page, "revealSource");
    assert.deepEqual(reveal, {
      type: "revealSource",
      path: "/workspace/slide.ss",
      start: 40,
      end: 75,
    });

    const outOfOrder = structuredClone(current);
    outOfOrder.generation = current.generation + 1;
    outOfOrder.snapshot_id = "out-of-order";
    outOfOrder.layout.pages = [outOfOrder.layout.pages[0]];
    await postSnapshot(page, 99, outOfOrder);
    await page.evaluate(() => new Promise((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(resolve))
    ));
    assert.equal(await page.locator(".page-shell").count(), 2, "an older snapshot replaced the current editor view");
    assert.equal(await page.locator(".object-sheet").count(), 1, "an older snapshot cleared the current selection");

    const finalSnapshot = await exerciseTranslationLifecycle(page, current);

    await page.waitForFunction(() =>
      document.querySelector('.page-shell[data-page-id="11"] .ss-pdf')
        ?.dataset.ssPdfRendered === "true"
    );
    await page.locator('.page-shell[data-page-id="11"] .ss-pdf > canvas').evaluate((canvas) => {
      canvas.dataset.identity = "retained-after-update";
    });
    await page.locator(".close-button").click();
    assert.equal(await page.locator(".object-sheet").count(), 0, "details sheet did not close");
    await page.locator(".activity-theme").click();
    assert.equal(await page.locator("html").getAttribute("data-theme"), "light");
    assert.equal(await page.evaluate(() => globalThis.__persisted.theme), "light");
    assert.equal(
      await page.locator('.page-shell[data-page-id="11"] .ss-pdf > canvas').getAttribute("data-identity"),
      "retained-after-update",
      "theme change recreated a rendered PDF canvas",
    );

    const failed = structuredClone(finalSnapshot);
    failed.stale = true;
    failed.build_diagnostics = [
      {
        uri: "file:///workspace/slide.ss",
        range: {
          start: { line: 11, character: 3 },
          end: { line: 11, character: 8 },
        },
        code: "ExpectedExpression",
        message: "expected an expression after '='",
      },
    ];
    await postSnapshot(page, 107, failed, 6);
    await page.waitForSelector(".toast--error");
    await expectBuildStatus(page, "failed", "Build failed");
    assert.equal(
      await page.locator(".toast--error").textContent(),
      "Build failed. The preview is showing the last successful result.\n" +
        "slide.ss:12:4 [ExpectedExpression] expected an expression after '='",
      "stale preview did not explain its build failure",
    );
    await postSnapshot(page, 108, failed, 6);
    assert.equal(
      await page.locator(".toast--error").count(),
      1,
      "a repeated failed build cleared its diagnostic message",
    );
    await postSnapshot(page, 109, finalSnapshot, 7);
    await page.waitForFunction(() => !document.querySelector(".toast--error"));
    await expectBuildStatus(page, "complete", "Build complete");

    await page.evaluate(() => {
      window.postMessage({
        type: "error",
        revision: 110,
        message: "WYSIWYG preview update failed.",
      }, "*");
    });
    await page.waitForSelector(".toast--error");
    await expectBuildStatus(page, "failed", "Build failed");
    await postSnapshot(page, 111, finalSnapshot, 7);
    await page.waitForFunction(() => !document.querySelector(".toast--error"));
    await expectBuildStatus(page, "complete", "Build complete");
    await page.locator('.page-shell[data-page-id="11"] .ss-pdf > canvas')
      .evaluate((canvas) => {
        canvas.dataset.identity = "retained-through-status";
      });
    assert.equal(
      await page.locator(".toast--error").count(),
      0,
      "a successful recovery retained the previous preview error",
    );

    await page.evaluate(() => {
      window.postMessage({
        type: "error",
        revision: 110,
        message: "obsolete preview failure",
      }, "*");
    });
    await page.waitForTimeout(50);
    assert.equal(
      await page.locator(".toast--error").count(),
      0,
      "an obsolete preview error replaced a newer snapshot",
    );

    await postBuildStatus(page, 112, "building");
    await expectBuildStatus(page, "building", "Building…");
    await postBuildStatus(page, 112, "unavailable");
    await expectBuildStatus(
      page,
      "unavailable",
      "Language server unavailable",
    );
    await postBuildStatus(page, 111, "building");
    await expectBuildStatus(
      page,
      "unavailable",
      "Language server unavailable",
    );
    assert.equal(
      await page.locator('.page-shell[data-page-id="11"] .ss-pdf > canvas')
        .getAttribute("data-identity"),
      "retained-through-status",
      "build status changes recreated the rendered preview",
    );

    await page.getByRole("button", { name: "Pages" }).click();
    assert.equal(await page.locator("aside.sidebar").count(), 0, "active sidebar did not close through its activity button");
    await page.getByRole("button", { name: "Outline" }).click();
    assert.equal(await page.locator(".sidebar-title").textContent(), "Outline");
    assert(await page.locator(".outline-row").count() >= 4, "outline sidebar omitted document structure");

    const restarted = structuredClone(finalSnapshot);
    restarted.generation = 1;
    restarted.snapshot_id = "1-restarted";
    restarted.layout.pages[1].name = "Restarted";
    await postBuildStatus(page, 113, "building");
    await expectBuildStatus(page, "building", "Building…");
    await postSnapshot(page, 113, restarted, 7);
    await expectBuildStatus(page, "complete", "Build complete");
    await page.waitForFunction(() => [...document.querySelectorAll(".page-caption")]
      .some((caption) => caption.textContent === "Restarted"));
    assert.equal(await page.evaluate(() => globalThis.__retiringPdfRoots.every((root) =>
      !root.isConnected && root.dataset.ssPdfRenderRoot === undefined
    )), true, "snapshot replacement retained PDF controllers from the old snapshot");

    const lifecycle = await page.evaluate(async () => {
      const pdf = await import("./pdf.js");
      const emptied = document.createElement("div");
      emptied.innerHTML = '<div class="ss-pdf"></div>';
      document.body.append(emptied);
      const obsolete = pdf.renderPdfItems(emptied);
      emptied.replaceChildren();
      await pdf.renderPdfItems(emptied);
      await obsolete;

      const pending = document.createElement("div");
      pending.innerHTML = '<div class="ss-pdf"></div>';
      document.body.append(pending);
      const starting = pdf.renderPdfItems(pending);
      await pdf.disposePdfRuntime();
      await starting;
      return {
        emptied: emptied.dataset.ssPdfRenderRoot,
        pending: pending.dataset.ssPdfRenderRoot,
      };
    });
    assert.equal(lifecycle.emptied, undefined,
      "removing every PDF item retained the old editor mount");
    assert.equal(lifecycle.pending, undefined,
      "editor PDF runtime disposal retained an in-flight mount");
  } finally {
    releasePdfRequest?.();
    await page.close();
  }
});

async function postSnapshot(page, revision, value, documentVersion = 1) {
  await page.evaluate(({ deliveryRevision, snapshotValue, version }) => {
    window.postMessage({
      type: "snapshot",
      revision: deliveryRevision,
      documentVersion: version,
      snapshot: snapshotValue,
    }, "*");
  }, { deliveryRevision: revision, snapshotValue: value, version: documentVersion });
}

async function postBuildStatus(page, revision, status) {
  await page.evaluate((message) => window.postMessage(message, "*"), {
    type: "buildStatus",
    revision,
    status,
  });
}

async function expectBuildStatus(page, status, label) {
  await page.waitForFunction(({ expectedStatus, expectedLabel }) => {
    const node = document.querySelector(".build-status");
    return node?.classList.contains(`build-status--${expectedStatus}`) &&
      node.querySelector(".build-status-label")?.textContent === expectedLabel;
  }, { expectedStatus: status, expectedLabel: label });
  const node = page.locator(".build-status");
  assert.equal(await node.getAttribute("role"), "status");
  assert.equal(await node.getAttribute("title"), label);
}

async function lastMessage(page, type) {
  return await page.evaluate((messageType) => {
    const values = globalThis.__messages.filter((message) => message.type === messageType);
    return values.at(-1) ?? null;
  }, type);
}
