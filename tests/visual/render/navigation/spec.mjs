#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath, pathToFileURL } from "node:url";
import { pdfAsset } from "../assets.mjs";
import { withBrowser } from "../capture.mjs";

const exec = promisify(execFile);
const directory = path.dirname(fileURLToPath(import.meta.url));
const repository = path.resolve(directory, "../../../..");

export async function inspectStandaloneNavigation(browser, baseUrl) {
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  const runtimeErrors = [];
  page.on("pageerror", (error) => runtimeErrors.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error" ||
        message.text().includes("Setting up fake worker")) {
      runtimeErrors.push(message.text());
    }
  });
  try {
    await page.addInitScript(() => {
      const createObjectURL = URL.createObjectURL.bind(URL);
      const NativeWorker = globalThis.Worker;
      globalThis.__pdfBlobCount = 0;
      globalThis.__pdfWorkerCount = 0;
      globalThis.__prematureBodyVisibility = false;
      globalThis.Worker = new Proxy(NativeWorker, {
        construct(target, argumentsList) {
          globalThis.__pdfWorkerCount += 1;
          return Reflect.construct(target, argumentsList);
        },
      });
      URL.createObjectURL = (value) => {
        if (value?.type === "application/pdf") globalThis.__pdfBlobCount += 1;
        return createObjectURL(value);
      };
      const visibilityObserver = new MutationObserver(() => {
        if (document.body &&
            !document.documentElement.dataset.ssReady &&
            !document.documentElement.dataset.ssError &&
            getComputedStyle(document.body).visibility !== "hidden") {
          globalThis.__prematureBodyVisibility = true;
        }
      });
      visibilityObserver.observe(document, {
        attributes: true,
        childList: true,
        subtree: true,
      });
    });
    await page.goto(`${baseUrl}/navigation.html#2`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => document.documentElement.dataset.ssReady === "true", null, { timeout: 120_000 });
    const hasPdf = await page.locator(".ss-pdf").count() > 0;
    assert.equal(await page.evaluate(() => globalThis.__prematureBodyVisibility), false,
      "standalone HTML exposed unstyled content before its resources were ready");
    await expectActivePage(page, 2);
    await expectPageFitsViewport(page);
    await expectHiddenPdfDeferred(page);
    assert.equal(await page.evaluate(() => typeof globalThis.ssDocument?.prepareForPrint), "function",
      "standalone HTML did not expose explicit print preparation");
    await page.evaluate(() => globalThis.ssDocument.prepareForPrint());
    assert.equal(await page.locator("html").getAttribute("data-ss-print-layout"), "true",
      "print preparation did not expose every page at its print geometry");
    await expectVisiblePdfRendered(page);
    await page.evaluate(() => globalThis.ssDocument.finishPrint());
    assert.equal(await page.locator("html").getAttribute("data-ss-print-layout"), null,
      "print preparation left the document in print layout");
    const printPdf = page.locator('.ss-page[data-ss-page-index="3"] .ss-pdf');
    if (await printPdf.count() > 0) {
      assert.equal(await printPdf.getAttribute("data-ss-pdf-rendered"), null,
        "print cleanup retained an offscreen PDF canvas");
    }
    await expectActivePage(page, 2);

    await page.keyboard.press("ArrowRight");
    await expectActivePage(page, 3);
    await expectVisiblePdfRendered(page);
    assert.equal(await page.evaluate(() => globalThis.__pdfWorkerCount), hasPdf ? 1 : 0,
      hasPdf
        ? "standalone HTML did not create one native PDF worker"
        : "PDF-free standalone HTML created an unnecessary worker");
    assert.equal(new URL(page.url()).hash, "#3", "right arrow did not update the page fragment");

    await page.keyboard.press("ArrowLeft");
    await expectActivePage(page, 2);
    await page.goBack({ waitUntil: "networkidle" });
    await expectActivePage(page, 3);
    await page.goForward({ waitUntil: "networkidle" });
    await expectActivePage(page, 2);

    await page.keyboard.press("ArrowDown");
    await expectActivePage(page, 3);
    await page.keyboard.press("ArrowUp");
    await expectActivePage(page, 2);

    await page.setViewportSize({ width: 900, height: 900 });
    await expectPageFitsViewport(page);

    await page.emulateMedia({ media: "print" });
    const displays = await page.locator(".ss-page").evaluateAll((pages) => pages.map((item) => getComputedStyle(item).display));
    assert.deepEqual(displays, ["block", "block", "block"], "print media did not expose every page");
    assert.deepEqual(runtimeErrors, [], "standalone HTML emitted browser errors");
  } finally {
    await page.close();
  }
}

