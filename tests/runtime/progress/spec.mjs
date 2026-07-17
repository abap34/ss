#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { ssBin } from "../harness.mjs";

const commonStages = [
  "Read inputs",
  "Parse source",
  "Analyze",
  "Evaluate document",
  "Prepare pages",
  "Solve layouts",
  "Compile rendering",
];

await testRenderProgress("pdf", "deck.pdf", [...commonStages, "Render PDF"]);
await testRenderProgress("html", "deck.html", [...commonStages, "Write HTML"]);
await testFailureClosesProgressLine();
await testQuietRenderHasNoProgress();

async function testRenderProgress(format, output, expectedStages) {
  const project = await mkdtemp(path.join(os.tmpdir(), `ss-${format}-progress-`));
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page first
text!("First page")
end

page second
text!("Second page")
end
`,
      "utf8",
    );
    const args = format === "pdf"
      ? ["render", "slide.ss", output]
      : ["render", "--format", "html", "slide.ss", output];
    const result = await runSs(args, project);
    assert.equal(result.code, 0, `${format} render failed:\n${result.stderr}`);
    assertProgressUpdates(result.stderr, expectedStages);
    assertProgressDetailsDoNotRegress(result.stderr);
    assertTerminalLines(result.stderr, expectedStages);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function assertProgressDetailsDoNotRegress(stderr) {
  const updates = stderr
    .split(/[\r\n]/)
    .map(parseProgressLine)
    .filter((value) => value !== null && value.detail !== null);
  const lastByStageAndDetail = new Map();
  for (const update of updates) {
    const key = `${update.current}:${update.detail.label}`;
    const previous = lastByStageAndDetail.get(key) ?? 0;
    assert(
      update.detail.current >= previous,
      `${update.detail.label} progress regressed from ${previous} to ${update.detail.current}:\n${stderr}`,
    );
    assert.equal(
      update.detail.total,
      updates.find((candidate) =>
        candidate.current === update.current && candidate.detail?.label === update.detail.label
      ).detail.total,
      `${update.detail.label} changed its declared total:\n${stderr}`,
    );
    lastByStageAndDetail.set(key, update.detail.current);
  }
}

async function testFailureClosesProgressLine() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-progress-failure-"));
  try {
    await writeFile(path.join(project, "slide.ss"), "page broken\nlet value =\nend\n", "utf8");
    const result = await runSs(["render", "slide.ss", "deck.pdf"], project);
    assert.notEqual(result.code, 0, "invalid source unexpectedly rendered");
    const lines = emulateTerminal(result.stderr).map(stripAnsi);
    assert(lines.some((line) => line.includes("ExpectedExpression")), `missing syntax diagnostic:\n${result.stderr}`);
    assert(
      !lines.some((line) => parseProgressLine(line) !== null && line.includes("ERROR:")),
      `diagnostic was appended to an active progress line:\n${result.stderr}`,
    );
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testQuietRenderHasNoProgress() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-progress-quiet-"));
  try {
    await writeFile(path.join(project, "slide.ss"), "page quiet\nend\n", "utf8");
    const result = await runSs(["render", "--quiet", "slide.ss", "deck.pdf"], project);
    assert.equal(result.code, 0, `quiet render failed:\n${result.stderr}`);
    assert.equal(result.stderr, "", `quiet render emitted progress:\n${result.stderr}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function assertProgressUpdates(stderr, expectedStages) {
  const updates = stderr
    .split(/[\r\n]/)
    .map(parseProgressLine)
    .filter((value) => value !== null);
  assert(updates.length >= expectedStages.length, `missing progress updates:\n${stderr}`);

  const seenStages = new Set();
  for (const update of updates) {
    assert.equal(update.total, expectedStages.length, `incorrect progress total in ${update.source}`);
    const expected = expectedStages[update.current - 1];
    assert(expected, `progress advanced beyond its declared stages in ${update.source}`);
    assert.equal(update.label, expected, `stage ${update.current} changed labels while active`);
    seenStages.add(update.current);
  }
  assert.deepEqual([...seenStages].sort((left, right) => left - right), expectedStages.map((_, index) => index + 1));
}

function assertTerminalLines(stderr, expectedStages) {
  const completed = emulateTerminal(stderr)
    .map(parseProgressLine)
    .filter((value) => value !== null);
  assert.deepEqual(
    completed.map((value) => value.label),
    expectedStages,
    `completed progress lines differ:\n${stderr}`,
  );
}

function parseProgressLine(source) {
  const plain = stripAnsi(source);
  const match = /^\[[=> ]+\]\s+(\d+)\/(\d+)\s+(.+?)\s{2,}\(/.exec(plain);
  if (!match) return null;
  const detailMatch = /\(([^,]+?)\s+(\d+)\/(\d+),/.exec(plain);
  return {
    current: Number(match[1]),
    total: Number(match[2]),
    label: match[3],
    detail: detailMatch === null
      ? null
      : {
          label: detailMatch[1],
          current: Number(detailMatch[2]),
          total: Number(detailMatch[3]),
        },
    source: plain,
  };
}

function stripAnsi(source) {
  return source.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
}

function emulateTerminal(source) {
  const lines = [];
  let current = "";
  for (const character of source) {
    if (character === "\r") {
      current = "";
    } else if (character === "\n") {
      lines.push(current);
      current = "";
    } else {
      current += character;
    }
  }
  if (current.length !== 0) lines.push(current);
  return lines;
}

function runSs(args, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(ssBin, args, {
      cwd,
      detached: process.platform !== "win32",
      stdio: ["ignore", "pipe", "pipe"],
    });
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
      reject(new Error(`ss timed out after 60000 ms: ${args.join(" ")}`));
    }, 60_000);
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
