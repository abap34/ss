#!/usr/bin/env node
import assert from "node:assert/strict";
import { cp, mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { PNG } from "pngjs";
import { pdfAsset, rasterAsset } from "./assets.mjs";
import { captureHtmlPages, capturePdfPages, maximumTextBaselineError, preparePdfViewer, withBrowser } from "./capture.mjs";
import { compareImages, decodePng, defaultThresholds, encodePng } from "./compare.mjs";
import { inspectStandaloneNavigation } from "./navigation/spec.mjs";

const exec = promisify(execFile);
const testRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const repository = path.resolve(testRoot, "../..");
const output = path.join(repository, ".ss-cache/render-parity");
const driver = path.resolve(repository, process.argv.slice(2).find((argument) => !argument.startsWith("--")) ?? "zig-out/bin/ss-render-parity-driver");
const full = process.argv.includes("--full");
const textBaselineTolerance = 0.03;
const pdfViewerThresholds = Object.freeze({
  ...defaultThresholds,
  largeDifferenceRatio: 0.006,
  spatialTolerance: 1,
});
const largeGlyphThresholds = Object.freeze({
  ...defaultThresholds,
  spatialTolerance: 1,
});
const largeGlyphItemThresholds = Object.freeze({
  meanAbsoluteError: 0.014,
  largeDifferenceRatio: 0.045,
  spatialTolerance: 1,
});
const canRenderLatex = full && await commandSucceeds("pdflatex", ["--version"]);
const canRenderAlgorithm2e = canRenderLatex &&
  await commandSucceeds("kpsewhich", ["algorithm2e.sty"]);
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await preparePdfViewer(output, repository);

const fixtures = [
  { name: "basic", source: path.join(repository, "tests/fixtures/project-basic/slide.ss") },
  { name: "fonts", source: path.join(repository, "tests/fixtures/render/parity/text/fonts.ss") },
  {
    name: "large-glyphs",
    source: path.join(repository, "tests/fixtures/render/parity/text/large/slide.ss"),
    pageThresholds: largeGlyphThresholds,
    itemThresholds: largeGlyphItemThresholds,
  },
  { name: "markdown-headings", source: path.join(repository, "tests/fixtures/render/parity/text/headings/slide.ss") },
  { name: "geometry", source: path.join(repository, "tests/fixtures/render/parity/geometry/slide.ss") },
  { name: "images", source: await prepareGeneratedFixture("images", "asset.png", rasterAsset()) },
  { name: "navigation", source: path.join(repository, "tests/fixtures/render/parity/navigation/slide.ss") },
];
if (full) {
  fixtures.push({ name: "vector", source: path.join(repository, "tests/fixtures/render/parity/vector/slide.ss") });
  fixtures.push({ name: "pdf", source: await prepareGeneratedFixture("pdf", "asset.pdf", pdfAsset()) });
  fixtures.push({ name: "semantics", source: path.join(repository, "tests/fixtures/render/parity/semantics/slide.ss") });
  if (canRenderLatex) {
    fixtures.push({ name: "math", source: path.join(repository, "tests/fixtures/render/math.ss") });
    fixtures.push({ name: "markdown-math", source: path.join(repository, "tests/fixtures/render/parity/math/markdown.ss") });
    fixtures.push({ name: "math-fallback", source: path.join(repository, "tests/fixtures/render/parity/math/fallback/slide.ss") });
  }
  if (canRenderAlgorithm2e) {
    fixtures.push({ name: "algorithm2e", source: path.join(repository, "tests/fixtures/render/parity/math/algorithm2e/slide.ss") });
  }
}

for (const fixture of fixtures) {
  await run(driver, [fixture.source, path.join(output, `${fixture.name}.pdf`), path.join(output, `${fixture.name}.html`)]);
}

let failed = false;
await withBrowser(output, async (browser, baseUrl) => {
  for (const fixture of fixtures) {
    const pdf = await capturePdfPages(browser, baseUrl, `${fixture.name}.pdf`);
    const html = await captureHtmlPages(browser, baseUrl, `${fixture.name}.html`);
    assert.equal(html.length, pdf.length, `${fixture.name}: PDF and HTML page counts differ`);
    for (let index = 0; index < pdf.length; index += 1) {
      assert(
        html[index].textBaselineError <= textBaselineTolerance,
        `${fixture.name} page ${index + 1}: browser text baseline differs from render IR by ${html[index].textBaselineError} pt`,
      );
      const expected = decodePng(pdf[index]);
      const actual = decodePng(html[index].image);
      const hasPdfViewer = html[index].items.some((item) => item.usesPdfViewer);
      const result = compareImages(expected, actual, hasPdfViewer
        ? pdfViewerThresholds
        : fixture.pageThresholds ?? defaultThresholds);
      await writeFile(path.join(output, `${fixture.name}-${index + 1}-pdf.png`), pdf[index]);
      await writeFile(path.join(output, `${fixture.name}-${index + 1}-html.png`), html[index].image);
      if (result.diff) await writeFile(path.join(output, `${fixture.name}-${index + 1}-diff.png`), encodePng(result.diff));
      process.stdout.write(`${fixture.name} page ${index + 1}: MAE=${result.meanAbsoluteError ?? "dimension mismatch"}, large=${result.largeDifferenceRatio ?? "dimension mismatch"}\n`);
      failed ||= !result.pass;
      for (const region of html[index].items) {
        // Thin rules and small PDF.js canvases need enough surrounding pixels for
        // their normalized error to describe page placement instead of glyph area.
        const padding = region.kind === "line" || region.usesPdfViewer ? 20 : 2;
        const expectedItem = cropRegion(expected, region, padding);
        const actualItem = cropRegion(actual, region, padding);
        if (!expectedItem || !actualItem) continue;
        const itemResult = compareImages(
          expectedItem,
          actualItem,
          itemThresholds(region, region.kind === "line" ? undefined : fixture.itemThresholds),
        );
        if (!itemResult.pass) {
          process.stdout.write(`${fixture.name} page ${index + 1} item ${region.id}: MAE=${itemResult.meanAbsoluteError ?? "dimension mismatch"}, large=${itemResult.largeDifferenceRatio ?? "dimension mismatch"}\n`);
        }
        failed ||= !itemResult.pass;
      }
    }
  }

  await inspectStandaloneNavigation(browser, baseUrl);
  await inspectTextBaselineDetection(browser, baseUrl);
  await inspectMarkdownHeadingStyles(browser, baseUrl);

  if (full) {
    await inspectNormalHtml(browser, baseUrl);
    await inspectEmbeddedPdf(browser, baseUrl);
    if (canRenderLatex) await inspectMarkdownLatex(browser, baseUrl);
    if (canRenderAlgorithm2e) await inspectLatexBody(browser, baseUrl);
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

async function inspectMarkdownHeadingStyles(browser, baseUrl) {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1200 } });
  try {
    await page.goto(`${baseUrl}/markdown-headings.html`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => document.documentElement.dataset.ssReady === "true");
    const styles = await page.locator(".ss-text-run").evaluateAll((runs) => {
      const normalizeColor = (value) => {
        const probe = document.createElement("span");
        probe.style.color = value;
        document.body.append(probe);
        const result = getComputedStyle(probe).color;
        probe.remove();
        return result;
      };
      return {
        values: runs.map((run) => ({
          size: Number.parseFloat(run.style.fontSize),
          color: getComputedStyle(run).color,
        })),
        expectedColors: [
          normalizeColor("rgb(80% 10% 10%)"),
          normalizeColor("rgb(10% 60% 20%)"),
          normalizeColor("rgb(10% 20% 80%)"),
          normalizeColor("rgb(70% 10% 60%)"),
          normalizeColor("rgb(10% 60% 70%)"),
          normalizeColor("rgb(80% 40% 10%)"),
        ],
      };
    });
    for (const size of [44, 36, 28, 24, 20, 18]) {
      assert(styles.values.some((value) => Math.abs(value.size - size) <= 0.001),
        `markdown heading did not render at ${size} pt`);
    }
    for (const color of styles.expectedColors) {
      assert(styles.values.some((value) => value.color === color),
        `markdown heading did not render with ${color}`);
    }
  } finally {
    await page.close();
  }
}

async function inspectTextBaselineDetection(browser, baseUrl) {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1200 } });
  try {
    await page.goto(`${baseUrl}/large-glyphs.html#1`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => document.documentElement.dataset.ssReady === "true");
    const active = page.locator('.ss-page[data-ss-active="true"]');
    assert(await maximumTextBaselineError(active) <= textBaselineTolerance, "unaltered text baseline failed its geometry check");
    await active.locator(".ss-text-run[data-ss-baseline-y]").first().evaluate((run) => {
      run.style.transform = "translateY(0.5pt)";
    });
    assert(
      await maximumTextBaselineError(active) >= 0.49,
      "text baseline geometry check did not detect a 0.5 pt vertical shift",
    );
  } finally {
    await page.close();
  }
}

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

