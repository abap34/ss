import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, copyFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../harness.mjs";

const scratch = path.join(root, ".ss-cache/tests/typed-code");
await mkdir(scratch, { recursive: true });
const project = await mkdtemp(path.join(scratch, "display-"));

function run(...args) {
  const result = spawnSync(ssBin, args, { cwd: project, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
}

function color(hex) {
  return [0, 2, 4].map(offset => Math.round(parseInt(hex.slice(offset, offset + 2), 16) / 255 * 10000) / 10000);
}

try {
  await copyFile(path.join(root, "tests/fixtures/typed-display/code.ss"), path.join(project, "slide.ss"));
  run("check", "--quiet", "slide.ss");
  run("dump", "--quiet", "slide.ss", "--output", "dump.json");
  const dump = JSON.parse(await readFile(path.join(project, "dump.json"), "utf8"));
  assert.equal(dump.page_order.length, 2);
  assert.deepEqual(dump.diagnostics, []);
  const codes = dump.nodes.filter(node => node.placement?.display.kind === "code");
  assert.equal(codes.length, 3);
  assert.deepEqual(codes.map(node => node.render.code.language), ["python", "plain", "python"]);
  assert.deepEqual(codes.map(node => node.render.text.font_size), [18, 22, 18]);
  assert.deepEqual(codes.map(node => node.placement.page), [dump.page_order[0], dump.page_order[0], dump.page_order[1]]);
  assert.deepEqual(codes[0].render.code.keyword_color, color("cf222e"));
  assert.deepEqual(codes[2].render.code.keyword_color, color("ff7b72"));
  assert.deepEqual(codes[0].render.chrome.fill, color("f6f8fa"));
  assert.deepEqual(codes[2].render.chrome.fill, color("0d1117"));
  for (const node of codes) {
    const source = node.placement.input.fields.find(field => field.name === "source").value.value;
    assert.equal(node.content, source);
    assert(node.content.includes("**Literal** $x$ ![image](missing.png)"));
    assert.equal(node.blocks, null);
    assert.equal(node.inline_lines, null);
    assert.equal(node.role, null);
    assert.deepEqual(node.fields, {});
    assert.equal(node.render.kind, "code");
    assert(node.width > 100 && node.height > 40);
    assert.equal(node.x, 64);
  }
  assert(codes[1].height > codes[0].height);
  assert(codes[1].width > codes[0].width);
  const parent = dump.nodes.find(node => node.id === codes[2].placement.parent);
  assert.equal(parent.placement.input.type.name, "Example");
  assert.deepEqual(parent.placement.children, [codes[2].id]);
  run("render", "--quiet", "slide.ss", "--output", "rendered.pdf");
  const pdf = await readFile(path.join(project, "rendered.pdf"));
  assert.equal(pdf.subarray(0, 5).toString(), "%PDF-");
} finally {
  await rm(project, { recursive: true, force: true });
}
