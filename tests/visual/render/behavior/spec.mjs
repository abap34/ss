#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { capturePdfPages, preparePdfViewer, withBrowser } from "../capture.mjs";
import { decodePng } from "../compare.mjs";

const exec = promisify(execFile);
const testRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const repository = path.resolve(testRoot, "../..");
const ss = path.resolve(repository, process.argv[2] ?? "zig-out/bin/ss");
const output = path.join(repository, ".ss-cache/render-behavior");
const projects = path.join(output, "projects");
const hasPdflatex = await commandAvailable("pdflatex", ["--version"]);

await rm(output, { recursive: true, force: true });
await mkdir(projects, { recursive: true });
await preparePdfViewer(output, repository);

const mathPages = await renderMathCases();
await renderPdfAssetCases();
await renderOffPageCase();

await withBrowser(output, async (browser, baseUrl) => {
  await testMathGeometry(browser, baseUrl, mathPages);
  await testPdfAssetGeometry(browser, baseUrl);
  await testOffPageObject(browser, baseUrl);
});

async function renderMathCases() {
  const project = await createProject("math");
  const pages = {
    structuredOne: 0,
    structuredTwo: 1,
    rawWide: null,
    rawNarrow: null,
    globalNarrow: null,
    localWide: null,
  };
  let source = `import std:themes/default as *

${hasPdflatex ? `document
raw_tex_width_ratio_all(0.82)
end
` : ""}

page math_scale_one
let formula = math!("x + y = z", 1)
~ formula.left == page.left + 96
~ formula.right == page.right - 96
~ formula.top == page.top - 240
end

page math_scale_two
let formula = math!("x + y = z", 2)
~ formula.left == page.left + 96
~ formula.right == page.right - 96
~ formula.top == page.top - 240
end
`;
  if (hasPdflatex) {
    pages.rawWide = 2;
    pages.rawNarrow = 3;
    pages.globalNarrow = 4;
    pages.localWide = 5;
    source += `
page tex_scale_one
let formula = tex!("x + y = z", 1)
formula.math.raw_tex_width_ratio = 1
~ formula.left == page.left + 96
~ formula.right == page.right - 96
~ formula.top == page.top - 240
end

page tex_width_ratio
let formula = tex!("x + y = z", 1)
formula.math.raw_tex_width_ratio = 0.82
~ formula.left == page.left + 96
~ formula.right == page.right - 96
~ formula.top == page.top - 240
end

page global_ratio
let formula = tex!("x + y = z", 1)
~ formula.left == page.left + 96
~ formula.right == page.right - 96
~ formula.top == page.top - 240
end

page local_override
let formula = tex!("x + y = z", 1)
formula.math.raw_tex_width_ratio = 1
~ formula.left == page.left + 96
~ formula.right == page.right - 96
~ formula.top == page.top - 240
end
`;
  }
  await writeFile(path.join(project, "slide.ss"), source, "utf8");
  await render(project, "math.pdf");
  return pages;
}

async function renderPdfAssetCases() {
  const project = await createProject("pdf-assets");
  await writeMinimalPdf(path.join(project, "asset.pdf"), 200, 100);
  await writeFile(path.join(project, "slide.ss"), `import std:core/prelude as *

page small
let asset = pdf!("asset.pdf", 0.3)
~ asset.left == page.left + 100
~ asset.right == page.right - 480
~ asset.top == page.top - 120
~ asset.bottom == page.top - 420
end

page large
let asset = pdf!("asset.pdf", 0.8)
~ asset.left == page.left + 100
~ asset.right == page.right - 480
~ asset.top == page.top - 120
~ asset.bottom == page.top - 420
end

page fixed_frame
let asset = pdf!("asset.pdf", 1)
~ asset.left == page.left + 100
~ asset.right == asset.left + 80
~ asset.top == page.top - 120
~ asset.bottom == page.top - 160
end
`, "utf8");
  const result = await render(project, "pdf-assets.pdf");
  assert.match(result.stderr, /FrameTooSmall/, "fixed PDF frame should produce FrameTooSmall");
}

async function renderOffPageCase() {
  const project = await createProject("off-page");
  await writeFile(path.join(project, "slide.ss"), `import std:core/prelude as *

page offpage
page_bg(c"1,1,1")
let marker = panel!()
marker.chrome.fill = c"1,0,0"
marker.chrome.stroke = none
marker.chrome.line_width = 0
place!(marker)
~ marker.left == page.right + 100
~ marker.bottom == page.bottom + 100
~ marker.width == 200
~ marker.height == 200
end
`, "utf8");
  const result = await render(project, "off-page.pdf");
  assert.match(result.stderr, /PageOverflow/, "off-page object should produce PageOverflow");
}