function itemThresholds(item, overrides) {
  let thresholds;
  if (item.kind === "line") {
    thresholds = {
      ...defaultThresholds,
      meanAbsoluteError: 0.012,
      largeDifferenceRatio: 0.06,
      spatialTolerance: 1,
    };
  } else if (item.kind === "latex") {
    thresholds = {
      ...defaultThresholds,
      meanAbsoluteError: 0.007,
      largeDifferenceRatio: 0.06,
      spatialTolerance: 1,
    };
  } else if (item.usesPdfViewer) {
    thresholds = {
      ...defaultThresholds,
      meanAbsoluteError: 0.0045,
      largeDifferenceRatio: 0.045,
      spatialTolerance: 1,
    };
  } else {
    thresholds = {
      ...defaultThresholds,
      meanAbsoluteError: 0.004,
      largeDifferenceRatio: 0.04,
      spatialTolerance: 1,
    };
  }
  return overrides ? { ...thresholds, ...overrides } : thresholds;
}

async function inspectNormalHtml(browser, baseUrl) {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1200 } });
  try {
    await page.goto(`${baseUrl}/semantics.html`, { waitUntil: "networkidle" });
    await page.evaluate(() => document.fonts.ready);
    const visibleText = await page.locator(".ss-text").allTextContents();
    assert(
      visibleText.some((value) => value.includes("SelectableTextToken")),
      `normal HTML text was not present in selectable elements: ${JSON.stringify(visibleText)}`,
    );
    const selected = await selectedText(page.locator(".ss-text", { hasText: "SelectableTextToken" }).first());
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
    await page.goto(`${baseUrl}/pdf.html`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => document.documentElement.dataset.ssReady === "true", null, { timeout: 120_000 });
    const container = page.locator('.ss-page[data-ss-page-index="1"] .ss-pdf');
    assert.equal(await container.getAttribute("data-page"), "2", "HTML selected the wrong PDF source page");
    const textLayer = container.locator(".textLayer");
    const text = await textLayer.textContent();
    assert(text?.includes("SelectablePdfToken"), `PDF.js text layer omitted source text: ${JSON.stringify(text)}`);
    const textBounds = await textLayer.boundingBox();
    assert(textBounds && textBounds.width > 0 && textBounds.height > 0,
      "PDF.js text layer had no pointer-selectable area");
    const textSpan = textLayer.locator("span:not(.markedContent)", { hasText: "SelectablePdfToken" }).first();
    const textSpanBounds = await textSpan.boundingBox();
    assert(textSpanBounds && textSpanBounds.width > 0 && textSpanBounds.height > 0,
      "PDF.js selectable text had no rendered area");
    const selected = await selectedText(textLayer);
    assert(selected.includes("SelectablePdfToken"), `PDF.js text selection lost source text: ${JSON.stringify(selected)}`);
    const dragSpan = textLayer.locator("span:not(.markedContent)", {
      hasText: "DragSelectablePdfToken",
    }).first();
    const dragged = await dragSelectedText(page, dragSpan);
    assert(dragged.includes("DragSelectablePdfToken"),
      `pointer drag could not select PDF text: ${JSON.stringify(dragged)}`);
    const link = container.locator('.annotationLayer a[href="https://example.com/pdf"]');
    assert.equal(await link.count(), 1, "PDF.js annotation layer omitted the URI link");
    assert.equal(await container.locator(".annotationLayer a").count(), 1,
      "PDF.js exposed an internal destination that the HTML document cannot resolve");
    const linkBounds = await link.boundingBox();
    assert(linkBounds && linkBounds.width > 0 && linkBounds.height > 0,
      "PDF.js annotation link had no clickable area");
    const linkGeometry = await link.evaluate((element) => {
      const item = element.closest(".ss-pdf");
      const itemBounds = item.getBoundingClientRect();
      const bounds = element.getBoundingClientRect();
      return {
        left: (bounds.left - itemBounds.left) / itemBounds.width,
        top: (bounds.top - itemBounds.top) / itemBounds.height,
        width: bounds.width / itemBounds.width,
        height: bounds.height / itemBounds.height,
        rotation: getComputedStyle(element.closest(".annotationLayer")).transform,
        hiddenAncestor: element.closest('[aria-hidden="true"]')?.className ?? null,
      };
    });
    assertNormalizedGeometry(linkGeometry, { left: 0.56, top: 0.01, width: 0.28, height: 0.95 });
    assert.notEqual(linkGeometry.rotation, "none", "PDF.js annotation layer ignored the source page rotation");
    assert.equal(linkGeometry.hiddenAncestor, null, "copied PDF annotation was hidden from assistive technology");
    assert.equal(await link.getAttribute("aria-label"), "https://example.com/pdf",
      "copied PDF annotation had no accessible name");
    assert.equal(await link.locator("xpath=parent::section").getAttribute("tabindex"), null,
      "copied PDF annotation created a duplicate keyboard stop");
    assert(await link.evaluate((element) => element.tabIndex >= 0),
      "copied PDF annotation was not reachable with keyboard navigation");
    await page.evaluate(() => {
      window.__ssPdfLinkClicked = false;
      document.addEventListener("click", (event) => {
        if (!(event.target instanceof Element) || !event.target.closest(".annotationLayer")) return;
        event.preventDefault();
        window.__ssPdfLinkClicked = true;
      }, { capture: true, once: true });
    });
    await link.focus();
    assert(await link.evaluate((element) => document.activeElement === element),
      "copied PDF annotation was not keyboard-focusable");
    await link.click();
    assert(await page.evaluate(() => window.__ssPdfLinkClicked),
      "PDF.js annotation did not receive a pointer click at its rendered location");

    await page.evaluate(() => {
      location.hash = "2";
    });
    await page.waitForFunction(() =>
      document.querySelector('.ss-page[data-ss-page-index="2"]')?.dataset.ssActive === "true"
    );
    const mediaContainer = page.locator('.ss-page[data-ss-page-index="2"] .ss-pdf');
    await page.waitForFunction(() =>
      document.querySelector('.ss-page[data-ss-page-index="2"] .ss-pdf')?.dataset.ssPdfRendered === "true"
    );
    const paintedOutsideCropBox = await mediaContainer.locator(":scope > canvas").evaluate((canvas) => {
      const context = canvas.getContext("2d");
      if (!context || canvas.width <= 0 || canvas.height <= 0) return null;
      const width = Math.max(1, Math.ceil(canvas.width * 0.1));
      const pixels = context.getImageData(0, 0, width, canvas.height).data;
      let count = 0;
      let minX = width;
      let minY = canvas.height;
      let maxX = -1;
      let maxY = -1;
      for (let index = 0; index < pixels.length; index += 4) {
        if (pixels[index + 3] > 0 && pixels[index] < 160 &&
            pixels[index + 1] < 160 && pixels[index + 2] < 160) {
          const pixel = index / 4;
          const x = pixel % width;
          const y = Math.floor(pixel / width);
          count += 1;
          minX = Math.min(minX, x);
          minY = Math.min(minY, y);
          maxX = Math.max(maxX, x);
          maxY = Math.max(maxY, y);
        }
      }
      return { count, minX, minY, maxX, maxY, width, height: canvas.height };
    });
    assert(paintedOutsideCropBox && paintedOutsideCropBox.count >= 80 &&
      paintedOutsideCropBox.maxX - paintedOutsideCropBox.minX >= 5 &&
      paintedOutsideCropBox.maxY - paintedOutsideCropBox.minY >= 50,
    `PDF.js MediaBox rendering omitted or distorted source content outside the CropBox: ${JSON.stringify(paintedOutsideCropBox)}`);
  } finally {
    await page.close();
  }
}

