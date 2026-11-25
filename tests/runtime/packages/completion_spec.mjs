import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { root, ssBin, withLspClient } from "../harness.mjs";
import { command, repository, writeFiles } from "./harness.mjs";

const scratch = path.join(root, ".test-tmp/package-completion");
await mkdir(scratch, { recursive: true });
const work = await mkdtemp(path.join(scratch, "project-"));
const deck = path.join(work, "deck");
const source = "page main\nend\n";
const offline = { ...process.env, GIT_ALLOW_PROTOCOL: "file" };
try {
  const base = await repository(work, "base", {
    "ss.toml": '[package]\nname = "base"\n',
    "lib.ss": 'fn label() -> String = "Base"\n',
    "extra.ss": 'fn label() -> String = "Extra"\n',
  });
  const arrows = await repository(work, "arrows", {
    "ss.toml": `[package]\nname = "arrows"\nentry = "entry.ss"\n[dependencies.base]\ngit = ${JSON.stringify(base)}\n`,
    "entry.ss": 'import pkg:base\nfn label() -> String = base::label()\n',
    "style.ss": 'type StrokeStyle { width: Number = 2 }\n',
    "heads/stealth.ss": 'fn width() -> Number = 10\n',
    "notes.txt": "Not a module",
    "old.style.ss": "Not an importable module name",
    ".hidden.ss": "Not a completion candidate",
  });
  const manifest = `[project]\nentry = "slide.ss"\n[dependencies.arrows]\ngit = ${JSON.stringify(arrows)}\n`;
  await writeFiles(deck, { "ss.toml": manifest, "slide.ss": source, "local.ss": source });

  async function session(file, body) {
    await withLspClient({ cwd: deck, env: offline }, async client => {
      await client.initialize();
      const uri = pathToFileURL(file).href;
      const ready = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source });
      await ready;
      let version = 1;
      async function complete(marked) {
        const offset = marked.indexOf("|");
        assert(offset >= 0);
        const text = marked.replace("|", "") + "\npage main\nend\n";
        const prefix = text.slice(0, offset).split("\n");
        const diagnostics = client.waitForDiagnostics(uri);
        client.changeDocument({ uri, text, version: ++version });
        await diagnostics;
        const result = await client.request("textDocument/completion", {
          textDocument: { uri }, position: { line: prefix.length - 1, character: prefix.at(-1).length },
        });
        assert(result.items.every(item => item.kind === 9 || item.kind === 19), JSON.stringify(result));
        return { text, items: result.items, labels: result.items.map(item => item.label) };
      }
      await body(complete);
    });
  }
  function apply(result, label) {
    const item = result.items.find(item => item.label === label);
    assert(item?.textEdit, JSON.stringify(result));
    const { start, end } = item.textEdit.range;
    const offset = p => result.text.split("\n").slice(0, p.line).reduce((n, line) => n + line.length + 1, 0) + p.character;
    return result.text.slice(0, offset(start)) + item.textEdit.newText + result.text.slice(offset(end));
  }
  const slide = path.join(deck, "slide.ss");
  // Declared dependencies are useful before the first fetch, without a lockfile.
  await session(slide, async complete => {
    for (const input of ['import "|', "import pkg:|", 'import "pkg:ar|rows" as a']) {
      const result = await complete(input);
      assert(result.labels.includes("pkg:arrows"), JSON.stringify(result));
      assert(!result.labels.includes("pkg:base"));
    }
    assert.equal(apply(await complete('import "pkg:ar|'), "pkg:arrows"), 'import "pkg:arrows"\npage main\nend\n');
    assert.deepEqual((await complete('import "pkg:arrows/|')).items, []);
  });
  await assert.rejects(readFile(path.join(deck, "ss.lock")), { code: "ENOENT" });
  await assert.rejects(stat(path.join(deck, ".ss-cache/packages")), { code: "ENOENT" });

  command(ssBin, ["fetch"], deck, 0, offline);
  const locked = await readFile(path.join(deck, "ss.lock"), "utf8");
  const lock = JSON.parse(locked);
  const packageRoot = path.join(deck, ".ss-cache/packages/sources", lock.packages.find(p => p.name === "arrows").id);
  await session(slide, async complete => {
    const rootResult = await complete("import pkg:|");
    assert.deepEqual(rootResult.labels, ["pkg:arrows", "pkg:arrows/"]);
    const modules = await complete('import "pkg:arrows/|');
    assert.deepEqual(modules.labels, ["pkg:arrows/entry", "pkg:arrows/heads/", "pkg:arrows/style"]);
    assert.equal(apply(modules, "pkg:arrows/style"), 'import "pkg:arrows/style"\npage main\nend\n');
    assert.equal(apply(modules, "pkg:arrows/heads/"), 'import "pkg:arrows/heads/\npage main\nend\n');
    const nested = await complete('import "pkg:arrows/heads/st|ealth" as head');
    assert.equal(apply(nested, "pkg:arrows/heads/stealth"), 'import "pkg:arrows/heads/stealth" as head\npage main\nend\n');
    for (const prefix of ["pkg:base/", "pkg:unknown/", "pkg:arrows/../", "pkg:arrows//", "pkg:arrows/heads/../../", "pkg:arrows/missing/"]) {
      assert.deepEqual((await complete(`import "${prefix}|`)).items, []);
    }
    // Re-read manifest data without requiring a watched-file notification.
    await writeFile(path.join(deck, "ss.toml"), manifest.replaceAll("dependencies.arrows", "dependencies.renamed"));
    assert.deepEqual((await complete("import pkg:|")).labels, ["pkg:renamed", "pkg:renamed/"]);
    assert.deepEqual((await complete("import pkg:arrows/|")).items, []);
    await writeFile(path.join(deck, "ss.toml"), "invalid [");
    const invalid = await complete('import "|');
    assert(invalid.labels.includes("std:text"));
    assert(invalid.labels.includes("local"));
    assert(!invalid.labels.some(label => label.startsWith("pkg:")));
    await writeFile(path.join(deck, "ss.toml"), manifest);
  });
  // A package sees its own direct dependencies, not the consumer's.
  await session(path.join(packageRoot, "entry.ss"), async complete => {
    assert.deepEqual((await complete("import pkg:|")).labels, ["pkg:base", "pkg:base/"]);
    assert((await complete("import pkg:base/|")).labels.includes("pkg:base/extra"));
    assert.deepEqual((await complete("import pkg:arrows/|")).items, []);
  });
  // Names survive missing sources; completion never restores them implicitly.
  await rename(packageRoot, packageRoot + ".saved");
  await session(slide, async complete => {
    assert((await complete("import pkg:|")).labels.includes("pkg:arrows"));
    assert.deepEqual((await complete("import pkg:arrows/|")).items, []);
  });
  await assert.rejects(readFile(path.join(packageRoot, "entry.ss")), { code: "ENOENT" });
  assert.equal(await readFile(path.join(deck, "ss.lock"), "utf8"), locked);
  console.log("Package completion: declarations before fetch, scoped dependencies, submodules, edits, stale locks and missing sources passed");
} finally {
  await rm(work, { recursive: true, force: true });
}
