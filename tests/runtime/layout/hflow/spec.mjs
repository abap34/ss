#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { root, ssBin, withLspClient } from "../../harness.mjs";
import { editorSnapshot } from "../../editor/support.mjs";

const outputRoot = path.join(root, ".ss-cache/tests/layout/hflow");
await mkdir(outputRoot, { recursive: true });
const output = await mkdtemp(path.join(outputRoot, "run-"));
const prelude = `import std:core/prelude as *
fn box(label: String, width: Number, height: Number) -> Object
  let item = new(label, "body", "text")
  ~ item.width == width
  ~ item.height == height
  return item
end
`;
const pair = `let a = place!(box("A", 240, 80))
let b = place!(box("B", 120, 60))
a // b`;
let count = 0;

for (const policy of ["left", "center", "right"]) {
  const dump = await runCase(`pair-${policy}`, `page example
hflow(LayoutPolicy.${policy})
${pair}
~ a.left == page.left + 160
~ a.top == page.top - 80
end`);
  const a = node(dump, "A"), b = node(dump, "B");
  close(anchor(a, policy), anchor(b, policy), `${policy} sibling alignment`);
  close(b.y + b.height, a.y - 32, "vertical gap");
}

for (const [documentPolicy, pagePolicy, expected] of [
  [null, null, "left"], ["center", null, "center"],
  ["right", "left", "left"], ["left", "center", "center"],
]) {
  const dump = await runCase(`inherit-${documentPolicy}-${pagePolicy}`, `
${documentPolicy ? `document\nhflow_doc(LayoutPolicy.${documentPolicy})\nend` : ""}
page example
${pagePolicy ? `hflow(LayoutPolicy.${pagePolicy})` : ""}
${pair}
~ a.left == page.left + 160
end`);
  close(anchor(node(dump, "A"), expected), anchor(node(dump, "B"), expected), "inherited alignment");
  const page = dump.nodes.find(node => node.kind === "page");
  assert.equal(Object.hasOwn(page.fields, "layout_h"), pagePolicy != null);
}

for (const policy of ["left", "center", "right"]) {
  const dump = await runCase(`page-${policy}`, `page example
hflow(LayoutPolicy.${policy}, 25)
let a = place!(box("A", 120, 80))
let b = place!(box("B", 240, 60))
a // b
end`);
  const a = node(dump, "A"), b = node(dump, "B");
  close(anchor(a, policy), anchor(b, policy), "page alignment");
  const left = Math.min(a.x, b.x), right = Math.max(a.x + a.width, b.x + b.width);
  close(policy === "left" ? left : policy === "center" ? (left + right) / 2 : right,
    policy === "left" ? 96 : policy === "center" ? 665 : 1184, "page placement");
}

for (const policy of ["left", "center", "right"]) {
  const dump = await runCase(`cell-${policy}`, `page example
hflow(LayoutPolicy.${policy})
let a = place!(box("A", 240, 80))
let b = place!(box("B", 120, 60))
let c = place!(box("C", 160, 180))
let d = place!(box("D", 100, 40))
let column = a // b
let row = column |=| (c // d)
~ row.left == page.left + 80
~ row.top == page.top - 80
~ row.width == 1000
end`);
  const expected = policy === "left" ? 80 : policy === "center" ? 322 : 564;
  close(anchor(node(dump, "A"), policy), expected, "upper object in allocated column");
  close(anchor(node(dump, "B"), policy), expected, "lower object in allocated column");
}

for (const axisAnchor of ["left", "center_x", "right"]) {
  const dump = await runCase(`explicit-${axisAnchor}`, `page example
hflow(LayoutPolicy.center)
${pair}
~ a.left == page.left + 160
~ b.${axisAnchor} == page.left + 500
end`);
  close(anchor(node(dump, "B"), axisAnchor === "center_x" ? "center" : axisAnchor), 500, "explicit constraint priority");
  close(node(dump, "A").x, 160, "explicit source stayed fixed");
}

const updated = await runCase("update", `page example
hflow(LayoutPolicy.center)
${pair}
~ a.left == page.left + 160
~!~ b.right == a.right + 15
end`);
close(node(updated, "B").x + node(updated, "B").width, node(updated, "A").x + 255, "constraint update priority");

const pages = await runCase("page-overrides", `document
hflow_doc(LayoutPolicy.center, 40)
end
page inherited
let a = place!(box("Inherited", 120, 80))
end
page overridden
hflow(LayoutPolicy.left)
let b = place!(box("Overridden", 120, 80))
end
page reset_offset
hflow(LayoutPolicy.center)
let c = place!(box("Reset", 120, 80))
end
page inherited_again
let d = place!(box("Inherited again", 120, 80))
end`);
close(anchor(node(pages, "Inherited"), "center"), 680, "document center offset");
close(node(pages, "Overridden").x, 96, "page left override");
close(anchor(node(pages, "Reset"), "center"), 640, "page offset reset");
close(anchor(node(pages, "Inherited again"), "center"), 680, "page override did not leak");

const row = await runCase("horizontal-row", `page example
hflow(LayoutPolicy.center)
let a = place!(box("A", 120, 80))
let b = place!(box("B", 240, 60))
a || b
end`);
close(node(row, "B").x, node(row, "A").x + 152, "horizontal adjacency");
close((node(row, "A").x + node(row, "B").x + 240) / 2, 640, "complete row centered");

const fixedTarget = await runCase("fixed-lower", `page example
hflow(LayoutPolicy.center)
${pair}
~ b.left == page.left + 900
end`);
close(node(fixedTarget, "B").x, 900, "fixed lower operand");
close(anchor(node(fixedTarget, "A"), "center"), 640, "fixed target did not pull its source");

