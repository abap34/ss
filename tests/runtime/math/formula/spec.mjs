import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";

const scratch = path.join(root, ".ss-cache/tests/typed-math");
await mkdir(scratch, { recursive: true });
const project = await mkdtemp(path.join(scratch, "formula-"));
function run(...args) {
  const result = spawnSync(ssBin, args, { cwd: project, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
}
const close = (a, b) => assert(Math.abs(a - b) < 0.1, a + " != " + b);
try {
  await copyFile(path.join(root, "tests/fixtures/typed-display/math.ss"), path.join(project, "slide.ss"));
  const probe = spawnSync("pdflatex", ["--version"], { timeout: 10000 });
  if (probe.error?.code === "ENOENT") {
    console.log("Math rendering skipped: pdflatex is unavailable");
  } else {
    assert.ifError(probe.error);
    assert.equal(probe.status, 0, "pdflatex availability probe failed");
    // CLI check includes layout measurement. Static display checks run in Zig.
    run("check", "--quiet", "slide.ss");
    run("dump", "--quiet", "slide.ss", "--output", "dump.json");
    const dump = JSON.parse(await readFile(path.join(project, "dump.json"), "utf8"));
    assert.deepEqual(dump.diagnostics, []);
    assert.equal(dump.page_order.length, 3);
    const formulas = dump.nodes.filter(node => node.placement?.input.type?.name === "Math");
    const bodies = dump.nodes.filter(node => node.placement?.display.kind === "latex");
    assert.equal(formulas.length, 5);
    assert.equal(bodies.length, 5);
    assert(dump.nodes.some(node => node.content === "Formulas: 2"));
    for (const formula of formulas) {
      assert.equal(formula.role, null);
      assert.equal(formula.placement.children.length, 1);
      const child = bodies.find(node => node.id === formula.placement.children[0]);
      assert(child);
      assert.equal(child.placement.parent, formula.id);
      assert.equal(child.placement.page, formula.placement.page);
      const source = formula.placement.input.fields.find(field => field.name === "source").value.value;
      assert.equal(child.content, "$\\displaystyle " + source + "\n$");
      assert.equal(child.blocks, null);
      assert.equal(child.inline_lines, null);
    }
    const [normal, enlarged, combined] = dump.page_order.map(page => bodies.filter(node => node.placement.page === page));
    assert.deepEqual([normal.length, enlarged.length, combined.length], [2, 1, 2]);
    const original = normal.find(node => node.content.includes("\\Example"));
    assert(original);
    combined.sort((a, b) => a.x - b.x);
    close(enlarged[0].width, original.width * 2);
    close(combined[0].width, original.width);
    close(combined[1].width, original.width);
    close(combined[1].x - combined[0].x - combined[0].width, 64);
    assert.equal(enlarged[0].render.latex.scale, 2);
    assert.equal(original.render.latex.scale, 1);
    run("render", "--quiet", "slide.ss", "--output", "slides.pdf");
    assert.equal((await readFile(path.join(project, "slides.pdf"))).subarray(0, 5).toString(), "%PDF-");
    run("render", "--quiet", "--format", "html", "slide.ss", "--output", "slides.html");
    const html = await readFile(path.join(project, "slides.html"), "utf8");
    assert.equal([...html.matchAll(/class="ss-item ss-latex ss-pdf"/g)].length, 5);
  }
} finally {
  await rm(project, { recursive: true, force: true });
}
