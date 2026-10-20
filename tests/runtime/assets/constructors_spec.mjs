import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../harness.mjs";
import { pdfAsset } from "../../support/assets/pdf.mjs";

const scratch = path.join(root, ".ss-cache/tests/asset-constructors");
await mkdir(scratch, { recursive: true });
const project = await mkdtemp(path.join(scratch, "api-"));
function run(...args) {
  const result = spawnSync(ssBin, args, { cwd: project, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  return result;
}
function success(...args) {
  const result = run(...args);
  assert.equal(result.status, 0, result.stderr);
}
const close = (a, b) => assert(Math.abs(a - b) < 0.1, `${a} != ${b}`);
const field = (record, name) => record.fields.find(item => item.name === name).value;
function assertTint(node, rgb) {
  const tint = field(field(field(node.placement.input, "style"), "asset"), "tint").value;
  const channels = tint.split(",").map(Number);
  assert.equal(channels.length, 3);
  channels.forEach((channel, index) => assert(Math.abs(channel - rgb[index] / 255) < 0.0001));
}
try {
  await writeFile(path.join(project, "asset.svg"), '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60"><rect width="120" height="60" fill="#2563eb"/></svg>');
  await writeFile(path.join(project, "asset.pdf"), pdfAsset());
  await writeFile(path.join(project, "unused.ss"), `import std:assets as a
const missing_image: a::Image = a::image("missing.svg")
const missing_pdf: a::Pdf = a::pdf("missing.pdf")
const unknown_icon: a::Icon = a::icon("fa-solid:not-a-real-icon")
page empty
end
`);
  success("dump", "--quiet", "unused.ss", "--output", "unused.json");
  const unused = JSON.parse(await readFile(path.join(project, "unused.json"), "utf8"));
  assert.deepEqual(unused.diagnostics, []);
  assert(!unused.nodes.some(node => node.kind === "object"));

  for (const [type, name, input, width, height] of [
    ["Image", "image", "asset.svg", 120, 60],
    ["Pdf", "pdf", "asset.pdf", 240, 120],
    ["Icon", "icon", "fa-solid:star", 72, 72],
  ]) {
    const source = `import std:assets as a
const value: a::${type} = a::${name}("${input}")
fn duplicate<T>(item: T) -> Group<T, T> = item || item
type Wrapped { source: String }
fn display(self: Placed<Wrapped>) -> a::${type} = a::${name}(self.value.source)
page first
  let count = selection_count(select<a::${type}>(pagectx()))
  let direct: Placed<a::${type}> = a::${name}!("${input}")
  let changed = place!(value with { style.asset.scale = 0.5 })
  ~ direct.left == page.left + count * 32
  ~ direct.top == page.top - 64
  ~ changed.left == direct.right + 32
  ~ changed.top == direct.top
end
page reuse
  let pair = place!(duplicate(value))
  ~ pair.left == page.left + 64
  ~ pair.top == page.top - 64
end
page wrapped
  let custom = place!(Wrapped { source = "${input}" })
  ~ custom.left == page.left + 64
  ~ custom.top == page.top - 64
end
`;
    await writeFile(path.join(project, "slide.ss"), source);
    success("check", "--quiet", "slide.ss");
    success("dump", "--quiet", "slide.ss", "--output", "dump.json");
    const dump = JSON.parse(await readFile(path.join(project, "dump.json"), "utf8"));
    assert.deepEqual(dump.diagnostics, []);
    const nodes = dump.nodes.filter(node => node.placement?.input.type?.name === type);
    assert.equal(nodes.length, 5);
    assert.equal(new Set(nodes.map(node => node.id)).size, 5);
    close(nodes[0].x, 64);
    for (const [index, node] of nodes.entries()) {
      const scale = index === 1 ? 0.5 : 1;
      close(node.width, width * scale);
      close(node.height, height * scale);
      assert.deepEqual(node.fields, {});
      assert.equal(node.content, input);
      assert.equal(node.placement.display.kind, name);
      if (index > 1) assert.deepEqual(node.placement.input, nodes[0].placement.input);
    }
    if (name === "icon") assertTint(nodes[0], [55, 65, 81]);
    success("render", "--quiet", "slide.ss", "--output", `${name}.pdf`);
    assert.equal((await readFile(path.join(project, `${name}.pdf`))).subarray(0, 5).toString(), "%PDF-");
    success("render", "--quiet", "--format", "html", "slide.ss", "--output", `${name}.html`);

    await writeFile(path.join(project, "invalid.ss"), source.replaceAll(input, name === "icon" ? "fa-solid:absent-icon" : "missing.asset"));
    const invalid = run("check", "--quiet", "invalid.ss");
    assert.notEqual(invalid.status, 0);
    assert.match(invalid.stderr, name === "icon" ? /InvalidFontAwesomeIcon/ : /AssetNotFound/);
    assert.match(invalid.stderr, /invalid\.ss:/);
    assert.doesNotMatch(invalid.stderr, /BuildFailed|unexpected failure/);
  }

  await writeFile(path.join(project, "options.ss"), `import std:assets as a
page options
  let sheet = a::pdf!("asset.pdf", a::AssetBlockStyle {} with { asset.pdf_page = 2 asset.pdf_box = a::PdfPageBox.media asset.scale = 0.5 })
  let symbol = a::icon!("fa-solid:heart", a::AssetBlockStyle {} with { asset.tint = c"#2563eb" })
  ~ sheet.left == page.left + 64
  ~ sheet.top == page.top - 64
  ~ symbol.left == sheet.right + 32
  ~ symbol.top == sheet.top
  ~ symbol.width == 40
  ~ symbol.height == 80
end
`);
  success("dump", "--quiet", "options.ss", "--output", "options.json");
  const options = JSON.parse(await readFile(path.join(project, "options.json"), "utf8"));
  assert.deepEqual(options.diagnostics, []);
  const sheet = options.nodes.find(node => node.placement?.display.kind === "pdf");
  close(sheet.width, 75);
  close(sheet.height, 150);
  const symbol = options.nodes.find(node => node.placement?.display.kind === "icon");
  close(symbol.width, 40);
  close(symbol.height, 80);
  assertTint(symbol, [37, 99, 235]);
} finally {
  await rm(project, { recursive: true, force: true });
}
