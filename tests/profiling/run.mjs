#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, readdir, writeFile } from "node:fs/promises";
import { cpus, release, totalmem } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { root, ssBin } from "../runtime/harness.mjs";
import { digest, summarizeRecording } from "./tools.mjs";
import { loadWorkload } from "./workload.mjs";
import { runSettings } from "./settings.mjs";
import { ProfileSession } from "./session.mjs";

const settings = runSettings(process.argv[3]);
const loaded = await loadWorkload(path.resolve(root, process.env.SS_PROFILE_WORKLOAD ?? "tests/fixtures/profiling/mixed-deck/workload.json"));
const workload = loaded.definition;
const scriptPath = path.resolve(root, process.env.SS_PROFILE_SCRIPT ?? "tests/profiling/experiments/standard/run.mjs");
const scriptDirectory = path.dirname(scriptPath);
const scriptInputs = await fingerprints(scriptDirectory);
const runnerInputs = await fingerprints(path.join(root, "tests/profiling"), false);
for (const file of ["tests/runtime/harness.mjs", "tests/runtime/process.mjs"]) runnerInputs[file] = digest(await readFile(path.join(root, file)));
await mkdir(path.join(root, ".agent-artifacts/profiling"), { recursive: true });
const output = await mkdtemp(path.join(root, ".agent-artifacts/profiling/run-"));
const project = path.join(output, "project");
const result = {
  schema: 3,
  workload: { definition: workload, definition_sha256: loaded.definition_sha256, tree_sha256: loaded.tree_sha256 },
  script: { entry: path.basename(scriptPath), inputs: scriptInputs },
  settings: { ...settings, runner_inputs: runnerInputs },
  measurements: {},
  recordings: {},
};
const session = new ProfileSession({ project, output, workload: loaded, settings, result, ssBin, scriptDirectory });
let failure;
let deadline;
try {
  for (const [file, bytes] of loaded.files) {
    const destination = path.join(project, file);
    await mkdir(path.dirname(destination), { recursive: true });
    await writeFile(destination, bytes);
  }
  const { environment, fontFiles } = await preflight();
  result.environment = environment;
  if (workload.assets) {
    const generated = await session.command(process.env.PYTHON ?? "python3", [path.join(root, "tests/profiling/assets.py")], {
      input: JSON.stringify({ destination: project, specification: JSON.parse(loaded.files.get(workload.assets.recipe)), font_files: fontFiles }),
    });
    assert.equal(generated.code, 0, generated.stderr);
    result.workload.generated_assets = JSON.parse(generated.stdout);
  }
  const validation = await session.validate();
  result.validation = { pages: validation.page_order.length };
  deadline = setTimeout(() => session.controller.abort(new Error("profiling script deadline exceeded")), settings.script_timeout_ms);
  const interrupted = new Promise((_, reject) => session.signal.addEventListener("abort", () => reject(session.signal.reason), { once: true }));
  const script = await Promise.race([import(pathToFileURL(scriptPath)), interrupted]);
  assert.equal(typeof script.run, "function", "profiling script must export async function run(session)");
  assert(Number.isSafeInteger(script.protocolVersion) && script.protocolVersion > 0, "profiling script must export a positive integer protocolVersion");
  result.script.protocol_version = script.protocolVersion;
  session.signal.throwIfAborted();
  await Promise.race([script.run(session), interrupted]);
} catch (error) {
  failure = error;
} finally {
  clearTimeout(deadline);
  try { await session.close(); } catch (error) { failure = failure ? new AggregateError([failure, error], "script and cleanup failed") : error; }
}
try {
  for (const [name, directory] of session.recordings) {
    const summary = await summarizeRecording(directory);
    result.recordings[name] = { slices: summary.slices, trace_bytes: summary.trace_bytes, loss: summary.loss };
    assert.equal(summary.partial, false, `${name} has incomplete trace data; increase SS_PROFILE_BUFFER_KB or checkpoint more often`);
  }
} catch (error) { failure ??= error; }
result.status = failure ? "failed" : "success";
if (failure) await writeFile(path.join(output, "failure.log"), String(failure.stack ?? failure));
await writeFile(path.join(output, "result.json"), JSON.stringify(result, null, 2) + "\n");
console.log(`Profiling results: ${path.relative(root, output)}`);
console.log(JSON.stringify(result.measurements, null, 2));
if (failure) throw failure;

async function preflight() {
  const versionResult = await session.command(ssBin, ["--version"]);
  assert.equal(versionResult.code, 0, versionResult.stderr);
  const version = (versionResult.stdout + versionResult.stderr).trim();
  if (settings.record) assert(version.includes("profiling: Perfetto"), "build with -Dprofiling=true or set SS_PROFILE_RECORD=0 for timing only");
  let latexVersion = null;
  if (workload.requires.tex) {
    const latex = await session.command("pdflatex", ["--version"]);
    assert.equal(latex.code, 0, "install pdflatex before running this workload");
    latexVersion = latex.stdout.split("\n")[0];
    for (const name of workload.requires.tex.packages) {
      const found = await session.command("kpsewhich", [`${name}.sty`]);
      assert(found.code === 0 && found.stdout.trim(), `missing TeX package: ${name}`);
    }
  }
  const fonts = [], fontFiles = [];
  for (const family of workload.requires.fonts) {
    const match = await session.command("fc-match", ["-f", "%{family}\n%{file}\n", family]);
    assert.equal(match.code, 0, "fontconfig fc-match is required");
    const [actual, filename] = match.stdout.trim().split("\n");
    assert(actual.replaceAll(" ", "").toLowerCase().includes(family.replaceAll(" ", "").toLowerCase()), `missing font ${family}; fontconfig selected ${actual}`);
    fontFiles.push(filename);
    fonts.push({ family, actual_family: actual, sha256: digest(await readFile(filename)) });
  }
  return { fontFiles, environment: {
    platform: process.platform, architecture: process.arch, os_release: release(),
    cpu_model: cpus()[0]?.model ?? "unknown", logical_cpus: cpus().length, total_memory_bytes: totalmem(),
    node: process.version, ss_binary_sha256: digest(await readFile(ssBin)), ss_version: version,
    pdflatex_version: latexVersion, fonts,
  } };
}

async function fingerprints(directory, recursive = true, prefix = "") {
  const files = {};
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const name = prefix + entry.name;
    assert(!entry.isSymbolicLink(), `profiling script inputs must not contain symlinks: ${name}`);
    if (entry.isDirectory() && recursive) Object.assign(files, await fingerprints(path.join(directory, entry.name), true, name + "/"));
    else if (entry.isFile() && (recursive || (/\.(mjs|py|sql|json)$/.test(name) && !name.includes("_spec.")))) files[name] = digest(await readFile(path.join(directory, entry.name)));
  }
  return files;
}
