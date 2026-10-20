import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";

const scratch = path.join(root, ".ss-cache/tests/typed-path");
await mkdir(scratch, { recursive: true });
const output = await mkdtemp(path.join(scratch, "display-"));
const source = path.join(root, "tests/fixtures/typed-display/path.ss");
function run(...args) {
  const result = spawnSync(ssBin, args, { cwd: root, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
}
const close = (actual, expected) => assert(Math.abs(actual - expected) < 0.1, `${actual} != ${expected}`);
try {
  run("check", "--quiet", source);
  run("dump", "--quiet", source, "--output", path.join(output, "dump.json"));
  const dump = JSON.parse(await readFile(path.join(output, "dump.json"), "utf8"));
  assert.deepEqual(dump.diagnostics, []);
  assert.equal(dump.page_order.length, 3);
  const shapes = dump.nodes.filter(node => node.placement?.display.kind === "path_shape");
  assert.equal(shapes.length, 7);
  assert(dump.nodes.some(node => node.content === "Shapes: 2"));
  const input = (node, key) => node.placement.input.fields.find(field => field.name === key).value;
  const byPage = dump.page_order.map(id => shapes.filter(node => node.placement.page === id).sort((a, b) => a.x - b.x));
  assert.deepEqual(byPage.map(nodes => nodes.length), [3, 2, 2]);
  for (const node of shapes) {
    assert.equal(node.placement.input.type.name, "PathShape");
    assert.equal(node.render.kind, "vector_path");
    assert.equal(node.blocks, null);
    assert.equal(node.inline_lines, null);
  }
  for (const [nodes, sizes] of [[byPage[0], [[180, 120], [240, 120], [200, 120]]], [byPage[1], [[180, 120], [180, 120]]], [byPage[2], [[180, 120], [90, 60]]]]) {
    nodes.forEach((node, index) => {
      close(node.width, sizes[index][0]);
      close(node.height, sizes[index][1]);
    });
  }
  assert.equal(input(byPage[2][1], "width").value, 180);
  assert.equal(input(byPage[2][1], "height").value, 120);
  assert.equal(new Set(shapes.map(node => node.id)).size, 7);
  run("render", "--quiet", source, "--output", path.join(output, "slides.pdf"));
  assert.equal((await readFile(path.join(output, "slides.pdf"))).subarray(0, 5).toString(), "%PDF-");
  run("render", "--quiet", "--format", "html", source, "--output", path.join(output, "slides.html"));
  const html = await readFile(path.join(output, "slides.html"), "utf8");
  assert(html.includes("<svg"));
  assert(html.includes("<path"));

  const invalidSource = path.join(output, "invalid.ss");
  await writeFile(invalidSource, (await readFile(source, "utf8")).replace("width = 180", "width = -1"));
  const invalid = spawnSync(ssBin, ["check", "--quiet", invalidSource], { cwd: root, encoding: "utf8", timeout: 60000 });
  assert.ifError(invalid.error);
  assert.notEqual(invalid.status, 0);
  assert.match(invalid.stderr, /InvalidShapeSize/);

  const smallSource = path.join(output, "small.ss");
  await writeFile(smallSource, `import std:graphics as g
import std:graphics/path as p
import std:graphics/paint as paint
page small
  let item = place!(g::PathShape {
    path = path(p::move_to(0, 0), p::line_to(1, 0), p::line_to(1, 1), p::close_path())
    width = 0.5 height = 0.4
    style = g::VectorStyle { fill = paint::solid_fill(c"#2563eb") stroke = paint::no_stroke() }
  })
  ~ item.left == page.left + 64
  ~ item.top == page.top - 64
end
`);
  run("dump", "--quiet", smallSource, "--output", path.join(output, "small.json"));
  const smallDump = JSON.parse(await readFile(path.join(output, "small.json"), "utf8"));
  assert.deepEqual(smallDump.diagnostics, []);
  const small = smallDump.nodes.find(node => node.placement?.display.kind === "path_shape");
  assert.equal(small.width, 0.5);
  assert.equal(small.height, 0.4);
  run("render", "--quiet", smallSource, "--output", path.join(output, "small.pdf"));

  const edgeSource = path.join(output, "edge.ss");
  await writeFile(edgeSource, (await readFile(smallSource, "utf8"))
    .replace("width = 0.5 height = 0.4", "width = 180 height = 100")
    .replace("paint::no_stroke()", 'paint::vector_stroke(c"#2563eb", 10)')
    .replace("page.left + 64", "page.left"));
  run("dump", "--quiet", edgeSource, "--output", path.join(output, "edge.json"));
  const edgeDump = JSON.parse(await readFile(path.join(output, "edge.json"), "utf8"));
  const edge = edgeDump.nodes.find(node => node.placement?.display.kind === "path_shape");
  assert.equal(edge.width, 180);
  assert.equal(edge.height, 100);
  assert(edgeDump.diagnostics.some(diagnostic => diagnostic.node_id === edge.id && diagnostic.code === "PageOverflow"), JSON.stringify({node: edge, diagnostics: edgeDump.diagnostics}));
  assert(!edgeDump.diagnostics.some(diagnostic => diagnostic.code === "FrameTooSmall"));

  // Identical path and paint with changed dimensions must invalidate measurements.
  const changedSource = path.join(output, "resized.ss");
  const originalSource = await readFile(source, "utf8");
  await writeFile(changedSource, originalSource.replace("width = 180", "width = 210"));
  run("dump", "--quiet", changedSource, "--output", path.join(output, "resized.json"));
  const resized = JSON.parse(await readFile(path.join(output, "resized.json"), "utf8"));
  const first = resized.nodes.filter(node => node.placement?.display.kind === "path_shape" && node.placement.page === resized.page_order[0]).sort((a, b) => a.x - b.x)[0];
  close(first.width, 210);
} finally {
  await rm(output, { recursive: true, force: true });
}
