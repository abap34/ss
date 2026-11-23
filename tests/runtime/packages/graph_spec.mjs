import assert from "node:assert/strict";
import { chmod, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../harness.mjs";
import { command, commit, git, repository, writeFiles } from "./harness.mjs";

const scratch = path.join(root, ".test-tmp/packages");
await mkdir(scratch, { recursive: true });
const work = await mkdtemp(path.join(scratch, "graph-"));
const quote = JSON.stringify;
const manifest = (name, dependencies = {}) => `[package]\nname = ${quote(name)}\n${declarations(dependencies)}`;
function declarations(dependencies) {
  return Object.entries(dependencies).map(([name, source]) =>
    `\n[dependencies.${name}]\n${Object.entries(source).map(([key, value]) => `${key} = ${quote(value)}\n`).join("")}`).join("");
}
const repo = (name, files = {}, dependencies = {}) => repository(work, name, {
  "ss.toml": manifest(name, dependencies), "lib.ss": "", ...files,
});
const ss = (deck, ...args) => command(ssBin, args, deck);
const bytes = (deck, file = "ss.lock") => readFile(path.join(deck, file), "utf8");
const lock = async deck => JSON.parse(await bytes(deck));
async function deck(name, dependencies = {}) {
  const directory = path.join(work, name);
  await writeFiles(directory, { "ss.toml": `[project]\nentry = "slide.ss"\n${declarations(dependencies)}`, "slide.ss": "page main\nend\n" });
  return directory;
}
async function failure(directory, pattern, ...args) {
  const before = await Promise.all([bytes(directory, "ss.toml"), bytes(directory).catch(e => {
    if (e.code !== "ENOENT") throw e;
    return null;
  })]);
  const result = command(ssBin, args, directory, 1);
  assert.match(result.stderr, pattern);
  assert.equal(await bytes(directory, "ss.toml"), before[0]);
  assert.equal(await bytes(directory).catch(e => {
    if (e.code !== "ENOENT") throw e;
    return null;
  }), before[1]);
  return result;
}
async function dump(directory, source, expected = 0) {
  await writeFile(path.join(directory, "slide.ss"), source);
  return command(ssBin, ["dump", "--quiet", "--output", "out.json"], directory, expected);
}
try {
  // The old lock's selections apply to new routes before any graph traversal.
  const d = await repo("d", { "lib.ss": 'fn value() -> String\n  return "Old"\nend\n' });
  const oldD = git(d, "rev-parse", "HEAD");
  const c = await repo("c", {}, { d: { git: d, branch: "main" } });
  const b = await repo("b", {}, { c: { git: c } });
  const a = await repo("a", {}, { c: { git: c } });
  const z = await repo("z", {}, { c: { git: c } });
  const original = await deck("original", { b: { git: b } });
  ss(original, "fetch");
  await writeFile(path.join(d, "lib.ss"), 'fn value() -> String\n  return "New"\nend\n');
  const newD = commit(d, "Advance branch");
  for (const [name, added] of [["before", a], ["after", z]]) {
    const project = await deck(name, { b: { git: b } });
    await copyFile(path.join(original, "ss.lock"), path.join(project, "ss.lock"));
    ss(project, "add", "--git", added);
    assert.equal((await lock(project)).packages.find(p => p.git === d).commit, oldD, "adding a route must preserve every known source selection");
    const beforeUpdate = await bytes(project);
    ss(project, "fetch");
    assert.equal(await bytes(project), beforeUpdate);
    ss(project, "update", "b");
    assert.equal((await lock(project)).packages.find(p => p.git === d).commit, oldD, "updating a parent does not implicitly refresh unchanged child sources");
    ss(project, "add", "--git", d, "--branch", "main");
    const parentCommit = (await lock(project)).packages.find(p => p.git === c).commit;
    ss(project, "update", "d");
    const updated = await lock(project);
    assert.equal(updated.packages.filter(p => p.git === d).length, 1);
    assert.equal(updated.packages.find(p => p.git === d).commit, newD);
    assert.equal(updated.packages.find(p => p.git === c).commit, parentCommit);
  }
  const e = await repo("e");
  await writeFile(path.join(b, "ss.toml"), manifest("b", { c: { git: c }, e: { git: e } }));
  const newB = commit(b, "Introduce dependency");
  const parentUpdate = await deck("parent-update", { b: { git: b } });
  await copyFile(path.join(original, "ss.lock"), path.join(parentUpdate, "ss.lock"));
  ss(parentUpdate, "fetch");
  assert(!(await lock(parentUpdate)).packages.some(p => p.git === e));
  ss(parentUpdate, "update", "b");
  const parentResult = await lock(parentUpdate);
  assert(parentResult.packages.some(p => p.git === e));
  assert.equal(parentResult.packages.find(p => p.git === b).commit, newB);
  assert.equal(parentResult.packages.find(p => p.git === d).commit, oldD);
  const permutation = await deck("permutation", { z: { git: z }, b: { git: b }, a: { git: a } });
  await copyFile(path.join(original, "ss.lock"), path.join(permutation, "ss.lock"));
  ss(permutation, "fetch");
  const canonical = await bytes(permutation);
  const reverse = await deck("reverse", { a: { git: a }, b: { git: b }, z: { git: z } });
  await copyFile(path.join(original, "ss.lock"), path.join(reverse, "ss.lock"));
  ss(reverse, "fetch");
  assert.equal(await bytes(reverse), canonical, "manifest visitation order must not affect canonical lock output");

  // Locked restoration fetches only exact object IDs, never branch/tag refs.
  const realGit = command("sh", ["-c", "command -v git"], work).stdout.trim();
  const probe = path.join(work, "git-commands");
  const bin = path.join(work, "bin");
  await mkdir(bin);
  await writeFile(path.join(bin, "git"), `#!/bin/sh\nprintf '%s\\n' "$*" >> ${quote(probe)}\nexec ${quote(realGit)} "$@"\n`);
  await chmod(path.join(bin, "git"), 0o755);
  const env = { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}` };
  const restored = await deck("restored", { a: { git: a }, b: { git: b }, z: { git: z } });
  await copyFile(path.join(permutation, "ss.lock"), path.join(restored, "ss.lock"));
  command(ssBin, ["fetch", "--locked"], restored, 0, env);
  assert.equal(await bytes(restored), canonical);
  assert(!(await readFile(probe, "utf8")).includes("refs/heads/"));
  assert(!(await readFile(probe, "utf8")).includes(" HEAD"));
  await writeFile(probe, "");
  command(ssBin, ["update"], permutation, 0, env);
  const calls = (await readFile(probe, "utf8")).trim().split("\n");
  assert.equal(calls.filter(line => line.endsWith(`fetch --no-tags -- ${d} refs/heads/main`)).length, 1, "shared branch selection resolves once per update");
  assert.equal((await lock(permutation)).packages.find(p => p.git === d).commit, newD);
  const missing = await deck("missing-lock");
  await failure(missing, /PackageLockRequired/, "fetch", "--locked");
  await writeFile(path.join(restored, "ss.toml"), `[project]\nentry = "slide.ss"\n${declarations({ b: { git: b } })}`);
  await failure(restored, /PackageLockRequired/, "fetch", "--locked");
  await writeFile(path.join(restored, "ss.lock"), "{ invalid json");
  await failure(restored, /InvalidPackageLock/, "fetch", "--locked");
  const altered = JSON.parse(canonical);
  altered.packages.find(p => p.git === d).entry = "absent.ss";
  await writeFile(path.join(reverse, "ss.lock"), JSON.stringify(altered));
  await failure(reverse, /PackageLockRequired/, "fetch", "--locked");

  // Different source specifications share nominal types only at the same commit.
  const base = await repo("base", { "lib.ss": 'type Label { value: String }\nfn make() -> Label\n  return Label { value = "Shared" }\nend\n' });
  const first = git(base, "rev-parse", "HEAD");
  git(base, "tag", "v1");
  const left = await repo("left", { "lib.ss": 'import pkg:base\nfn make() -> base::Label\n  return base::make()\nend\n' }, { base: { git: base, tag: "v1" } });
  const right = await repo("right", { "lib.ss": 'import pkg:base\nfn show(value: base::Label) -> String\n  return value.value\nend\n' }, { base: { git: base, branch: "main" } });
  const types = await deck("types", { left: { git: left }, right: { git: right } });
  ss(types, "fetch");
  assert.equal((await lock(types)).packages.filter(p => p.git === base).length, 1);
  const practical = 'import pkg:left as l\nimport pkg:right as r\npage main\n  text!(r::show(l::make()))\nend\n';
  await dump(types, practical);
  assert.match(await bytes(types, "out.json"), /Shared/);
  assert.match((await dump(types, "import pkg:base\npage main\nend\n", 1)).stderr, /UnknownPackage/);
  await writeFile(path.join(base, "lib.ss"), (await bytes(base, "lib.ss")).replace("Shared", "Changed"));
  const second = commit(base, "Change library");
  ss(types, "fetch");
  assert.equal((await lock(types)).packages.find(p => p.git === base).commit, first);
  ss(types, "update");
  assert.deepEqual((await lock(types)).packages.filter(p => p.git === base).map(p => p.commit).sort(), [first, second].sort());
  assert.match((await dump(types, practical, 1)).stderr, /TypeMismatch/);

  const otherBase = path.join(work, "other-base");
  command("git", ["clone", "--", base, otherBase], work);
  await writeFile(path.join(right, "ss.toml"), manifest("right", { base: { git: otherBase, rev: first } }));
  commit(right, "Use another repository with the same package name");
  ss(types, "update", "right");
  const distinctRepositories = (await lock(types)).packages.filter(p => p.name === "base");
  assert.equal(distinctRepositories.length, 2);
  assert(distinctRepositories.every(p => p.commit === first));
  assert.notEqual(distinctRepositories[0].id, distinctRepositories[1].id);
  assert.match((await dump(types, practical, 1)).stderr, /TypeMismatch/);

  // Identity cycles differ from revisiting the same repository at an older commit.
  const versioned = await repo("versioned");
  const v1 = git(versioned, "rev-parse", "HEAD");
  const adapter = await repo("adapter", {}, { versioned: { git: versioned, rev: v1 } });
  await writeFile(path.join(versioned, "ss.toml"), manifest("versioned", { adapter: { git: adapter, rev: git(adapter, "rev-parse", "HEAD") } }));
  const v2 = commit(versioned, "Depend on adapter");
  const acyclic = await deck("acyclic");
  ss(acyclic, "add", "--git", versioned, "--rev", v2);
  assert.equal((await lock(acyclic)).packages.length, 3);

  // Failed additions and mismatched hand-written names never modify project files.
  const invalid = await deck("invalid");
  for (const [name, metadata, pattern] of [
    ["unnamed", "[package]\n", /MissingPackageName/],
    ["badname", '[package]\nname = "bad-name"\n', /InvalidPackageName/],
    ["noentry", '[package]\nname = "noentry"\nentry = "missing.ss"\n', /InvalidPackageEntry/],
  ]) {
    const target = await repo(name, { "ss.toml": metadata });
    await failure(invalid, pattern, "add", "--git", target);
  }
  ss(invalid, "add", "--git", base, "--rev", first);
  const duplicate = await repo("duplicate", { "ss.toml": manifest("base") });
  await failure(invalid, /DependencyAlreadyExists/, "add", "--git", duplicate);
  await failure(invalid, /usage:/, "add", "alias", "--git", base);
  await failure(invalid, /usage:/, "add", "--git", base, "--locked");
  await failure(invalid, /usage:/, "update", "--locked");
  await writeFile(path.join(invalid, "ss.toml"), `[project]\nentry = "slide.ss"\n${declarations({ wrong: { git: base } })}`);
  await failure(invalid, /Dependency 'wrong' declares package.name = 'base'[\s\S]*PackageNameMismatch/, "fetch");
  console.log("Package graph: order independence, global selections, locked restoration, scoped names and nominal identity passed");
} finally {
  await rm(work, { recursive: true, force: true });
}
