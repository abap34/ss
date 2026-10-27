import assert from "node:assert/strict";
import { lstat, readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { digest } from "./tools.mjs";

// Version 1 describes immutable project inputs and edits to the entry file.
// Sampling, timeouts, compiler options, and trace buffers are run settings.
export function validateWorkload(value) {
  object(value, "workload", ["schema_version", "id", "entry", "inputs", "requires", "expect"], ["$schema", "assets", "editor"]);
  assert.equal(value.schema_version, 1, "unsupported workload schema_version");
  if (value.$schema !== undefined) string(value.$schema, "$schema");
  identifier(value.id, "id");
  relativePath(value.entry, "entry");
  object(value.inputs, "inputs", [], Object.keys(value.inputs ?? {}));
  assert(Object.keys(value.inputs).length > 0, "inputs must not be empty");
  for (const [file, hash] of Object.entries(value.inputs)) {
    relativePath(file, "input path");
    assert(file !== "workload.json", "inputs must not include workload.json itself");
    assert(typeof hash === "string" && hash.length === 64 && /^[a-f0-9]{64}$/.test(hash), `invalid SHA-256 for ${file}`);
  }
  assert(Object.hasOwn(value.inputs, value.entry), "entry must be listed in inputs");
  object(value.requires, "requires", ["fonts"], ["tex"]);
  strings(value.requires.fonts, "requires.fonts", 0);
  if (value.requires.tex !== undefined) {
    object(value.requires.tex, "requires.tex", ["packages"]);
    strings(value.requires.tex.packages, "requires.tex.packages", 0);
    for (const name of value.requires.tex.packages) assert(!/[^A-Za-z0-9_-]/.test(name), `invalid TeX package: ${name}`);
  }
  object(value.expect, "expect", ["pages"]);
  assert(Number.isSafeInteger(value.expect.pages) && value.expect.pages > 0, "expect.pages must be a positive integer");
  if (value.assets !== undefined) {
    object(value.assets, "assets", ["recipe"]);
    relativePath(value.assets.recipe, "assets.recipe");
    assert(Object.hasOwn(value.inputs, value.assets.recipe), "assets.recipe must be listed in inputs");
  }
  if (value.editor !== undefined) {
    object(value.editor, "editor", ["edits", "burst"]);
    assert(Array.isArray(value.editor.edits) && value.editor.edits.length > 0 && value.editor.edits.length <= 30, "editor.edits must contain 1 to 30 edits");
    const ids = new Set();
    for (const edit of value.editor.edits) {
      object(edit, "editor edit", ["id", "before", "after"]);
      identifier(edit.id, "edit id");
      assert(!ids.has(edit.id), `duplicate edit id: ${edit.id}`);
      ids.add(edit.id);
      string(edit.before, `${edit.id}.before`);
      string(edit.after, `${edit.id}.after`);
      assert.notEqual(edit.before, edit.after, `${edit.id} must change the source`);
    }
    assert(Array.isArray(value.editor.burst) && value.editor.burst.length >= 2 && value.editor.burst.length <= 30, "editor.burst must contain 2 to 30 edit ids");
    for (const id of value.editor.burst) assert(ids.has(id), `unknown burst edit: ${id}`);
    for (let index = 1; index < value.editor.burst.length; index++) {
      const edit = value.editor.edits.find((item) => item.id === value.editor.burst[index]);
      const previous = value.editor.edits.find((item) => item.id === value.editor.burst[index - 1]);
      assert(edit.before !== previous.before || edit.after !== previous.after, "adjacent burst edits must differ");
    }
  }
}

export async function loadWorkload(filename) {
  const definition = JSON.parse(await readFile(filename, "utf8"));
  validateWorkload(definition);
  const directory = path.dirname(filename);
  const inventory = (await inputFiles(directory)).filter((file) => file !== path.basename(filename)).sort();
  assert.deepEqual(inventory, Object.keys(definition.inputs).sort(), "inputs must list every project file, excluding workload.json and compiler caches");
  const files = new Map();
  for (const file of inventory) {
    const bytes = await readFile(path.join(directory, file));
    assert.equal(digest(bytes), definition.inputs[file], `workload input changed: ${file}`);
    files.set(file, bytes);
  }
  const source = files.get(definition.entry).toString("utf8");
  const edits = new Map();
  for (const edit of definition.editor?.edits ?? []) {
    const changed = editSource(source, edit);
    assert(![...edits.values()].includes(changed), `duplicate edit result: ${edit.id}`);
    edits.set(edit.id, changed);
  }
  return {
    definition, files, source, edits,
    definition_sha256: digest(canonical(definition)),
    tree_sha256: digest(canonical(definition.inputs)),
  };
}

export function editSource(source, edit) {
  const offset = source.indexOf(edit.before);
  assert(offset >= 0 && source.indexOf(edit.before, offset + 1) < 0, `${edit.id}.before must occur exactly once in the entry file`);
  return source.slice(0, offset) + edit.after + source.slice(offset + edit.before.length);
}

async function inputFiles(directory, prefix = "") {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.name === ".ss-cache" && entry.isDirectory()) continue;
    const name = prefix + entry.name;
    const info = await lstat(path.join(directory, entry.name));
    assert(!info.isSymbolicLink(), `workload inputs must not contain symlinks: ${name}`);
    if (info.isDirectory()) files.push(...await inputFiles(path.join(directory, entry.name), `${name}/`));
    else {
      assert(info.isFile(), `workload input must be a regular file: ${name}`);
      files.push(name);
    }
  }
  return files;
}

function object(value, label, required, optional = []) {
  assert(value !== null && typeof value === "object" && !Array.isArray(value), `${label} must be an object`);
  for (const key of required) assert(Object.hasOwn(value, key), `missing ${label}.${key}`);
  for (const key of Object.keys(value)) assert(required.includes(key) || optional.includes(key), `unknown ${label}.${key}`);
}
function string(value, label) { assert(typeof value === "string" && value.length > 0, `${label} must be a nonempty string`); }
function identifier(value, label) { assert(typeof value === "string" && /^[a-z]/.test(value) && !/[^a-z0-9-]/.test(value), `${label} must be a lowercase identifier`); }
function strings(value, label, minimum) {
  assert(Array.isArray(value) && value.length >= minimum, `${label} must be an array`);
  value.forEach((item) => string(item, label));
  assert.equal(new Set(value).size, value.length, `${label} must not contain duplicates`);
}
function relativePath(value, label) {
  string(value, label);
  assert(!value.includes("\\") && !value.includes("\0") && value.split("/").every((part) => part && part !== "." && part !== ".." && part !== ".ss-cache" && part !== ".agent-artifacts" && !part.includes(":")), `${label} must be a normalized project-relative path`);
}
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value !== null && typeof value === "object") return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
  return JSON.stringify(value);
}
