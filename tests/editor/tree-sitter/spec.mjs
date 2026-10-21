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
const output = path.resolve(sourceGrammar, "../../.ss-cache/tests/editor/tree-sitter");
await mkdir(output, { recursive: true });
const directory = await mkdtemp(path.join(output, "run-"));
const cases = [
  {
    name: "literal-line-feed-constant",
    source: 'const NEWLINE: String = "\n"\npage Lines\n  let content = "First" ++ NEWLINE ++ "Second"\nend\n',
  },
  {
    name: "ordinary-identifiers",
    source: "fn property(value: Number) -> Number\n  return value\nend\npage Names\n  let for = 1\n  let in = property(for)\n  let then = in\nend\n",
  },
  {
    name: "ordinary-line-call",
    source: 'page Names\n  property title "data-kind" value\nend\n',
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
    name: "former-type-spellings-are-names",
    source: "fn types(a: document, b: page, c: selection<Page>, d: anchor, e: string, f: number, g: metadata, h: bool, i: boolean, j: constraints, k: void) -> Void\n  return\nend\n",
    typeNames: ["document", "page", "selection", "Page", "anchor", "string", "number", "metadata", "bool", "boolean", "constraints", "void", "Void"],
  },
  {
    name: "lowercase-type-declarations",
    source: "type number { value: Number }\ntype metadata { name: String }\ntype selection<T> { value: T }\nenum mode { light dark }\nfn read(value: selection<number>, extra: metadata) -> Selection<Page>\n  return pages(document)\nend\n",
    typeNames: ["number", "Number", "metadata", "String", "selection", "T", "T", "mode", "selection", "number", "metadata", "Selection", "Page"],
  },
  {
    name: "qualified-lowercase-type-names",
    source: "fn read(value: library::number) -> library::metadata\n  return library::metadata { value = value }\nend\npage Calls\n  let wrapped = library::selection<Number> { value = 1 }\n  let result = library::read<Number>(1)\n  let less = library::value < 3\nend\n",
    typeNames: ["number", "metadata", "metadata", "selection", "Number", "Number"],
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
