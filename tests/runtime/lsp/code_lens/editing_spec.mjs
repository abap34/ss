import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { root, withLspClient } from "../../harness.mjs";

const scratch = path.join(root, ".test-tmp/code-lens-editing");
await mkdir(scratch, { recursive: true });
const directory = await mkdtemp(path.join(scratch, "project-"));
const entry = path.join(directory, "slide.ss");
const uri = pathToFileURL(entry).href;
const query = { textDocument: { uri } };
const pages = 'page Before\n  text!("Before")\nend\npage "After"\n  text!("After")\nend\n';
const source = `import std:themes/default as *\n${pages}`;
async function assertLenses(client, text, version, label, names = ["Before", '"After"']) {
  const lenses = await client.request("textDocument/codeLens", query);
  assert.equal(lenses.length, names.length, `${label}: lost navigation ${JSON.stringify(lenses)}`);
  for (const [i, name] of names.entries()) {
    const offset = name === "" ? text.lastIndexOf("page ") : text.indexOf(`page ${name}`);
    assert(offset >= 0);
    const start = Buffer.byteLength(text.slice(0, offset));
    const target = { uri, start, version };
    assert.deepEqual(lenses[i].command.arguments, [target], `${label}: stale target`);
    assert.equal(lenses[i].command.title, "Jump to slide");
    assert.equal(lenses[i].range.start.line, text.slice(0, offset).split("\n").length - 1);
    assert.equal(lenses[i].range.start.line, lenses[i].range.end.line, `${label}: lens must occupy one line`);
  }
}
try {
  await writeFile(path.join(directory, "ss.toml"), '[project]\nentry="slide.ss"\n[editor.lsp]\ndebounce=60000\n[editor.wysiwyg.refresh]\nautomatic=false\n');
  await writeFile(entry, source);
  await withLspClient({ cwd: directory, measureProfile: true }, async client => {
    await client.initialize();
    await assertLenses(client, source, null, "closed file");
    const ready = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source, version: 1 });
    assert.deepEqual((await ready).params.diagnostics, []);
    await assertLenses(client, source, 1, "opened file");
    let version = 1;
    const variants = [
      ["missing import", `import "./not-created-yet"\n${source}`],
      ["missing include", `include "not-created-yet.ss"\n${source}`],
      ["unfinished function", `fn helper() -> Number\n  return\n${source}`],
      ["unfinished global expression", `const pending = TextStyle {\n${source}`],
      ["unfinished expression", source.replace('text!("Before")', "let item =")],
      ["unfinished call", source.replace('text!("Before")', "text!(")],
      ["unfinished last-page call", source.replace('text!("After")', "text!(")],
      ["unfinished record", source.replace('text!("Before")', "let style = theme.text with { size =")],
      ["unfinished local block", source.replace('text!("Before")', "if true\n  text!(")],
      ["unfinished earlier string", source.replace('text!("Before")', 'text!("')],
      ["unfinished earlier block string", source.replace('text!("Before")', "text! <<\nUnfinished")],
      ["unfinished string", source.replace('text!("After")', 'text!("')],
      ["unfinished block string", source.replace('text!("After")', "text! <<\nUnfinished")],
      ["invalid stages", source.replace('text!("Before")', "stages s { 0:0:2 }")],
      ["type error", source.replace('text!("Before")', "let item: Number = false")],
      ["shifted source", `;; \u{1f680} before declarations\r\n\r\n${source.replaceAll("\n", "\r\n")}`],
    ];
    for (const [label, text] of variants) {
      client.changeDocument({ uri, text, version: ++version });
      await assertLenses(client, text, version, label);
    }
    for (const receiver of ["p", "pa", "pag", "page", "page.", "page.background_fill ="]) {
      const text = source.replace('text!("Before")', receiver);
      client.changeDocument({ uri, text, version: ++version });
      await assertLenses(client, text, version, `page receiver ${receiver}`);
    }
    // Repeated body edits must never temporarily remove the line above a page.
    for (let i = 0; i < 12; i++) {
      const text = source.replace('text!("Before")', i % 2 ? 'text!("Changed")' : "let item =");
      client.changeDocument({ uri, text, version: ++version });
      await assertLenses(client, text, version, `typing ${i}`);
    }
    client.changeDocument({ uri, text: source, version: ++version });
    await assertLenses(client, source, version, "completed body edits");
    const unnamed = source.replace('page "After"', "page ");
    client.changeDocument({ uri, text: unnamed, version: ++version });
    await assertLenses(client, unnamed, version, "temporarily empty page name", ["Before", ""]);
    client.changeDocument({ uri, text: source, version: ++version });
    await assertLenses(client, source, version, "restored page name");
    const prefix = "const example: String = <<\n";
    const unclosed = prefix + source;
    client.changeDocumentRange({ uri, version: ++version, range: { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } }, text: prefix });
    await assertLenses(client, unclosed, version, "unfinished surrounding literal");
    const end = { line: unclosed.split("\n").length - 1, character: 0 };
    client.changeDocumentRange({ uri, version: ++version, range: { start: end, end }, text: ">>\n" });
    await assertLenses(client, unclosed + ">>\n", version, "complete surrounding literal", []);
    client.changeDocument({ uri, text: source, version: ++version });
    await assertLenses(client, source, version, "restored declarations");
    const removed = source.slice(0, source.indexOf('page "After"'));
    client.changeDocument({ uri, text: removed, version: ++version });
    await assertLenses(client, removed, version, "deleted page", ["Before"]);
    client.changeDocument({ uri, text: source, version: ++version });
    await assertLenses(client, source, version, "restored page");
    // Pipeline edits and requests instead of waiting after each edit. A newer
    // ingress revision must not turn a physical page list into ContentModified.
    const pending = [];
    for (let i = 0; i < 40; i++) {
      const text = source.replace('text!("Before")', i % 2 ? 'text!("Changed")' : "let item =");
      client.changeDocument({ uri, text, version: ++version });
      pending.push(assertLenses(client, text, version, `overlapping edit ${i}`));
      client.notify("workspace/didChangeWatchedFiles", { changes: [{ uri, type: 2 }] });
    }
    await Promise.all(pending);
    await client.close();
    const semanticBuilds = Number(client.stderr.match(/analysis static semantics: (\d+) calls/)?.[1] ?? 0);
    assert.equal(semanticBuilds, 1, `CodeLens requests triggered semantic analysis\n${client.stderr}`);
  });
  console.log("CodeLens editing: incomplete syntax, failed imports, current positions and analysis independence passed");
} finally {
  await rm(directory, { recursive: true, force: true });
}
