import assert from "node:assert/strict";
import { readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { LspClient } from "../runtime/harness.mjs";
import { terminateProcessTree } from "../runtime/process.mjs";
import { command, digest } from "./tools.mjs";

export class ProfileSession {
  constructor({ project, output, workload, settings, result, ssBin, scriptDirectory }) {
    Object.assign(this, { project, output, workload, settings, result, ssBin, scriptDirectory });
    this.recordings = new Map();
    this.cleanups = [];
    this.controller = new AbortController();
    this.signal = this.controller.signal;
    this.commands = new Map();
    this.measurements = new Set();
  }

  async command(executable, args, options = {}) {
    this.signal.throwIfAborted();
    const controller = new AbortController();
    const signals = [this.signal, controller.signal, ...(options.signal ? [options.signal] : [])];
    const pending = command(executable, args, { cwd: this.project, timeoutMs: this.settings.timeout_ms, ...options, signal: AbortSignal.any(signals) });
    this.commands.set(pending, controller);
    try { return await pending; } finally { this.commands.delete(pending); }
  }

  async render({ recording = null, args = [] } = {}) {
    const commandArgs = ["render", this.workload.definition.entry, path.join(this.output, "deck.pdf"), "--quiet", ...args];
    if (recording) commandArgs.push("--profile", this.recording(recording), "--profile-buffer-kb", String(this.settings.profile_buffer_kb));
    const response = await this.command(this.ssBin, commandArgs);
    assert.equal(response.code, 0, response.stderr);
    return response;
  }

  async validate() {
    const filename = path.join(this.output, "validation.json");
    const response = await this.command(this.ssBin, ["dump", this.workload.definition.entry, filename, "--quiet"]);
    assert.equal(response.code, 0, response.stderr);
    const dumped = JSON.parse(await readFile(filename));
    assert.equal(dumped.page_order?.length, this.workload.definition.expect.pages, "workload page count changed");
    return dumped;
  }

  async clearProjectCache() {
    // The host creates this project copy exclusively for the current run.
    await rm(path.join(this.project, ".ss-cache"), { recursive: true, force: true });
  }

  recording(name) {
    this.signal.throwIfAborted();
    assert(this.settings.record, "recording requires SS_PROFILE_RECORD=1");
    assert(typeof name === "string" && /^[a-z]/.test(name) && !/[^a-z0-9-]/.test(name), "recording names must be lowercase identifiers");
    assert(!this.recordings.has(name), `recording already exists: ${name}`);
    const directory = path.join(this.output, name);
    this.recordings.set(name, directory);
    return directory;
  }

  async editor({ recording = null } = {}) {
    this.signal.throwIfAborted();
    const client = new LspClient({
      cwd: this.project,
      profileDirectory: recording ? this.recording(recording) : null,
      profileBufferKb: this.settings.profile_buffer_kb,
    });
    const abort = () => terminateProcessTree(client.child.pid);
    this.signal.addEventListener("abort", abort, { once: true });
    this.defer(async () => {
      try {
        if (!client.exitStatus) await client.close();
      } catch (error) {
        terminateProcessTree(client.child.pid);
        throw error;
      } finally { this.signal.removeEventListener("abort", abort); }
    });
    await client.initialize();
    return client;
  }

  async measure(name, action, { samples = this.settings.samples, warmups = this.settings.warmups, beforeEach = async () => {} } = {}) {
    assert(typeof name === "string" && name.length > 0, "measurement name must be a nonempty string");
    assert(!Object.hasOwn(this.result.measurements, name) && !this.measurements.has(name), `measurement already exists: ${name}`);
    assert(Number.isSafeInteger(samples) && samples > 0 && Number.isSafeInteger(warmups) && warmups >= 0, "invalid sample or warmup count");
    this.measurements.add(name);
    const values = [];
    for (let index = 0; index < warmups + samples; index++) {
      this.signal.throwIfAborted();
      const sample = { index, warmup: index < warmups };
      await beforeEach(sample);
      this.signal.throwIfAborted();
      const started = performance.now();
      await action(sample);
      if (index >= warmups) values.push(performance.now() - started);
    }
    const summary = statistics(values);
    Object.defineProperty(this.result.measurements, name, { value: summary, enumerable: true });
    return summary;
  }

  async input(filename) {
    filename = filename instanceof URL ? fileURLToPath(filename) : path.resolve(filename);
    const bytes = await readFile(filename);
    this.result.script.inputs[path.relative(this.scriptDirectory, filename)] = digest(bytes);
    return bytes;
  }

  async save(filename, value) {
    assert(path.basename(filename) === filename && filename !== "." && filename !== "..", "save requires a filename inside the output directory");
    assert(!["result.json", "failure.log", "validation.json", "deck.pdf"].includes(filename), "filename is reserved by the profiling host");
    await writeFile(path.join(this.output, filename), typeof value === "string" ? value : JSON.stringify(value, null, 2) + "\n", { flag: "wx" });
  }

  defer(cleanup) { assert.equal(typeof cleanup, "function"); this.cleanups.push(cleanup); }

  async close() {
    const errors = [];
    for (const controller of this.commands.values()) controller.abort(new Error("profiling session closed"));
    await Promise.allSettled([...this.commands.keys()]);
    for (const cleanup of this.cleanups.splice(0).reverse()) {
      try { await cleanup(); } catch (error) { errors.push(error); }
    }
    this.controller.abort(new Error("profiling session closed"));
    await Promise.allSettled([...this.commands.keys()]);
    if (errors.length) throw new AggregateError(errors, "profiling cleanup failed");
  }
}

export function statistics(values) {
  assert(values.length > 0 && values.every((value) => Number.isFinite(value) && value >= 0), "samples must be nonempty finite durations");
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return {
    samples_ms: values,
    median_ms: sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2,
    p95_ms: sorted[Math.ceil(sorted.length * 0.95) - 1],
  };
}
