import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";

const scratch = path.join(root, ".ss-cache/tests/placed-composition");
await mkdir(scratch, { recursive: true });
const output = await mkdtemp(path.join(scratch, "case-"));
const source = path.join(root, "tests/fixtures/typed-display/placed-composition.ss");
function run(args, expected = 0) {
  const result = spawnSync(ssBin, args, { cwd: root, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  assert.equal(result.status, expected, result.stderr);
  return result.stderr + result.stdout;
}
const close = (actual, expected) => assert(Math.abs(actual - expected) < 0.1, `${actual} != ${expected}`);
try {
  run(["check", "--quiet", source]);
  const json = path.join(output, "dump.json");
  run(["dump", "--quiet", source, "--output", json]);
  const dump = JSON.parse(await readFile(json, "utf8"));
  assert.deepEqual(dump.diagnostics, []);
  const byId = id => dump.nodes.find(node => node.id === id);
  const children = node => node.placement.children.map(byId);
  const pageNodes = index => dump.nodes.filter(node => node.placement?.page === dump.page_order[index]);
  const rootGroup = index => pageNodes(index).find(node => node.placement.input.kind === "group" && node.placement.parent === dump.page_order[index]);
  const text = content => dump.nodes.find(node => node.content === content);
  const direct = rootGroup(0);
  assert.equal(pageNodes(0).length, 3, "grouping copied its existing children");
  close(direct.width, 664);
  close(direct.x, 80);
  for (const child of children(direct)) close(child.width, 320);
  close(children(direct)[1].x - children(direct)[0].x - 320, 24);
  const natural = rootGroup(1);
  close(children(natural)[1].x - children(natural)[0].x - 320, 48);
  const selected = rootGroup(2);
  assert.equal(children(selected).length, 2);
  assert.equal(children(selected)[0].id, text("Selected A").id);
  close(text("Selected A").width, 160);
  const ordered = rootGroup(3);
  assert.deepEqual(children(ordered).map(node => node.content), ["Paint B", "Paint A"]);
  close(text("Paint B").width, 180);
  close(text("Paint A").width, 140);
  close(text("Title").width, 240);
  const nested = rootGroup(5);
  assert.equal(children(nested).length, 2);
  assert.equal(children(children(nested)[0]).length, 2);
  const flat = rootGroup(6);
  assert.equal(children(flat).length, 3);
  assert.equal(pageNodes(6).length, 4);
  for (const child of children(flat)) close(child.width, (900 - 64) / 3);
  assert.equal(pageNodes(7).length, 2);
  const report = pageNodes(8).find(node => node.placement.parent === dump.page_order[8] && node.placement.input.kind === "record");
  assert.equal(report.content, "1", "generic adoption was missing from a preceding typed query");
  for (const child of children(rootGroup(9))) close(child.height, 184);
  const vertical = children(rootGroup(10));
  close(vertical[0].y - vertical[1].y - vertical[1].height, 48);

  run(["render", "--quiet", source, "--output", path.join(output, "placed.pdf")]);
  assert.equal((await readFile(path.join(output, "placed.pdf"))).subarray(0, 5).toString(), "%PDF-");
  const html = path.join(output, "placed.html");
  run(["render", "--quiet", source, "--format", "html", "--output", html]);
  const manifest = await readFile(html, "utf8");
  assert(manifest.length > 0);
  const orderedPage = [...manifest.matchAll(/<section class="ss-page"[^]*?<\/section>/g)][3][0];
  const paint = orderedPage.split('<div class="ss-semantic-layer">')[0];
  const painted = [...new Set([...paint.matchAll(/data-ss-node-id="(\d+)"/g)].map(match => Number(match[1])))];
  assert.deepEqual(painted, [text("Decoration").id, text("Paint B").id, text("Paint A").id]);

  for (const [name, body, code] of [
    ["duplicate", 'let a = text!("A")\nlet g = group!(a, a)', "DuplicateGroupChild"],
    ["alias", 'let a = text!("A")\nlet alias = a\nlet g = a || alias', "DuplicateGroupChild"],
    ["parent", 'let a = text!("A")\nlet g = a || text!("B")\nlet h = group!(a)', "DuplicatePlacementParent"],
    ["mixed", 'let g = text!("A") || text("B")', "InvalidGroupInput"],
    ["effect", 'let a = text!("A")\nlet g = pure(a)', "PlacementEffect"],
    ["operator-effect", 'let a = text!("A")\nlet g = pure(a)', "PlacementEffect"],
    ["gap", 'let g = text!("A") || text!("B")\ng.layout.gap = 24\ng.layout.gap = 32', "DuplicatePropertyDefinition"],
    ["negative-gap", 'let g = text!("A") || text!("B")\ng.layout.gap = -1', "InvalidGroupSplit"],
    ["conflict", 'let g = label!("A") |=| label!("B")\n~ g.width == 900', "ConstraintConflict"],
    ["display", 'let a = place!(Impure {})', "ImpureDisplayFunction"],
    ["operator-display", 'let a = place!(Impure {})', "ImpureDisplayFunction"],
    ["collection-cycle", 'let g = group!(select<Group>(pagectx()))', "ExecutionDependencyCycle"],
  ]) {
    const file = path.join(output, `${name}.ss`);
    const helper = name.endsWith("effect") ? `fn pure(a: Placed<Text>) -> Placed<Group>\nreturn ${name === "effect" ? "group!(a)" : "a || a"}\nend\n` : name.endsWith("display") ? `type Impure {}\nfn display(self: Placed<Impure>) -> Text\nlet g = ${name === "display" ? "group!(self)" : "self || self"}\nreturn text("Invalid")\nend\n` : '';
    await writeFile(file, `fn label!(s: String) -> Placed<Text>\nlet a = text!(s)\n~ a.width == 320\nreturn a\nend\n${helper}page test\n${body}\nend\n`);
    const result = run(["check", "--quiet", file], 1);
    assert(result.includes(code), `${name}: missing ${code}: ${result}`);
  }
} finally {
  await rm(output, { recursive: true, force: true });
}
