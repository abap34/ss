import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { root, ssBin, withLspClient } from "../../harness.mjs";

const scratch = path.join(root, ".test-tmp", "practical-references");
await mkdir(scratch, { recursive: true });
const cwd = await mkdtemp(path.join(scratch, "run-"));
const fixture = path.join(root, "tests/fixtures/runtime/document/references/practical");
let checked = 0;

function run(args, expectedError) {
  const result = spawnSync(ssBin, args, { cwd, encoding: "utf8", timeout: 30000 });
  assert.ifError(result.error);
  if (expectedError) {
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, new RegExp(expectedError));
    assert.doesNotMatch(result.stderr, /UnscheduledPlacementReference|panic:|Segmentation fault/);
  } else assert.equal(result.status, 0, result.stderr);
  return result;
}

async function dump(input) {
  run(["dump", "--quiet", input, "--output", "dump.json"]);
  const value = JSON.parse(await readFile(path.join(cwd, "dump.json"), "utf8"));
  assert.deepEqual(value.diagnostics, []);
  checked += 1;
  return value;
}

function texts(value) {
  return value.nodes.filter(n => n.placement?.display.kind === "text");
}

async function source(name, value) {
  const file = path.join(cwd, name + ".ss");
  await writeFile(file, value);
  return file;
}

function shuffle(values, seed) {
  const result = [...values];
  let state = seed;
  for (let i = result.length - 1; i > 0; i -= 1) {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    const j = state % (i + 1);
    [result[i], result[j]] = [result[j], result[i]];
  }
  return result;
}

