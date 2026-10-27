#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { LspClient, ssBin } from "../harness.mjs";
import { terminateProcessTree } from "../process.mjs";
import { command, digest, summarizeRecording, traceProcessor } from "../../profiling/tools.mjs";

const project = await mkdtemp(path.join(tmpdir(), "ss-profile-spec-"));
const source = `import std:themes/default as *
page first
let heading = text!("Alpha PROFILE_PRIVATE_TOKEN")
end
page second
text!("Second page")
end
`;
try {
  await writeFile(path.join(project, "slide.ss"), source);
  const version = await run(["--version"]);
  if (!version.stdout.includes("profiling: Perfetto")) {
    const unavailable = await run(["check", "slide.ss", "--profile", path.join(project, "unavailable")]);
    assert.notEqual(unavailable.code, 0);
    assert.match(unavailable.stderr, /-Dprofiling=true/);
    console.log("profiling: disabled build rejects recording without fetching tools");
  } else {
    await traceProcessor();
    await testSharedBoundaries();
    await testCli();
    await testWatch();
    await testLsp();
    console.log("profiling: SDK traces, worker attribution, errors, cancellation, checkpoints, privacy, and output parity passed");
  }
} finally { await rm(project, { recursive: true, force: true }); }

async function testSharedBoundaries() {
  const directory = path.join(project, "shared-boundaries");
  const generated = await command(path.resolve(process.argv[3]), [directory]);
  assert.equal(generated.code, 0, generated.stderr);
  const summary = await summarizeRecording(directory);
  assert.equal(summary.partial, false);
  assert.equal(summary.mismatched_slices, 0);
  const processor = await traceProcessor();
  const intervals = await command(processor, ["--full-sort", "-Q", `
    SELECT child.ts = parent.ts AND child.dur < parent.dur AS valid
    FROM slice child JOIN slice parent
    WHERE child.name = 'semantics_call_graph' AND parent.name = 'static_semantics'`, path.join(directory, "trace.pftrace")]);
  assert.equal(intervals.code, 0, intervals.stderr);
  assert.equal(intervals.stdout.trim().split(/\r?\n/).at(-1), "1", "same-start nesting changed the named durations");
  const crossing = await command(processor, ["--full-sort", "-Q", `
    SELECT first.ts < second.ts AND first.ts + first.dur > second.ts
      AND first.ts + first.dur < second.ts + second.dur AS valid
    FROM slice first JOIN slice second
    WHERE first.name = 'module_graph' AND second.name = 'module_index'`, path.join(directory, "trace.pftrace")]);
  assert.equal(crossing.code, 0, crossing.stderr);
  assert.equal(crossing.stdout.trim().split(/\r?\n/).at(-1), "1", "crossing completed intervals lost their boundaries");
}

