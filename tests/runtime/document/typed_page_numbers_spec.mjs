import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../harness.mjs";

const scratch = path.join(root, ".ss-cache/tests/typed-document");
await mkdir(scratch, { recursive: true });
const output = await mkdtemp(path.join(scratch, "pages-"));
const source = path.join(root, "tests/fixtures/typed-document/slide.ss");

function run(...args) {
  const result = spawnSync(ssBin, args, { cwd: root, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
}

try {
  run("check", "--quiet", source);
  run("dump", "--quiet", source, "--output", path.join(output, "dump.json"));
  const dump = JSON.parse(await readFile(path.join(output, "dump.json"), "utf8"));
  assert.equal(dump.page_order.length, 4);
  assert.deepEqual(dump.diagnostics, []);
  const placed = dump.nodes.filter(node => node.placement);
  const byType = name => placed.filter(node => node.placement.input.type.name === name);
  const numbers = byType("PageNumber");
  assert.equal(numbers.length, 3);
  assert.deepEqual(numbers.map(node => node.placement.page), dump.page_order.slice(1));
  for (const [index, number] of numbers.entries()) {
    const text = dump.nodes.find(node => node.id === number.placement.children[0]);
    assert.equal(text.content, `${index + 1}/3`);
    assert.equal(text.placement.page, number.placement.page);
    assert.equal(number.y, 28);
    assert(Math.abs(number.x + number.width - 1216) < 0.01);
    assert.equal(number.role, null);
    assert.equal(number.placement.display.state, "expanded");
  }
  const contents = byType("Contents");
  assert.equal(contents.length, 1);
  const contentsText = dump.nodes.find(node => node.id === contents[0].placement.children[0]);
  assert.equal(contentsText.content, "- From source data to a slide ... 2\n- Reuse one definition across pages ... 3");
  assert.equal(byType("Section").length, 2);
  assert(placed.some(node => node.content === "See the architecture on page 2."));
  assert.equal(byType("Image").length, 1);
  assert.equal(byType("Code").length, 1);
  assert.equal(dump.nodes.filter(node => node.kind === "object").length, placed.length);
  for (const node of placed) assert.equal(node.role, null);
  run("render", "--quiet", source, "--output", path.join(output, "slides.pdf"));
  assert.equal((await readFile(path.join(output, "slides.pdf"))).subarray(0, 5).toString(), "%PDF-");
} finally {
  await rm(output, { recursive: true, force: true });
}
