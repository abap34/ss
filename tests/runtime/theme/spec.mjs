#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "../harness.mjs";

const specDir = path.dirname(fileURLToPath(import.meta.url));
const repository = path.resolve(specDir, "../../..");
const fixtures = path.resolve(specDir, "../../fixtures/runtime/theme");

await testEveryMarkdownHeadingStyleReachesRenderIr();
await testProjectThemeWrapperPreservesMarkdownHeadingStyle();

async function testEveryMarkdownHeadingStyleReachesRenderIr() {
  const node = await dumpTextNode(path.join(fixtures, "markdown-headings"), "HeadingOne");
  const paint = node.render?.text;
  assert(paint, `text paint was not emitted: ${JSON.stringify(node.render)}`);
  assertNear(paint.font_size, 18, "body font size");
  assertNear(paint.line_height, 24, "body line height");
  assertColor(paint.color, [0.1, 0.1, 0.1], "body color");

  const expected = {
    h1: { fontSize: 44, lineHeight: 50, color: [0.8, 0.1, 0.1] },
    h2: { fontSize: 36, lineHeight: 42, color: [0.1, 0.6, 0.2] },
    h3: { fontSize: 28, lineHeight: 34, color: [0.1, 0.2, 0.8] },
    h4: { fontSize: 24, lineHeight: 29, color: [0.7, 0.1, 0.6] },
    h5: { fontSize: 20, lineHeight: 25, color: [0.1, 0.6, 0.7] },
    h6: { fontSize: 18, lineHeight: 23, color: [0.8, 0.4, 0.1] },
  };
  for (const [level, style] of Object.entries(expected)) {
    assertHeadingPaint(paint.markdown_headings?.[level], style, level);
  }
}

async function testProjectThemeWrapperPreservesMarkdownHeadingStyle() {
  const node = await dumpTextNode(path.join(fixtures, "project-wrapper"), "WrappedHeading");
  const paint = node.render?.text;
  assert(paint, `wrapped text paint was not emitted: ${JSON.stringify(node.render)}`);
  assertNear(paint.font_size, 23, "wrapped body font size");
  assertHeadingPaint(
    paint.markdown_headings?.h2,
    {
      fontSize: 30,
      lineHeight: 37,
      color: [13 / 255, 125 / 255, 22 / 255],
    },
    "wrapped h2",
  );
}

async function dumpTextNode(fixture, contentFragment) {
  const output = await mkdtemp(path.join(os.tmpdir(), "ss-theme-dump-"));
  try {
    const dumpPath = path.join(output, "dump.json");
    await runSs(["dump", path.join(fixture, "slide.ss"), dumpPath], repository);
    const dump = JSON.parse(await readFile(dumpPath, "utf8"));
    const node = dump.nodes.find((candidate) => candidate.content?.includes(contentFragment));
    assert(node, `text node containing ${contentFragment} was not found: ${JSON.stringify(dump.nodes)}`);
    return node;
  } finally {
    await rm(output, { recursive: true, force: true });
  }
}

function assertHeadingPaint(actual, expected, label) {
  assert(actual, `${label} paint was not emitted`);
  assertNear(actual.font_size, expected.fontSize, `${label} font size`);
  assertNear(actual.line_height, expected.lineHeight, `${label} line height`);
  assertColor(actual.color, expected.color, `${label} color`);
}

function assertColor(actual, expected, label) {
  assert(Array.isArray(actual) && actual.length === expected.length, `${label}: ${JSON.stringify(actual)}`);
  for (let index = 0; index < expected.length; index += 1) {
    assertNear(actual[index], expected[index], `${label} channel ${index}`);
  }
}

function assertNear(actual, expected, label) {
  assert(typeof actual === "number" && Math.abs(actual - expected) <= 0.0001,
    `${label}: expected ${expected}, got ${actual}`);
}

async function runSs(args, cwd) {
  const result = await spawnCollect(ssBin, args, cwd);
  if (result.code !== 0) {
    throw new Error(`ss ${args.join(" ")} failed with ${result.code}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  }
}

async function spawnCollect(command, args, cwd) {
  return await new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    const timeout = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`${command} ${args.join(" ")} timed out`));
    }, 30000);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timeout);
      resolve({ code: code ?? -1, stdout, stderr });
    });
  });
}
