#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync,
  rmSync, symlinkSync, writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const worker = path.resolve(process.argv[2]);
const output = path.join(root, ".ss-cache", "tree-sitter-build-tests");
mkdirSync(output, { recursive: true });
const temporary = mkdtempSync(path.join(output, "case-"));
const active = new Set();
const manifestText = readFileSync(path.join(root, "third_party/tree-sitter-languages/manifest.json"), "utf8");
const manifest = JSON.parse(manifestText);
const hash = createHash("sha256").update(manifestText).digest("hex").slice(0, 24);
const shared = path.join(temporary, "shared");
const seed = path.join(temporary, "sources");
const barrier = path.join(temporary, "release");
const started = path.join(temporary, "fetch-started");
const fetched = path.join(temporary, "fetches");
const bin = path.join(temporary, "bin");
const zig = process.env.SS_TEST_ZIG || "zig";

function write(relative, text) {
  const target = path.join(seed, relative);
  mkdirSync(path.dirname(target), { recursive: true });
  writeFileSync(target, text);
}
write("runtime/lib/src/lib.c", "/* runtime */\n");
write("runtime/lib/include/tree_sitter/api.h", "#define TREE_SITTER_LANGUAGE_VERSION 15\n#define TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION 13\n");
for (const language of manifest.languages) {
  for (const file of language.files) {
    if (!file.to.startsWith("src/") && !file.to.startsWith("common/") && !file.to.includes("/src/")) continue;
    write(`${language.name}/${file.from}`, `/* ${language.name}/${file.from} */\n`);
    for (const header of ["parser.h", "alloc.h", "array.h"]) {
      write(`${language.name}/${path.dirname(file.from)}/tree_sitter/${header}`, "/* support */\n");
    }
  }
}
mkdirSync(bin);
writeFileSync(path.join(bin, "git"), `#!${process.execPath}
const fs = require("node:fs");
const path = require("node:path");
const command = process.argv[2];
if (command === "fetch") {
  fs.appendFileSync(process.env.SS_TEST_FETCHES, process.cwd() + "\\n");
  fs.writeFileSync(process.env.SS_TEST_STARTED, "ready");
  const deadline = Date.now() + 120000;
  while (!fs.existsSync(process.env.SS_TEST_BARRIER)) {
    if (Date.now() > deadline) process.exit(3);
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
  }
} else if (command === "checkout") {
  const name = path.basename(process.cwd());
  fs.cpSync(path.join(process.env.SS_TEST_SEED, name === "tree-sitter-runtime" ? "runtime" : name), process.cwd(), { recursive: true });
}
`, { mode: 0o755 });
const environment = {
  ...process.env,
  PATH: `${bin}${path.delimiter}${process.env.PATH}`,
  SS_TEST_SEED: seed,
  SS_TEST_BARRIER: barrier,
  SS_TEST_STARTED: started,
  SS_TEST_FETCHES: fetched,
};

