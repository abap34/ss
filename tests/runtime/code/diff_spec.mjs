import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../harness.mjs";

const scratch = path.join(root, ".test-tmp/diff-code");
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
  await copyFile(path.join(root, "tests/fixtures/render/diff/slide.ss"), path.join(project, "slide.ss"));
  run("dump", "--quiet", "slide.ss", "dump.json");
  const dump = JSON.parse(await readFile(path.join(project, "dump.json"), "utf8"));
  assert.deepEqual(dump.diagnostics, []);
  assert.equal(dump.page_order.length, 5);
  const codes = dump.nodes.filter(node => node.render?.kind === "code");
  assert.deepEqual(codes.map(node => node.render.code.language), ["diff", "diff", "diff", "diff"]);
  const markdown = dump.nodes.find(node => node.content?.startsWith("```diff"));
  assert(markdown);
  for (const [role, hex, custom] of [
    ["addition", "1a7f37", "118833"],
    ["deletion", "cf222e", "bb2233"],
    ["change", "9a6700", "aa7700"],
  ]) {
    assert.deepEqual(codes[0].render.code[`${role}_color`], color(hex));
    assert.deepEqual(markdown.render.text[`markdown_code_${role}_color`], color(hex));
    assert.deepEqual(codes[1].render.code[`${role}_color`], color(custom));
  }
  for (const [role, hex, custom, dark] of [
    ["addition", "dafbe1", "d5f5e3", "0f2d1a"],
    ["deletion", "ffebe9", "fadbd8", "3d1c1e"],
    ["change", "fff8c5", "fcf3cf", "392e12"],
  ]) {
    assert.deepEqual(codes[0].render.code[`${role}_fill`], color(hex));
    assert.deepEqual(markdown.render.text[`markdown_code_${role}_fill`], color(hex));
    assert.deepEqual(codes[1].render.code[`${role}_fill`], color(custom));
    assert.deepEqual(codes[2].render.code[`${role}_fill`], color(dark));
    assert.equal(codes[3].render.code[`${role}_fill`], null);
  }
  run("render", "--quiet", "slide.ss", "rendered.pdf");
  assert.equal((await readFile(path.join(project, "rendered.pdf"))).subarray(0, 5).toString(), "%PDF-");
  run("render", "--quiet", "--format", "html", "slide.ss", "rendered.html");
  const html = await readFile(path.join(project, "rendered.html"), "utf8");
  const renderedColors = new Set([...html.matchAll(/rgb\(([\d.]+)% ([\d.]+)% ([\d.]+)%\)/g)].map(match =>
    match.slice(1).map(value => Math.round(Number(value) * 255 / 100).toString(16).padStart(2, "0")).join("")));
  for (const hex of ["1a7f37", "cf222e", "9a6700", "118833", "bb2233", "aa7700", "dafbe1", "ffebe9", "fff8c5", "d5f5e3", "fadbd8", "fcf3cf", "0f2d1a", "3d1c1e", "392e12"]) {
    assert(renderedColors.has(hex), `HTML omitted diff color: ${hex}`);
  }
  for (const content of ["added text", "removed text", "changed text", "unchanged context"]) {
    assert(html.includes(content), `HTML omitted diff content: ${content}`);
  }
} finally {
  await rm(project, { recursive: true, force: true });
}
