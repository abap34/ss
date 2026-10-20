import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, copyFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../harness.mjs";

const scratch = path.join(root, ".ss-cache/tests/typed-latex");
await mkdir(scratch, { recursive: true });
const project = await mkdtemp(path.join(scratch, "display-"));
function run(...args) {
  const result = spawnSync(ssBin, args, { cwd: project, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
}
try {
  await writeFile(path.join(project, "unused.ss"), `import std:math as formulas
const body: formulas::Latex = formulas::latex("Undefined TeX command")
page unused
end
`);
  run("dump", "--quiet", "unused.ss", "--output", "unused.json");
  const unused = JSON.parse(await readFile(path.join(project, "unused.json"), "utf8"));
  assert.deepEqual(unused.diagnostics, []);
  assert(!unused.nodes.some(node => node.placement));
  await copyFile(path.join(root, "tests/fixtures/typed-display/latex.ss"), path.join(project, "slide.ss"));
  const probe = spawnSync("pdflatex", ["--version"], { timeout: 10000 });
  if (probe.error?.code !== "ENOENT") {
    assert.ifError(probe.error);
    assert.equal(probe.status, 0, "pdflatex availability probe failed");
    // CLI check includes layout measurement. Static display checks run in Zig.
    run("check", "--quiet", "slide.ss");
    run("dump", "--quiet", "slide.ss", "--output", "dump.json");
    const dump = JSON.parse(await readFile(path.join(project, "dump.json"), "utf8"));
    assert.deepEqual(dump.diagnostics, []);
    const bodies = dump.nodes.filter(node => node.placement?.display.kind === "latex");
    assert.equal(bodies.length, 3);
    assert.deepEqual(bodies.map(node => node.render.latex.scale), [1, 2, 1]);
    assert.deepEqual(bodies.map(node => node.placement.page), dump.page_order);
    for (const node of bodies) {
      assert.equal(node.content, bodies[0].content);
      assert(node.content.includes(String.raw`\textbf{LaTeX body}`));
      assert.deepEqual(node.fields, {});
      assert.equal(node.blocks, null);
      assert.equal(node.inline_lines, null);
      assert.equal(node.render.kind, "latex");
    }
    const near = (a, b) => assert(Math.abs(a - b) < 0.08, `${a} != ${b}`);
    function widths(html) {
      return [...html.matchAll(/<(?:span|div) class="ss-item ss-latex ss-pdf"[^>]*style="[^\"]*?width:([-0-9.]+)pt/g)].map(match => Number(match[1]));
    }
    run("render", "--quiet", "--format", "html", "slide.ss", "--output", "rendered.html");
    const initial = widths(await readFile(path.join(project, "rendered.html"), "utf8"));
    assert.equal(initial.length, 3);
    assert(initial[0] > 0);
    near(initial[1], initial[0] * 2);
    near(initial[2], initial[0]);
    run("render", "--quiet", "slide.ss", "--output", "rendered.pdf");
    assert.equal((await readFile(path.join(project, "rendered.pdf"))).subarray(0, 5).toString(), "%PDF-");
    // A changed preamble must produce a different fragment even when the body is reused.
    const source = await readFile(path.join(project, "slide.ss"), "utf8");
    await writeFile(path.join(project, "slide.ss"), source.replace("f(#1)", "abcdefgh(#1)"));
    run("render", "--quiet", "--format", "html", "slide.ss", "--output", "updated.html");
    const updated = widths(await readFile(path.join(project, "updated.html"), "utf8"));
    assert.equal(updated.length, 3);
    assert(updated[0] > initial[0] + 20);
    near(updated[1], updated[0] * 2);
    near(updated[2], updated[0]);
  }
} finally {
  await rm(project, { recursive: true, force: true });
}
