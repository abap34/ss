import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";

const scratch = path.join(root, ".test-tmp/cli-init");
await mkdir(scratch, { recursive: true });
const output = await mkdtemp(path.join(scratch, "project-"));
const generated = ["components.ss", "slide.ss", "ss.toml", "theme.ss"];

function run(cwd, ...args) {
  const result = spawnSync(ssBin, args, {
    cwd, encoding: "utf8", timeout: 60_000, killSignal: "SIGKILL",
  });
  assert.ifError(result.error);
  return result;
}

function succeed(cwd, ...args) {
  const result = run(cwd, ...args);
  assert.equal(result.status, 0, result.stderr);
  return result;
}

async function project(name) {
  const directory = path.join(output, name);
  await mkdir(directory, { recursive: true });
  return directory;
}

async function dump(cwd, name) {
  succeed(cwd, "dump", "--project", ".", "--output", name);
  const document = JSON.parse(await readFile(path.join(cwd, name), "utf8"));
  assert.deepEqual(document.diagnostics, [], "generated deck must have no layout diagnostics");
  assert.equal(document.page_order.length, 3);
  return document;
}

try {
  await testGeneratedDeckAndCustomization();
  await testNestedEntry();
  await testOverwriteProtection();
  await testReservedEntryNames();
  console.log("init: generated deck, customization, nested entries, and overwrite protection passed");
} finally {
  await rm(output, { recursive: true, force: true });
}

async function testGeneratedDeckAndCustomization() {
  const cwd = await project("default");
  const initialized = succeed(cwd, "init");
  assert.deepEqual((await readdir(cwd)).sort(), generated);
  for (const file of generated) assert(initialized.stderr.includes(file));
  const next = initialized.stderr.split("\nnext:\n")[1]?.trim();
  assert.equal(next, "ss render --project . --output deck.pdf");
  succeed(cwd, ...next.split(" ").slice(1));
  assert.equal((await readFile(path.join(cwd, "deck.pdf"))).subarray(0, 5).toString(), "%PDF-");
  const original = await dump(cwd, "original.json");
  assert(original.nodes.some(node => node.content === "My presentation"));
  assert(original.nodes.some(node => node.content === "Source: add a reference here."));
  assert.equal(original.nodes.find(node => node.id === original.page_order[1]).fields.notes, "Add speaker notes here.");
  assert.equal(original.nodes.find(node => node.content === "Left column").render.text.font_size, 26);
  const command = original.nodes.find(node => node.content === next && node.render?.text);
  assert.equal(command?.render.text.font_size, 22);

  const entry = path.join(cwd, "slide.ss");
  await writeFile(entry, (await readFile(entry, "utf8"))
    .replace("My presentation", "Our project update")
    .replace('text! "Left column"', 'text!("Left column", deck::theme.body with { text.size = 18 })'));
  const theme = path.join(cwd, "theme.ss");
  await writeFile(theme, (await readFile(theme, "utf8"))
    .replace("#2563eb", "#0d7d16")
    .replace("body.text.size = 26", "body.text.size = 29"));
  const components = path.join(cwd, "components.ss");
  await writeFile(components, (await readFile(components, "utf8"))
    .replace("text!(author, theme.byline)", 'text!("By " ++ author, theme.byline)'));
  const customized = await dump(cwd, "customized.json");
  assert(customized.nodes.some(node => node.content === "Our project update"));
  assert(customized.nodes.some(node => node.content === "By Your name"));
  assert.equal(customized.nodes.find(node => node.content === "Left column").render.text.font_size, 18);
  assert.equal(customized.nodes.find(node => node.content === "Right column").render.text.font_size, 29);
  const heading = customized.nodes.find(node => node.content === "Text and code" && node.render?.text);
  const color = heading?.render?.text?.color;
  assert(Array.isArray(color));
  for (const [index, expected] of [13 / 255, 125 / 255, 22 / 255].entries()) {
    assert(Math.abs(color[index] - expected) < 0.0001, "theme accent did not reach the heading");
  }
}

async function testNestedEntry() {
  const cwd = await project("nested");
  succeed(cwd, "init", "slides", "--entry", "talks/demo.ss");
  assert.deepEqual((await readdir(path.join(cwd, "slides"))).sort(), ["ss.toml", "talks"]);
  assert.deepEqual((await readdir(path.join(cwd, "slides/talks"))).sort(), ["components.ss", "demo.ss", "theme.ss"]);
  const config = await readFile(path.join(cwd, "slides/ss.toml"), "utf8");
  assert(config.includes('entry = "talks/demo.ss"'));
  succeed(path.join(cwd, "slides"), "render", "--project", ".");
}

async function testOverwriteProtection() {
  for (const file of generated) {
    const cwd = await project(`protected-${file}`);
    await writeFile(path.join(cwd, file), "Keep my edits\n");
    const result = run(cwd, "init", ".");
    assert.notEqual(result.status, 0);
    assert(result.stderr.includes(`${file} already exists`), result.stderr);
    assert.deepEqual(await readdir(cwd), [file], "init wrote part of the project before checking conflicts");
    assert.equal(await readFile(path.join(cwd, file), "utf8"), "Keep my edits\n");
  }

  const cwd = await project("force");
  for (const file of [...generated, "keep.txt"]) await writeFile(path.join(cwd, file), "Keep my edits\n");
  succeed(cwd, "init", ".", "--force");
  for (const file of generated) assert.notEqual(await readFile(path.join(cwd, file), "utf8"), "Keep my edits\n");
  assert.equal(await readFile(path.join(cwd, "keep.txt"), "utf8"), "Keep my edits\n");
  succeed(cwd, "render", "--project", ".");
}

async function testReservedEntryNames() {
  const cwd = await project("reserved");
  for (const entry of ["components.ss", "theme.ss", "ss.toml", "talks/theme.ss", "talks/../ss.toml"]) {
    const result = run(cwd, "init", ".", "--entry", entry, "--force");
    assert.notEqual(result.status, 0);
    assert(result.stderr.includes("--entry conflicts with generated file"), result.stderr);
    assert.deepEqual(await readdir(cwd), []);
  }
}
