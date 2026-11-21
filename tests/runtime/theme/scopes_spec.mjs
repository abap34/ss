import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../harness.mjs";
import { inputField } from "../../support/display.mjs";

const scratch = path.join(root, ".test-tmp/scoped-theme");
await mkdir(scratch, { recursive: true });
const cwd = await mkdtemp(path.join(scratch, "scopes-"));
const fixture = path.join(root, "tests/fixtures/runtime/theme/scopes/slide.ss");
function run(args, error) {
  const r = spawnSync(ssBin, args, { cwd, encoding: "utf8", timeout: 45000, killSignal: "SIGKILL" });
  assert.ifError(r.error);
  if (error) {
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, new RegExp(error));
    assert.doesNotMatch(r.stderr, /LoweringFailed|UnscheduledPlacementReference/);
  } else assert.equal(r.status, 0, r.stderr);
}
async function source(text) {
  await writeFile(path.join(cwd, "input.ss"), text);
  return "input.ss";
}
async function json(args) {
  run([...args, "--output", "result.json"]);
  return JSON.parse(await readFile(path.join(cwd, "result.json"), "utf8"));
}
function parent(graph, prefix, ordinal = 0) {
  const units = graph.units.filter(u => u.kind.endsWith("statement") && u.source.startsWith(prefix));
  assert(units[ordinal], prefix);
  return units[ordinal].id;
}
const display = (g, p) => g.units.find(u => u.kind === "display" && u.producer === p && u.display_step === 0).id;
const edge = (g, from, to) => g.edges.some(e => e.from === from && e.to === to);
const text = dump => dump.nodes.filter(n => n.placement?.display.kind === "text");
try {
  const dump = await json(["dump", "--quiet", fixture]);
  assert.deepEqual(dump.diagnostics, []);
  const sizes = label => text(dump).filter(n => n.content === label)
    .sort((a, b) => dump.page_order.indexOf(a.placement.page) - dump.page_order.indexOf(b.placement.page))
    .map(n => n.render[n.render.kind].font_size);
  assert.deepEqual(sizes("Shared"), [21, 35, 21]);
  assert.deepEqual(sizes("Badge"), [13, 19]);
  assert.deepEqual(sizes("Subsection"), [27, 39]);
  assert.deepEqual(sizes("Same unit"), [35]);
  assert.deepEqual(sizes("return 1"), [22]);
  assert.deepEqual(sizes("Explicit"), [12]);
  const shared = text(dump).filter(n => n.content === "Shared");
  assert(shared.every(n => inputField(n.placement.input, "style").kind === "none"));
  assert.deepEqual(shared[0].placement.input, shared[1].placement.input);
  assert(inputField(text(dump).find(n => n.content === "Explicit").placement.input, "style").kind === "record");
  const g = await json(["debug", "schedule", fixture]);
  const doc = parent(g, "appearance::theme!");
  const page = parent(g, "ui::setup!");
  assert(edge(g, doc, parent(g, "let large")));
  for (const [i, writer] of [doc, page, doc].entries()) {
    const construct = parent(g, "place!(shared)", i);
    assert(!edge(g, doc, construct) && !edge(g, page, construct));
    assert(edge(g, writer, display(g, construct)));
    assert(!edge(g, writer === doc ? page : doc, display(g, construct)));
  }
  const explicit = display(g, parent(g, 'text!("Explicit"'));
  assert(!edge(g, page, explicit) && !edge(g, doc, explicit));
  run(["render", "--quiet", fixture, "--output", "scopes.pdf"]);
  assert.equal((await readFile(path.join(cwd, "scopes.pdf"))).subarray(0, 5).toString(), "%PDF-");

  await copyFile(path.join(root, "src/cli/templates/components.ss"), path.join(cwd, "components.ss"));
  await writeFile(path.join(cwd, "theme.ss"), "fn footnote_style(t: Theme) -> TextBlockStyle = t.text\n");
  const components = 'import "./components" as { footnote! }\n';
  const nested = await source(components + `fn setup!(t: Theme) -> Void
  theme!(t)
  footnote!("Inside")
end
page local
  footnote!("Earlier in source")
  setup!(document_theme() with { text.size = 13 })
end
document
  theme!(Theme {} with { text.size = 9 })
end`);
  const nestedGraph = await json(["debug", "schedule", nested]);
  const chain = ["theme!(", "setup!(", "footnote!("].map(prefix => parent(nestedGraph, prefix));
  assert(edge(nestedGraph, chain[0], chain[1]) && edge(nestedGraph, chain[1], chain[2]));
  assert(!edge(nestedGraph, chain[1], chain[1]));
  assert.deepEqual(nestedGraph.execution_order.filter(id => chain.includes(id)), chain);
  const notes = text(await json(["dump", "--quiet", nested]));
  assert.deepEqual(notes.map(n => [n.content, n.render.text.font_size]).sort(),
    [["Earlier in source", 13], ["Inside", 13]]);

  // Only paths reaching the footnote need the definition. Callers must
  // include early returns when deciding whether the page overrides the document.
  for (const [otherwise, fallback] of [["return", true], ["theme!(Theme {} with { text.size = 17 })", false]]) {
    const input = await source(components + `fn choose!(flag: Bool) -> Void
  if flag
    theme!(Theme {} with { text.size = 13 })
  else
    ${otherwise}
  end
  footnote!("Inside")
end
page first
  choose!(page_index(pagectx()) == 1)
  footnote!("Outside first")
end
page second
  choose!(page_index(pagectx()) == 1)
  footnote!("Outside second")
end
document
  theme!(Theme {} with { text.size = 9 })
end`);
    const graph = await json(["debug", "schedule", input]);
    const writer = parent(graph, "theme!(");
    for (const i of [0, 1]) {
      const set = parent(graph, "choose!(", i), outside = parent(graph, "footnote!(", i);
      assert(!edge(graph, writer, set));
      assert(edge(graph, set, outside));
      assert(!edge(graph, parent(graph, "choose!(", 1 - i), outside));
      assert.equal(edge(graph, writer, outside), fallback);
    }
    const placed = text(await json(["dump", "--quiet", input]));
    assert.deepEqual(placed.filter(n => n.content === "Inside").map(n => n.render.text.font_size).sort(),
      fallback ? [13] : [13, 17]);
    assert.equal(placed.find(n => n.content === "Outside first").render.text.font_size, 13);
    assert.equal(placed.find(n => n.content === "Outside second").render.text.font_size, fallback ? 9 : 17);
  }

  const documentRead = await source(`fn apply!(t: Theme) -> Void
  theme!(t)
  docctx().layout_h_center_offset = document_theme().text.size
end
document
  apply!(Theme {} with { text.size = 26 })
end
page first
  text!(str(docctx().layout_h_center_offset))
end`);
  assert.equal(text(await json(["dump", "--quiet", documentRead]))[0].content, "26");

  // Arguments run before omitted defaults and the callee's body. Defining a
  // theme in an argument cannot supply an earlier argument's read.
  const callOrder = `fn define!() -> Number
  theme!(Theme {} with { text.size = 27 })
  return 0
end
fn label!(n: Number, size: Number = theme_for(pagectx()).text.size) -> Placed<Text>
  return text!(str(size), theme_for(pagectx()).text)
end
page first
  label!(define!())
end`;
  const [called] = text(await json(["dump", "--quiet", await source(callOrder)]));
  assert.deepEqual([called.content, called.render.text.font_size], ["27", 27]);
  run(["dump", "--quiet", await source(callOrder.replace("label!(define!())", "label!(theme_for(pagectx()).text.size, define!())"))],
    "ExecutionDependencyCycle");

  // The original cross-page reproducer had opposite directions for two
  // settings. These are separate graphs even if all the reads precede writes.
  const separate = await source(`page first
  text!(str(pagectx().layout_v_center_offset))
  pagectx().layout_v_center_offset = pagectx().layout_h_center_offset
  pagectx().layout_h_center_offset = 18
end
page second
  text!(str(pagectx().layout_h_center_offset))
  pagectx().layout_h_center_offset = pagectx().layout_v_center_offset
  pagectx().layout_v_center_offset = 42
end`);
  assert.deepEqual(text(await json(["dump", "--quiet", separate])).map(n => n.content).sort(), ["18", "42"]);

  // A conditional writer preceding a read is not a reason to wait for the
  // current unit. The read can still need another unit on the unwritten path.
  for (const external of [false, true]) {
    const local = await source(components + `fn accent!(enabled: Bool) -> Void
  if enabled
    theme!(Theme {} with { text.size = 17 })
  end
end
fn panel!(enabled: Bool) -> Void
  accent!(enabled)
  footnote!("Reference")
end
page first
  panel!(page_index(pagectx()) == 2)
  ${external ? "theme!(Theme {} with { text.size = 23 })" : ""}
end
page second
  panel!(page_index(pagectx()) == 2)
end
document
  theme!(Theme {} with { text.size = 12 })
end`);
    const graph = await json(["debug", "schedule", local]);
    const panel = parent(graph, "panel!(");
    const doc = graph.units.find(u => u.kind === "document_statement").id;
    assert(!edge(graph, panel, panel));
    assert.equal(edge(graph, doc, panel), !external);
    if (external) assert(edge(graph, parent(graph, "theme!("), panel));
    const output = await json(["dump", "--quiet", local]);
    for (const [i, expected] of [external ? 23 : 12, 17].entries()) {
      const note = text(output).find(n => n.content === "Reference" && n.placement.page === output.page_order[i]);
      assert.equal(note.render.text.font_size, expected);
    }
  }

  const exclusive = await source(components + `fn panel!(emphasis: Bool) -> Void
  if !emphasis
    footnote!("Reference")
    return
  end
  theme!(Theme {} with { text.size = 17 })
  footnote!("Reference")
end
page first
  panel!(page_index(pagectx()) == 2)
end
page second
  panel!(page_index(pagectx()) == 2)
end
document
  theme!(Theme {} with { text.size = 12 })
end`);
  const branches = await json(["dump", "--quiet", exclusive]);
  for (const [i, expected] of [12, 17].entries()) {
    const only = text(branches).filter(n => n.placement.page === branches.page_order[i]);
    assert.deepEqual(only.map(n => n.render.text.font_size), [expected]);
  }

  const ordinary = await source(`fn position!(compact: Bool) -> Void
  if compact
    pagectx().layout_h_center_offset = 18
  end
  let offset = pagectx().layout_h_center_offset
  text!(str(offset))
end
page first
  position!(page_index(pagectx()) == 2)
  pagectx().layout_h_center_offset = 24
end
page second
  position!(page_index(pagectx()) == 2)
end`);
  const positioned = await json(["dump", "--quiet", ordinary]);
  for (const [i, expected] of ["24", "18"].entries()) {
    assert.deepEqual(text(positioned).filter(n => n.placement.page === positioned.page_order[i]).map(n => n.content), [expected]);
  }

  // Producing the callback can read a setting even when its selection is
  // empty. Capture that read before invoking fold or setting the page theme.
  const reducer = `fn reducer(size: Number) -> (Number, Page) -> Number
  return (total: Number, p: Page) |-> total + size
end
fn setup!() -> Void
  let empty = selection_filter(pages(docctx()), (p: Page) |-> false)
  let f = fold(empty, 0, reducer(theme_for(pagectx()).text.size))
  theme!(Theme {})
end
page first
  setup!()
end`;
  run(["dump", "--quiet", await source(reducer)], "ExecutionDependencyCycle");

  for (const body of [
    'footnote!("Too early")\n  theme!(Theme {})',
    'footnote!("Too early")\n  if page_index(pagectx()) == 1\n    theme!(Theme {})\n  end',
    'if page_index(pagectx()) == 1\n    theme!(Theme {})\n  end\n  footnote!("Middle")\n  theme!(Theme {})',
    'theme!(theme_for(pagectx()) with { text.size = 18 })',
    'if page_index(pagectx()) == 1\n    theme!(theme_for(pagectx()) with { text.size = 18 })\n  end',
    'let parent = theme_for(pagectx())\n  theme!(parent)',
  ]) {
    const input = await source(components + `fn setup!() -> Void\n  ${body}\nend\npage first\n  setup!()\nend`);
    run(["dump", "--quiet", input], "ExecutionDependencyCycle");
  }

  // An unknown condition may leave the page theme unset. Keep the parent
  // provider even when the conditional writer is present in the same graph.
  for (const [comparison, size] of [["== 1", 42], ["== 2", 23]]) {
    const input = await source(`fn maybe!(flag: Bool) -> Void
  if !flag
    return
  end
  theme!(Theme {} with { text.size = 42 })
end
page local
  text!("Conditional")
  maybe!(page_index(pagectx()) ${comparison})
end
document
  theme!(Theme {} with { text.size = 23 })
end`);
    const graph = await json(["debug", "schedule", input]);
    const target = display(graph, parent(graph, 'text!("Conditional")'));
    assert(edge(graph, parent(graph, "maybe!("), target));
    assert(edge(graph, parent(graph, "theme!("), target));
    assert.equal(text(await json(["dump", "--quiet", input]))[0].render.text.font_size, size);
  }

  // An ordinary page query has a dynamic destination. A resolved placement
  // reference additionally rules out a dependency on the caller's page theme.
  for (const [destination, exact] of [
    ["first(filter(pages(docctx()), (p: Page) |-> page_index(p) == 2))", false],
    ["(*&destination::anchor).page", true],
  ]) {
    const cross = await source(`type Marker { label: String }
fn display(self: Placed<Marker>) -> Text = text(self.value.label, theme_for(pagectx()).text)
page caller
  place_on!(${destination}, Marker { label = "Moved" })
  theme!(Theme {} with { text.size = 16 })
end
page destination
  let anchor = text!("Anchor")
  theme!(Theme {} with { text.size = 37 })
end`);
    const moved = text(await json(["dump", "--quiet", cross])).find(n => n.content === "Moved");
    assert.equal(moved.render.text.font_size, 37);

    const routes = await json(["debug", "schedule", cross]);
    const target = display(routes, parent(routes, "place_on!("));
    assert(edge(routes, parent(routes, "theme!(", 1), target));
    if (exact) assert(!edge(routes, parent(routes, "theme!("), target));
  }

  // Defining an optional setting as none settles the local read but still
  // requires the fallback.
  for (const [value, fallback] of [["none", true], ['c"#445566"', false]]) {
    const input = await source(`fn choose!() -> Void
  pagectx().background_fill = ${value}
  let color = pagectx().background_fill ?? docctx().background_fill
end
page local
  choose!()
end
document
  docctx().background_fill = c"#123456"
end`);
    const graph = await json(["debug", "schedule", input]);
    assert.equal(edge(graph, parent(graph, "docctx().background_fill"), parent(graph, "choose!(")), fallback);
  }

  // A document default is redundant only if every possible arm defines the
  // same page setting. This rule also applies to ordinary optional settings.
  for (const [last, fallback] of [['c"#445566"', false], ["none", true]]) {
    const input = await source(`fn choose!(flag: Bool) -> Void
  if flag
    pagectx().background_fill = c"#112233"
  else
    pagectx().background_fill = ${last}
  end
end
page first
  let color = pagectx().background_fill ?? docctx().background_fill
  choose!(page_index(pagectx()) == 1)
end
document
  docctx().background_fill = c"#123456"
end`);
    const graph = await json(["debug", "schedule", input]);
    const read = parent(graph, "let color");
    assert(edge(graph, parent(graph, "choose!("), read));
    assert.equal(edge(graph, parent(graph, "docctx().background_fill"), read), fallback);
  }

  // Only the taken branch can issue a second definition.
  for (const [test, duplicate] of [["== 1", true], ["== 2", false]]) {
    const input = await source(`fn extra!(flag: Bool) -> Void
  if flag
    theme!(Theme {})
  end
end
page first
  theme!(Theme {})
  extra!(page_index(pagectx()) ${test})
end`);
    await json(["debug", "schedule", input]);
    run(["dump", "--quiet", input], duplicate ? "DuplicatePropertyDefinition" : undefined);
  }

  for (const [src, diagnostic] of [
    ['page a\n theme!(theme_for(pagectx()))\nend', "ExecutionDependencyCycle"],
    ['document\n theme!(document_theme())\nend', "ExecutionDependencyCycle"],
    ['page a\n theme!(Theme {})\n theme!(Theme {})\nend', "DuplicatePropertyDefinition"],
    ['document\n theme!(Theme {})\n theme!(Theme {})\nend', "DuplicatePropertyDefinition"],
    ['page a\n theme!(4)\nend', "TypeMismatch"],
    ['type Local { size: Number }\nfn display(self: Placed<Local>) -> Text\n theme!(Theme {})\n return text("X")\nend\npage a\n place!(Local { size = 1 })\nend', "ImpureDisplayFunction"],
  ]) run(["dump", "--quiet", await source(src)], diagnostic);
} finally {
  await rm(cwd, { recursive: true, force: true });
}