async function testMathGeometry(browser, baseUrl, pages) {
  const images = await capturePdfPages(browser, baseUrl, "math.pdf");
  const structuredOne = trimmedGeometry(images[pages.structuredOne]);
  const structuredTwo = trimmedGeometry(images[pages.structuredTwo]);
  assert(structuredOne && structuredTwo, "structured math was not visible");
  assert(
    structuredTwo.width > structuredOne.width * 1.85 && structuredTwo.width < structuredOne.width * 2.15,
    `structured math scale should roughly double width: ${summary(structuredOne)} -> ${summary(structuredTwo)}`,
  );

  if (pages.rawWide === null) return;
  const rawWide = trimmedGeometry(images[pages.rawWide]);
  const rawNarrow = trimmedGeometry(images[pages.rawNarrow]);
  const globalNarrow = trimmedGeometry(images[pages.globalNarrow]);
  const localWide = trimmedGeometry(images[pages.localWide]);
  assert(rawWide && rawNarrow && globalNarrow && localWide, "raw TeX was not visible");
  const availableWidth = (1280 - 96 * 2) * 2;
  assert(rawWide.width > availableWidth * 0.85, `raw TeX should use most of its frame: ${summary(rawWide)}`);
  assert(rawWide.width < availableWidth * 0.99, `raw TeX should retain breathing room: ${summary(rawWide)}`);
  assert(rawNarrow.width < rawWide.width * 0.9, `local raw TeX ratio was ignored: ${summary(rawWide)} -> ${summary(rawNarrow)}`);
  assert(globalNarrow.width < localWide.width * 0.9, `local raw TeX ratio should override the page policy: ${summary(globalNarrow)} -> ${summary(localWide)}`);
  assert(structuredOne.width < rawWide.width * 0.25, `structured math should retain its natural width: ${summary(structuredOne)} vs ${summary(rawWide)}`);
}

async function testPdfAssetGeometry(browser, baseUrl) {
  const images = await capturePdfPages(browser, baseUrl, "pdf-assets.pdf");
  assert.equal(images.length, 3);
  const small = trimmedGeometry(images[0]);
  const large = trimmedGeometry(images[1]);
  const fixed = trimmedGeometry(images[2]);
  assert(small && large && fixed, "embedded PDF content was not visible");
  assert(large.width > small.width * 2, `PDF factor should change rendered width: ${summary(small)} -> ${summary(large)}`);
  assert(large.height > small.height * 2, `PDF factor should change rendered height: ${summary(small)} -> ${summary(large)}`);
  assert(fixed.width > 300 && fixed.height > 150, `fixed frame should not shrink embedded PDF content: ${summary(fixed)}`);
}

async function testOffPageObject(browser, baseUrl) {
  const images = await capturePdfPages(browser, baseUrl, "off-page.pdf");
  assert.equal(images.length, 1);
  assert.equal(trimmedGeometry(images[0]), null, "off-page object was scaled or translated into the page");
}

function trimmedGeometry(bytes) {
  const image = decodePng(bytes);
  let left = image.width;
  let top = image.height;
  let right = -1;
  let bottom = -1;
  for (let y = 0; y < image.height; y += 1) {
    for (let x = 0; x < image.width; x += 1) {
      const offset = (y * image.width + x) * 4;
      if (image.data[offset + 3] <= 16) continue;
      if (image.data[offset] >= 235 && image.data[offset + 1] >= 235 && image.data[offset + 2] >= 235) continue;
      left = Math.min(left, x);
      top = Math.min(top, y);
      right = Math.max(right, x);
      bottom = Math.max(bottom, y);
    }
  }
  if (right < left || bottom < top) return null;
  return { x: left, y: top, width: right - left + 1, height: bottom - top + 1 };
}

function summary(geometry) {
  return `${geometry.width}x${geometry.height}+${geometry.x}+${geometry.y}`;
}

async function createProject(name) {
  const directory = path.join(projects, name);
  await mkdir(directory, { recursive: true });
  return directory;
}

async function render(project, outputName) {
  return await exec(ss, ["render", "slide.ss", path.join(output, outputName)], {
    cwd: project,
    timeout: 180_000,
    maxBuffer: 8 * 1024 * 1024,
  });
}

async function commandAvailable(command, args) {
  try {
    await exec(command, args, { timeout: 10_000 });
    return true;
  } catch {
    return false;
  }
}

async function writeMinimalPdf(filePath, width, height) {
  const stream = `0.9 0.1 0.1 rg\n0 0 ${width} ${height} re\nf\n`;
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${width} ${height}] /Contents 4 0 R >>`,
    `<< /Length ${Buffer.byteLength(stream)} >>\nstream\n${stream}endstream`,
  ];
  let pdf = "%PDF-1.4\n";
  const offsets = [0];
  for (const [index, body] of objects.entries()) {
    offsets.push(Buffer.byteLength(pdf));
    pdf += `${index + 1} 0 obj\n${body}\nendobj\n`;
  }
  const xrefOffset = Buffer.byteLength(pdf);
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (let index = 1; index < offsets.length; index += 1) {
    pdf += `${String(offsets[index]).padStart(10, "0")} 00000 n \n`;
  }
  pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xrefOffset}\n%%EOF\n`;
  await writeFile(filePath, pdf, "binary");
}
