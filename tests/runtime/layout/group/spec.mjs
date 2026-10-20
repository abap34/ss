import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";

const scratch = path.join(root, ".ss-cache/tests/typed-group");
await mkdir(scratch, { recursive: true });
const output = await mkdtemp(path.join(scratch, "display-"));
const source = path.join(root, "tests/fixtures/typed-display/group.ss");
function run(...args) {
  const result = spawnSync(ssBin, args, { cwd: root, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
}
try {
  run("check", "--quiet", source);
  run("dump", "--quiet", source, "--output", path.join(output, "dump.json"));
  const dump = JSON.parse(await readFile(path.join(output, "dump.json"), "utf8"));
  assert.deepEqual(dump.diagnostics, []);
  assert.equal(dump.page_order.length, 2);
  const groups = dump.nodes.filter(node => node.placement?.input.kind === "group");
  assert.equal(groups.length, 2);
  assert.notEqual(groups[0].id, groups[1].id);
  for (const [index, group] of groups.entries()) {
    assert.equal(group.placement.display.state, "group");
    assert.deepEqual(group.placement.input.type.arguments.map(type => type.name), ["Text", "Code"]);
    assert.deepEqual(group.placement.input.children.map(value => value.type.name), ["Text", "Code"]);
    assert.equal(group.placement.page, dump.page_order[index]);
    assert.equal(group.placement.children.length, 2);
    const [title, code] = group.placement.children.map(id => dump.nodes.find(node => node.id === id));
    for (const child of [title, code]) {
      assert.equal(child.placement.parent, group.id);
      assert.equal(child.placement.page, group.placement.page);
      assert.equal(child.x, 64);
      assert(child.width > 0 && child.height > 0);
    }
    assert(title.y > code.y + code.height);
    assert.equal(group.x, 64);
    assert(group.height >= title.height + 40 + code.height - 0.1);
    assert.equal(code.content, groups[0].placement.input.children[1].fields.find(field => field.name === "source").value.value);
  }
  run("render", "--quiet", source, "--output", path.join(output, "slides.pdf"));
  assert.equal((await readFile(path.join(output, "slides.pdf"))).subarray(0, 5).toString(), "%PDF-");
} finally {
  await rm(output, { recursive: true, force: true });
}
