import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { root, ssBin } from "../runtime/harness.mjs";
import { command, digest } from "./tools.mjs";
import { ProfileSession, statistics } from "./session.mjs";
import { runSettings } from "./settings.mjs";

const optimize = process.argv[3] ?? "ReleaseSafe";
const source = 'import std:themes/default as *\npage first\ntext!("Alpha")\nend\n';

test("run settings support all build modes and validate effective limits", { timeout: 5000 }, () => {
  for (const mode of ["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"]) assert.equal(runSettings(mode, {}).optimize, mode);
  const settings = runSettings("ReleaseFast", { SS_PROFILE_RECORD: "0", SS_PROFILE_SAMPLES: "12", SS_PROFILE_WARMUPS: "0" });
  assert.equal(settings.record, false);
  assert.equal(settings.samples, 12);
  assert.equal(settings.warmups, 0);
  for (const [name, value] of [["SS_PROFILE_RECORD", "yes"], ["SS_PROFILE_SAMPLES", "0"], ["SS_PROFILE_WARMUPS", "-1"], ["SS_PROFILE_TIMEOUT_MS", "1.5"], ["SS_PROFILE_SCRIPT_TIMEOUT_MS", "0"], ["SS_PROFILE_BUFFER_KB", "63"]]) {
    assert.throws(() => runSettings("ReleaseSafe", { [name]: value }), undefined, name);
  }
  assert.throws(() => runSettings("unknown", {}));
});

test("sample statistics use an even-count median and retain observation order", { timeout: 5000 }, () => {
  assert.deepEqual(statistics([8, 2, 4, 6]), { samples_ms: [8, 2, 4, 6], median_ms: 5, p95_ms: 8 });
  for (const invalid of [[], [NaN], [-1], [Infinity]]) assert.throws(() => statistics(invalid));
});

test("measurement setup is outside the timed action and cleanups run after failure", { timeout: 5000 }, async (context) => {
  const session = await temporarySession(context);
  const events = [];
  for (const name of ["../escape", "name\n", "name/child", ""]) assert.throws(() => session.recording(name), /identifiers/);
  assert.equal(session.recording("custom"), path.join(session.output, "custom"));
  assert.throws(() => session.recording("custom"), /already exists/);
  await assert.rejects(session.save("../escape.json", {}), /inside the output/);
  await assert.rejects(session.save("result.json", {}), /reserved/);
  const measured = await session.measure("custom operation", ({ index, warmup }) => events.push(["measure", index, warmup]), {
    samples: 2, warmups: 1, beforeEach: ({ index }) => events.push(["prepare", index]),
  });
  assert.equal(measured.samples_ms.length, 2);
  assert.deepEqual(events.map((event) => event[0]), ["prepare", "measure", "prepare", "measure", "prepare", "measure"]);
  assert.equal(events[1][2], true);
  assert.equal(events[3][2], false);
  await assert.rejects(session.measure("custom operation", async () => {}), /already exists/);
  await assert.rejects(session.measure("failed operation", async () => { throw new Error("expected failure"); }), /expected failure/);
  session.defer(() => events.push("first cleanup"));
  session.defer(() => { events.push("second cleanup"); throw new Error("cleanup failure"); });
  await assert.rejects(session.close(), /cleanup failed/);
  assert.deepEqual(events.slice(-2), ["second cleanup", "first cleanup"]);
});

test("closing a session stops an outstanding command and waits for exit", { timeout: 5000 }, async (context) => {
  const session = await temporarySession(context);
  const pidFile = path.join(session.project, "pid.txt");
  const running = session.command(process.execPath, ["-e", "require('fs').writeFileSync(process.argv[1],String(process.pid));setInterval(()=>{},1000)", pidFile]);
  const rejected = assert.rejects(running, /session closed/);
  let pid;
  for (let index = 0; index < 100; index++) {
    try { pid = Number(await readFile(pidFile)); break; } catch { await delay(10); }
  }
  assert(pid > 0, "child did not start");
  await session.close();
  await rejected;
  assert.throws(() => process.kill(pid, 0), { code: "ESRCH" });
});