async function testCli() {
  assert.equal((await run(["dump", "slide.ss", "plain.json", "--quiet"])).code, 0);
  const directory = path.join(project, "cli");
  const recorded = await run(["dump", "slide.ss", "recorded.json", "--quiet", "--jobs", "2", "--profile", directory]);
  assert.equal(recorded.code, 0, recorded.stderr);
  assert.deepEqual(JSON.parse(await readFile(path.join(project, "plain.json"))), JSON.parse(await readFile(path.join(project, "recorded.json"))));
  const cli = await readRecording(directory);
  assert.equal(cli.manifest.input_sha256, digest(source));
  assert.equal(cli.summary.partial, false, JSON.stringify(cli.summary.loss));
  assert.equal(cli.summary.unfinished_slices, 0);
  assert.equal(cli.summary.mismatched_slices, 0, "completed span boundaries exchanged their partners");
  assert(cli.summary.stages.some((stage) => stage.category === "analysis"));
  assert(cli.summary.stages.some((stage) => stage.category === "function"));
  assert(cli.summary.stages.some((stage) => stage.category.includes("cache")));
  const operation = cli.summary.operations.find((op) => op.name === "dump" && op.outcome === "success");
  assert(operation);
  assert(cli.summary.threads.some((item) => item.operation === operation.operation && item.count >= 2), "page workers lost their initiating operation");
  assert(cli.summary.samples.some((sample) => sample.name === "process.peak_rss_bytes" && sample.maximum > 0));
  const processor = await traceProcessor();
  const nested = await command(processor, ["--full-sort", "-Q", `
    SELECT COUNT(*) AS invalid FROM slice child JOIN slice parent
      ON child.name = 'readSource' AND parent.name = 'analyzeFile'
      AND EXTRACT_ARG(child.arg_set_id, 'debug.operation') = EXTRACT_ARG(parent.arg_set_id, 'debug.operation')
    WHERE child.ts < parent.ts OR child.ts + child.dur > parent.ts + parent.dur`, path.join(directory, "trace.pftrace")]);
  assert.equal(nested.code, 0, nested.stderr);
  assert.equal(nested.stdout.trim().split(/\r?\n/).at(-1), "0", "readSource escaped analyzeFile");
  const manifest = await readFile(path.join(directory, "manifest.json"));
  assert.notEqual((await run(["check", "slide.ss", "--profile", directory])).code, 0);
  assert.deepEqual(await readFile(path.join(directory, "manifest.json")), manifest);
  for (const args of [["--profile-buffer-kb", "2"], ["--profile-buffer-kb", "64"], ["--profile", path.join(project, "invalid"), "--profile-buffer-kb", "1048577"]]) {
    assert.notEqual((await run(["check", "slide.ss", ...args])).code, 0);
  }
  const crowded = "import std:themes/default as *\n" + Array.from({ length: 100 }, (_, index) => `page p${index}\ntext!("Page ${index}")\nend\n`).join("");
  await writeFile(path.join(project, "crowded.ss"), crowded);
  const limitedDirectory = path.join(project, "limited");
  const limitedRun = await run(["check", "crowded.ss", "--quiet", "--profile", limitedDirectory, "--profile-buffer-kb", "64"]);
  assert.equal(limitedRun.code, 0, limitedRun.stderr);
  const limited = await readRecording(limitedDirectory);
  assert.equal(limited.manifest.buffer_kb, 64);
  assert(limited.summary.partial && limited.summary.loss.length > 0, "overflow must be reported as incomplete data");
  await writeFile(path.join(project, "broken.ss"), "page broken\nlet x =\nend\n");
  const failedDirectory = path.join(project, "failed");
  assert.notEqual((await run(["check", "broken.ss", "--profile", failedDirectory, "--quiet"])).code, 0);
  const failed = await readRecording(failedDirectory);
  assert(failed.summary.operations.some((op) => op.outcome === "failed"));
}

async function testWatch() {
  const directory = path.join(project, "watch");
  const child = spawn(ssBin, ["watch", "check", "slide.ss", "--quiet", "--interval-ms", "50", "--profile", directory], { cwd: project, detached: true, stdio: ["ignore", "ignore", "pipe"] });
  child.stderr.resume();
  const exited = new Promise((resolve, reject) => { child.once("error", reject); child.once("exit", resolve); });
  const timer = setTimeout(() => terminateProcessTree(child.pid), 30_000);
  try {
    await waitForBuilds(1);
    await writeFile(path.join(project, "slide.ss"), source.replace("Alpha", "Omega"));
    await waitForBuilds(2);
  } finally {
    clearTimeout(timer);
    terminateProcessTree(child.pid);
    await exited;
    await writeFile(path.join(project, "slide.ss"), source);
  }
  const watched = await readRecording(directory);
  assert(watched.manifest.checkpoints >= 2);
  assert.equal(watched.summary.completed, false);
  assert(watched.summary.operations.filter((op) => op.name === "watch.check" && op.outcome === "success").length >= 2);
  async function waitForBuilds(count) {
    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline) {
      try {
        const manifest = JSON.parse(await readFile(path.join(directory, "manifest.json")));
        if (manifest.checkpoints >= count) return;
      } catch (error) { if (error.code !== "ENOENT" && !(error instanceof SyntaxError)) throw error; }
      await new Promise((resolve) => setTimeout(resolve, 30));
    }
    throw new Error(`watch checkpoint ${count} timed out`);
  }
}

