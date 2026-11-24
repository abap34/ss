import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFile, mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";

const project = await mkdtemp(path.join(os.tmpdir(), "ss-inline-code-"));

function run(...args) {
  const result = spawnSync(ssBin, args, { cwd: project, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
}

function color(hex) {
  return [0, 2, 4].map(offset => Math.round(parseInt(hex.slice(offset, offset + 2), 16) / 255 * 10000) / 10000);
}

try {
  await copyFile(path.join(root, "tests/fixtures/render/inline-code/slide.ss"), path.join(project, "slide.ss"));
  run("dump", "--quiet", "slide.ss", "dump.json");
  const dump = JSON.parse(await readFile(path.join(project, "dump.json"), "utf8"));
  assert.deepEqual(dump.diagnostics, []);
  const bodies = dump.nodes.filter(node => node.render?.kind === "text");
  assert.equal(bodies.length, 3);
  const styled = bodies.find(node => node.content.startsWith("# Heading"));
  assert(styled);
  assert.deepEqual(styled.render.text.markdown_inline_code_color, color("b5485d"));
  assert.deepEqual(styled.render.text.markdown_inline_code_fill, color("f3f4f6"));
  for (const body of bodies.filter(node => node !== styled)) {
    assert.equal(body.render.text.markdown_inline_code_color, null);
    assert.equal(body.render.text.markdown_inline_code_fill, null);
    assert.deepEqual(body.render.text.color, color("102a43"));
    assert.deepEqual(body.render.text.markdown_code_fill, styled.render.text.markdown_code_fill);
    assert.deepEqual(body.render.text.markdown_code_plain_color, styled.render.text.markdown_code_plain_color);
  }
  run("render", "--quiet", "slide.ss", "rendered.pdf");
  assert.equal((await readFile(path.join(project, "rendered.pdf"))).subarray(0, 5).toString(), "%PDF-");
  run("render", "--quiet", "--format", "html", "slide.ss", "rendered.html");
  const html = await readFile(path.join(project, "rendered.html"), "utf8");
  const colors = new Set([...html.matchAll(/rgb\(([\d.]+)% ([\d.]+)% ([\d.]+)%\)/g)].map(match =>
    match.slice(1).map(value => Math.round(Number(value) * 255 / 100).toString(16).padStart(2, "0")).join("")));
  for (const hex of ["b5485d", "f3f4f6", "102a43", "fff2a8"]) {
    assert(colors.has(hex), `HTML omitted inline code or surrounding text color: ${hex}`);
  }
} finally {
  await rm(project, { recursive: true, force: true });
}
