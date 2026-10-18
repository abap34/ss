import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../harness.mjs";
import { pdfAsset } from "../../support/assets/pdf.mjs";

const scratch = path.join(root, ".ss-cache/tests/typed-pdf");
await mkdir(scratch, { recursive: true });
const project = await mkdtemp(path.join(scratch, "display-"));
const source = await readFile(path.join(root, "tests/fixtures/typed-display/pdf.ss"), "utf8");

function run(...args) {
  const result = spawnSync(ssBin, args, { cwd: project, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  return result;
}

function success(...args) {
  const result = run(...args);
  assert.equal(result.status, 0, result.stderr);
}

function field(record, name) {
  const value = record.fields.find(item => item.name === name)?.value;
  assert(value, `Missing input field: ${name}`);
  return value;
}

try {
  await writeFile(path.join(project, "asset.pdf"), pdfAsset());
  await writeFile(path.join(project, "slide.ss"), source);
  success("check", "--quiet", "slide.ss");
  success("dump", "--quiet", "slide.ss", "--output", "dump.json");
  const dump = JSON.parse(await readFile(path.join(project, "dump.json"), "utf8"));
  assert.equal(dump.page_order.length, 2);
  assert.deepEqual(dump.diagnostics, []);
  const pdfs = dump.nodes.filter(node => node.placement?.display.kind === "pdf");
  assert.equal(pdfs.length, 3);
  const expected = [
    { width: 116, height: 216, page: 2, box: "crop", owner: dump.page_order[0] },
    { width: 136, height: 256, page: 2, box: "media", owner: dump.page_order[0] },
    { width: 208, height: 112, page: 1, box: "crop", owner: dump.page_order[1] },
  ];
  for (const [index, node] of pdfs.entries()) {
    const want = expected[index];
    assert(Math.abs(node.width - want.width) < 0.01, `PDF ${index} width: ${node.width}`);
    assert(Math.abs(node.height - want.height) < 0.01, `PDF ${index} height: ${node.height}`);
    assert.equal(node.placement.page, want.owner);
    assert.equal(node.content, "asset.pdf");
    assert.equal(node.payload_kind, "pdf_ref");
    assert(!Object.hasOwn(node, "role"));
    assert.deepEqual(node.fields, {});
    assert.equal(node.render.kind, "vector_asset");
    const asset = field(field(node.placement.input, "style"), "asset");
    assert.equal(field(asset, "pdf_page").value, want.page);
    assert.equal(field(asset, "pdf_box").case, want.box);
  }
  const parent = dump.nodes.find(node => node.id === pdfs[2].placement.parent);
  assert.equal(parent.placement.input.type.name, "Sheet");
  assert.deepEqual(parent.placement.children, [pdfs[2].id]);
  assert.equal(new Set(pdfs.map(node => node.id)).size, 3);
  success("render", "--quiet", "slide.ss", "--output", "rendered.pdf");
  const rendered = await readFile(path.join(project, "rendered.pdf"));
  assert.equal(rendered.subarray(0, 5).toString(), "%PDF-");

  for (const filename of ["asset.bin", "asset.svg"]) {
    await writeFile(path.join(project, filename), pdfAsset());
    await writeFile(path.join(project, "renamed.ss"), source.replace('path = "asset.pdf"', `path = "${filename}"`));
    success("dump", "--quiet", "renamed.ss", "--output", "renamed.json");
    const renamed = JSON.parse(await readFile(path.join(project, "renamed.json"), "utf8"));
    const renamedPdfs = renamed.nodes.filter(node => node.placement?.display.kind === "pdf");
    assert.deepEqual(renamedPdfs.map(node => [node.width, node.height]), pdfs.map(node => [node.width, node.height]));
    success("render", "--quiet", "renamed.ss", "--output", "renamed.pdf");
  }

  await writeFile(path.join(project, "not-a-pdf.svg"), '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><rect width="100" height="50" fill="blue"/></svg>');
  await writeFile(path.join(project, "wrong-format.ss"), source.replace('path = "asset.pdf"', 'path = "not-a-pdf.svg"'));
  const wrongFormat = run("render", "--quiet", "wrong-format.ss", "--output", "wrong-format.pdf");
  assert.notEqual(wrongFormat.status, 0);
  assert.match(wrongFormat.stderr, /RenderFailed: PDF asset:/);
  assert.match(wrongFormat.stderr, /InvalidPdfResource:/);
  assert.match(wrongFormat.stderr, /use image! for images and pdf! for PDF files/);
  assert.match(wrongFormat.stderr, /failed to read PDF page geometry/);
  assert.doesNotMatch(wrongFormat.stderr, /panic:/);

  for (const number of ["0", "-1", "1.5", "100000000000000000000"]) {
    await writeFile(path.join(project, "invalid.ss"), source.replace("asset.pdf_page = 2", `asset.pdf_page = ${number}`));
    const result = run("check", "--quiet", "invalid.ss");
    assert.notEqual(result.status, 0, `Invalid page number accepted: ${number}`);
    assert.match(result.stderr, /InvalidAsset/);
    assert.match(result.stderr, /positive integer/);
    assert.doesNotMatch(result.stderr, /panic:/);
  }
  await writeFile(path.join(project, "missing.ss"), source.replace('path = "asset.pdf"', 'path = "missing.pdf"'));
  const missing = run("check", "--quiet", "missing.ss");
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /AssetNotFound/);
  assert.match(missing.stderr, /missing\.pdf/);

  await writeFile(path.join(project, "out-of-range.ss"), source.replace("asset.pdf_page = 2", "asset.pdf_page = 3"));
  const absentPage = run("render", "--quiet", "out-of-range.ss", "--output", "absent.pdf");
  assert.notEqual(absentPage.status, 0);
  assert.match(absentPage.stderr, /InvalidPdfResource/);
  assert.doesNotMatch(absentPage.stderr, /panic:/);
} finally {
  await rm(project, { recursive: true, force: true });
}
