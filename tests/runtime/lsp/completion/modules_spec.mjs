import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { root, withLspClient } from "../../harness.mjs";

const scratch = path.join(root, ".test-tmp/module-completion");
await mkdir(scratch, { recursive: true });
const project = await mkdtemp(path.join(scratch, "project-"));
const file = path.join(project, "slide.ss");
const initial = 'import "arrows" as arrows\npage main\nend\n';
try {
  await writeFile(path.join(project, "ss.toml"), '[project]\nentry = "slide.ss"\n');
  await writeFile(file, initial);
  await writeFile(path.join(project, "arrows.ss"), 'import "implementation" as { curve }\nfn straight(length: Number = 100) -> Number = length\ntype Stroke { width: Number = 1 }\n');
  await writeFile(path.join(project, "implementation.ss"), 'fn curve() -> Number = 1\nfn hidden() -> Number = 2\n');
  await writeFile(path.join(project, "notes.txt"), "Not a module\n");
  await mkdir(path.join(project, "components"));
  await writeFile(path.join(project, "components/cover.ss"), 'fn cover() -> String = "Cover"\n');

  await withLspClient({ cwd: project }, async client => {
    const initialized = await client.initialize();
    assert(initialized.capabilities.completionProvider.triggerCharacters.includes("/"));
    const uri = pathToFileURL(file).href;
    let version = 1;
    const ready = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: initial, version });
    await ready;
    async function complete(marked) {
      const offset = marked.indexOf("|CURSOR|");
      assert(offset >= 0);
      const text = marked.replace("|CURSOR|", "");
      const prefix = text.slice(0, offset).split("\n");
      const diagnostics = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, text, version: ++version });
      await diagnostics;
      const response = await client.request("textDocument/completion", {
        textDocument: { uri },
        position: { line: prefix.length - 1, character: prefix.at(-1).length },
        context: { triggerKind: 1 },
      });
      return { text, items: response.items, labels: response.items.map(item => item.label) };
    }
    function apply(text, item) {
      assert(item.textEdit, JSON.stringify(item));
      const { start, end } = item.textEdit.range;
      const offset = p => text.split("\n").slice(0, p.line).reduce((n, line) => n + line.length + 1, 0) + p.character;
      return text.slice(0, offset(start)) + item.textEdit.newText + text.slice(offset(end));
    }
    for (const expression of ["arrows::|CURSOR|", "arrows:: |CURSOR|", "arrows::st|CURSOR|", "arrows::st|CURSOR|raight(30)"]) {
      const result = await complete(`import "arrows" as arrows\npage main\n  let value = ${expression}\nend\n`);
      for (const name of ["straight", "curve", "Stroke"]) assert(result.labels.includes(name), JSON.stringify(result));
      for (const name of ["page", "text!", "hidden"]) assert(!result.labels.includes(name), JSON.stringify(result));
      const item = result.items.find(item => item.label === "straight");
      assert.match(apply(result.text, item), /arrows:: ?straight(?:\(30\))?\n/);
    }
    const unicode = await complete('import "arrows" as arrows\npage main\n  let value = "😀" ++ arrows::st|CURSOR|raight(30)\nend\n');
    assert.match(apply(unicode.text, unicode.items.find(item => item.label === "straight")), /"😀" \+\+ arrows::straight\(30\)/);
    const missing = await complete('page main\n  let value = missing::|CURSOR|\nend\n');
    assert.deepEqual(missing.items, []);

    for (const [marked, label, expected] of [
      ['import "|CURSOR|', "arrows", 'import "arrows"'],
      ['import |CURSOR|', "arrows", 'import arrows'],
      ['import "ar|CURSOR|rows" as a', "arrows", 'import "arrows" as a'],
      ['import std:te|CURSOR|', "std:text", 'import std:text'],
      ['import "std:te|CURSOR|"', "std:text", 'import "std:text"'],
      ['import "co|CURSOR|', "components/", 'import "components/'],
      ['import "components/|CURSOR|', "components/cover", 'import "components/cover"'],
      ['import "./ar|CURSOR|', "./arrows", 'import "./arrows"'],
    ]) {
      const result = await complete(marked + "\npage main\nend\n");
      assert(result.items.every(item => item.kind === 9 || item.kind === 19), JSON.stringify(result));
      for (const name of ["text!", "page", "notes", "slide"]) assert(!result.labels.includes(name), JSON.stringify(result));
      const selected = result.items.find(item => item.label === label);
      assert(selected, JSON.stringify(result));
      assert.equal(apply(result.text, selected), expected + "\npage main\nend\n");
    }
    const absent = await complete('import "missing-directory/|CURSOR|\npage main\nend\n');
    assert.deepEqual(absent.items, []);
  });
  console.log("Module completion: unfinished qualified names, re-exports, import paths, replacement ranges and Unicode passed");
} finally {
  await rm(project, { recursive: true, force: true });
}
