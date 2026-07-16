#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { cp, mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";
import { pdfAsset } from "../../visual/render/assets.mjs";

const testRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const repository = path.resolve(testRoot, "..");
const optimize = process.argv[2];
const ss = path.resolve(repository, process.argv[3] ?? "zig-out/bin/ss");
const sampleCount = 5;
const output = path.join(repository, ".ss-cache/render-benchmark");
const project = path.join(output, "project");
const cache = path.join(project, ".ss-cache");
const baselinePath = process.env.SS_RENDER_BENCHMARK_BASELINE;
const writeBaselinePath = process.env.SS_RENDER_BENCHMARK_WRITE_BASELINE;

assert.equal(optimize, "ReleaseSafe", "render benchmark requires -Doptimize=ReleaseSafe");
assert(!(baselinePath && writeBaselinePath), "baseline comparison and baseline creation are mutually exclusive");

await prepareProject();
const metrics = {
  pdf_cold: await measureCold(["render", "slide.ss", "out.pdf"]),
  pdf_warm: await measureWarm(["render", "slide.ss", "out.pdf"]),
  html_warm: await measureWarm(["render", "--format", "html", "slide.ss", "out-html"]),
};
const result = {
  schema: 1,
  optimize,
  platform: process.platform,
  architecture: process.arch,
  samples: sampleCount,
  metrics,
};
await writeFile(path.join(output, "result.json"), `${JSON.stringify(result, null, 2)}\n`, "utf8");
printResult(result);

if (writeBaselinePath) {
  const target = path.resolve(repository, writeBaselinePath);
  await mkdir(path.dirname(target), { recursive: true });
  await writeFile(target, `${JSON.stringify(result, null, 2)}\n`, "utf8");
  process.stdout.write(`baseline written to ${target}\n`);
}
if (baselinePath) {
  const baseline = JSON.parse(await readFile(path.resolve(repository, baselinePath), "utf8"));
  compareToBaseline(result, baseline);
}

async function prepareProject() {
  await rm(output, { recursive: true, force: true });
  await mkdir(project, { recursive: true });
  const fixture = path.join(repository, "tests/fixtures/render/benchmark");
  await cp(path.join(fixture, "slide.ss"), path.join(project, "slide.ss"));
  await cp(path.join(fixture, "asset.svg"), path.join(project, "asset.svg"));
  await cp(path.join(repository, "assets/logo.png"), path.join(project, "asset.png"));
  await writeFile(path.join(project, "asset.pdf"), pdfAsset());
}

async function measureCold(args) {
  const samples = [];
  for (let index = 0; index < sampleCount; index += 1) {
    await rm(cache, { recursive: true, force: true });
    await removeOutput(args.at(-1));
    samples.push(await timedRun(args));
  }
  return summarize(samples);
}

async function measureWarm(args) {
  await rm(cache, { recursive: true, force: true });
  await removeOutput(args.at(-1));
  await timedRun(args);
  const samples = [];
  for (let index = 0; index < sampleCount; index += 1) samples.push(await timedRun(args));
  return summarize(samples);
}

async function removeOutput(relativePath) {
  await rm(path.join(project, relativePath), { recursive: true, force: true });
}

async function timedRun(args) {
  const timeArgs = process.platform === "darwin" ? ["-l", ss, ...args] : ["-v", ss, ...args];
  const started = performance.now();
  const result = await spawnCollect("/usr/bin/time", timeArgs, project, 180_000);
  const elapsedMs = performance.now() - started;
  if (result.code !== 0) {
    throw new Error(`benchmark command failed with ${result.code}: ${args.join(" ")}\n${result.stderr}`);
  }
  const maximumRssBytes = parseMaximumRss(result.stderr);
  const target = path.join(project, args.at(-1));
  const info = await stat(target);
  assert(info.isFile() || info.isDirectory(), `benchmark output was not published: ${target}`);
  return { elapsed_ms: elapsedMs, maximum_rss_bytes: maximumRssBytes };
}

function summarize(samples) {
  assert.equal(samples.length, sampleCount);
  const retained = samples.slice(1);
  return {
    median_ms: median(retained.map((sample) => sample.elapsed_ms)),
    maximum_rss_bytes: Math.max(...retained.map((sample) => sample.maximum_rss_bytes)),
    samples,
  };
}

function median(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle];
}

function parseMaximumRss(stderr) {
  const darwin = /^\s*(\d+)\s+maximum resident set size\s*$/m.exec(stderr);
  if (darwin) return Number(darwin[1]);
  const linux = /^\s*Maximum resident set size \(kbytes\):\s*(\d+)\s*$/m.exec(stderr);
  if (linux) return Number(linux[1]) * 1024;
  throw new Error(`could not parse maximum resident set size from /usr/bin/time output:\n${stderr}`);
}

function printResult(result) {
  for (const [name, metric] of Object.entries(result.metrics)) {
    process.stdout.write(`${name}: median=${metric.median_ms.toFixed(2)} ms，max-rss=${formatBytes(metric.maximum_rss_bytes)}\n`);
  }
}

function compareToBaseline(current, baseline) {
  assert.equal(baseline.schema, current.schema, "benchmark baseline schema differs");
  assert.equal(baseline.optimize, current.optimize, "benchmark baseline optimization mode differs");
  assert.equal(baseline.platform, current.platform, "benchmark baseline operating system differs");
  assert.equal(baseline.architecture, current.architecture, "benchmark baseline architecture differs");
  for (const name of ["pdf_cold", "pdf_warm", "html_warm"]) {
    const actual = current.metrics[name];
    const expected = baseline.metrics?.[name];
    assert(expected, `benchmark baseline omitted ${name}`);
    assert(
      actual.median_ms <= expected.median_ms * 1.05,
      `${name} median regressed from ${expected.median_ms.toFixed(2)} ms to ${actual.median_ms.toFixed(2)} ms`,
    );
    assert(
      actual.maximum_rss_bytes <= expected.maximum_rss_bytes * 1.10,
      `${name} maximum RSS regressed from ${formatBytes(expected.maximum_rss_bytes)} to ${formatBytes(actual.maximum_rss_bytes)}`,
    );
  }
  process.stdout.write("render benchmark is within the recorded time and memory limits\n");
}

function formatBytes(bytes) {
  return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
}

function spawnCollect(command, args, cwd, timeoutMs) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, detached: process.platform !== "win32", stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => stdout += chunk);
    child.stderr.on("data", (chunk) => stderr += chunk);
    const timeout = setTimeout(() => {
      if (process.platform === "win32") child.kill("SIGKILL");
      else {
        try {
          process.kill(-child.pid, "SIGKILL");
        } catch {}
      }
      reject(new Error(`benchmark command timed out after ${timeoutMs} ms: ${args.join(" ")}`));
    }, timeoutMs);
    child.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timeout);
      resolve({ code, stdout, stderr });
    });
  });
}
