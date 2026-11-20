import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { root, ssBin, withLspClient } from "../../harness.mjs";

const scratch = path.join(root, ".test-tmp", "forward-bindings");
await mkdir(scratch, { recursive: true });
const cwd = await mkdtemp(path.join(scratch, "run-"));
let checked = 0;

function run(args, expected) {
  const result = spawnSync(ssBin, args, { cwd, encoding: "utf8", timeout: 30000 });
  assert.ifError(result.error);
  if (expected) {
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, new RegExp(expected));
    assert.doesNotMatch(result.stderr, /panic:|Segmentation fault/);
  } else assert.equal(result.status, 0, result.stderr);
  return result;
}

async function source(name, value) {
  const file = path.join(cwd, name + ".ss");
  await writeFile(file, value);
  return file;
}

async function dump(name, value) {
  const file = await source(name, value);
  run(["dump", "--quiet", file, "--output", "dump.json"]);
  const result = JSON.parse(await readFile(path.join(cwd, "dump.json"), "utf8"));
  assert.deepEqual(result.diagnostics, []);
  checked += 1;
  return result;
}

const texts = result => result.nodes.filter(n => n.placement?.display.kind === "text").map(n => n.content);
const page = body => `page main\n${body}\nend`;

try {
  assert.deepEqual(texts(await dump("alias", page(`
    let alias = title
    text!(alias.value.content.source ++ " alias")
    let title = text!("Title")
  `))).sort(), ["Title", "Title alias"]);

  assert.deepEqual(texts(await dump("closure", page(`
    text!(format("Title"))
    let format = (value: String) |-> prefix ++ value
    let prefix = "Later "
  `))), ["Later Title"]);

  assert.deepEqual(texts(await dump("record", `
    type Format { apply: String -> String }
    ${page(`text!(format.apply("Title"))
      let format = Format { apply = decorate }
      let decorate = (value: String) |-> prefix ++ value
      let prefix = "Record "`)}
  `)), ["Record Title"]);

  assert.deepEqual(texts(await dump("shadow", `
    const title: String = "Outer"
    ${page('text!(title)\nlet title = "Inner"')}
  `)), ["Inner"]);

  assert.deepEqual(texts(await dump("function-local", `
    fn label(value: Number) -> String
      let str = str(value)
      return str
    end
    ${page('text!(label(number))\nlet number = 42')}
  `)), ["42"]);

  const constrained = await dump("constraints", page(`
    ~ alias.left == title.right + 24
    ~ title.left == page.left + 72
    ~ title.width == 200
    ~ subtitle.width == 200
    let alias = subtitle
    let title = text!("Title")
    let subtitle = text!("Subtitle")
  `));
  const title = constrained.nodes.find(n => n.content === "Title");
  const subtitle = constrained.nodes.find(n => n.content === "Subtitle");
  assert.equal(title.x, 72);
  assert.equal(subtitle.x, title.x + title.width + 24);

  for (const annotation of ["", ": String"]) {
    assert.deepEqual(texts(await dump("query-name", page(`
      text!(first(select(target, name)).value.content.source)
      let target = text!("Selected")
      let name${annotation} = prefix ++ "placement"
      let prefix: String = "self_"
    `))), ["Selected", "Selected"]);
  }

  await dump("document-blocks", `
    document
      theme!(later)
    end
    ${page('text!("Document theme")')}
    document
      let later = Theme {} with { text.size = 19 }
    end
  `);

  // Effects must follow aliases, record fields, and captured callables even
  // when all of their declarations occur after the call.
  for (const [expression, optional] of [["reader()", ""], ["callbacks.read()", ""], ["(callbacks.read ?? reader)()", "?"]]) {
    assert.deepEqual(texts(await dump("property-closure", `
      type Callbacks { read: (() -> String)${optional} }
      ${page(`text!(${expression})
        write(target)
        let callbacks = Callbacks { read = reader }
        let reader = () |-> str(target.layout_h_center_offset)
        let write = (item: Page) |-> set_offset(item)
        let target = pagectx()`)}
      fn set_offset(item: Page) -> Void
        item.layout_h_center_offset = 42
      end
    `)), ["42"]);
  }

  assert.deepEqual(texts(await dump("shadow-lambda", page(`
    text!(str(apply(7)) ++ label)
    let apply = (label: Number) |-> label + 1
    let label = " later"
  `))), ["8 later"]);

  // Reusing a nested closure must preserve each captured input and prefix.
  const captured = await dump("nested-captures", `
    type Caption { read: () -> String }
    type Captions { left: Caption right: Caption }
    fn display(self: Placed<Caption>) -> Text = text(self.value.read())
    fn decorate(prefix: String, read: () -> String) -> () -> String
      return () |-> prefix ++ read()
    end
    fn caption(prefix: String, target: Placed<Text>) -> Caption
      return Caption { read = decorate(prefix, () |-> target.value.content.source) }
    end
    page main
      place!(captions.left)
      place!(captions.right)
      place!(captions.left)
      let captions = Captions {
        left = caption("Left ", first)
        right = caption("Right ", second)
      }
      let first = text!("A")
      let second = text!("B")
    end
  `);
  assert.deepEqual(texts(captured).sort(), ["A", "B", "Left A", "Left A", "Right B"]);

  assert.deepEqual(texts(await dump("branch-environment", `
    const prefix: String = "Outer "
    fn local_label(target: Number, prefix: String) -> String = prefix ++ str(target)
    fn label(target: Page) -> String
      if true
        let prefix = local_label(7, "Inner ")
      end
      return prefix ++ str(target.layout_h_center_offset)
    end
    ${page(`text!(label(target))
      target.layout_h_center_offset = 42
      let target = pagectx()`)}
  `)), ["Outer 42"]);

  // A function call remains one execution unit. Its sequential locals can
  // shadow library functions, including the pages(doc) idiom in seminar decks.
  const numbering = `
    fn add_pageno_all!(doc: Document) -> Void
      let pages = pages(doc)
      foreach(pages, (target: Page) |-> add_number!(target))
    end
    fn add_number!(target: Page) -> Void
      place_on!(target, pageno())
    end
    document
      add_pageno_all!(document)
      let document = docctx()
    end
    page first
      text!("First")
    end
    page second
      text!("Second")
    end
  `;
  const numbered = await dump("page-numbering", numbering);
  assert(texts(numbered).includes("1/2") && texts(numbered).includes("2/2"));

  const claims = await dump("construction-order", `
    type Claim { title: String }
    fn display(self: Placed<Claim>) -> Text
      let all = select<Claim>(self.document)
      return text(str(number_of(self, all) ?? 0) ++ ": " ++ self.value.title)
    end
    ${page(`text!(join(all, ", ", (item: Placed<Claim>) |-> item.value.title))
      let first_claim = place!(Claim { title = "First " ++ last_claim.value.title })
      let middle_claim = place!(Claim { title = "Middle" })
      let last_claim = place!(Claim { title = "Last" })
      let all = select<Claim>(docctx())`)}
  `);
  for (const value of ["First Last, Middle, Last", "1: First Last", "2: Middle", "3: Last"])
    assert(texts(claims).includes(value), value);

  for (const nested of [false, true]) {
    const value = await dump("selected-groups", `
      type Badge { title: String }
      fn display(self: Placed<Badge>) -> Group<Text, Text>
        return text(self.value.title) // text("Detail")
      end
      ${page(`text!(str(selection_count(select<Text>(first(groups)))))
        let groups = select<${nested ? "Group<Group<Badge>>" : "Group<Badge>"}>(pagectx())
        ${nested ? "let outer = group!(selection(inner))\nlet inner = group!(first(badges))" : "let root = group!(badges)"}
        let badges = select<Badge>(pagectx())
        let badge = place!(Badge { title = "Title" })`)}
    `);
    assert.deepEqual(texts(value).sort(), ["2", "Detail", "Title"]);
  }

  const staged = await dump("staged-bindings", page(`
    stages phase { 1:3 }
    text!(title.value.content.source ++ " alias")
    show phase >= 2
      let title = text!("Stage " ++ str(phase))
    end
    theme!(page_theme)
    let page_theme = Theme {} with { text.size = 14 + phase }
  `));
  assert.equal(staged.page_order.length, 3);
  for (let phase = 1; phase <= 3; phase += 1) {
    const text = staged.nodes.find(n => n.content === `Stage ${phase} alias`);
    assert(text);
    assert.equal(text.render.text.font_size, 14 + phase);
    assert.equal(text.placement.page, staged.page_order[phase - 1]);
  }
  assert.deepEqual(texts(await dump("stage-shadow", page(`
    stages i { 1:2 }
    text!(str(i))
    let i = 42
  `))), ["42", "42"]);

  const chain = Array.from({ length: 256 }, (_, i) => `let item${i} = item${i + 1}`).join("\n");
  assert.deepEqual(texts(await dump("long-chain", page(`text!(item0)\n${chain}\nlet item256 = "Tail"`))), ["Tail"]);

  // Named queries discover extra literal facts while solving result types.
  // Exercise repeated growth of that graph, including annotated aliases.
  const queries = Array.from({ length: 96 }, (_, i) => `
    let selected${i} = first(select(target, name${i}))
    let name${i}: String = prefix${i} ++ "placement"
    let prefix${i}: String = "self_"
  `).join("\n");
  assert.deepEqual(texts(await dump("growing-type-graph", page(`
    text!(selected95.value.content.source ++ " alias")
    ${queries}
    let target = text!("Selected")
  `))).sort(), ["Selected", "Selected alias"]);

  for (const [name, code, diagnostic] of [
    ["type-cycle", page("let a = b\nlet b = a"), "ReferenceNeedsType"],
    ["value-cycle", page("let a: Number = b\nlet b = a"), "ExecutionDependencyCycle"],
    ["self-cycle", page("let a: Number = a + 1"), "ExecutionDependencyCycle"],
    ["stage-cycle", page("stages i { 1:2 }\nlet i: Number = i + 1"), "ExecutionDependencyCycle"],
    ["function-order", "fn bad() -> Number\nlet a = b\nlet b = 1\nreturn a\nend\npage main\nend", "UnknownIdentifier"],
    ["branch-order", page("if true\nlet a = b\nlet b = 1\nend"), "UnknownIdentifier"],
    ["duplicate", page('let value = "First"\nlet value = "Second"'), "DuplicateBinding"],
    ["type-mismatch", page('text!(amount)\nlet amount = 1'), "TypeMismatch"],
    ["closure-cycle", page('let a: () -> String = () |-> b()\nlet b: () -> String = () |-> a()'), "ExecutionDependencyCycle"],
    ["closure-missing", page('let f = () |-> missing\ntext!(f())'), "UnknownIdentifier"],
    ["page-scope", 'page a\ntext!(title)\nend\npage b\nlet title = "Other page"\nend', "UnknownIdentifier"],
  ]) {
    run(["dump", "--quiet", await source(name, code)], diagnostic);
    checked += 1;
  }

  // Perturb every declaration, including closures, generics, records, and
  // annotated query names. No source-order propagation may affect the result.
  const declarations = [
    'let a = id(text!("A"))',
    'let b = text!(a.value.content.source ++ "B")',
    'let c = text!(format(box.value.value.content.source))',
    'let box = Box { value = b }',
    'let format: String -> String = (value: String) |-> prefix ++ value',
    'let prefix: String = "C"',
    'let name: String = query_prefix ++ "placement"',
    'let query_prefix = "self_"',
    'let alias = first(select(c, name))',
    'text!(alias.value.content.source ++ " copy")',
  ];
  for (let seed = 1; seed <= 16; seed += 1) {
    const statements = [...declarations];
    let random = seed;
    for (let i = statements.length - 1; i > 0; i -= 1) {
      random = (Math.imul(random, 1664525) + 1013904223) >>> 0;
      const j = random % (i + 1);
      [statements[i], statements[j]] = [statements[j], statements[i]];
    }
    const code = `type Box<T> { value: T }\nfn id<T>(value: T) -> T = value\n${page(statements.join("\n"))}`;
    assert.deepEqual(texts(await dump("permutation", code)).sort(), ["A", "AB", "CAB", "CAB copy"], `permutation ${seed}`);
  }

  const project = path.join(cwd, "project");
  await cp(path.join(root, "tests/fixtures/runtime/document/bindings/practical"), project, { recursive: true });
  const slide = path.join(project, "slide.ss");
  const deck = await dump("practical", `import "./project/slide" as *`);
  assert.equal(deck.page_order.length, 6);
  for (const content of ["Read Method", "Claim 1: Setup", "Claim 2: Result", "Setup, Result", "1/6", "6/6"])
    assert(texts(deck).includes(content), content);
  for (const [content, size] of [["Read Method", 18], ["Claim 2: Result", 26], ["Method note", 11], ["Stage 3 alias", 21]])
    assert.equal(deck.nodes.find(n => n.content === content).render.text.font_size, size, content);
  run(["render", "--quiet", slide, "--output", "deck.pdf"]);
  assert.equal((await readFile(path.join(cwd, "deck.pdf"))).subarray(0, 5).toString(), "%PDF-");

  // A failed edit must not leave provisional types or captured facts in the
  // next editor generation.
  const editing = value => page(`text!(label)\n${value}`);
  const editor = path.join(cwd, "editor");
  await mkdir(editor);
  const editingPath = path.join(editor, "slide.ss");
  const valid = editing('let label = "Before"');
  await writeFile(editingPath, valid);
  const uri = pathToFileURL(editingPath).href;
  await withLspClient({ cwd: editor }, async client => {
    await client.initialize();
    const opened = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: valid, version: 1 });
    assert.deepEqual((await opened).params.diagnostics, []);
    const initial = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert(initial.display.html.includes("Before"));
    let version = 1;
    for (const [binding, diagnostic] of [["let label = 1", "TypeMismatch"], ["", "UnknownIdentifier"], ['let label = "After"', null]]) {
      version += 1;
      const pending = client.waitForDiagnostics(uri, (items, message) => message.params.version === version &&
        (!diagnostic || items.some(d => d.code === diagnostic || d.message.includes(diagnostic))));
      client.changeDocument({ uri, text: editing(binding), version });
      const diagnostics = (await pending).params.diagnostics;
      if (!diagnostic) assert.deepEqual(diagnostics, []);
    }
    const repaired = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert(!repaired.stale && repaired.generation > initial.generation);
    assert(repaired.display.html.includes("After"));
  });
  console.log(`forward bindings: ${checked} documents, PDF, and editor recovery passed`);
} finally {
  await rm(cwd, { recursive: true, force: true });
}
