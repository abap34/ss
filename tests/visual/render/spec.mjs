#!/usr/bin/env node
import assert from "node:assert/strict";
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { PNG } from "pngjs";
import { pdfAsset, rasterAsset } from "./assets.mjs";
import { captureHtmlPages, capturePdfPages, preparePdfViewer, withBrowser } from "./capture.mjs";
import { compareImages, decodePng, defaultThresholds, encodePng } from "./compare.mjs";

const exec = promisify(execFile);
const testRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const repository = path.resolve(testRoot, "../..");
const output = path.join(repository, ".ss-cache/render-parity");
const driver = path.resolve(repository, process.argv.slice(2).find((argument) => !argument.startsWith("--")) ?? "zig-out/bin/ss-render-parity-driver");
const full = process.argv.includes("--full");
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await preparePdfViewer(output, repository);

const fixtures = [
  { name: "basic", source: path.join(repository, "tests/fixtures/project-basic/slide.ss") },
  { name: "fonts", source: path.join(repository, "tests/fixtures/render/parity/text/fonts.ss") },
  { name: "geometry", source: path.join(repository, "tests/fixtures/render/parity/geometry/slide.ss") },
  { name: "images", source: await prepareGeneratedFixture("images", "asset.png", rasterAsset()) },
];
if (full) {
  fixtures.push({ name: "vector", source: path.join(repository, "tests/fixtures/render/parity/vector/slide.ss") });
  fixtures.push({ name: "pdf", source: await prepareGeneratedFixture("pdf", "asset.pdf", pdfAsset()) });
  fixtures.push({ name: "semantics", source: path.join(repository, "tests/fixtures/render/parity/semantics/slide.ss") });
  fixtures.push({ name: "math", source: path.join(repository, "tests/fixtures/render/math.ss") });
  fixtures.push({ name: "markdown-math", source: path.join(repository, "tests/fixtures/render/parity/math/markdown.ss") });
}

for (const fixture of fixtures) {
  await run(driver, [fixture.source, path.join(output, `${fixture.name}.pdf`), path.join(output, `${fixture.name}-html`)]);
}

let failed = false;
await withBrowser(output, async (browser, baseUrl) => {
  for (const fixture of fixtures) {
    const pdf = await capturePdfPages(browser, baseUrl, `${fixture.name}.pdf`);
    const html = await captureHtmlPages(browser, baseUrl, `${fixture.name}-html`);
    assert.equal(html.length, pdf.length, `${fixture.name}: PDF and HTML page counts differ`);
    for (let index = 0; index < pdf.length; index += 1) {
      const expected = decodePng(pdf[index]);
      const actual = decodePng(html[index].image);
      const result = compareImages(expected, actual);
      await writeFile(path.join(output, `${fixture.name}-${index + 1}-pdf.png`), pdf[index]);
      await writeFile(path.join(output, `${fixture.name}-${index + 1}-html.png`), html[index].image);
      if (result.diff) await writeFile(path.join(output, `${fixture.name}-${index + 1}-diff.png`), encodePng(result.diff));
      process.stdout.write(`${fixture.name} page ${index + 1}: MAE=${result.meanAbsoluteError ?? "dimension mismatch"}, large=${result.largeDifferenceRatio ?? "dimension mismatch"}\n`);
      failed ||= !result.pass;
      for (const region of html[index].items) {
        const expectedItem = cropRegion(expected, region, 2);
        const actualItem = cropRegion(actual, region, 2);
        if (!expectedItem || !actualItem) continue;
        const itemResult = compareImages(expectedItem, actualItem, itemThresholds(region.kind));
        if (!itemResult.pass) {
          process.stdout.write(`${fixture.name} page ${index + 1} item ${region.id}: MAE=${itemResult.meanAbsoluteError ?? "dimension mismatch"}, large=${itemResult.largeDifferenceRatio ?? "dimension mismatch"}\n`);
        }
        failed ||= !itemResult.pass;
      }
    }
  }

  if (full) {
    await inspectNormalHtml(browser, baseUrl);
    await inspectEmbeddedPdf(browser, baseUrl);
    await inspectStructuredMath(browser, baseUrl);
  }

  const baselinePath = process.env.SS_RENDER_BASELINE_PDF;
  if (baselinePath) {
    await cp(path.resolve(baselinePath), path.join(output, "baseline.pdf"));
    const baseline = await capturePdfPages(browser, baseUrl, "baseline.pdf");
    const current = await capturePdfPages(browser, baseUrl, "basic.pdf");
    assert.equal(baseline.length, current.length, "baseline and current PDF page counts differ");
    for (let index = 0; index < current.length; index += 1) {
      const result = compareImages(decodePng(baseline[index]), decodePng(current[index]));
      process.stdout.write(`PDF regression page ${index + 1}: MAE=${result.meanAbsoluteError ?? "dimension mismatch"}, large=${result.largeDifferenceRatio ?? "dimension mismatch"}\n`);
      failed ||= !result.pass;
    }
  }
});

function cropRegion(source, region, padding) {
  const x = Math.max(0, region.x - padding);
  const y = Math.max(0, region.y - padding);
  const right = Math.min(source.width, region.right + padding);
  const bottom = Math.min(source.height, region.bottom + padding);
  const width = right - x;
  const height = bottom - y;
  if (width <= 0 || height <= 0) return null;
  const result = new PNG({ width, height });
  PNG.bitblt(source, result, x, y, width, height, 0, 0);
  return result;
}