test("command deadlines terminate the process before rejecting", { timeout: 5000 }, async () => {
  await assert.rejects(command(process.execPath, ["-e", "setInterval(()=>{},1000)"], { timeoutMs: 50 }), /exceeded 50ms/);
});

test("custom scripts compose checks, rendering, editor requests, and external inputs", { timeout: 60_000 }, async (context) => {
  const directory = await temporaryWorkload(context, false);
  const scriptDirectory = path.join(directory, "experiment");
  await mkdir(scriptDirectory);
  await writeFile(path.join(scriptDirectory, "helper.mjs"), 'export const caption = "Beta";\n');
  await writeFile(path.join(directory, "external.txt"), "record this dependency\n");
  const script = path.join(scriptDirectory, "run.mjs");
  await writeFile(script, `
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
import { caption } from "./helper.mjs";
export const protocolVersion = 17;
export async function run(p) {
  await p.input(new URL("../external.txt", import.meta.url));
  p.defer(() => p.save("cleaned.json", {closed: true}));
  await p.measure("custom check", async () => {
    const response = await p.command(p.ssBin, ["check", p.workload.definition.entry, "--quiet"]);
    assert.equal(response.code, 0, response.stderr);
  });
  await p.measure("custom render", () => p.render());
  const client = await p.editor();
  const uri = pathToFileURL(p.project + "/slide.ss").href;
  client.openDocument({uri, text: p.workload.source, version: 1});
  const snapshot = () => client.startRequest("ss/editorSnapshot", {textDocument: {uri}}, p.settings.timeout_ms).promise;
  await snapshot();
  let version = 1;
  for (const title of [caption, "Gamma"]) {
    await p.measure("rebuild " + title, async () => {
      client.changeDocument({uri, text: p.workload.source.replace("Alpha", title + ++version), version});
      assert.equal((await snapshot()).layout.pages.length, 1);
    });
  }
  p.result.custom = {editor: true, caption};
}
`);
  const { result, output } = await execute(context, directory, { SS_PROFILE_SCRIPT: script });
  assert.equal(result.status, "success");
  assert.equal(result.script.protocol_version, 17);
  assert.equal(Object.keys(result.script.inputs).length, 3);
  assert(result.script.inputs["helper.mjs"]);
  assert(result.script.inputs["../external.txt"]);
  assert.deepEqual(Object.keys(result.measurements), ["custom check", "custom render", "rebuild Beta", "rebuild Gamma"]);
  assert.equal(result.measurements["custom check"].samples_ms.length, 1);
  assert.deepEqual(result.recordings, {});
  assert.equal(JSON.parse(await readFile(path.join(output, "cleaned.json"))).closed, true);
  assert.equal(await readFile(path.join(directory, "project/slide.ss"), "utf8"), source);
});

test("standard script measures a small deck and works with either recording backend", { timeout: 60_000 }, async (context) => {
  const directory = await temporaryWorkload(context, true);
  const version = await command(ssBin, ["--version"], { timeoutMs: 5000 });
  const record = version.stdout.includes("profiling: Perfetto");
  const { result } = await execute(context, directory, { SS_PROFILE_RECORD: record ? "1" : "0" });
  assert.equal(result.status, "success");
  assert.equal(result.script.protocol_version, 2);
  assert.equal(result.measurements.pdf_cold.samples_ms.length, 1);
  assert.equal(result.measurements.lsp.text_first.samples_ms.length, 1);
  assert.equal(result.measurements.lsp.rapid_edits.outcomes.length, 3);
  assert.deepEqual(Object.keys(result.recordings), record ? ["render-cold", "render-warm", "lsp"] : []);
});

