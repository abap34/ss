import assert from "node:assert/strict";
import { execFile, spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { pathToFileURL } from "node:url";
import { root, ssBin, withLspClient } from "../harness.mjs";
import { WatchProcess } from "../watch/harness.mjs";
import { command as executeCommand, git, repository as createRepository } from "./harness.mjs";

const scratch = path.join(root, ".test-tmp/packages");
await mkdir(scratch, { recursive: true });
const work = await mkdtemp(path.join(scratch, "git-"));
const deck = path.join(work, "deck");
await mkdir(deck);
const quote = JSON.stringify;
const command = (binary, args, cwd = deck, expected = 0) => executeCommand(binary, args, cwd, expected);
const ss = (...args) => command(ssBin, args);
const repository = (name, files) => createRepository(work, name, files);
async function lock() { return JSON.parse(await readFile(path.join(deck, "ss.lock"), "utf8")); }
async function config() { return readFile(path.join(deck, "ss.toml"), "utf8"); }
function fail(pattern, ...args) {
  const result = command(ssBin, args, deck, 1);
  assert.match(result.stderr, pattern);
}
async function dump(source, output = "output.json") {
  await writeFile(path.join(deck, "slide.ss"), source);
  ss("dump", "--quiet", "--output", output);
  return JSON.parse(await readFile(path.join(deck, output), "utf8"));
}
function texts(document) { return document.nodes.filter(n => n.kind === "object").map(n => n.content).join("\n"); }
const configSource = '# Keep this comment.\n[project]\nentry = "slide.ss"\n';
try {
  const base = await repository("base library", {
    "ss.toml": '[package]\nname = "base"\nentry = "lib.ss"\n',
    "lib.ss": 'type Label { value: String }\nfn label() -> Label\n  return Label { value = "First" }\nend\n',
    "extra.ss": 'fn extra() -> String\n  return "Extra"\nend\n',
  });
  git(base, "tag", "v1");
  const first = git(base, "rev-parse", "HEAD");
  const wrapper = await repository("wrapper", {
    "ss.toml": `[package]\nname = "wrapper"\nentry = "lib.ss"\n[dependencies]\nbase = { git = ${quote(base)}, tag = "v1" }\n`,
    "ss.lock": "This package lock is deliberately invalid and must be ignored by consumers.\n",
    "lib.ss": 'import pkg:base\nfn show(value: base::Label) -> String\n  return value.value\nend\nfn caption() -> String\n  return base::label().value\nend\n',
  });
  await writeFile(path.join(deck, "ss.toml"), configSource);
  ss("add", "--git", base, "--tag", "v1");
  ss("add", "--git", wrapper, "--branch", "main");
  assert((await config()).startsWith(configSource));
  let fixed = await lock();
  assert.equal(fixed.packages.length, 2, "shared package identity must be reused");
  assert.equal(fixed.packages.find(p => p.git === base).commit, first);
  const wrapperId = fixed.packages.find(p => p.git === wrapper).id;
  const initialLock = await readFile(path.join(deck, "ss.lock"), "utf8");
  const practical = 'import pkg:base\nimport pkg:base/extra as extra\nimport pkg:wrapper\npage main\n  text!(wrapper::show(base::label()))\n  text!(extra::extra())\nend\n';
  assert.match(texts(await dump(practical)), /First[\s\S]*Extra/);
  await writeFile(path.join(base, "lib.ss"), (await readFile(path.join(base, "lib.ss"), "utf8")).replace("First", "Second"));
  git(base, "add", "."); git(base, "commit", "-m", "Update label"); git(base, "tag", "-f", "v1");
  ss("fetch");
  assert.equal((await lock()).packages.find(p => p.git === base).commit, first, "fetch must preserve moved tags");
  assert.match(texts(await dump(practical)), /First/);
  assert.match(ss("update", "base").stderr, /base@[0-9a-f]{12}[\s\S]*used by project, wrapper/);
  fixed = await lock();
  assert.equal(fixed.packages.find(p => p.git === wrapper).id, wrapperId);
  assert.equal(fixed.packages.filter(p => p.git === base).length, 1, "a shared source specification must update everywhere");
  assert.match(texts(await dump(practical)), /Second[\s\S]*Extra/);
  const changed = 'import pkg:wrapper\npage main\n  text!(wrapper::caption())\nend\n';
  assert.match(texts(await dump(changed)), /Second/);
  const beforeConfig = await config();
  const beforeLock = await readFile(path.join(deck, "ss.lock"), "utf8");
  fail(/GitCommandFailed/, "add", "--git", base, "--tag", "missing-tag");
  assert.equal(await config(), beforeConfig);
  assert.equal(await readFile(path.join(deck, "ss.lock"), "utf8"), beforeLock);
  fail(/DependencyAlreadyExists/, "add", "--git", base);
  fail(/InvalidDependencySource/, "add", "--git", base, "--tag", "v1", "--branch", "main");
  fail(/UnknownPackage/, "update", "unknown");
  ss("fetch", "--locked");
  assert.equal(await readFile(path.join(deck, "ss.lock"), "utf8"), beforeLock);
  await rename(base, `${base}.offline`);
  await rename(wrapper, `${wrapper}.offline`);
  ss("fetch");
  assert.match(texts(await dump(changed)), /Second/);
  ss("render", "--quiet", "--output", "offline.pdf");
  assert((await readFile(path.join(deck, "offline.pdf"))).subarray(0, 5).equals(Buffer.from("%PDF-")));
  await rm(path.join(deck, ".ss-cache", "packages", "sources"), { recursive: true });
  fail(/PackageNotFetched[\s\S]*ss fetch/, "dump", "--quiet", "--output", "missing.json");
  ss("fetch", "--locked"); // Restore snapshots from retained Git objects without the remotes.
  // Both graphs used by the editor below must have their snapshots available.
  await writeFile(path.join(deck, "ss.lock"), initialLock);
  ss("fetch", "--locked");
  await writeFile(path.join(deck, "ss.lock"), beforeLock);
  assert.match(texts(await dump(changed)), /Second/);
  for (const spec of ["pkg:base/../outside", "pkg:base/extra.ss", "pkg:/base", "pkg:base//extra"]) {
    await writeFile(path.join(deck, "slide.ss"), `import ${quote(spec)} as x\npage main\nend\n`);
    fail(/InvalidPackageImport|InvalidImportSpec/, "dump", "--quiet", "--output", "invalid.json");
  }
  await writeFile(path.join(deck, "ss.toml"), `${beforeConfig}\n[dependencies.missing]\ngit = "https://example.invalid/missing"\n`);
  await writeFile(path.join(deck, "slide.ss"), changed);
  fail(/ss fetch/, "dump", "--quiet", "--output", "stale.json");
  await writeFile(path.join(deck, "ss.toml"), beforeConfig);
  await dump(changed);
  const fakeBin = path.join(work, "no-git");
  await mkdir(fakeBin);
  const gitProbe = path.join(work, "git-called");
  await writeFile(path.join(fakeBin, "git"), `#!/bin/sh\necho called > ${quote(gitProbe)}\nexit 42\n`);
  await chmod(path.join(fakeBin, "git"), 0o755);
  const env = { ...process.env, PATH: `${fakeBin}${path.delimiter}${process.env.PATH}` };
  const offlineDump = spawnSync(ssBin, ["dump", "--quiet", "--output", "without-git.json"], { cwd: deck, env, encoding: "utf8", timeout: 60000 });
  assert.ifError(offlineDump.error);
  assert.equal(offlineDump.status, 0, offlineDump.stderr);
  const uri = pathToFileURL(path.join(deck, "slide.ss")).href;
  await withLspClient({ cwd: deck, env }, async client => {
    await client.initialize();
    const ready = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: changed, version: 1 });
    assert.deepEqual((await ready).params.diagnostics, []);
    const line = changed.split("\n")[2];
    const definition = await client.request("textDocument/definition", {
      textDocument: { uri }, position: { line: 2, character: line.indexOf("caption") + 1 },
    });
    assert(definition?.some(target => target.uri.includes("/.ss-cache/packages/sources/")), JSON.stringify(definition));
    const initial = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert(initial.display.html.includes("Second"));
    await writeFile(path.join(deck, "ss.lock"), initialLock);
    const refreshed = client.waitForDiagnostics(uri);
    client.notify("workspace/didChangeWatchedFiles", { changes: [{ uri: pathToFileURL(path.join(deck, "ss.lock")).href, type: 2 }] });
    await refreshed;
    const updated = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert(updated.display.html.includes("First"));
  });
  await assert.rejects(readFile(gitProbe), { code: "ENOENT" });
  await writeFile(path.join(deck, "ss.lock"), beforeLock);
  const watching = new WatchProcess(deck, ["render", "--format", "html", "--quiet", "--project", deck, "--output", "observed.html"]);
  try {
    await watching.waitForOutput(path.join(deck, "observed.html"), bytes => bytes.includes("Second"), "initial package contents");
    await writeFile(path.join(deck, "ss.lock"), initialLock);
    await watching.waitForOutput(path.join(deck, "observed.html"), bytes => bytes.includes("First"), "locked package update");
    await writeFile(path.join(deck, "ss.lock"), beforeLock);
    await watching.waitForOutput(path.join(deck, "observed.html"), bytes => bytes.includes("Second"), "restored package update");
  } finally {
    await watching.close();
  }
  const damaged = JSON.parse(beforeLock);
  damaged.packages[0].id = "../escape";
  await writeFile(path.join(deck, "ss.lock"), JSON.stringify(damaged));
  fail(/InvalidPackageLock/, "dump", "--quiet", "--output", "damaged.json");
  await writeFile(path.join(deck, "ss.lock"), beforeLock);
  // Update all must also refresh a package's transitive declarations.
  await rename(`${base}.offline`, base);
  await rename(`${wrapper}.offline`, wrapper);
  ss("update");
  assert.equal((await lock()).packages.length, 2);
  assert.match(texts(await dump(practical)), /Second[\s\S]*Extra/);
  const assets = await repository("assets", {
    "ss.toml": '[package]\nname = "assets"\nentry = "parts/lib.ss"\n',
    "parts/lib.ss": 'fn badge!() -> Placed<Image>\n  return image!(asset_path("badge.svg"))\nend\nfn caption() -> String\n  return readlines(asset_path("caption.txt"))\nend\n',
    "parts/caption.txt": "Packaged caption",
    "parts/badge.svg": '<svg xmlns="http://www.w3.org/2000/svg" width="30" height="20"><rect width="30" height="20" fill="red"/></svg>',
  });
  ss("add", "--git", assets);
  const document = await dump('import pkg:assets\npage main\n  assets::badge!()\n  text!(assets::caption())\nend\n');
  assert.match(texts(document), /Packaged caption/);
  ss("render", "--quiet", "--output", "assets.pdf");
  const inlineDeck = path.join(work, "inline");
  await mkdir(inlineDeck);
  const inlineSource = '# preserve inline settings\nproject = { entry = "slide.ss" }\ndependencies = { assets = { git = ' + quote(assets) + ' } } # preserve dependency comment\n';
  await writeFile(path.join(inlineDeck, "ss.toml"), inlineSource);
  await writeFile(path.join(inlineDeck, "slide.ss"), 'import pkg:assets\npage main\n  text!(assets::caption())\nend\n');
  command(ssBin, ["add", "--git", wrapper, "--branch", "main", "--project", inlineDeck]);
  const editedInline = await readFile(path.join(inlineDeck, "ss.toml"), "utf8");
  assert(editedInline.includes("# preserve inline settings"));
  assert(editedInline.includes("# preserve dependency comment"));
  command(ssBin, ["dump", "--quiet", "--project", inlineDeck, "--output", path.join(inlineDeck, "inline.json")]);
  const concurrent = path.join(work, "concurrent");
  await mkdir(concurrent);
  await writeFile(path.join(concurrent, "ss.toml"), configSource);
  const execute = promisify(execFile);
  await Promise.all([["--git", base, "--tag", "v1"], ["--git", wrapper]].map(args => execute(ssBin, ["add", ...args], {
    cwd: concurrent, timeout: 60000,
  })));
  const concurrentLock = JSON.parse(await readFile(path.join(concurrent, "ss.lock"), "utf8"));
  assert.deepEqual(concurrentLock.dependencies.map(edge => edge.name), ["base", "wrapper"]);
  assert.equal(concurrentLock.packages.length, 2);
  const custom = path.join(work, "custom.toml");
  await writeFile(custom, 'project.entry = "deck/slide.ss"\n[dependencies]\nwrapper = { git = ' + quote(wrapper) + ', branch = "main" }\n');
  await writeFile(path.join(deck, "slide.ss"), changed);
  command(ssBin, ["fetch", "--project", custom]);
  command(ssBin, ["dump", "--quiet", "--project", custom, "--output", path.join(work, "custom.json")]);
  assert.match(texts(JSON.parse(await readFile(path.join(work, "custom.json"), "utf8"))), /Second/);
  const pinned = path.join(work, "pinned");
  await mkdir(pinned);
  await writeFile(path.join(pinned, "ss.toml"), configSource);
  await writeFile(path.join(pinned, "slide.ss"), 'import pkg:base\npage main\n  text!(base::label().value)\nend\n');
  command(ssBin, ["add", "--git", base, "--rev", first], pinned);
  command(ssBin, ["dump", "--quiet", "--output", "pinned.json"], pinned);
  assert.match(texts(JSON.parse(await readFile(path.join(pinned, "pinned.json"), "utf8"))), /First/);
  const cycleAPath = path.join(work, "cycle-a");
  const cycleBPath = path.join(work, "cycle-b");
  const cycleA = await repository("cycle-a", {
    "ss.toml": '[package]\nname = "a"\nentry = "lib.ss"\n[dependencies]\nb = { git = ' + quote(cycleBPath) + ' }\n',
    "lib.ss": "",
  });
  await repository("cycle-b", {
    "ss.toml": '[package]\nname = "b"\nentry = "lib.ss"\n[dependencies]\na = { git = ' + quote(cycleAPath) + ' }\n',
    "lib.ss": "",
  });
  const beforeCycleConfig = await config();
  const beforeCycleLock = await readFile(path.join(deck, "ss.lock"), "utf8");
  fail(/Package dependency cycle: a@[0-9a-f]{12} -> b@[0-9a-f]{12} -> a@[0-9a-f]{12}[\s\S]*PackageDependencyCycle/, "add", "--git", cycleA);
  assert.equal(await config(), beforeCycleConfig);
  assert.equal(await readFile(path.join(deck, "ss.lock"), "utf8"), beforeCycleLock);
  console.log("Git packages: fixed commits, offline restore, scoped dependencies, shared types, assets and failures passed");
} finally {
  await rm(work, { recursive: true, force: true });
}
