import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";
import { checkReferenceTypes } from "./types.mjs";
import { checkForwardBindings } from "./forward_bindings.mjs";
import { checkForwardTypes } from "./forward_types.mjs";
import { checkSelectionReads } from "./selections.mjs";

const scratch = path.join(root, ".test-tmp", "placement-references");
await mkdir(scratch, { recursive: true });
const cwd = await mkdtemp(path.join(scratch, "run-"));
function run(args, expectedError) {
  const result = spawnSync(ssBin, args, { cwd, encoding: "utf8", timeout: 30000 });
  assert.ifError(result.error);
  assert.doesNotMatch(result.stderr, /UnscheduledPlacementReference|panic:|Segmentation fault/);
  if (expectedError) {
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, new RegExp(expectedError));
  } else assert.equal(result.status, 0, result.stderr);
  return result.stderr;
}
async function source(text) {
  await writeFile(path.join(cwd, "input.ss"), text);
  return "input.ss";
}
async function json(args) {
  run([...args, "--output", "result.json"]);
  return JSON.parse(await readFile(path.join(cwd, "result.json"), "utf8"));
}
async function texts(input) {
  const dump = await json(["dump", "--quiet", input]);
  return dump.nodes.filter(n => n.placement?.display.kind === "text").map(n => n.content);
}
const title = 'fn title(r: Ref<Placed<Text>>) -> String = (*r).value.content.source\n';
try {
  await checkForwardTypes({ source, texts, run });
  await checkForwardBindings({ source, texts, run });
  await checkReferenceTypes({ source, texts, run });
  await checkSelectionReads({ source, texts, json, run });
  const fixture = path.join(root, "tests/fixtures/compiler/semantics/placement-references/slide.ss");
  assert.deepEqual(await texts(fixture), ["Split refers to Merge (2)", "Merge refers to Split (1)", "Earlier: Merge"]);
  const graph = await json(["debug", "schedule", fixture]);
  const unit = prefix => graph.units.find(u => u.source.startsWith(prefix)).id;
  const split = unit("let split"), merge = unit("let merge");
  const display = parent => graph.units.find(u => u.kind === "display" && u.producer === parent && u.display_step === 0).id;
  const edge = (from, to) => graph.edges.some(e => e.from === from && e.to === to);
  assert(!edge(split, merge) && !edge(merge, split));
  assert(edge(split, display(merge)) && edge(merge, display(split)));

  const pick = [
    "fn pick<T>(flag: Bool, a: Ref<T>, b: Ref<T>) -> Ref<T>",
    "  if flag", "    return a", "  end", "  return b", "end",
  ].join("\n");
  const routing = await source([title, pick,
    "type Box<T> { item: T }",
    "page first",
    '  let a = text!("A")',
    "  let r = Box<Ref<Placed<Text>>> { item = pick(page_index(pagectx()) == 1, &a, &b) }",
    "  let show_title = () |-> title(r.item)",
    '  text!("Picked " ++ show_title())',
    '  let b = text!("B")',
    "end",
    "page second",
    '  let a = text!("C")',
    '  text!("Local " ++ title(&a) ++ ", remote " ++ title(&first::a))',
    "end",
  ].join("\n"));
  const routedText = await texts(routing);
  assert(routedText.includes("Picked A"));
  assert(routedText.includes("Local C, remote A"));
  const routed = await json(["debug", "schedule", routing]);
  const find = s => routed.units.find(u => u.source.startsWith(s)).id;
  const picked = find('text!("Picked');
  const feeds = routed.edges.filter(e => e.to === picked).map(e => e.from);
  assert(feeds.includes(find('let a = text!("A")')) && feeds.includes(find("let b =")));
  assert(!feeds.includes(find('let a = text!("C")')));

  const stages = await source([title, "page staged", "  stages n { 1:2 }",
    '  text!("Stage " ++ title(&staged::target))', "  let target = text!(str(n))", "end"].join("\n"));
  const staged = await texts(stages);
  for (const n of [1, 2]) assert(staged.includes("Stage " + n));
  const cross = await source([title, "document", '  let p = new_page(docctx(), "Page")',
    '  let a: Placed<Text> = place_on!(p, text(title(&b)))',
    '  let b: Placed<Text> = place_on!(p, text("Document target"))', "end"].join("\n"));
  assert.deepEqual(await texts(cross), ["Document target", "Document target"]);

  const callbacks = [
    "type Action { run: () -> String }",
    "fn display(self: Placed<Action>) -> Text = text(\"Action\")",
    "type Reader { target: Ref<Placed<Action>> }",
    "fn display(self: Placed<Reader>) -> Text = text((*self.value.target).value.run())",
  ].join("\n") + "\n";
  const callbackPage = (fn, body) => [callbacks, fn, "page main",
    "  place!(Reader { target = &action })",
    "  let action: Placed<Action> = place!(Action { run = " + body + " })",
    '  let label = text!("Captured")', "end"].join("\n");
  assert.deepEqual((await texts(await source(callbackPage(title, "() |-> title(&label)")))).sort(), ["Action", "Captured", "Captured"]);
  run(["dump", "--quiet", await source(callbackPage(
    'fn mutate() -> String\n  docctx().layout_h_center_offset = 7\n  return "changed"\nend', "mutate"))], "ImpureDisplayFunction");
  run(["dump", "--quiet", await source(callbackPage(
    "fn recursive() -> String = (*&main::action).value.run()", "recursive"))], "RecursiveFunction");

  // Carry a Boolean through a record and a closure. The unchosen target
  // deliberately depends on the result, so a spurious dependency is a cycle.
  const precise = flag => [title, pick, "type Choice { flag: Bool }",
    "fn invert(x: Bool) -> Bool = !x",
    "page precise", '  let good = text!("Reachable")',
    "  let c = Choice { flag = " + flag + " }",
    "  let choose = () |-> pick(invert(!c.flag), &good, &other)",
    '  let result: Placed<Text> = text!("Picked " ++ title(choose()))',
    '  let other: Placed<Text> = text!(title(&result))', "end"].join("\n");
  assert.deepEqual(await texts(await source(precise("true"))), ["Reachable", "Picked Reachable", "Picked Reachable"]);
  for (const flag of ["false", "page_index(pagectx()) == 1"]) {
    run(["dump", "--quiet", await source(precise(flag))], "ExecutionDependencyCycle");
  }

  // Returned handles in record defaults and explicit updates survive separate
  // compilation of a project module. Short-circuiting avoids reading dead code.
  await writeFile(path.join(cwd, "choose.ss"), `type Box<T> { value: T }
fn read<T>(box: Box<Ref<T>>) -> T = *box.value
fn pick<T>(handle: Ref<T>?, fallback: Ref<T>) -> Ref<T> = handle ?? fallback
fn first<T>(r: Ref<T>, ignored: Ref<T>) -> T
  return *r
  return *ignored
end`);
  const optional = await source(['import "./choose" as lib', title,
    "type Local { value: Ref<Placed<Text>> = &one::target }", "page one",
    '  let first = text!(title(lib::pick(Local {}.value, &other)))',
    '  let boxed = lib::Box<Ref<Placed<Text>>> { value = &other } with { value = &target }',
    '  let via = text!(lib::read(boxed).value.content.source)',
    '  let live = text!(lib::first(&target, &other).value.content.source)',
    '  let other = text!(first.value.content.source ++ via.value.content.source ++ live.value.content.source)',
    '  let target = text!("T")',
    '  let fallback = text!(title(lib::pick(none, &other)))', "end"].join("\n"));
  assert.deepEqual((await texts(optional)).sort(), ["T", "T", "T", "T", "TTT", "TTT"]);

  // A scalar does not need a known numeric value, but it does have a
  // present branch. Joining it with none must retain both reference edges.
  for (const [test, label] of [["== 1", "A"], ["== 2", "B"]]) {
    const input = await source([title, pick,
      "fn number(flag: Bool) -> Number?", "  if flag", "    return 3 + 4", "  end", "  return none", "end",
      "fn chosen(n: Number?, a: Ref<Placed<Text>>, b: Ref<Placed<Text>>) -> Ref<Placed<Text>>",
      "  if n?", "    return a", "  end", "  return b", "end",
      "page main", "  let result = text!(title(chosen(number(page_index(pagectx()) " + test + "), &a, &b)))",
      '  let a = text!("A")', '  let b = text!("B")', "end"].join("\n"));
    const schedule = await json(["debug", "schedule", input]);
    const id = prefix => schedule.units.find(u => u.source.startsWith(prefix)).id;
    for (const writer of ["let a", "let b"])
      assert(schedule.edges.some(e => e.from === id(writer) && e.to === id("let result")));
    assert.deepEqual((await texts(input)).sort(), ["A", "B", label].sort());
  }

  for (const [test, label] of [["== 1", "A"], ["== 2", "B"]]) {
    const input = await source([title, pick, "type Label { text: String }",
      "fn maybe(flag: Bool) -> Label?", "  if flag", '    return Label { text = "ok" }', "  end", "  return none", "end",
      "page main", "  let field = maybe(page_index(pagectx()) " + test + ")?.text",
      "  let result = text!(title(pick(field?, &a, &b)))",
      '  let a = text!("A")', '  let b = text!("B")', "end"].join("\n"));
    const schedule = await json(["debug", "schedule", input]);
    const id = prefix => schedule.units.find(u => u.source.startsWith(prefix)).id;
    for (const writer of ["let a", "let b"])
      assert(schedule.edges.some(e => e.from === id(writer) && e.to === id("let result")));
    assert.deepEqual((await texts(input)).sort(), ["A", "B", label].sort());
  }

  const previous = await source([title, pick, "page first",
    '  let result = text!(title(pick(previous_page(pagectx())?, &a, &b)))',
    '  let a = text!("A")', '  let b = text!("B")', "end"].join("\n"));
  const prevGraph = await json(["debug", "schedule", previous]);
  const prevId = prefix => prevGraph.units.find(u => u.source.startsWith(prefix)).id;
  for (const writer of ["let a", "let b"])
    assert(prevGraph.edges.some(e => e.from === prevId(writer) && e.to === prevId("let result")));
  assert.deepEqual((await texts(previous)).sort(), ["A", "B", "B"]);

  const depth = 256;
  const link = i => ["*&p" + (i + 1), "read(&p" + (i + 1) + ")", "*Box { target = &p" + (i + 1) + " }.target"][i % 3];
  const chain = await source([title, "type Box { target: Ref<Placed<Text>> }",
    "fn read(r: Ref<Placed<Text>>) -> Placed<Text> = *r",
    "page main", '  text!("First " ++ title(&p0))',
    ...Array.from({ length: depth }, (_, i) => "  let p" + i + ": Placed<Text> = " + link(i)),
    '  let p' + depth + ' = text!("End")', "end"].join("\n"));
  assert.deepEqual((await texts(chain)).sort(), ["End", "First End"]);

  for (const [text, code] of [
    [title + 'page main\n let a: Placed<Text> = text!(title(&a))\nend', "ExecutionDependencyCycle"],
    [title + 'page main\n let a = text!(title(&b))\n let b = text!(title(&a))\nend', "ExecutionDependencyCycle"],
    ['page main\n let n = 1\n let r = &n\nend', "InvalidReferenceTarget"],
    ['fn unused<T>(x: T) -> Ref<Placed<Text>> = &main::n\npage main\n let n = 1\nend', "InvalidReferenceTarget"],
    ['page main\n let n = *42\nend', "ExpectedPlacementReference"],
    ['fn bad(x: Placed<Text>) -> Ref<Placed<Text>> = &x\n', "InvalidReferenceTarget"],
    ['page main\n let a = text!("X")\n let fn1 = (a: Placed<Text>) |-> &a\nend', "InvalidReferenceTarget"],
    ['page main\n let q = &missing\nend', "InvalidReferenceTarget"],
    ['fn make() -> Placed<Text> = text!("outer")\npage main\n let r = &target\n let make = () |-> 1\n let target = make()\nend', "InvalidReferenceTarget"],
    ['page main\n let a: Placed<Text> = *&b\n let b: Placed<Text> = *&a\nend', "ExecutionDependencyCycle"],
    ['type Wrong { ref: Ref<Number> }', "InvalidReferenceType"],
    ['fn maybe<T>() -> Ref<T>? = none\npage main\n let invalid = maybe<Number>()\nend', "InvalidReferenceType"],
    ['type Maybe<T> { target: Ref<T>? = none }\npage main\n let invalid = Maybe<Number> {}\nend', "InvalidReferenceType"],
    ['page staged\n stages n { 1:2 }\n let a = text!("X")\nend\npage caller\n let q = &staged::a\nend', "AmbiguousReferencePage"],
  ]) run(["dump", "--quiet", await source(text)], code);
} finally {
  await rm(cwd, { recursive: true, force: true });
}