async function expectActivePage(page, pageNumber) {
  await page.waitForFunction((expected) => {
    const pages = [...document.querySelectorAll(".ss-page")];
    return pages.every((item, index) => item.dataset.ssActive === String(index + 1 === expected));
  }, pageNumber);
  const active = page.locator('.ss-page[data-ss-active="true"]');
  assert.equal(await active.count(), 1, "standalone HTML did not expose exactly one page");
  assert.equal(await active.getAttribute("data-ss-page-index"), String(pageNumber));
}

async function expectPageFitsViewport(page) {
  await page.waitForFunction(() => {
    const item = document.querySelector('.ss-page[data-ss-active="true"]');
    if (!item) return false;
    const rect = item.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0 &&
      rect.width <= innerWidth + 0.5 && rect.height <= innerHeight + 0.5 &&
      (Math.abs(rect.width - innerWidth) <= 0.5 || Math.abs(rect.height - innerHeight) <= 0.5);
  });
}

async function expectHiddenPdfDeferred(page) {
  const container = page.locator('.ss-page[data-ss-page-index="3"] .ss-pdf');
  if (await container.count() === 0) return;
  assert.equal(await container.getAttribute("data-canvas-background"), "transparent");
  assert.equal(await page.evaluate(() => globalThis.__pdfBlobCount), 0, "hidden PDF bytes were decoded before navigation");
  assert.equal(await page.evaluate(() => globalThis.__pdfWorkerCount), 0, "hidden PDF created a worker before navigation");
  assert.equal(await container.getAttribute("data-ss-pdf-rendered"), null, "hidden PDF rendered before navigation");
  assert.equal(await container.locator(".textLayer").count(), 0, "hidden PDF created a text layer before navigation");
}

async function expectVisiblePdfRendered(page) {
  const container = page.locator('.ss-page[data-ss-page-index="3"] .ss-pdf');
  if (await container.count() === 0) return;
  await page.waitForFunction(() => {
    const item = document.querySelector('.ss-page[data-ss-page-index="3"] .ss-pdf');
    return item?.dataset.ssPdfRendered === "true" || Boolean(item?.dataset.error);
  });
  const error = await container.getAttribute("data-error");
  assert.equal(error, null, "visible PDF page failed to render: " + error);
  assert.equal(await page.evaluate(() => globalThis.__pdfBlobCount), 1, "visible PDF bytes were decoded more than once");
  const text = await container.locator(".textLayer").textContent();
  assert(text?.includes("SelectablePdfToken"), "visible PDF page omitted its text layer: " + JSON.stringify(text));
}

async function runStandalone() {
  const output = path.join(repository, ".ss-cache/render-navigation");
  const driverArgument = process.argv.slice(2).find((argument) => !argument.startsWith("--"));
  const driver = path.resolve(repository, driverArgument ?? "zig-out/bin/ss-render-parity-driver");
  await rm(output, { recursive: true, force: true });
  const fixture = path.join(output, "fixture");
  await mkdir(fixture, { recursive: true });
  await writeFile(path.join(fixture, "asset.pdf"), pdfAsset());
  await writeFile(path.join(fixture, "slide.ss"), navigationFixture());
  await exec(driver, [
    path.join(fixture, "slide.ss"),
    path.join(output, "navigation.pdf"),
    path.join(output, "navigation.html"),
  ], { cwd: repository, timeout: 180_000, maxBuffer: 8 * 1024 * 1024 });
  await withBrowser(output, async (browser, baseUrl) => {
    await inspectStandaloneNavigation(browser, baseUrl);
    const fileRoot = pathToFileURL(output).href.replace(/\/$/, "");
    await inspectStandaloneNavigation(browser, fileRoot);
  });
}

function navigationFixture() {
  return `import std:themes/default as *

page first
let title = h1!("First page")
~ title.left == page.left + 96
~ title.top == page.top - 72
end

page second
let title = h1!("Second page")
~ title.left == page.left + 96
~ title.top == page.top - 72
end

page third
let picture = scale(pdf_obj("asset.pdf"), 0.72)
picture.asset.pdf_page = 2
picture.asset.pdf_box = PdfPageBox.crop
picture.chrome.fill = none
picture.chrome.stroke = none
picture.chrome.line_width = 0
place!(picture)
~ picture.left == page.left + 312
~ picture.top == page.top - 168
end
`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  await runStandalone();
}
