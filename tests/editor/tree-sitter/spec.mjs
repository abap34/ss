import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const exec = promisify(execFile);
const sourceGrammar = fileURLToPath(new URL("../../../editor/tree-sitter-ss/", import.meta.url));
const grammar = path.resolve(process.argv[2] ?? sourceGrammar);
const cli = path.join(sourceGrammar, "node_modules/.bin/tree-sitter");
const output = path.resolve(sourceGrammar, "../../.test-tmp/editor/tree-sitter");
await mkdir(output, { recursive: true });
const directory = await mkdtemp(path.join(output, "run-"));
const cases = [
  {
    name: "include-member-and-parameter",
    source: 'type Options { include: Bool }\nfn accept(include: Bool) -> Bool\n  return include\nend\n',
    node: "function_declaration",
  },
  {
    name: "literal-line-feed-constant",
    source: 'const NEWLINE: String = "\n"\npage Lines\n  let content = "First" ++ NEWLINE ++ "Second"\nend\n',
  },
  {
    name: "ordinary-identifiers",
    source: "fn compute(value: Number) -> Number\n  return value\nend\npage Names\n  let first = 1\n  let second = compute(first)\n  let third = second\nend\n",
  },
  {
    name: "ordinary-line-call",
    source: 'page Names\n  label title "data-kind" value\nend\n',
    node: "line_call_statement",
  },
  {
    name: "conditional-statement",
    source: 'page Conditional\n  if true\n    let value = 1\n  else\n    let fallback = 2\n  end\nend\n',
    node: "if_statement",
  },
  {
    name: "builtin-type-names",
    source: "fn types(a: Document, b: Page, c: Anchor, d: String, e: Color, f: Number, g: Bool, h: Constraints, i: Path, j: None, k: Selection<Page>, l: Group<Text, Image>, m: Placed<Text>, n: Placement) -> Void\n  return\nend\n",
    typeNames: ["Document", "Page", "Anchor", "String", "Color", "Number", "Bool", "Constraints", "Path", "None", "Selection", "Page", "Group", "Text", "Image", "Placed", "Text", "Placement", "Void"],
  },
  {
    name: "lowercase-type-declarations",
    source: "type widget { value: Number }\ntype details { name: String }\ntype envelope<T> { value: T }\nenum mode { light dark }\nfn read(value: envelope<widget>, extra: details) -> Selection<Page>\n  return pages(docctx())\nend\n",
    typeNames: ["widget", "Number", "details", "String", "envelope", "T", "T", "mode", "envelope", "widget", "details", "Selection", "Page"],
  },
  {
    name: "qualified-lowercase-type-names",
    source: "fn read(value: library::widget) -> library::details\n  return library::details { value = value }\nend\npage Calls\n  let wrapped = library::envelope<Number> { value = 1 }\n  let result = library::read<Number>(1)\n  let less = library::value < 3\nend\n",
    typeNames: ["widget", "details", "details", "envelope", "Number", "Number"],
  },
];

const typeQuery = path.join(directory, "types.scm");
await writeFile(typeQuery, "(type_identifier) @name\n");

async function captures(query, file, capture) {
  const { stdout } = await exec(cli, ["query", path.resolve(sourceGrammar, query), file], {
    cwd: grammar, timeout: 30000, killSignal: "SIGKILL", maxBuffer: 1024 * 1024,
  });
  const names = [];
  for (const line of stdout.split("\n")) {
    const match = line.match(/capture: \d+ - ([\w.]+), .*text: `([^`]+)`$/);
    if (match?.[1] === capture) names.push(match[2]);
  }
  return names;
}

for (const { name, source, node, typeNames } of cases) {
  const file = path.join(directory, `${name}.ss`);
  await writeFile(file, source);
  const result = await exec(cli, ["parse", file], {
    cwd: grammar, timeout: 30000, killSignal: "SIGKILL", maxBuffer: 1024 * 1024,
  });
  assert.doesNotMatch(result.stdout, /\((?:ERROR|MISSING)\b/, `${name}: unexpected syntax errors`);
  if (node) assert.match(result.stdout, new RegExp(`\\(${node}\\b`), `${name}: expected ${node}`);
  if (typeNames) assert.deepEqual(await captures(typeQuery, file, "name"), typeNames, `${name}: type name captures`);
}

const definitions = path.join(directory, "definitions.ss");
await writeFile(definitions, "import std:text as *\nfn plain(value: Number) -> Number\n  return value\nend\nfn notify!() -> Void\n  return\nend\nfn/! label(value: String) -> Text\n  return text(value)\nend\n");
const queries = [
  ["queries/locals.scm", "local.definition.function"],
  ["../zed/languages/ss/outline.scm", "name"],
  ["../helix/queries/ss/tags.scm", "name"],
];
for (const [query, capture] of queries) {
  assert.deepEqual(await captures(query, definitions, capture), ["plain", "notify!", "label"], `${query}: function definitions`);
}
console.log(`Tree-sitter syntax and queries: ${cases.length} syntax cases and ${queries.length} definition queries passed`);