test("script failures and deadlines preserve results and run cleanup", { timeout: 60_000 }, async (context) => {
  const directory = await temporaryWorkload(context, false);
  const experiment = path.join(directory, "experiment");
  await mkdir(experiment);
  const script = path.join(experiment, "run.mjs");
  await writeFile(script, `export const protocolVersion = 1;
export async function run(p) {
  p.defer(() => p.save("cleanup.json", true));
  await p.editor();
  throw new Error("deliberate script failure");
}`);
  const failed = await execute(context, directory, { SS_PROFILE_SCRIPT: script }, 1);
  assert.equal(failed.result.status, "failed");
  assert.match(await readFile(path.join(failed.output, "failure.log"), "utf8"), /deliberate script failure/);
  assert.equal(JSON.parse(await readFile(path.join(failed.output, "cleanup.json"))), true);
  await writeFile(script, `export const protocolVersion = 1;
export async function run(p) {
  p.defer(() => p.save("cleanup.json", true));
  await new Promise(() => {});
}`);
  const expired = await execute(context, directory, { SS_PROFILE_SCRIPT: script, SS_PROFILE_SCRIPT_TIMEOUT_MS: "2000" }, 1);
  assert.equal(expired.result.status, "failed");
  assert.match(await readFile(path.join(expired.output, "failure.log"), "utf8"), /deadline exceeded/);
  assert.equal(JSON.parse(await readFile(path.join(expired.output, "cleanup.json"))), true);
});

test("script module initialization honors the experiment deadline", { timeout: 60_000 }, async (context) => {
  const directory = await temporaryWorkload(context, false);
  const experiment = path.join(directory, "experiment");
  await mkdir(experiment);
  const script = path.join(experiment, "run.mjs");
  await writeFile(script, `await new Promise(() => {});
export const protocolVersion = 1;
export async function run() {}
`);
  const expired = await execute(context, directory, { SS_PROFILE_SCRIPT: script, SS_PROFILE_SCRIPT_TIMEOUT_MS: "2000" }, 1);
  assert.equal(expired.result.status, "failed");
  assert.match(await readFile(path.join(expired.output, "failure.log"), "utf8"), /deadline exceeded/);
  assert.equal(expired.result.script.protocol_version, undefined);
});

async function temporarySession(context) {
  const directory = await mkdtemp(path.join(tmpdir(), "ss-profile-session-"));
  const session = new ProfileSession({ project: directory, output: directory, workload: {}, settings: runSettings("ReleaseSafe", {}), result: { measurements: {}, script: { inputs: {} } }, ssBin, scriptDirectory: directory });
  context.after(async () => { await session.close(); await rm(directory, { recursive: true, force: true }); });
  return session;
}

async function temporaryWorkload(context, editor) {
  const directory = await mkdtemp(path.join(tmpdir(), "ss-profile-runner-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const project = path.join(directory, "project");
  await mkdir(project);
  const definition = { schema_version: 1, id: "small", entry: "slide.ss", inputs: { "slide.ss": digest(source) }, requires: { fonts: [] }, expect: { pages: 1 } };
  if (editor) definition.editor = {
    edits: [{ id: "first", before: "Alpha", after: "Omega" }, { id: "second", before: "Alpha", after: "Gamma" }], burst: ["first", "second", "first"],
  };
  await writeFile(path.join(project, "slide.ss"), source);
  await writeFile(path.join(project, "workload.json"), JSON.stringify(definition));
  return directory;
}

async function execute(context, directory, env, expectedCode = 0) {
  const response = await command(process.execPath, ["tests/profiling/run.mjs", ssBin, optimize], { timeoutMs: 55_000, env: {
    ...process.env, SS_PROFILE_WORKLOAD: path.join(directory, "project/workload.json"),
    SS_PROFILE_SCRIPT: path.join(root, "tests/profiling/experiments/standard/run.mjs"),
    SS_PROFILE_RECORD: "0", SS_PROFILE_SAMPLES: "1", SS_PROFILE_WARMUPS: "0", SS_PROFILE_TIMEOUT_MS: "20000", SS_PROFILE_SCRIPT_TIMEOUT_MS: "50000", ...env,
  } });
  const match = response.stdout.match(/Profiling results: (.+)/);
  assert(match, response.stdout + response.stderr);
  const output = path.join(root, match[1]);
  context.after(() => rm(output, { recursive: true, force: true }));
  assert.equal(response.code, expectedCode, response.stdout + response.stderr);
  return { output, result: JSON.parse(await readFile(path.join(output, "result.json"))) };
}