try {
  await cp(fixture, cwd, { recursive: true });
  const slide = path.join(cwd, "slide.ss");
  const deck = await dump(slide);
  assert.equal(deck.page_order.length, 6);
  const placed = texts(deck);
  for (const [content, size, page] of [
    ["Method -> Result / 3", 17, 1], ["Result -> Method / 2", 29, 2],
    ["Overview note", 11, 0],
    ...[1, 2, 3].flatMap(stage => [
      [`First ${stage} -> Second ${stage} / ${stage + 3}`, 17 + stage, stage + 2],
      [`Second ${stage} -> First ${stage} / ${stage + 3}`, 17 + stage, stage + 2],
    ]),
  ]) {
    const text = placed.find(n => n.content === content);
    assert(text, content);
    assert.equal(text.render.text.font_size, size, content);
    assert.equal(text.placement.page, deck.page_order[page], content);
  }
  assert.deepEqual(placed.filter(n => n.content === "Repeated").map(n => n.render.text.font_size), [17, 29]);
  assert(placed.some(n => n.content === "Method, Result, First 1, Second 1, First 2, Second 2, First 3, Second 3"));
  run(["render", "--quiet", slide, "--output", "deck.pdf"]);
  assert.equal((await readFile(path.join(cwd, "deck.pdf"))).subarray(0, 5).toString(), "%PDF-");
  if (spawnSync("pdftotext", ["-v"], { timeout: 5000 }).status === 0) {
    const pdf = spawnSync("pdftotext", ["deck.pdf", "-"], { cwd, encoding: "utf8", timeout: 15000 });
    assert.ifError(pdf.error);
    assert.equal(pdf.status, 0, pdf.stderr);
    const content = pdf.stdout.replace(/\s+/g, " ");
    for (const label of ["Method -> Result / 3", "Result -> Method / 2", "First 3 -> Second 3 / 6"])
      assert(content.includes(label), label);
  }

  // Every permutation describes the same value dependencies. Lexical locals
  // inside helpers are intentionally unchanged.
  const helpers = `type Box<T> { value: T }
fn id<T>(value: T) -> T = value
fn apply(f: () -> String) -> String = f()
fn label(r: Ref<Placed<Text>>) -> String = (*r).value.content.source
fn choose<T>(flag: Bool, a: T, b: T) -> T
  if flag
    return a
  end
  return b
end`;
  const declarations = [
    'let a = id(text!("A"))',
    'let b = id(text!("B" ++ label(&a)))',
    'let c = id(text!("C" ++ apply(() |-> label(&b))))',
    'let d = id(text!("D" ++ label(Box { value = &b }.value)))',
    'let e = id(text!("E" ++ label(choose(true, &c, &f))))',
    'let f = id(text!("F" ++ label(&e)))',
    'let g = id(text!("G" ++ label(&d) ++ label(&e)))',
  ];
  const expected = ["A", "BA", "CBA", "DBA", "ECBA", "FECBA", "GDBAECBA"].sort();
  for (let seed = 1; seed <= 16; seed += 1) {
    const input = await source("permutation", [helpers, "page main", ...shuffle(declarations, seed), "end"].join("\n"));
    assert.deepEqual(texts(await dump(input)).map(n => n.content).sort(), expected, `permutation ${seed}`);
  }

  // One display input is reused on two pages. Its captured reference and the
  // active page theme must both remain dependencies of each expansion.
  const reused = await source("reused", `type Label { content: () -> String }
fn display(self: Placed<Label>) -> Text = text(self.value.content())
const shared: Label = Label { content = () |-> (*&target::title).value.content.source }
page first
  place!(shared)
  place!(shared)
  theme!(Theme {} with { text.size = 13 })
end
page second
  place!(shared)
  theme!(Theme {} with { text.size = 31 })
end
page target
  let title = text!("Captured target")
end`);
  const reusedDump = await dump(reused);
  const reusedText = texts(reusedDump).filter(n => n.content === "Captured target");
  assert.equal(reusedText.length, 4);
  for (const [page, sizes] of [[0, [13, 13]], [1, [31]]]) {
    assert.deepEqual(reusedText.filter(n => n.placement.page === reusedDump.page_order[page]).map(n => n.render.text.font_size), sizes);
  }

  // Included page declarations share the module's reference namespace.
  await source("body", 'page included\n  let target = text!("Included")\nend\n');
  const included = await source("included", `${helpers}
page main
  text!("Read " ++ label(&included::target))
end
include "body.ss"`);
  assert(texts(await dump(included)).some(n => n.content === "Read Included"));

  const documentBlocks = await source("document-blocks", `${helpers}
document
  let p = new_page(docctx(), "Generated")
  let a = place_on!(p, text("Read " ++ label(&b)))
end
document
  let b = place_on!(p, text("Later block"))
end`);
  assert.deepEqual(texts(await dump(documentBlocks)).map(n => n.content).sort(), ["Later block", "Read Later block"]);

  for (const [name, code, diagnostic] of [
    ["type-cycle", "let a = *&b\nlet b = *&a", "ReferenceNeedsType"],
    ["value-cycle", "let a: Placed<Text> = *&b\nlet b = *&a", "ExecutionDependencyCycle"],
    ["missing-target", "let r = &missing", "InvalidReferenceTarget"],
  ]) {
    run(["dump", "--quiet", await source(name, "page main\n" + code + "\nend")], diagnostic);
    checked += 1;
  }

  // Recover both semantic facts and editor preview after changing a referenced
  // binding's type, temporarily deleting it, and repairing the same document.
  const editing = body => `${helpers}\npage main\n  text!(label(&target))\n  ${body}\nend`;
  const valid = editing('let target = id(text!("Before"))');
  const editorProject = path.join(cwd, "editor");
  await mkdir(editorProject);
  const editingPath = path.join(editorProject, "slide.ss");
  await writeFile(editingPath, valid);
  const uri = pathToFileURL(editingPath).href;
  await withLspClient({ cwd: editorProject }, async client => {
    await client.initialize();
    const opened = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: valid, version: 1 });
    assert.deepEqual((await opened).params.diagnostics, []);
    const initial = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert.equal(initial.layout.pages.length, 1);
    assert(initial.display.html.includes("Before"));
    let version = 1;
    for (const [body, diagnostic] of [
      ["let target = 1", "InvalidReferenceTarget"],
      ["", "InvalidReferenceTarget"],
      ['let target = id(text!("After"))', null],
    ]) {
      version += 1;
      const pending = client.waitForDiagnostics(uri, (items, message) =>
        message.params.version === version && (!diagnostic || items.some(d => d.code === diagnostic || d.message.includes(diagnostic))));
      client.changeDocument({ uri, text: editing(body), version });
      const diagnostics = (await pending).params.diagnostics;
      if (diagnostic) assert(diagnostics.some(d => d.code === diagnostic || d.message.includes(diagnostic)), JSON.stringify(diagnostics));
      else assert.deepEqual(diagnostics, []);
    }
    const repaired = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert.equal(repaired.layout.pages.length, 1);
    assert(!repaired.stale);
    assert(repaired.generation > initial.generation);
    assert(repaired.display.html.includes("After"));
    assert(!repaired.display.html.includes("Before"));
    assert.doesNotMatch(client.stderr, /UnscheduledPlacementReference|panic:|Segmentation fault/);
  });
  console.log(`Practical references: ${checked} documents, PDF output, and editor recovery passed`);
} finally {
  await rm(cwd, { recursive: true, force: true });
}
