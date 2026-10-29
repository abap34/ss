import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { terminateProcessTree } from "../runtime/process.mjs";

const root = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const perfettoManifest = JSON.parse(readFileSync(new URL("../../third_party/perfetto/manifest.json", import.meta.url), "utf8"));
export const perfettoVersion = `v${perfettoManifest.version}`;

export function command(executable, args, { cwd = root, input = null, timeoutMs = 180_000, signal, env = process.env } = {}) {
  return new Promise((resolve, reject) => {
    signal?.throwIfAborted();
    const start = performance.now();
    const child = spawn(executable, args, { cwd, env, detached: true, stdio: [input === null ? "ignore" : "pipe", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    let failure = null;
    const stop = (error) => {
      failure ??= error;
      try { terminateProcessTree(child.pid); } catch (killError) { cleanup(); reject(killError); }
    };
    const abort = () => stop(signal.reason ?? new Error("command aborted"));
    const timer = setTimeout(() => stop(new Error(`${path.basename(executable)} exceeded ${timeoutMs}ms`)), timeoutMs);
    const cleanup = () => { clearTimeout(timer); signal?.removeEventListener("abort", abort); };
    signal?.addEventListener("abort", abort, { once: true });
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => { cleanup(); reject(error); });
    child.on("close", (code, exitSignal) => {
      cleanup();
      if (failure) reject(failure);
      else resolve({ code, signal: exitSignal, stdout, stderr, elapsed_ms: performance.now() - start });
    });
    if (input !== null) { child.stdin.on("error", () => {}); child.stdin.end(input); }
  });
}

let pendingProcessor;
export function traceProcessor() {
  pendingProcessor ??= installProcessor().catch((error) => {
    pendingProcessor = undefined;
    throw error;
  });
  return pendingProcessor;
}
async function installProcessor() {
  const installer = fileURLToPath(new URL("../../third_party/perfetto/tools/processor.py", import.meta.url));
  const result = await command(process.env.PYTHON ?? "python3", [installer,
    "--cache", path.join(root, ".test-tmp/profiling/tools"),
    "--platform", `${process.platform}-${process.arch}`,
  ], { timeoutMs: 180_000 });
  assert.equal(result.code, 0, result.stderr);
  const binary = result.stdout.trim();
  assert(path.isAbsolute(binary), `invalid Trace Processor path: ${binary}`);
  return binary;
}

export function digest(bytes) { return createHash("sha256").update(bytes).digest("hex"); }

export async function summarizeRecording(directory) {
  const processor = await traceProcessor();
  const query = fileURLToPath(new URL("summary.sql", import.meta.url));
  const measured = await command(processor, ["--full-sort", "--query-file", query, path.join(directory, "trace.pftrace")], { timeoutMs: 60_000 });
  assert.equal(measured.code, 0, measured.stderr);
  // A single JSON cell keeps the public summary independent of CSV column types.
  const rows = measured.stdout.trim().split(/\r?\n/);
  const cell = rows.at(-1);
  const summary = JSON.parse(cell.startsWith('"') ? cell.slice(1, -1).replaceAll('""', '"') : cell);
  const manifest = JSON.parse(await readFile(path.join(directory, "manifest.json")));
  summary.schema = 2;
  summary.completed = manifest.completed;
  summary.partial = !manifest.completed || summary.loss.length > 0 || summary.unfinished_slices > 0 || summary.mismatched_slices > 0;
  summary.trace_bytes = (await stat(path.join(directory, "trace.pftrace"))).size;
  summary.processor = `Perfetto ${perfettoVersion}`;
  await writeFile(path.join(directory, "summary.json"), JSON.stringify(summary, null, 2) + "\n");
  return summary;
}