function itemThresholds(kind) {
  if (kind === "line") {
    return {
      ...defaultThresholds,
      meanAbsoluteError: 0.012,
      largeDifferenceRatio: 0.06,
      spatialTolerance: 1,
    };
  }
  if (kind === "math") {
    return {
      ...defaultThresholds,
      meanAbsoluteError: 0.005,
      largeDifferenceRatio: 0.025,
      spatialTolerance: 1,
    };
  }
  if (kind === "pdf") {
    return {
      ...defaultThresholds,
      meanAbsoluteError: 0.005,
      largeDifferenceRatio: 0.05,
      spatialTolerance: 1,
    };
  }
  return {
    ...defaultThresholds,
    meanAbsoluteError: 0.004,
    largeDifferenceRatio: 0.025,
    spatialTolerance: 1,
  };
}

async function inspectNormalHtml(browser, baseUrl) {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1200 } });
  try {
    await page.goto(`${baseUrl}/semantics-html/index.html`, { waitUntil: "networkidle" });
    await page.evaluate(() => document.fonts.ready);
    const visibleText = await page.locator(".ss-text").allTextContents();
    assert(
      visibleText.some((value) => value.includes("SelectableTextToken")),
      `normal HTML text was not present in selectable elements: ${JSON.stringify(visibleText)}`,
    );
    const selected = await page.locator(".ss-text", { hasText: "SelectableTextToken" }).first().evaluate((element) => {
      const selection = getSelection();
      selection.removeAllRanges();
      const range = document.createRange();
      range.selectNodeContents(element);
      selection.addRange(range);
      return selection.toString();
    });
    assert(selected.includes("SelectableTextToken"), `normal HTML selection lost text: ${JSON.stringify(selected)}`);
    assert.equal(
      await page.locator('.ss-semantic-layer a[href="https://example.com/semantic"]').count(),
      1,
      "semantic HTML link was not preserved",
    );
    assert.equal(await page.locator(".ss-semantic-layer ol li").count(), 2, "ordered-list semantics were not preserved");
    assert.equal(await page.locator(".ss-semantic-layer table").count(), 1, "table semantics were not preserved");
    const coordinateError = await page.locator(".ss-page").evaluate((pageElement) => {
      const pageRect = pageElement.getBoundingClientRect();
      const width = Number.parseFloat(pageElement.style.width);
      const scale = pageRect.width / width;
      let maximum = Math.max(
        Math.abs(pageRect.width / scale - width),
        Math.abs(pageRect.height / scale - Number.parseFloat(pageElement.style.height)),
      );
      for (const item of pageElement.querySelectorAll(":scope > .ss-item")) {
        if (getComputedStyle(item).transform !== "none") continue;
        const rect = item.getBoundingClientRect();
        const expectedLeft = Number.parseFloat(item.style.left);
        const expectedTop = Number.parseFloat(item.style.top);
        if (Number.isFinite(expectedLeft)) maximum = Math.max(maximum, Math.abs((rect.left - pageRect.left) / scale - expectedLeft));
        if (Number.isFinite(expectedTop)) maximum = Math.max(maximum, Math.abs((rect.top - pageRect.top) / scale - expectedTop));
      }
      return maximum;
    });
    assert(coordinateError <= 0.01, `DOM coordinates differ from render IR styles by ${coordinateError} pt`);
  } finally {
    await page.close();
  }
}

async function inspectEmbeddedPdf(browser, baseUrl) {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1200 } });
  try {
    await page.goto(`${baseUrl}/pdf-html/index.html`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => document.documentElement.dataset.ssReady === "true", null, { timeout: 120_000 });
    const container = page.locator(".ss-pdf");
    assert.equal(await container.getAttribute("data-page"), "2", "HTML selected the wrong PDF source page");
    const textLayer = container.locator(".textLayer");
    const text = await textLayer.textContent();
    assert(text?.includes("SelectablePdfToken"), `PDF.js text layer omitted source text: ${JSON.stringify(text)}`);
    const selected = await textLayer.evaluate((element) => {
      const selection = getSelection();
      selection.removeAllRanges();
      const range = document.createRange();
      range.selectNodeContents(element);
      selection.addRange(range);
      return selection.toString();
    });
    assert(selected.includes("SelectablePdfToken"), `PDF.js text selection lost source text: ${JSON.stringify(selected)}`);
    const link = container.locator('.annotationLayer a[href="https://example.com/pdf"]');
    assert.equal(await link.count(), 1, "PDF.js annotation layer omitted the URI link");
  } finally {
    await page.close();
  }
}

async function inspectStructuredMath(browser, baseUrl) {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1200 } });
  try {
    await page.goto(`${baseUrl}/markdown-math-html/index.html`, { waitUntil: "networkidle" });
    await page.evaluate(() => document.fonts.ready);
    assert(await page.locator(".ss-math-text").count() > 0, "structured mathematics omitted its selectable HTML text layer");
    assert(await page.locator(".ss-semantic-layer math.ss-mathml").count() >= 2, "structured mathematics omitted MathML semantics");
    assert.equal(await page.locator(".ss-math svg").count(), 0, "structured mathematics used an SVG display fallback");
    assert.equal(await page.locator(".ss-math.ss-pdf").count(), 0, "structured mathematics used a PDF display fallback");
  } finally {
    await page.close();
  }
}

async function prepareGeneratedFixture(name, assetName, assetBytes) {
  const directory = path.join(output, "fixture-projects", name);
  await mkdir(directory, { recursive: true });
  await cp(
    path.join(repository, `tests/fixtures/render/parity/${name}/slide.ss`),
    path.join(directory, "slide.ss"),
  );
  await writeFile(path.join(directory, assetName), assetBytes);
  return path.join(directory, "slide.ss");
}

if (failed) throw new Error(`rendering parity exceeded thresholds; inspect ${output}`);

async function run(file, args) {
  await exec(file, args, { cwd: repository, timeout: 180_000, maxBuffer: 8 * 1024 * 1024 });
}
