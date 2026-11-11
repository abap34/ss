import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";
import { pdfAsset } from "../../../support/assets/pdf.mjs";
import { imageSourceIs } from "../../../support/display.mjs";

const scratch = path.join(root, ".test-tmp/integer-stages");
await mkdir(scratch, { recursive: true });
const directory = await mkdtemp(path.join(scratch, "assets-"));
function run(...args) {
  const result = spawnSync(ssBin, args, { cwd: directory, encoding: "utf8", timeout: 60000, killSignal: "SIGKILL" });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}
try {
  await writeFile(path.join(directory, "slide.ss"), await readFile(path.join(root, "tests/fixtures/staging/integers.ss")));
  await writeFile(path.join(directory, "appendix.pdf"), pdfAsset());
  for (const number of [7, 5, 3, 1]) {
    await writeFile(path.join(directory, `frame-${number}.svg`),
      `<svg xmlns="http://www.w3.org/2000/svg" width="180" height="100"><rect width="180" height="100" fill="#2488aa"/><text x="10" y="50">Frame ${number}</text></svg>`);
  }
  run("check", "--quiet", "slide.ss");
  run("dump", "--quiet", "slide.ss", "dump.json");
  const dump = JSON.parse(await readFile(path.join(directory, "dump.json"), "utf8"));
  const pages = dump.modules.find(module => module.kind === "project").program.pages;
  assert.deepEqual(pages.map(page => page.stageValue), [7, 5, 3, 1, 2, 1]);
  assert.deepEqual(pages.map(page => page.stageIndex), [0, 1, 2, 3, 0, 1]);
  assert.deepEqual(pages.map(page => page.name), ["Frames / 7", "Frames / 5", "Frames / 3", "Frames / 1", "Appendix / 2", "Appendix / 1"]);
  assert(pages.every(page => page.stageName === null));
  assert.equal(dump.page_order.length, 6);
  assert.deepEqual(dump.diagnostics, []);
  const images = dump.nodes.filter(node => imageSourceIs(node, "file"));
  assert.deepEqual(images.map(node => node.content), ["frame-7.svg", "frame-5.svg", "frame-3.svg", "frame-1.svg"]);
  const pdfs = dump.nodes.filter(node => imageSourceIs(node, "pdf"));
  assert.equal(pdfs.length, 2);
  for (const [index, node] of pdfs.entries()) {
    const source = node.placement.input.fields.find(field => field.name === "source").value;
    assert.equal(source.fields.find(field => field.name === "pdf_page").value.value, 2 - index);
    assert.equal(node.placement.page, dump.page_order[index + 4]);
  }
  const expanded = run("expand", "slide.ss");
  assert.doesNotMatch(expanded, /\bstages\b/);
  assert.equal((expanded.match(/^page /gm) ?? []).length, 6);
  run("render", "--quiet", "slide.ss", "rendered.pdf");
  assert.equal((await readFile(path.join(directory, "rendered.pdf"))).subarray(0, 5).toString(), "%PDF-");
} finally {
  await rm(directory, { recursive: true, force: true });
}
console.log("Integer stages: ordered image paths, PDF page selection, expansion, and rendering passed");
