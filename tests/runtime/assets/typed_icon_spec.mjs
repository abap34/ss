import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../harness.mjs";

const scratch = path.join(root, ".test-tmp/typed-icon");
await mkdir(scratch, { recursive: true });
const output = await mkdtemp(path.join(scratch, "display-"));
const source = path.join(root, "tests/fixtures/typed-display/icon.ss");
function run(...args) {
  const result = spawnSync(ssBin, args, { cwd: output, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  return result;
}
function success(...args) {
  const result = run(...args);
  assert.equal(result.status, 0, result.stderr);
}
const close = (actual, expected) => assert(Math.abs(actual - expected) < 0.1, `${actual} != ${expected}`);
try {
  success("check", "--quiet", source);
  success("dump", "--quiet", source, "--output", path.join(output, "dump.json"));
  const dump = JSON.parse(await readFile(path.join(output, "dump.json"), "utf8"));
  assert.deepEqual(dump.diagnostics, []);
  assert.equal(dump.page_order.length, 2);
  const icons = dump.nodes.filter(node => node.placement?.display.kind === "icon");
  assert.equal(icons.length, 5);
  assert(dump.nodes.some(node => node.content === "Icons: 2"));
  const byPage = dump.page_order.map(id => icons.filter(node => node.placement.page === id).sort((a, b) => a.x - b.x));
  assert.deepEqual(byPage.map(nodes => nodes.length), [3, 2]);
  for (const node of icons) {
    assert.deepEqual(node.fields, {});
    assert.equal(node.placement.input.type.name, "Icon");
    assert.equal(node.render.kind, "vector_asset");
    assert.equal(node.blocks, null);
    assert.equal(node.inline_lines, null);
  }
  for (const [nodes, sizes] of [[byPage[0], [72, 108, 36]], [byPage[1], [72, 72]]]) {
    nodes.forEach((node, index) => { close(node.width, sizes[index]); close(node.height, sizes[index]); });
  }
  assert.equal(byPage[0][0].content, "fa-solid:star");
  assert.equal(byPage[0][1].content, "fa-solid:heart");
  assert.deepEqual(byPage[0][0].placement.input, byPage[0][2].placement.input);
  const field = (record, name) => record.fields.find(item => item.name === name).value;
  const tint = node => field(field(field(node.placement.input, "style"), "asset"), "tint");
  assert.notDeepEqual(tint(byPage[0][0]), tint(byPage[0][1]));
  assert.equal(new Set(icons.map(node => node.id)).size, 5);
  success("render", "--quiet", source, "--output", path.join(output, "slides.pdf"));
  assert.equal((await readFile(path.join(output, "slides.pdf"))).subarray(0, 5).toString(), "%PDF-");
  success("render", "--quiet", "--format", "html", source, "--output", path.join(output, "slides.html"));
  const html = await readFile(path.join(output, "slides.html"), "utf8");
  assert(html.includes("mask:url('ss-resource:svg:"));
  const svgResources = [...html.matchAll(/<script[^>]*data-media-type="image\/svg\+xml"[^>]*>([^<]+)<\/script>/g)]
    .map(match => Buffer.from(match[1], "base64").toString("utf8"));
  assert(svgResources.length >= 2);
  assert(svgResources.every(svg => svg.includes("<svg") && svg.includes("<path")));

  const original = await readFile(source, "utf8");
  const changed = path.join(output, "changed.ss");
  await writeFile(changed, original.replace("asset.scale = 1.5", "asset.scale = 0.5"));
  success("dump", "--quiet", changed, "--output", path.join(output, "changed.json"));
  const updated = JSON.parse(await readFile(path.join(output, "changed.json"), "utf8"));
  const heart = updated.nodes.find(node => node.placement?.display.kind === "icon" && node.content === "fa-solid:heart");
  close(heart.width, 36);
  close(heart.height, 36);

  for (const name of ["fa-solid:not-a-real-ss-icon", "unrecognized:star", "image.svg", ""]) {
    const invalid = path.join(output, "invalid.ss");
    await writeFile(invalid, original.replace("fa-solid:star", name));
    const result = run("check", "--quiet", invalid);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /InvalidFontAwesomeIcon/);
    assert.doesNotMatch(result.stderr, /AssetNotFound/);
  }
  console.log("typed icon display: ok");
} finally {
  await rm(output, { recursive: true, force: true });
}
