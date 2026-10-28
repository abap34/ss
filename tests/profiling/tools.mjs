import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { terminateProcessTree } from "../runtime/process.mjs";

const root = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
export const perfettoVersion = "v58.2";
const distributions = {
  "linux-x64": ["linux-amd64.zip", "32c739f71b2d39721afd294c0b038f2499a44a71b5b6bcdd85b83faca0b240b9"],
  "linux-arm64": ["linux-arm64.zip", "a82bf4111a340a7ea8577bcfd62e014e8e81b9e6a35a3190f5415fb800051ab0"],
  "darwin-x64": ["mac-amd64.zip", "1ec01f5de30fbf3b4e91c2b96508e3f537f0f57d1d1ce4bdf0892c98c4de039c"],
  "darwin-arm64": ["mac-arm64.zip", "9dbd484a32c9833c95cf58ca5ef86d2c9ad4767149054ad4eaa52bdf027d1507"],
};

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
  pendingProcessor ??= installProcessor();
  return pendingProcessor;
}
async function installProcessor() {
  const platform = `${process.platform}-${process.arch}`;
  const distribution = distributions[platform];
  assert(distribution, `no pinned Trace Processor for ${platform}`);
  const [archive, expected] = distribution;
  const parent = path.join(root, ".test-tmp/profiling/tools", perfettoVersion);
  const destination = path.join(parent, platform);
  const binary = path.join(destination, "trace_processor_shell");
  try {
    const info = JSON.parse(await readFile(path.join(destination, "verified.json")));
    if (info.archive_sha256 === expected && info.binary_sha256 === digest(await readFile(binary))) return binary;
  } catch { /* Install or replace an incomplete tool cache. */ }
  await mkdir(parent, { recursive: true });
  const temporary = await mkdtemp(path.join(parent, "download-"));
  try {
    const response = await fetch(`https://github.com/google/perfetto/releases/download/${perfettoVersion}/${archive}`, { signal: AbortSignal.timeout(60_000) });
    assert(response.ok, `Trace Processor download failed: ${response.status}`);
    const bytes = Buffer.from(await response.arrayBuffer());
    assert(bytes.length < 40_000_000 && digest(bytes) === expected, "Trace Processor archive checksum mismatch");
    const archivePath = path.join(temporary, "tools.zip");
    const temporaryBinary = path.join(temporary, "trace_processor_shell");
    await writeFile(archivePath, bytes);
    const extracted = await command(process.env.PYTHON ?? "python3", ["-c", `import sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
 names=[name for name in archive.namelist() if name.rsplit('/',1)[-1]=='trace_processor_shell']
 if len(names)!=1: raise ValueError('expected exactly one Trace Processor binary')
 with open(sys.argv[2],'xb') as output: output.write(archive.read(names[0]))
`, archivePath, temporaryBinary], { timeoutMs: 30_000 });
    assert.equal(extracted.code, 0, extracted.stderr);
    await chmod(temporaryBinary, 0o755);
    await rm(archivePath);
    await writeFile(path.join(temporary, "verified.json"), JSON.stringify({ version: perfettoVersion, archive_sha256: expected, binary_sha256: digest(await readFile(temporaryBinary)) }));
    // Only this owned, versioned tool cache is replaced.
    await rm(destination, { recursive: true, force: true });
    await rename(temporary, destination);
    return binary;
  } finally { await rm(temporary, { recursive: true, force: true }); }
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