function run(command, args, cwd = root, seconds = 120) {
  const child = spawn(command, args, { cwd, env: environment, detached: process.platform !== "win32", stdio: ["ignore", "pipe", "pipe"] });
  active.add(child);
  let text = "";
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; kill(child); }, seconds * 1000);
  const done = new Promise((resolve, reject) => {
    child.stdout.on("data", (chunk) => { text += chunk; });
    child.stderr.on("data", (chunk) => { text += chunk; });
    child.on("error", reject);
    child.on("close", (code) => {
      clearTimeout(timer);
      active.delete(child);
      if (timedOut) reject(new Error(`Timed out: ${command} ${args.join(" ")}\n${text}`));
      else resolve({ code, text });
    });
  });
  return done;
}
function kill(child) {
  if (!child.pid) return;
  try {
    if (process.platform === "win32") child.kill("SIGKILL");
    else process.kill(-child.pid, "SIGKILL");
  } catch (error) {
    if (error.code !== "ESRCH") throw error;
  }
}
async function success(command, args, cwd) {
  const result = await run(command, args, cwd);
  assert.equal(result.code, 0, result.text);
  return result;
}
async function waitFor(file) {
  const deadline = Date.now() + 90000;
  while (!existsSync(file)) {
    assert(Date.now() < deadline, `Timed out waiting for ${file}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}
function buildArgs(target, cache = shared, extra = []) {
  return ["build", target, `-Dtree-sitter-cache=${cache}`, "-Dcommit=test", "--summary", "all", ...extra];
}
function checkout(name) {
  const target = path.join(temporary, name);
  mkdirSync(target);
  for (const entry of readdirSync(root)) {
    if (entry.startsWith(".") || ["zig-out", "_workspace", "dev.sh"].includes(entry)) continue;
    symlinkSync(path.join(root, entry), path.join(target, entry));
  }
  return target;
}
try {
  const noNative = ["-Dqpdf-cxx=ss-missing-cxx", "-Dqpdf-pkg-config=ss-missing-pkg-config"];
  await success(zig, buildArgs("--help", shared, noNative));
  assert(!existsSync(shared), "build graph construction created the source cache");
  await success(zig, buildArgs("test-language-type", shared, noNative));
  await success(zig, buildArgs("test-fs", shared, noNative));
  assert(!existsSync(shared), "an independent test prepared tree-sitter sources");
  assert(!existsSync(fetched), "an independent test fetched a source repository");

  const firstCheckout = checkout("first");
  const secondCheckout = checkout("second");
  const first = run(zig, buildArgs("tree-sitter-prepare"), firstCheckout);
  await waitFor(started);
  const second = run(zig, buildArgs("tree-sitter-prepare"), secondCheckout);
  for (const command of ["clear", "prune"]) {
    const result = await run(worker, [command, shared]);
    assert.notEqual(result.code, 0);
    assert.match(result.text, /ActiveTreeSitterCacheLease/);
  }
  writeFileSync(barrier, "continue");
  const results = await Promise.all([first, second]);
  for (const result of results) assert.equal(result.code, 0, result.text);
  const fetches = readFileSync(fetched, "utf8").trim().split("\n");
  assert.equal(fetches.length, manifest.languages.length + 1, "concurrent builders fetched the same manifest twice");
  const bundle = path.join(shared, "bundles", hash);
  assert.equal(JSON.parse(readFileSync(path.join(bundle, "complete.json"))).manifest_hash, hash);
  assert.deepEqual(readdirSync(path.join(shared, "bundles")), [hash]);
  for (const language of manifest.languages) {
    for (const file of language.files) {
      if (!file.to.startsWith("src/") && !file.to.startsWith("common/") && !file.to.includes("/src/")) continue;
      assert.equal(readFileSync(path.join(bundle, "generated", language.name, file.to), "utf8"), `/* ${language.name}/${file.from} */\n`);
    }
  }
  await success(zig, buildArgs("tree-sitter-prepare"), firstCheckout);
  assert.equal(readFileSync(fetched, "utf8").trim().split("\n").length, fetches.length);
  await success(worker, ["clear", shared]);
  assert(!existsSync(shared));

  const failedCache = path.join(temporary, "failed");
  const required = manifest.languages[0].files.find((file) => file.to === "src/parser.c");
  rmSync(path.join(seed, manifest.languages[0].name, required.from));
  const failed = await run(zig, buildArgs("tree-sitter-prepare", failedCache, [`-Dtree-sitter-sources=${seed}`]));
  assert.notEqual(failed.code, 0);
  assert.match(failed.text, /failed to copy tree-sitter source/);
  assert.deepEqual(readdirSync(path.join(failedCache, "bundles")), []);
  await success(worker, ["clear", failedCache]);
  write(`${manifest.languages[0].name}/${required.from}`, "/* repaired */\n");
  await success(zig, buildArgs("tree-sitter-prepare", failedCache, [`-Dtree-sitter-sources=${seed}`]));
  assert(existsSync(path.join(failedCache, "bundles", hash, "complete.json")));
  console.log("isolated build dependencies, concurrent publication, leases, and recovery passed");
} finally {
  for (const child of active) kill(child);
  if (active.size) await Promise.all([...active].map((child) => new Promise((resolve) => child.once("close", resolve))));
  rmSync(temporary, { recursive: true, force: true });
}
