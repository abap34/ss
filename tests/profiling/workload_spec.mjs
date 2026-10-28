import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { digest } from "./tools.mjs";
import { editSource, loadWorkload, validateWorkload } from "./workload.mjs";

const source = 'page first\ntext!("Alpha")\nend\n';
function definition() {
  return {
    schema_version: 1, id: "example", entry: "slide.ss",
    inputs: { "slide.ss": digest(source) },
    requires: { fonts: [] }, expect: { pages: 1 },
    editor: {
      edits: [{ id: "first", before: '"Alpha"', after: '"Omega"' }, { id: "second", before: '"Alpha"', after: '"Gamma"' }],
      burst: ["first", "second", "first"],
    },
  };
}

test("mixed deck inventory, hashes, and explicit edits are valid", { timeout: 10_000 }, async () => {
  const workload = await loadWorkload(fileURLToPath(new URL("../fixtures/profiling/mixed-deck/workload.json", import.meta.url)));
  assert.equal(workload.definition.expect.pages, 104);
  assert.equal(workload.edits.size, 3);
  assert.deepEqual([...workload.edits.keys()], ["beginning", "middle", "end"]);
  for (const changed of workload.edits.values()) {
    assert.equal(Buffer.byteLength(changed), Buffer.byteLength(workload.source));
    assert.notEqual(changed, workload.source);
  }
});

test("unsupported versions, unknown keys, malformed values, and invalid edit references fail", { timeout: 10_000 }, () => {
  const invalid = [
    (value) => { value.schema_version = 2; },
    (value) => { value.sample_count = 10; },
    (value) => { value.id = "Example"; },
    (value) => { value.id = "example\n"; },
    (value) => { value.entry = "other.ss"; },
    (value) => { value.expect.pages = 0; },
    (value) => { value.expect.pages = 1.5; },
    (value) => { value.requires.fonts = ["Example", "Example"]; },
    (value) => { value.requires.tex = { packages: ["../example"] }; },
    (value) => { value.requires.tex = { packages: ["example\n"] }; },
    (value) => { value.inputs["slide.ss"] = "not-a-sha256"; },
    (value) => { value.assets = { recipe: "missing.json" }; },
    (value) => { value.editor.edits[1].id = "first"; },
    (value) => { value.editor.edits[0].after = value.editor.edits[0].before; },
    (value) => { value.editor.burst = ["first", "missing"]; },
    (value) => { value.editor.burst = ["first", "first"]; },
    (value) => { value.editor.edits = []; },
  ];
  for (const mutate of invalid) {
    const value = definition();
    mutate(value);
    assert.throws(() => validateWorkload(value));
  }
  for (const file of ["../outside.ss", "/absolute.ss", "a/./b.ss", "a//b.ss", "a/../b.ss", "a\\b.ss", "C:/b.ss", ".ss-cache/a.ss", ".agent-artifacts/a.ss", ".test-tmp/a.ss", "a\0b.ss", "workload.json"]) {
    const value = definition();
    value.inputs[file] = digest(source);
    assert.throws(() => validateWorkload(value), undefined, file);
  }
  for (const value of [null, [], false, "workload", {}]) assert.throws(() => validateWorkload(value));
});

test("literal edits preserve surrounding source and reject ambiguous or missing matches", { timeout: 10_000 }, () => {
  const edit = { id: "text", before: '"Alpha"', after: '"$& \\n"' };
  assert.equal(editSource(source, edit), 'page first\ntext!("$& \\n")\nend\n');
  assert.throws(() => editSource(source + source, edit), /exactly once/);
  assert.throws(() => editSource("unrelated source", edit), /exactly once/);
});

test("loading rejects changed, missing, unlisted, or symlinked inputs", { timeout: 10_000 }, async (context) => {
  const directory = await temporaryProject(context);
  const manifest = path.join(directory, "workload.json");
  await writeFile(path.join(directory, "slide.ss"), `${source}\n`);
  await assert.rejects(loadWorkload(manifest), /input changed/);
  await writeFile(path.join(directory, "slide.ss"), source);
  await writeFile(path.join(directory, "unlisted.ss"), "unexpected input");
  await assert.rejects(loadWorkload(manifest), /list every project file/);
  await rm(path.join(directory, "unlisted.ss"));
  await rm(path.join(directory, "slide.ss"));
  await assert.rejects(loadWorkload(manifest), /list every project file/);
  const target = path.join(directory, "target.ss");
  await writeFile(target, source);
  await symlink(target, path.join(directory, "slide.ss"));
  await assert.rejects(loadWorkload(manifest), /symlinks/);
});

test("fingerprints ignore object ordering and formatting but retain edit meaning", { timeout: 10_000 }, async (context) => {
  const directory = await temporaryProject(context);
  const filename = path.join(directory, "workload.json");
  const first = await loadWorkload(filename);
  const reordered = Object.fromEntries(Object.entries(definition()).reverse());
  await writeFile(filename, JSON.stringify(reordered));
  const second = await loadWorkload(filename);
  assert.equal(first.definition_sha256, second.definition_sha256);
  assert.equal(first.tree_sha256, second.tree_sha256);
  reordered.editor.edits[0].after = '"Delta"';
  await writeFile(filename, JSON.stringify(reordered));
  const third = await loadWorkload(filename);
  assert.notEqual(first.definition_sha256, third.definition_sha256);
  assert.equal(first.tree_sha256, third.tree_sha256);
  await mkdir(path.join(directory, ".ss-cache"));
  await writeFile(path.join(directory, ".ss-cache", "compiler-cache"), "ignored compiler state");
  assert.equal((await loadWorkload(filename)).definition_sha256, third.definition_sha256);
  assert.equal(await readFile(path.join(directory, "slide.ss"), "utf8"), source);
});

test("render-only workloads omit assets, TeX, and editor operations", { timeout: 10_000 }, async (context) => {
  const value = definition();
  delete value.editor;
  const directory = await temporaryProject(context, value);
  const loaded = await loadWorkload(path.join(directory, "workload.json"));
  assert.equal(loaded.edits.size, 0);
});

async function temporaryProject(context, value = definition()) {
  const directory = await mkdtemp(path.join(tmpdir(), "ss-workload-spec-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  await writeFile(path.join(directory, "slide.ss"), source);
  await writeFile(path.join(directory, "workload.json"), JSON.stringify(value));
  return directory;
}
