#!/usr/bin/env node
import assert from "node:assert/strict";
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { captureHtmlPages, capturePdfPages, withBrowser } from "./capture.mjs";
import { compareImages, decodePng, encodePng } from "./compare.mjs";

const exec = promisify(execFile);
const testRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const repository = path.resolve(testRoot, "../..");
const output = path.join(repository, ".ss-cache/render-parity");
const executable = path.resolve(repository, process.argv.slice(2).find((argument) => !argument.startsWith("--")) ?? "zig-out/bin/ss");
const full = process.argv.includes("--full");
const fixtures = [{ name: "basic", source: path.join(repository, "tests/fixtures/project-basic/slide.ss") }];
if (full && await commandAvailable("pdflatex")) {
  fixtures.push({ name: "math", source: path.join(repository, "tests/fixtures/render/math.ss") });
}

await rm(output, { recursive: true, force: true });
await mkdir(path.join(output, "pdfjs"), { recursive: true });
await cp(path.join(repository, "third_party/pdfjs/pdf.mjs"), path.join(output, "pdfjs/pdf.mjs"));
await cp(path.join(repository, "third_party/pdfjs/pdf.worker.mjs"), path.join(output, "pdfjs/pdf.worker.mjs"));
await writeFile(path.join(output, "pdf-viewer.html"), pdfViewerHtml(), "utf8");

for (const fixture of fixtures) {
  await run(executable, ["render", "--output", path.join(output, `${fixture.name}.pdf`), fixture.source, "--quiet"]);
  await run(executable, ["render", "--format", "html", "--output", path.join(output, `${fixture.name}-html`), fixture.source, "--quiet"]);
}

let failed = false;
await withBrowser(output, async (browser, baseUrl) => {
  for (const fixture of fixtures) {
    const pdf = await capturePdfPages(browser, baseUrl, `${fixture.name}.pdf`);
    const html = await captureHtmlPages(browser, baseUrl, `${fixture.name}-html`);
    assert.equal(html.length, pdf.length, `${fixture.name}: PDF and HTML page counts differ`);
    for (let index = 0; index < pdf.length; index += 1) {
      const expected = decodePng(pdf[index]);
      const actual = decodePng(html[index]);
      const result = compareImages(expected, actual);
      await writeFile(path.join(output, `${fixture.name}-${index + 1}-pdf.png`), pdf[index]);
      await writeFile(path.join(output, `${fixture.name}-${index + 1}-html.png`), html[index]);
      if (result.diff) await writeFile(path.join(output, `${fixture.name}-${index + 1}-diff.png`), encodePng(result.diff));
      process.stdout.write(`${fixture.name} page ${index + 1}: MAE=${result.meanAbsoluteError ?? "dimension mismatch"}, large=${result.largeDifferenceRatio ?? "dimension mismatch"}\n`);
      failed ||= !result.pass;
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

if (full && !fixtures.some((fixture) => fixture.name === "math")) {
  process.stdout.write("math parity skipped because pdflatex is unavailable\n");
}
if (failed) throw new Error(`rendering parity exceeded thresholds; inspect ${output}`);

async function run(file, args) {
  await exec(file, args, { cwd: repository, timeout: 180_000, maxBuffer: 8 * 1024 * 1024 });
}

async function commandAvailable(file) {
  try {
    await exec(file, ["--version"], { cwd: repository, timeout: 10_000, maxBuffer: 1024 * 1024 });
    return true;
  } catch (error) {
    return error?.code !== "ENOENT" ? Promise.reject(error) : false;
  }
}

function pdfViewerHtml() {
  return `<!doctype html>
<meta charset="utf-8">
<style>html,body{margin:0}canvas{display:block}</style>
<main></main>
<script type="module">
import * as pdfjs from "./pdfjs/pdf.mjs";
try {
  pdfjs.GlobalWorkerOptions.workerSrc = "./pdfjs/pdf.worker.mjs";
  const source = new URL(location.href).searchParams.get("source");
  const pdf = await pdfjs.getDocument({url:source,isEvalSupported:false}).promise;
  for (let index=1;index<=pdf.numPages;index++) {
    const page = await pdf.getPage(index);
    const viewport = page.getViewport({scale:2});
    const canvas = document.createElement("canvas");
    canvas.width = Math.floor(viewport.width);
    canvas.height = Math.floor(viewport.height);
    document.querySelector("main").append(canvas);
    await page.render({canvasContext:canvas.getContext("2d"),viewport}).promise;
  }
} catch (error) {
  globalThis.ssPdfError = error instanceof Error ? error.stack : String(error);
} finally {
  globalThis.ssPdfReady = true;
}
</script>`;
}
