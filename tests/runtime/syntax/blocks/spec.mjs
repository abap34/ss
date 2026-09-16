#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { root, ssBin, withLspClient } from "../../harness.mjs";

const exec = promisify(execFile);
const output = path.join(root, ".ss-cache/tests/syntax/blocks");
await mkdir(output, { recursive: true });
const project = await mkdtemp(path.join(output, "run-"));
const slide = path.join(project, "slide.ss");
const uri = pathToFileURL(slide).href;
const wrap = (body) => `import std:core/prelude as *\npage Blocks\n${body}\nend\n`;
const operators = ["||", "//", "|=|", "/=/"];
let cases = 0;
const example = await readFile(path.join(root, "tests/fixtures/syntax/blocks/composition.ss"), "utf8");
await check(example);
const dumpFile = path.join(project, "blocks.json");
await exec(ssBin, ["dump", "--quiet", slide, dumpFile], { cwd: project, timeout: 15000, killSignal: "SIGKILL" });
const dump = JSON.parse(await readFile(dumpFile, "utf8"));
assert.deepEqual(dump.nodes.filter((node) => node.content).map((node) => node.content), ["A >> remains text", "B", "C"]);

for (const operator of operators) {
  await check(wrap(`let g = (text << ;; header\nInline >> content\n>>) ${operator}\ntext(<< # header\nB\n>>)\nplace!(g)`));
  for (const left of ['text("A")', "text <<\nA\n>>"]) {
    for (const separator of ["\n", "\n\n", "\n;; comment\n", "\n# comment\n"]) {
      await check(wrap(`let g = ${left}${separator}${operator} text("B")\nplace!(g)`));
    }
  }
}
const unterminated = wrap("text(<<\nMissing closing delimiter");
await check(unterminated, ["UnterminatedBlockString", "opened here", "'>>'", "before end of file", "slide.ss:3:6"], ["ExpectedEnd", "UnknownIdentifier"]);
await check("fn label() -> String\nreturn <<\nmissing\n", ["UnterminatedBlockString", "opened here"], ["ExpectedReturn", "ExpectedEnd"]);
await check(wrap('let g = (text <<\nA\n>> || text("B")'), ["expected ')'", "found end"], ["Unterminated"]);
await check(wrap('text(<<\nA\n>>'), ["expected ')'", "found end"], ["Unterminated"]);
await check(wrap("text << unexpected\n>>"), ["line break after block header", "found unexpected"]);
for (const first of operators) {
  for (const second of operators) {
    if (first === second) continue;
    await check(wrap(`text("A") ${first} text("B") ${second} text("C")`), [
      `mixed '${first}' and '${second}'`, `a ${first} (b ${second} c)`,
    ]);
  }
}

// The CLI excerpt must resume code highlighting after each closing delimiter,
// even when another block begins on the same line.
await writeFile(slide, wrap('let g = text << ;; header\nA\n>> |=| text <<\nB\n>> || text("C")'));
try {
  await exec(ssBin, ["check", "--quiet", "--color", "always", slide], { cwd: project, timeout: 15000, killSignal: "SIGKILL" });
  assert.fail("mixed operators were accepted");
} catch (error) {
  assert.equal(error.code, 1);
  assert(error.stderr.includes('\u001b[33m||\u001b[0m'), `operator after block retained string highlighting: ${error.stderr}`);
  assert(error.stderr.includes('\u001b[36mtext\u001b[0m'), `call after block retained string highlighting: ${error.stderr}`);
}

await writeFile(slide, unterminated);
await withLspClient({ cwd: project }, async (client) => {
  await client.initialize();
  const diagnosed = client.waitForDiagnostics(uri, (items, message) => items.length > 0 && message.params.version === 1);
  client.openDocument({ uri, text: unterminated, version: 1 });
  const items = (await diagnosed).params.diagnostics;
  assert.equal(items.length, 1, "block error produced cascading diagnostics");
  assert.match(items[0].message, /UnterminatedBlockString.*opened here/);
  assert.deepEqual(items[0].range, { start: { line: 2, character: 5 }, end: { line: 2, character: 7 } });
  const fixed = wrap('place!((text <<\nA\n>>) |=| text("B"))');
  const cleared = client.waitForDiagnostics(uri, (items, message) => items.length === 0 && message.params.version === 2);
  client.changeDocument({ uri, text: fixed, version: 2 });
  await cleared;
});
console.log(`block syntax: ${cases} CLI cases and LSP diagnostics passed`);

async function check(text, messages = [], absent = []) {
  await writeFile(slide, text);
  let failure;
  try {
    await exec(ssBin, ["check", "--quiet", slide], { cwd: project, timeout: 15000, killSignal: "SIGKILL" });
  } catch (error) {
    failure = error;
  }
  if (messages.length === 0) assert(!failure, failure?.stderr ?? "valid block expression failed");
  else {
    assert.equal(failure?.code, 1, `expected a source error: ${failure?.stderr}`);
    for (const message of messages) assert(failure.stderr.includes(message), `missing ${JSON.stringify(message)} in ${failure.stderr}`);
    for (const message of absent) assert(!failure.stderr.includes(message), `unexpected ${JSON.stringify(message)} in ${failure.stderr}`);
  }
  cases += 1;
}
