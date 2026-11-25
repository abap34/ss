import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";

const scratch = path.join(root, ".test-tmp/cli-init");
await mkdir(scratch, { recursive: true });
const output = await mkdtemp(path.join(scratch, "project-"));
const gitConfig = path.join(output, "gitconfig");
await writeFile(gitConfig, "");
const testEnvironment = { ...process.env, GIT_CONFIG_GLOBAL: gitConfig, GIT_CONFIG_NOSYSTEM: "1" };
const generated = ["components.ss", "slide.ss", "ss.toml", "theme.ss"];

function run(cwd, ...args) {
  return runWithEnvironment(cwd, args);
}

function runWithEnvironment(cwd, args, overrides = {}) {
  const result = spawnSync(ssBin, args, {
    cwd, encoding: "utf8", timeout: 60_000, killSignal: "SIGKILL",
    env: { ...testEnvironment, ...overrides },
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
  await testPackages();
  await testPackageValidation();
  await testGitSetup();
  const interactive = spawnSync("python3", [path.join(root, "tests/runtime/cli/init/interactive.py"), ssBin, output], {
    env: testEnvironment, encoding: "utf8", timeout: 60_000, killSignal: "SIGKILL",
  });
  assert.ifError(interactive.error);
  assert.equal(interactive.status, 0, interactive.stdout + interactive.stderr);
  console.log(interactive.stdout.trim());
  console.log("init: package creation, Git import, validation, generated deck, customization, nested entries, and overwrite protection passed");
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
  const command = original.nodes.find(node => node.content === next && node.render?.code);
  assert.equal(command?.render.code.font_size, 22);

  const entry = path.join(cwd, "slide.ss");
  await writeFile(entry, (await readFile(entry, "utf8"))
    .replace("My presentation", "Our project update")
    .replace('text! "Left column"', 'text!("Left column", deck::theme.text with { size = 18 })'));
  const theme = path.join(cwd, "theme.ss");
  await writeFile(theme, (await readFile(theme, "utf8"))
    .replace("#2563eb", "#0d7d16")
    .replace("text.size = 26", "text.size = 29"));
  const components = path.join(cwd, "components.ss");
  await writeFile(components, (await readFile(components, "utf8"))
    .replace("text!(author)", 'text!("By " ++ author)'));
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

async function testPackages() {
  const cwd = await project("packages");
  for (const [directory, entry] of [["arrows", "lib.ss"], ["arrows.ss", "src/library.ss"], ["local", 'source files/lib.ss']]) {
    succeed(cwd, "init", "--package", "--no-git", directory, "--entry", entry);
    const pkg = path.join(cwd, directory);
    assert.deepEqual((await readdir(pkg)).sort(), ["README.md", "examples", entry.split("/")[0], "ss.toml"].sort());
    const manifest = await readFile(path.join(pkg, "ss.toml"), "utf8");
    assert(manifest.includes(`name = "${directory.replace(/\.ss$/, "")}"`));
    assert(manifest.includes(`entry = "${entry}"`));
    succeed(pkg, "dump", "--project", ".", "--output", "example.json");
    const document = JSON.parse(await readFile(path.join(pkg, "example.json"), "utf8"));
    assert.equal(document.page_order.length, 1);
    assert.deepEqual(document.diagnostics, []);
    assert(document.nodes.some(node => node.content === "Hello from a package"));
  }
  const unusual = "parent's space/quoted/";
  const initialized = succeed(cwd, "init", "--package", "--no-git", unusual, "--entry", "src/label.ss");
  const next = initialized.stderr.split("\nnext:\n")[1]?.trim();
  assert(next?.startsWith("ss render "));
  const rendered = spawnSync("sh", ["-c", next], {
    cwd, encoding: "utf8", timeout: 60_000, killSignal: "SIGKILL",
    env: { ...process.env, PATH: `${path.dirname(ssBin)}:${process.env.PATH}` },
  });
  assert.ifError(rendered.error);
  assert.equal(rendered.status, 0, rendered.stderr);
  const existing = await project("existing.ss");
  succeed(existing, "init", "--package", "--no-git", ".");
  assert((await readFile(path.join(existing, "ss.toml"), "utf8")).includes('name = "existing"'));
  succeed(existing, "render", "--project", ".", "--output", "example.pdf");
  assert.equal((await readFile(path.join(existing, "example.pdf"))).subarray(0, 5).toString(), "%PDF-");

  // A generated package must also work through the Git dependency mechanism.
  const { git } = await import("../../packages/harness.mjs");
  git(existing, "init", "-b", "main");
  git(existing, "config", "user.name", "Package Test");
  git(existing, "config", "user.email", "packages@example.invalid");
  git(existing, "add", "ss.toml", "lib.ss");
  git(existing, "commit", "-m", "Generated package");
  const consumer = await project("consumer");
  await writeFile(path.join(consumer, "ss.toml"), '[project]\nentry = "slide.ss"\n');
  await writeFile(path.join(consumer, "slide.ss"), 'import pkg:existing as library\npage example\n  library::label!("Imported package")\nend\n');
  succeed(consumer, "add", "--git", existing);
  succeed(consumer, "dump", "--project", ".", "--output", "result.json");
  assert(JSON.parse(await readFile(path.join(consumer, "result.json"), "utf8")).nodes.some(node => node.content === "Imported package"));
}

async function testPackageValidation() {
  const cwd = await project("invalid_packages");
  for (const name of ["bad-name", ".ss", "end", "arrows.ss.ss"]) {
    assert.notEqual(run(cwd, "init", "--package", "--no-git", name).status, 0);
    assert.deepEqual(await readdir(cwd), [], "invalid names must not create directories");
  }
  for (const entry of ["../outside.ss", "/outside.ss", "readme.txt", 'src/"label".ss', "lib.extra.ss", "examples/slide.ss", "README.md/lib.ss", "examples/slide.ss/lib.ss"]) {
    assert.notEqual(run(cwd, "init", "--package", "--no-git", "valid", "--entry", entry).status, 0);
    assert.deepEqual(await readdir(cwd), [], "invalid entries must not create files");
  }
  for (const file of ["ss.toml", "lib.ss", "README.md", "examples/slide.ss"]) {
    const directory = await project(`protected_${file.replaceAll(/[/.]/g, "_")}`);
    await mkdir(path.dirname(path.join(directory, file)), { recursive: true });
    await writeFile(path.join(directory, file), "Keep this content");
    assert.notEqual(run(directory, "init", "--package", "--no-git").status, 0);
    assert.equal(await readFile(path.join(directory, file), "utf8"), "Keep this content");
    assert.deepEqual((await readdir(directory)).sort(), [file.split("/")[0]]);
    succeed(directory, "init", "--package", "--no-git", "--force");
    assert.notEqual(await readFile(path.join(directory, file), "utf8"), "Keep this content");
  }
  const blocked = await project("blocked");
  await writeFile(path.join(blocked, "examples"), "Keep this file");
  assert.notEqual(run(blocked, "init", "--package", "--no-git", "--force").status, 0);
  assert.deepEqual(await readdir(blocked), ["examples"]);
  assert.equal(await readFile(path.join(blocked, "examples"), "utf8"), "Keep this file");
}

async function testGitSetup() {
  const { git } = await import("../../packages/harness.mjs");
  const cwd = await project("git_setup");
  const origin = directory => git(directory, "remote", "get-url", "origin");
  succeed(cwd, "init", "--package", "arrows.ss", "--user", "alice");
  const arrows = path.join(cwd, "arrows.ss");
  assert.equal(origin(arrows), "https://github.com/alice/arrows.ss");
  assert((await readFile(path.join(arrows, "README.md"), "utf8")).includes("https://github.com/alice/arrows.ss"));
  assert.notEqual(spawnSync("git", ["-C", arrows, "rev-parse", "--verify", "HEAD"], { timeout: 10_000 }).status, 0, "init must not create commits");

  await writeFile(gitConfig, '[github]\nuser = bob\n');
  succeed(cwd, "init", "--package", "inferred");
  assert.equal(origin(path.join(cwd, "inferred")), "https://github.com/bob/inferred.ss");
  succeed(cwd, "init", "--package", "explicit", "--user", "alice");
  assert.equal(origin(path.join(cwd, "explicit")), "https://github.com/alice/explicit.ss");
  succeed(cwd, "init", "--package", "private", "--user", "team/subgroup", "--host", "git.example.com:8443");
  assert.equal(origin(path.join(cwd, "private")), "https://git.example.com:8443/team/subgroup/private.ss");
  succeed(cwd, "init", "--package", "plain", "--no-git");
  assert(!(await readdir(path.join(cwd, "plain"))).includes(".git"));

  const preserved = path.join(cwd, "preserved");
  await mkdir(preserved);
  git(preserved, "init");
  git(preserved, "remote", "add", "origin", "git@example.com:team/custom.git");
  assert.notEqual(run(preserved, "init", "--package", "--force", "--user", "alice").status, 0);
  assert.deepEqual(await readdir(preserved), [".git"], "origin conflicts must be checked before writing templates");
  succeed(preserved, "init", "--package");
  assert.equal(origin(preserved), "git@example.com:team/custom.git");
  succeed(preserved, "init", "--package", "--force", "--no-git");
  assert.equal(origin(preserved), "git@example.com:team/custom.git");

  const parent = path.join(cwd, "parent");
  await mkdir(parent);
  git(parent, "init");
  git(parent, "remote", "add", "origin", "https://example.com/parent.git");
  const result = runWithEnvironment(parent, ["init", "--package", "child", "--user", "alice"], {
    GIT_DIR: path.join(parent, ".git"), GIT_WORK_TREE: parent,
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(origin(parent), "https://example.com/parent.git");
  assert.equal(origin(path.join(parent, "child")), "https://github.com/alice/child.ss");

  const existing = path.join(cwd, "existing");
  await mkdir(existing);
  git(existing, "init");
  succeed(existing, "init", "--package", "--user", "alice");
  assert.equal(origin(existing), "https://github.com/alice/existing.ss");
  succeed(existing, "init", "--package", "--force", "--user", "alice");
  assert.equal(git(existing, "config", "--get-all", "remote.origin.url"), origin(existing));

  const invalid = await project("invalid_git_setup");
  for (const flags of [
    ["--user", ""], ["--user", "../alice"], ["--user", "alice@host"],
    ["--user", "alice\nother"], ["--user", "alice//team"],
    ["--host", "https://example.com", "--user", "alice"],
    ["--host", "example.com/path", "--user", "alice"],
    ["--host", "user@example.com", "--user", "alice"],
    ["--host", "example.com:70000", "--user", "alice"],
    ["--host", "git.example.com"], ["--no-git", "--user", "alice"],
    ["--user"], ["--host"], ["--user", "alice", "--user", "bob"],
  ]) {
    assert.notEqual(run(invalid, "init", "--package", "target", ...flags).status, 0, flags.join(" "));
    assert.deepEqual(await readdir(invalid), []);
  }
  for (const flags of [["--user", "alice"], ["--host", "example.com"], ["--no-git"]]) {
    assert.notEqual(run(invalid, "init", ...flags).status, 0);
    assert.deepEqual(await readdir(invalid), []);
  }
  await writeFile(gitConfig, "");
  const noninteractive = run(invalid, "init", "--package", "target");
  assert.notEqual(noninteractive.status, 0);
  assert(noninteractive.stderr.includes("--user NAME or --no-git"));
  assert(!noninteractive.stderr.includes("(empty to cancel):"));
  assert.deepEqual(await readdir(invalid), []);
}
