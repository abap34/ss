#!/usr/bin/env node
import assert from "node:assert/strict";
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { PNG } from "pngjs";
import { captureHtmlPages, capturePdfPages, preparePdfViewer, withBrowser } from "./capture.mjs";
import { compareImages, decodePng, defaultThresholds, encodePng } from "./compare.mjs";

const exec = promisify(execFile);
const testRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const repository = path.resolve(testRoot, "../..");
const output = path.join(repository, ".ss-cache/render-parity");
const driver = path.resolve(repository, process.argv.slice(2).find((argument) => !argument.startsWith("--")) ?? "zig-out/bin/ss-render-parity-driver");
const full = process.argv.includes("--full");
const fixtures = [
  { name: "basic", source: path.join(repository, "tests/fixtures/project-basic/slide.ss") },
  { name: "fonts", source: path.join(repository, "tests/fixtures/render/parity/text/fonts.ss") },
];
if (full) {
  fixtures.push({ name: "math", source: path.join(repository, "tests/fixtures/render/math.ss") });
  fixtures.push({ name: "markdown-math", source: path.join(repository, "tests/fixtures/render/parity/math/markdown.ss") });
}

await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await preparePdfViewer(output, repository);

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
  return {
    ...defaultThresholds,
    meanAbsoluteError: 0.004,
    largeDifferenceRatio: 0.025,
    spatialTolerance: 1,
  };
}

if (failed) throw new Error(`rendering parity exceeded thresholds; inspect ${output}`);

async function run(file, args) {
  await exec(file, args, { cwd: repository, timeout: 180_000, maxBuffer: 8 * 1024 * 1024 });
}