const manyStacks = await runCase("many-independent-stacks", `page example
hflow(LayoutPolicy.center)
${Array.from({ length: 12 }, (_, index) => `
let a${index} = place!(box("A${index}", 240, 80))
let b${index} = place!(box("B${index}", 120, 60))
a${index} // b${index}
~ a${index}.top == page.top - 80`).join("\n")}
end`);
for (let index = 0; index < 12; index++) {
  close(anchor(node(manyStacks, `A${index}`), "center"), 640, "independent stack placement");
  close(anchor(node(manyStacks, `B${index}`), "center"), 640, "independent stack alignment");
}

for (const operator of ["||", "|=|"]) {
  const dump = await runCase(operator === "||" ? "natural-columns" : "natural-equal-columns", `page example
hflow(LayoutPolicy.center)
let a = place!(box("A", 240, 80))
let b = place!(box("B", 120, 60))
let c = place!(box("C", 240, 180))
let d = place!(box("D", 100, 40))
(a // b) ${operator} (c // d)
end`);
  const a = node(dump, "A"), b = node(dump, "B"), c = node(dump, "C"), d = node(dump, "D");
  close(anchor(a, "center"), anchor(b, "center"), "natural left column alignment");
  close(anchor(c, "center"), anchor(d, "center"), "natural right column alignment");
  close(c.x, a.x + a.width + 32, "natural column gap");
  close((a.x + c.x + c.width) / 2, 640, "natural columns centered together");
}

const deleted = await runCase("deleted-alignment", `page example
hflow(LayoutPolicy.center)
${pair}
~ a.left == page.left + 160
~!~ b.center_x
end`);
assert(!deleted.constraints.some(constraint => constraint.default_alignment && constraint.target_node === node(deleted, "B").id), "deleted alignment was regenerated");

const code = "```ss\n" + 'let value = text!("Example line")\n'.repeat(12) + "```";
const naturalText = await runCase("natural-text-columns", `page example
hflow(LayoutPolicy.center)
let a = text!("A description above an illustration")
let b = place!(box("B", 160, 160))
let c = text! <<
${code}
>>
let d = text!("Example caption")
(a // b) |=| (c // d)
end`);
const description = node(naturalText, "A description above an illustration");
const illustration = node(naturalText, "B");
const codeBlock = node(naturalText, code);
const caption = node(naturalText, "Example caption");
close(anchor(description, "center"), anchor(illustration, "center"), "natural text and illustration alignment");
close(anchor(codeBlock, "center"), anchor(caption, "center"), "code and caption alignment");
assert(description.x + description.width <= codeBlock.x + 0.1, "natural columns overlapped");
for (const item of [description, illustration, codeBlock, caption]) {
  assert(item.x >= 95.9 && item.x + item.width <= 1184.1, "natural columns exceeded horizontal page margins");
}
assert(illustration.y >= 0 && caption.y >= 0, "natural columns extended below the page");

const editorSource = `${prelude}page example
hflow(LayoutPolicy.left)
${pair}
~ a.left == page.left + 160
end\n`;
const directory = await saveCase("editor", editorSource);
const uri = pathToFileURL(path.join(directory, "slide.ss")).href;
await withLspClient({ cwd: directory }, async (client) => {
  await client.initialize();
  for (const [index, policy] of ["left", "center", "right"].entries()) {
    const source = editorSource.replace("hflow(LayoutPolicy.left)", `hflow(LayoutPolicy.${policy})`);
    const diagnostics = client.waitForDiagnostics(uri);
    if (index === 0) client.openDocument({ uri, text: source });
    else client.changeDocument({ uri, text: source, version: index + 1 });
    assert.deepEqual((await diagnostics).params.diagnostics, []);
    const snapshot = await editorSnapshot(client, uri);
    const a = snapshot.layout.objects.find(object => object.id === snapshot.editing.find(target => target.binding === "a").node_id);
    const b = snapshot.layout.objects.find(object => object.id === snapshot.editing.find(target => target.binding === "b").node_id);
    close(anchor(a, policy), anchor(b, policy), "editor alignment after policy change");
  }
});
console.log(`horizontal flow: ${count} cases passed`);

function anchor(node, policy) {
  return node.x + (policy === "left" ? 0 : policy === "center" ? node.width / 2 : node.width);
}

function node(dump, label) {
  const result = dump.nodes.find(node => node.content === label);
  assert(result, `missing ${label}`);
  return result;
}

function close(actual, expected, label) {
  assert(Math.abs(actual - expected) < 0.1, `${label}: ${actual} != ${expected}`);
}

async function saveCase(name, source) {
  const directory = path.join(output, name);
  await mkdir(directory, { recursive: true });
  await writeFile(path.join(directory, "slide.ss"), source);
  await writeFile(path.join(directory, "ss.toml"), '[project]\nentry = "slide.ss"\n');
  count++;
  return directory;
}

async function runCase(name, source) {
  const directory = await saveCase(name, `${prelude}${source}\n`);
  await new Promise((resolve, reject) => {
    const child = spawn(ssBin, ["dump", "--quiet", "slide.ss", "dump.json"], { cwd: directory });
    let stderr = "";
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.stdout.resume();
    const timeout = setTimeout(() => child.kill("SIGKILL"), 30000);
    child.on("error", error => { clearTimeout(timeout); reject(error); });
    child.on("close", (code, signal) => {
      clearTimeout(timeout);
      if (code === 0) resolve();
      else reject(new Error(`${name}: ${signal || code}\n${stderr}`));
    });
  });
  const dump = JSON.parse(await readFile(path.join(directory, "dump.json"), "utf8"));
  assert(!dump.diagnostics.some(diagnostic => diagnostic.severity === "error"), JSON.stringify(dump.diagnostics));
  return dump;
}
