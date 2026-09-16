#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { root, ssBin, withLspClient } from "../../harness.mjs";
import { editorSnapshot } from "../../editor/support.mjs";
import { assertPractical, close, frame, geometry, item } from "./assertions.mjs";

const exec = promisify(execFile);
const outputRoot = path.join(root, ".ss-cache/tests/layout/practical");
await mkdir(outputRoot, { recursive: true });
const project = await mkdtemp(path.join(outputRoot, "run-"));
await cp(path.join(root, "tests/fixtures/layout/practical"), project, { recursive: true });
const slide = path.join(project, "slide.ss");
const source = await readFile(slide, "utf8");
let runs = 0;

const baseline = await dump("cold", source, { jobs: 1 });
assertPractical(baseline);
const warm = await dump("warm", source, { jobs: 4 });
assertPractical(warm);
assert.deepEqual(geometry(warm), geometry(baseline), "parallel solving or persistent caches changed layout");

const variants = [
  { name: "center", source: source.replace("column_policy: LayoutPolicy = LayoutPolicy.top", "column_policy: LayoutPolicy = LayoutPolicy.center"), options: { centered: true } },
  { name: "narrow", source: source.replace("column_width: Number = 1000", "column_width: Number = 880"), options: { width: 880 } },
  { name: "longer", source: source.replace("A synthetic paragraph explains how a small collection is checked before processing.", "A synthetic paragraph explains how a small collection is checked before processing. Additional records require careful review so that every missing value is reported with enough context."), options: {} },
  { name: "larger-font", source: source.replace("  let upper = text <<", "  description.text.size = 28\n  let upper = text <<"), options: {} },
  { name: "moved", source: source.replace("~ row.left == page.left + 150", "~ row.left == page.left + 150\n  ~!~ row.left == page.left + 190").replace("~ row.top == page.top - 210", "~ row.top == page.top - 210\n  ~!~ row.top == page.top - 250"), options: { cardShift: 40, cardDrop: 40 } },
];
for (const variant of variants) {
  variant.dump = await dump(variant.name, variant.source);
  assertPractical(variant.dump, variant.options);
  const affected = variant.name === "moved" ? "cards" : "columns";
  for (const page of ["columns", "matrix", "table_code", "flow", "image_caption", "cards"].filter((name) => name !== affected)) {
    assert.deepEqual(geometry(variant.dump, page), geometry(baseline, page), `${variant.name}: unrelated page ${page} moved`);
  }
}
assert(item(variants[2].dump, "columns", "## Collection notes").height > item(baseline, "columns", "## Collection notes").height, "longer text retained its old height");
assert(item(variants[3].dump, "columns", "## Collection notes").height > item(baseline, "columns", "## Collection notes").height, "larger font retained its old height");
assert(item(variants[1].dump, "columns", "## Collection notes").height >= item(baseline, "columns", "## Collection notes").height, "narrower text unexpectedly lost lines");

// Check the detector itself, so a weakened assertion cannot quietly make the
// suite pass when the same geometry regression returns.
const corruptions = [
  ["collapsed", (d) => { item(d, "cards", "## Collect\n").width = 0; }, /collapsed frame/],
  ["non-finite", (d) => { item(d, "cards", "## Collect\n").y = NaN; }, /non-finite/],
  ["clipped", (d) => { item(d, "table_code", "| stage |").height = 10; }, /clipped/],
  ["overlap", (d) => { const a = item(d, "cards", "## Collect\n"); item(d, "cards", "## Transform\n").x = a.x; }, /overlapping/],
  ["off-page", (d) => { item(d, "image_caption", "Diagram caption:").x = 1300; }, /page bounds/],
  ["stale measurement", (d) => { item(d, "columns", "## Collection notes").measurement.measured_width = 700; }, /stale measured width/],
  ["spacing", (d) => { item(d, "cards", "Card summary:").y -= 10; }, /summary follows moved group/],
];
for (const [name, corrupt, diagnostic] of corruptions) {
  const damaged = structuredClone(baseline);
  corrupt(damaged);
  assert.throws(() => assertPractical(damaged), diagnostic, `detector missed ${name}`);
}

await writeFile(slide, source);
await run(["check", "--quiet", slide]);
await run(["render", "--quiet", slide, path.join(project, "practical.pdf")]);
await run(["render", "--quiet", "--format", "html", slide, path.join(project, "practical.html")]);
const html = await readFile(path.join(project, "practical.html"), "utf8");
assert.equal((html.match(/<section class="ss-page"/g) ?? []).length, 6, "HTML omitted a practical page");

// Exercise source updates in one editor session, then revisit the original
// source to catch stale measurements and page-local result reuse.
const uri = pathToFileURL(slide).href;
await withLspClient({ cwd: project }, async (client) => {
  await client.initialize();
  let version = 1;
  const ready = client.waitForDiagnostics(uri);
  client.openDocument({ uri, text: source, version });
  assert.deepEqual((await ready).params.diagnostics, [], "initial editor diagnostics");
  const initial = await editorSnapshot(client, uri);
  assertSnapshot(initial, baseline);
  assert.equal((await editorSnapshot(client, uri)).snapshot_id, initial.snapshot_id, "unchanged editor snapshot was rebuilt");
  for (const variant of [...variants, { name: "restored", source, dump: baseline }]) {
    await writeFile(slide, variant.source);
    const diagnostics = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: ++version, text: variant.source });
    assert.deepEqual((await diagnostics).params.diagnostics, [], `${variant.name}: editor diagnostics`);
    const snapshot = await editorSnapshot(client, uri);
    await writeFile(path.join(project, `${variant.name}-snapshot.json`), JSON.stringify(snapshot));
    assertSnapshot(snapshot, variant.dump);
  }
});
console.log(`practical layout: ${runs} document solves, ${variants.length + 2} editor states, ${corruptions.length} detector checks passed (6 synthetic pages)`);
console.log(`practical layout artifacts: ${project}`);

function assertSnapshot(snapshot, expected) {
  const actual = snapshot.layout.objects;
  const nodes = expected.nodes.filter((node) => node.kind === "object");
  assert.equal(actual.length, nodes.length, "editor omitted or duplicated objects");
  for (const node of nodes) {
    const object = actual.find((candidate) => candidate.id === node.id);
    assert(object, `editor omitted object ${node.id}`);
    // The shared editor layout uses the document's bottom-left coordinates.
    for (const key of Object.keys(frame(node))) close(object[key], node[key], `editor/CLI ${node.id}.${key}`);
    if (["text", "code"].includes(node.render?.kind) && node.content) {
      assert(snapshot.display.html.includes(`data-ss-node-id="${node.id}"`), `editor display omitted text object ${node.id}`);
    }
  }
}

async function dump(name, text, { jobs = 2 } = {}) {
  await writeFile(slide, text);
  const destination = path.join(project, `${name}.json`);
  await run(["dump", "--quiet", "--jobs", String(jobs), slide, destination]);
  runs += 1;
  return JSON.parse(await readFile(destination, "utf8"));
}

async function run(args) {
  try {
    return await exec(ssBin, args, { cwd: project, timeout: 60000, killSignal: "SIGKILL", maxBuffer: 8 * 1024 * 1024 });
  } catch (error) {
    throw new Error(`ss ${args.join(" ")} failed\n${error.stdout ?? ""}\n${error.stderr ?? ""}`, { cause: error });
  }
}