async function testLsp() {
  const directory = path.join(project, "lsp");
  const client = new LspClient({ cwd: project, profileDirectory: directory });
  const uri = pathToFileURL(path.join(project, "slide.ss")).href;
  const timer = setTimeout(() => terminateProcessTree(client.child.pid), 60_000);
  try {
    await client.initialize();
    const opened = client.waitForDiagnostics(uri, (_, message) => message.params.version === 1, "opened");
    client.openDocument({ uri, text: source, version: 1 });
    await opened;
    await client.request("ss/editorSnapshot", { textDocument: { uri } });
    const filler = Array.from({ length: 100_000 }, () => ";; PROFILE_PRIVATE_TOKEN").join("\n");
    client.changeDocument({ uri, version: 2, text: `${source}${filler}\n` });
    const request = client.startRequest("textDocument/completion", { textDocument: { uri }, position: { line: 0, character: 0 } }, 30_000);
    const outcome = request.promise.then(() => null, (error) => error);
    client.cancelRequest(request.id);
    assert.match((await outcome)?.message ?? "", /-32800/);
    const restored = client.waitForDiagnostics(uri, (_, message) => message.params.version === 3, "restored");
    client.changeDocument({ uri, version: 3, text: source.replace("Alpha", "Omega") });
    await restored;
    await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert.deepEqual(await client.request("ss/profile", {}), { written: true });
    const checkpoint = await readRecording(directory);
    assert(checkpoint.summary.operations.some((op) => op.name === "ss/editorSnapshot"));
    assert(checkpoint.summary.operations.some((op) => op.outcome === "canceled"));
    assert(checkpoint.summary.stages.some((stage) => stage.category === "queue"));
    assert(checkpoint.summary.operations.some((op) => op.version === 3));
    assert(checkpoint.summary.operations.some((op) => op.request > 0));
    await client.close();
    const final = await readRecording(directory);
    assert(final.summary.operations.some((op) => op.name === "lsp" && op.outcome === "success"));
    assert.equal(final.summary.partial, false, JSON.stringify(final.summary.loss));
    assert.equal(final.summary.unfinished_slices, 0);
    const layoutStages = final.summary.stages.filter((stage) => stage.category === "wysiwyg");
    assert(layoutStages.length > 0);
    for (const stage of layoutStages) {
      assert.notEqual(stage.operation, 0, "structured layout work lost its initiating operation");
      assert(final.summary.operations.some((operation) => operation.operation === stage.operation && operation.name !== "lsp"), `${stage.name} has no initiating request or rebuild`);
    }
  } finally {
    clearTimeout(timer);
    if (!client.exitStatus) { try { await client.close(); } catch { terminateProcessTree(client.child.pid); } }
  }
}

async function readRecording(directory) {
  const summary = await summarizeRecording(directory);
  const manifest = JSON.parse(await readFile(path.join(directory, "manifest.json")));
  for (const file of ["manifest.json", "summary.json", "trace.pftrace"]) {
    const bytes = await readFile(path.join(directory, file));
    for (const sensitive of ["PROFILE_PRIVATE_TOKEN", project, "file://"]) assert(!bytes.includes(Buffer.from(sensitive)), `recorded ${sensitive}`);
  }
  assert.equal(manifest.schema, 2);
  assert.equal(summary.schema, 2);
  return { manifest, summary };
}
function run(args) { return command(ssBin, args, { cwd: project, timeoutMs: 45_000 }); }
