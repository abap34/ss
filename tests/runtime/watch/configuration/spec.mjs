import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { root } from "../../harness.mjs";
import { WatchProcess, settle } from "../harness.mjs";

const scratch = path.join(root, ".ss-cache", "tests", "watch-configuration");
await mkdir(scratch, { recursive: true });
await testReloadAndRecovery();
await testExplicitOverrides();
await testConfigurationDiscovery();
console.log("Watch configuration: reload, discovery, explicit overrides and recovery passed");

async function testReloadAndRecovery() {
  const directory = await mkdtemp(path.join(scratch, "reload-"));
  let watch;
  try {
    await prepare(directory);
    watch = new WatchProcess(directory, ["render", "--format", "html", "--quiet", "--project", directory]);
    await watch.waitFor(() => watch.log.includes("ProjectConfigNotFound:"), "missing initial configuration");
    await writeConfiguration(directory, "first.ss", "assets-first");
    await waitForHtml(watch, directory, "first.html", "First input");
    assert(watch.log.includes("watch: project configuration is valid"), watch.log);

    await writeConfiguration(directory, "second.ss", "assets-second");
    await waitForHtml(watch, directory, "second.html", "Second input");
    await rm(path.join(directory, "second.ss"));
    await watch.waitFor(() => watch.log.includes("InputReadFailed:"), "deleted active entry");
    await writeFile(path.join(directory, "assets-second", "content.data"), "Recreated entry input");
    await writeFile(path.join(directory, "second.ss"), deck());
    await waitForHtml(watch, directory, "second.html", "Recreated entry input");
    await settle();
    const changes = watch.occurrences("watch: change detected");
    await writeFile(path.join(directory, "first.ss"), "invalid obsolete source");
    await writeFile(path.join(directory, "assets-first", "content.data"), "Unused input");
    await settle();
    assert.equal(watch.occurrences("watch: change detected"), changes, watch.log);

    await rename(path.join(directory, "assets-second"), path.join(directory, "saved-assets"));
    await writeFile(path.join(directory, "assets-second"), "not a directory");
    await watch.waitFor(() => watch.log.includes("could not inspect asset base directory"), "asset inspection failure");
    await writeConfiguration(directory, "second.ss", "assets-first");
    await waitForHtml(watch, directory, "second.html", "Unused input");

    const missing = watch.occurrences("ProjectConfigNotFound:");
    await rm(path.join(directory, "ss.toml"));
    await watch.waitFor(() => watch.occurrences("ProjectConfigNotFound:") > missing, "deleted configuration");
    await writeFile(path.join(directory, "ss.toml"), '[project]\nentry = "second.ss"\n[cli]\njobs = 0\n');
    await watch.waitFor(() => watch.log.includes("InvalidCliJobs:"), "invalid replacement configuration");
    await settle();
    const errors = watch.occurrences("InvalidCliJobs:");
    await settle();
    assert.equal(watch.occurrences("InvalidCliJobs:"), errors, watch.log);
    await writeFile(path.join(directory, "assets-first", "content.data"), "Recovered input");
    await writeConfiguration(directory, "second.ss", "assets-first");
    await waitForHtml(watch, directory, "second.html", "Recovered input");
  } finally {
    await watch?.close();
    await rm(directory, { recursive: true, force: true });
  }
}

async function testExplicitOverrides() {
  const directory = await mkdtemp(path.join(scratch, "overrides-"));
  let watch;
  try {
    await prepare(directory);
    await writeConfiguration(directory, "first.ss", "assets-first");
    watch = new WatchProcess(directory, [
      "render", "--format", "html", "--quiet", "--project", directory,
      "first.ss", "--output", "selected.html", "--asset-base-dir", "assets-first", "--jobs", "1",
    ]);
    await waitForHtml(watch, directory, "selected.html", "First input");
    await writeFile(path.join(directory, "second.ss"), "invalid unused entry");
    await writeFile(path.join(directory, "assets-first", "content.data"), "Explicit input");
    await writeConfiguration(directory, "second.ss", "assets-second", '[cli]\njobs = 4\ndiagnostic_level = "note"\n');
    await waitForHtml(watch, directory, "selected.html", "Explicit input");
    assert.equal(await exists(path.join(directory, "second.html")), false, watch.log);
    assert.equal(await exists(path.join(directory, "first.html")), false, watch.log);
  } finally {
    await watch?.close();
    await rm(directory, { recursive: true, force: true });
  }
}

async function testConfigurationDiscovery() {
  const directory = await mkdtemp(path.join(scratch, "discovery-"));
  let watch;
  try {
    await prepare(directory);
    const inner = path.join(directory, "inner");
    await mkdir(inner);
    await writeFile(path.join(inner, "slide.ss"), deck());
    await writeConfiguration(directory, "first.ss", "assets-first");
    watch = new WatchProcess(inner, ["render", "--format", "html", "--quiet", "slide.ss", "observed.html"]);
    await waitForHtml(watch, inner, "observed.html", "First input");
    await writeConfiguration(inner, "slide.ss", "../assets-second");
    await waitForHtml(watch, inner, "observed.html", "Second input");
    await settle();
    const changes = watch.occurrences("watch: project configuration changed");
    await writeConfiguration(directory, "second.ss", "assets-first");
    await settle();
    assert.equal(watch.occurrences("watch: project configuration changed"), changes, watch.log);
    await rm(path.join(inner, "ss.toml"));
    await waitForHtml(watch, inner, "observed.html", "First input");
    await mkdir(path.join(inner, "ss.toml"));
    await watch.waitFor(() => watch.log.includes("ProjectConfigIsDirectory:"), "invalid discovered configuration kind");
    await writeFile(path.join(directory, "assets-first", "content.data"), "Recovered discovery");
    await rm(path.join(inner, "ss.toml"), { recursive: true });
    await waitForHtml(watch, inner, "observed.html", "Recovered discovery");
  } finally {
    await watch?.close();
    await rm(directory, { recursive: true, force: true });
  }
}

async function prepare(directory) {
  for (const [name, content] of [["first", "First input"], ["second", "Second input"]]) {
    await mkdir(path.join(directory, `assets-${name}`));
    await writeFile(path.join(directory, `assets-${name}`, "content.data"), content);
    await writeFile(path.join(directory, `${name}.ss`), deck());
  }
}

function deck() {
  return 'import std:themes/default as *\npage main\ntext!(readlines("content.data"))\nend\n';
}

async function writeConfiguration(directory, entry, assets, extra = "") {
  await writeFile(path.join(directory, "ss.toml"), `[project]\nentry = "${entry}"\nasset_base_dir = "${assets}"\n${extra}`);
}

async function waitForHtml(watch, directory, name, content) {
  await watch.waitFor(async () => {
    try { return (await readFile(path.join(directory, name), "utf8")).includes(content); } catch (error) {
      if (error.code === "ENOENT") return false;
      throw error;
    }
  }, `${name} containing ${content}`);
}

async function exists(file) {
  try { await stat(file); return true; } catch (error) {
    if (error.code === "ENOENT") return false;
    throw error;
  }
}
