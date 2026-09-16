import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const exec = promisify(execFile);
const grammar = fileURLToPath(new URL("../", import.meta.url));
const output = path.resolve(grammar, "../../.ss-cache/tests/syntax/tree-sitter-formatting");
await mkdir(output, { recursive: true });
const directory = await mkdtemp(path.join(output, "run-"));
const file = path.join(directory, "generated.ss");
const operators = ["||", "//", "|=|", "/=/"];
const gaps = ["", " ", "\n", "\n\n", "\n;; generated comment\n\t", "\r\n# generated comment\r\n  "];
const leaf = (index) => ({ leaf: index });
const chain = (operator, ...children) => ({ operator, children });
const trees = [];
for (const operator of operators) {
  trees.push(chain(operator, leaf(0), leaf(1)), chain(operator, leaf(0), leaf(1), leaf(2)));
  for (const inner of operators) {
    trees.push(chain(operator, chain(inner, leaf(0), leaf(1)), leaf(2)));
    trees.push(chain(operator, leaf(0), chain(inner, leaf(1), leaf(2))));
  }
}

const statements = [];
let expectedCompositions = 0;
for (const tree of trees) {
  for (const [gapIndex, gap] of gaps.entries()) {
    for (const wrapped of [false, true]) {
      const style = (gapIndex + Number(wrapped)) % 4;
      function print(node, nested = false) {
        let text;
        if (node.children) {
          expectedCompositions += node.children.length - 1;
          text = node.children.map((child) => print(child, true)).join(`${gap}${node.operator}${gap}`);
        } else {
          const label = String.fromCharCode(65 + node.leaf);
          switch ((style + node.leaf) % 4) {
            case 0: text = `text(${gap}"${label}"${gap})`; break;
            case 1: text = `text "${label}"`; break;
            case 2: text = `text(<<\n${label}\n>>${gap})`; break;
            case 3: text = `text << # header\n${label}\n>>`; break;
          }
        }
        if (nested && node.children) text = `(${gap}${text}${gap})`;
        if (wrapped) text = `((${gap}${text}${gap}))`;
        return text;
      }
      statements.push(`let item_${statements.length} = ${print(tree)}`);
    }
  }
}

// Statement sugar must not swallow the operator or terminate before it.
for (const operator of operators) {
  for (const gap of gaps) {
    for (const left of ["a", 'text("A")', 'text "A"', "text <<\nA\n>>"]) {
      statements.push(`${left}${gap}${operator}${gap}b`);
      expectedCompositions += 1;
    }
  }
}
await writeFile(file, `page Generated\n${statements.join("\n")}\nend\n`);
const { stdout } = await exec(path.join(grammar, "node_modules/.bin/tree-sitter"), ["parse", file], {
  cwd: grammar, timeout: 30000, killSignal: "SIGKILL", maxBuffer: 16 * 1024 * 1024,
});
assert.doesNotMatch(stdout, /\((?:ERROR|MISSING)\b/, `invalid generated syntax in ${file}`);
assert.equal((stdout.match(/\(composition_expression\b/g) ?? []).length, expectedCompositions,
  `an operator was swallowed or a statement ended early in ${file}`);
assert.equal(statements.length, 576);
console.log(`generated Tree-sitter formatting: ${statements.length} cases passed`);