function assertNormalizedGeometry(actual, expected) {
  for (const key of ["left", "top", "width", "height"]) {
    const error = Math.abs(actual[key] - expected[key]);
    assert(error <= 0.015,
      `PDF.js annotation ${key} differs from the rotated CropBox geometry: ${actual[key]} instead of ${expected[key]}`);
  }
}

async function inspectMarkdownLatex(browser, baseUrl) {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1200 } });
  try {
    await page.goto(`${baseUrl}/markdown-math.html`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => document.documentElement.dataset.ssReady === "true", null, { timeout: 120_000 });
    assert(await page.locator(".ss-latex.ss-pdf").count() >= 2, "Markdown mathematics omitted LaTeX PDF items");
    assert(await page.locator('.ss-semantic-layer .ss-latex-semantic[role="math"]').count() >= 2, "Markdown mathematics omitted semantic labels");
    assert.equal(await page.locator("math").count(), 0, "Markdown mathematics unexpectedly emitted MathML");
  } finally {
    await page.close();
  }
}

async function inspectLatexBody(browser, baseUrl) {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1200 } });
  try {
    await page.goto(`${baseUrl}/algorithm2e.html`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => document.documentElement.dataset.ssReady === "true", null, { timeout: 120_000 });
    const container = page.locator(".ss-latex.ss-pdf");
    assert.equal(await container.count(), 1, "LaTeX body did not use one scoped PDF.js viewer");
    assert.equal(await container.getAttribute("data-canvas-background"), "transparent", "LaTeX body did not request a transparent PDF canvas");
    assert.equal(await page.locator('object[type="application/pdf"]').count(), 0, "LaTeX body used a PDF object element");
    const cornerAlpha = await container.locator("canvas").evaluate((canvas) =>
      canvas.getContext("2d").getImageData(0, 0, 1, 1).data[3]);
    assert.equal(cornerAlpha, 0, "LaTeX PDF canvas painted an opaque background");
    const textLayer = container.locator(".textLayer");
    const text = await textLayer.textContent();
    const textBounds = await textLayer.boundingBox();
    assert(textBounds && textBounds.width > 0 && textBounds.height > 0,
      "LaTeX text layer had no pointer-selectable area");
    assert(text?.includes("SelectableAlgorithmInput"), `algorithm2e input text was not selectable: ${JSON.stringify(text)}`);
    assert(text?.includes("SelectableAlgorithmResult"), `algorithm2e result text was not selectable: ${JSON.stringify(text)}`);
    const selected = await selectedText(textLayer);
    assert(selected.includes("SelectableAlgorithmInput") && selected.includes("SelectableAlgorithmResult"),
      `algorithm2e selection lost text: ${JSON.stringify(selected)}`);
    const dragSpan = textLayer.locator("span:not(.markedContent)", {
      hasText: "SelectableAlgorithmInput",
    }).first();
    const dragged = await dragSelectedText(page, dragSpan);
    assert(dragged.includes("SelectableAlgorithmInput"),
      `pointer drag could not select LaTeX text: ${JSON.stringify(dragged)}`);
    assert.equal(await page.locator('.ss-semantic-layer [role="math"]').count(), 1, "LaTeX body omitted its math semantics");
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

async function selectedText(locator) {
  return await locator.evaluate((element) => {
    const selection = getSelection();
    selection.removeAllRanges();
    const range = document.createRange();
    range.selectNodeContents(element);
    selection.addRange(range);
    return selection.toString();
  });
}

async function dragSelectedText(page, locator) {
  const bounds = await locator.boundingBox();
  assert(bounds && bounds.width > 0 && bounds.height > 0,
    "selectable text had no pointer target");
  const horizontal = bounds.width >= bounds.height;
  const start = horizontal
    ? { x: bounds.x + 1, y: bounds.y + bounds.height / 2 }
    : { x: bounds.x + bounds.width / 2, y: bounds.y + 1 };
  const end = horizontal
    ? { x: bounds.x + bounds.width - 1, y: start.y }
    : { x: start.x, y: bounds.y + bounds.height - 1 };
  for (const [from, to] of [[start, end], [end, start]]) {
    await page.evaluate(() => getSelection()?.removeAllRanges());
    await page.mouse.move(from.x, from.y);
    await page.mouse.down();
    await page.mouse.move(to.x, to.y, { steps: 20 });
    await page.mouse.up();
    const selected = await page.evaluate(() => getSelection()?.toString() ?? "");
    if (selected) return selected;
  }
  return "";
}

if (failed) throw new Error(`rendering parity exceeded thresholds; inspect ${output}`);

async function run(file, args) {
  await exec(file, args, { cwd: repository, timeout: 180_000, maxBuffer: 8 * 1024 * 1024 });
}

async function commandSucceeds(file, args) {
  try {
    await exec(file, args, { cwd: repository, timeout: 10_000, maxBuffer: 1024 * 1024 });
    return true;
  } catch {
    return false;
  }
}
