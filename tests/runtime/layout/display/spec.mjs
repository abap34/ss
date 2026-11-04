import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";
import { singlePagePdfAsset } from "../../../support/assets/pdf.mjs";

const scratch = path.join(root, ".test-tmp/layout/display");
await mkdir(scratch, { recursive: true });
const output = await mkdtemp(path.join(scratch, "run-"));
const tolerance = 0.1;
const close = (actual, expected, message) => assert(Math.abs(actual - expected) < tolerance, `${message}: ${actual} != ${expected}`);
const top = node => node.y + node.height;
function run(...args) {
  const result = spawnSync(ssBin, args, { cwd: output, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
}
async function dumpSource(name, source) {
  await writeFile(path.join(output, `${name}.ss`), source);
  run("check", "--quiet", `${name}.ss`);
  run("dump", "--quiet", `${name}.ss`, "--output", `${name}.json`);
  const dump = JSON.parse(await readFile(path.join(output, `${name}.json`), "utf8"));
  return dump;
}
function children(dump, node) {
  return node.placement.children.map(id => dump.nodes.find(item => item.id === id));
}
function leaves(dump, node) {
  return node.placement.children.length ? children(dump, node).flatMap(child => leaves(dump, child)) : [node];
}
function roots(dump, page) {
  return dump.nodes.filter(node => node.placement?.page === page && node.placement.parent === page);
}
function checkFlow(before, group, after, policy, label) {
  close(before.y - top(group), 32, `${label}: preceding text reserves the row height`);
  close(group.y - top(after), 24, `${label}: following text starts below the row`);
  if (policy === "center") close((top(before) + after.y) / 2, 360, `${label}: body is centered`);
}

let passed = false;
try {
  await writeFile(path.join(output, "list.pdf"), singlePagePdfAsset(654, 361));
  await writeFile(path.join(output, "code.pdf"), singlePagePdfAsset(500, 229));
  const fixture = await readFile(path.join(root, "tests/fixtures/layout/display/slide.ss"), "utf8");
  const pages = await dumpSource("pages", fixture);
  assert.deepEqual(pages.diagnostics, []);
  assert.equal(pages.page_order.length, 2);
  for (const [index, page] of pages.page_order.entries()) {
    const [header, intro, row] = roots(pages, page);
    assert.equal(row.placement.input.composition, "equal_horizontal");
    close(row.width, 1088, "row width");
    close(intro.y - top(row), 28, "intro is above the two columns");
    assert(top(intro) <= header.y + tolerance, "body overlaps the fixed header");
    close((top(intro) + row.y) / 2, 360, "intro and row share vertical centering");
    const [text, pdf] = children(pages, row);
    const [image] = children(pages, pdf);
    assert.equal(pdf.placement.input.type.name, "Pdf");
    assert.equal(image.placement.display.kind, "image");
    close(text.width, 528, "text column width");
    close(pdf.width, 528, "PDF column width");
    close(pdf.x - text.x - text.width, 32, "column gap");
    close(image.height, index === 0 ? 361 * 0.75 + 20 : 229 + 20, "PDF keeps its content height and padding");
    close(pdf.height, image.height, "display expansion shares the returned height");
    close(row.height, Math.max(text.height, image.height), "row height fits the taller column");
    close(text.y + text.height / 2, image.y + image.height / 2, "columns follow centered alignment");
    for (const node of leaves(pages, row)) {
      assert(node.y >= 0 && top(node) <= 720, "column extends outside the page");
    }
  }
  run("render", "--quiet", "pages.ss", "--output", "pages.pdf");
  run("render", "--quiet", "pages.ss", "--format", "html", "--output", "pages.html");
  const html = await readFile(path.join(output, "pages.html"), "utf8");
  const tags = html.match(/<[^>]*data-ss-node-id="\d+"[^>]*>/g) ?? [];
  for (const node of pages.nodes.filter(node => node.placement?.display.kind === "image")) {
    const box = tags.find(tag => tag.includes(`data-ss-node-id="${node.id}"`) && tag.includes("ss-box"));
    assert(box, "PDF frame is missing in HTML output");
    const renderedTop = Number(box.match(/(?:;|")top:([\d.-]+)pt/)?.[1]);
    close(renderedTop, 720 - top(node), "HTML PDF frame follows the solved position");
  }

  // Compare ordinary values with one or several display expansions. Actual
  // Group returns must keep group allocation; leaf returns keep leaf alignment.
  const prelude = `import std:prelude as *
type Wrapper<T> { content: T }
fn wrap<T>(content: T) -> Wrapper<T> = Wrapper<T> { content = content }
fn display<T>(self: Placed<Wrapper<T>>) -> T = self.value.content
`;
  const cases = [];
  const variants = [
    ["text", 'text("Words in a wrapped label. More words wrap inside the column.")'],
    ["image", 'Image { source = ImageSource { kind = ImageSourceKind.pdf source = "code.pdf" } }'],
    ["shape", 'rectangle(180, 120)'],
    ["group", 'text("First child") // text("Second child")'],
    ["equal-group", 'text("First child") |=| text("Second child")'],
  ];
  let source = prelude;
  for (const policy of ["center", "top"]) for (const operator of ["||", "//", "|=|", "/=/"]) {
    for (const [kind, value] of variants) {
      const name = `${policy}-${operator}-${kind}`;
      const guide = kind.includes("group") ? "The guide contains enough words to be taller than either short child in the neighboring group. ".repeat(2) : "Guide";
      cases.push({ name, policy });
      for (const depth of [0, 1, 3]) {
        let expression = `(${value})`;
        for (let layer = 0; layer < depth; layer++) expression = `wrap(${expression})`;
        source += `page _
vflow(LayoutPolicy.${policy})
text!("Before row")
let row = place!(text(${JSON.stringify(guide)}) ${operator} ${expression})
~ row.width == 1000
text!("After row")
end
`;
      }
    }
  }
  const matrix = await dumpSource("matrix", source);
  for (const [index, { name, policy }] of cases.entries()) {
    let expected;
    for (let variant = 0; variant < 3; variant++) {
      const page = matrix.page_order[index * 3 + variant];
      const [before, row, after] = roots(matrix, page);
      checkFlow(before, row, after, policy, `${name}, variant ${variant}`);
      const frames = [before, row, after, ...leaves(matrix, row)].map(node => [node.x, node.y, node.width, node.height]);
      if (!expected) expected = frames;
      else for (const [i, frame] of frames.entries()) for (let axis = 0; axis < 4; axis++) {
        close(frame[axis], expected[i][axis], `${name}: display depth ${variant} changed frame ${i}, axis ${axis}`);
      }
    }
  }
  assert.deepEqual(matrix.diagnostics, []);

  for (const depth of [0, 1, 3]) {
    let value = 'text("Second child") // text("Third child")';
    let assetValue = 'pdf("code.pdf")';
    for (let layer = 0; layer < depth; layer++) value = `wrap(${value})`;
    for (let layer = 0; layer < depth; layer++) assetValue = `wrap(${assetValue})`;
    const updates = await dumpSource(`updates-${depth}`, `${prelude}
page _
text!("Before row")
let row = place!(text("Guide") |=| (${value}))
~ row.width == 1000
let items = select<Text>(row)
let a = first(items)
let b = first(items - selection(a))
let c = first(items - selection(a) - selection(b))
~!~ c.top == b.bottom - 80
text!("After row")
end
page _
text!("Before row")
let row = place!(text("Guide") |=| ${assetValue})
let asset = first(select<Pdf>(row))
~ asset.height == 120
text!("After row")
end
page _
text!("Before row")
let row = place!(text("Guide") /=/ ${assetValue})
~ row.width == 1000
~ row.height == 300
text!("After row")
end
`);
    assert.deepEqual(updates.diagnostics, []);
    const [before, row, after] = roots(updates, updates.page_order[0]);
    const [, b, c] = leaves(updates, row);
    close(b.y - top(c), 80, "nested constraint update survives display expansion");
    close(row.height, b.height + c.height + 80, "updated child spacing determines row height");
    checkFlow(before, row, after, "center", "updated nested group");
    for (const [index, height] of [[1, 120], [2, 134]]) {
      const [before, row, after] = roots(updates, updates.page_order[index]);
      const [, image] = leaves(updates, row);
      close(image.height, height, "explicit and equal-cell heights reach the returned image");
      checkFlow(before, row, after, "center", "allocated PDF height");
    }
  }
  console.log(`display layout: 2 representative PDF pages, ${cases.length * 3} composition cases, and 9 constraint cases passed`);
  passed = true;
} finally {
  if (passed) await rm(output, { recursive: true, force: true });
  else console.error(`Failed display layout artifacts: ${output}`);
}
