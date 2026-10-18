import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";

const scratch = path.join(root, ".ss-cache/tests/typed-composition");
await mkdir(scratch, { recursive: true });
const output = await mkdtemp(path.join(scratch, "display-"));
const source = path.join(root, "tests/fixtures/typed-display/composition.ss");
function run(...args) {
  const result = spawnSync(ssBin, args, { cwd: root, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
}
const close = (a, b) => assert(Math.abs(a - b) < 0.1, `${a} != ${b}`);
try {
  run("check", "--quiet", source);
  run("dump", "--quiet", source, "--output", path.join(output, "dump.json"));
  const dump = JSON.parse(await readFile(path.join(output, "dump.json"), "utf8"));
  assert.deepEqual(dump.diagnostics, []);
  assert.equal(dump.page_order.length, 6);
  const byId = id => dump.nodes.find(node => node.id === id);
  const groups = dump.page_order.map(page => dump.nodes.find(node => node.placement?.page === page && node.placement.input.kind === "group" && node.placement.parent === page));
  assert(groups.every(Boolean));
  const children = item => item.placement.children.map(byId);
  for (const group of groups) {
    assert(!Object.hasOwn(group, "role"));
    close(group.x, 80);
    close(group.y + group.height, 640);
    for (const child of children(group)) {
      assert.equal(child.placement.page, group.placement.page);
      assert.equal(child.placement.parent, group.id);
    }
  }
  const [row, column, equalRow, equalColumn, nested, reused] = groups;
  assert.deepEqual(groups.map(node => node.placement.input.composition), ["horizontal", "vertical", "equal_horizontal", "equal_vertical", "equal_horizontal", "horizontal"]);
  close(children(row)[1].x - children(row)[0].x - children(row)[0].width, 48);
  close(children(column)[0].y - children(column)[1].y - children(column)[1].height, 24);
  assert.equal(children(equalRow).length, 3);
  for (const child of children(equalRow)) close(child.width, 284);
  for (const child of children(equalColumn)) close(child.height, 138);
  for (const child of children(nested)) close(child.width, 430);
  close(children(reused)[1].x - children(reused)[0].x - children(reused)[0].width, 96);
  assert.equal(row.placement.input.gap, 48);
  assert.equal(children(nested)[0].placement.input.gap, 48);
  assert.equal(reused.placement.input.gap, 96);
  assert.notEqual(children(row)[0].id, children(children(nested)[0])[0].id);
  assert.notEqual(children(row)[0].id, children(reused)[0].id);
  run("render", "--quiet", source, "--output", path.join(output, "slides.pdf"));
  assert.equal((await readFile(path.join(output, "slides.pdf"))).subarray(0, 5).toString(), "%PDF-");
} finally {
  await rm(output, { recursive: true, force: true });
}
