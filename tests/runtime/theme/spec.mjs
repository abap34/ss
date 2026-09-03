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
await testThemeOptionsAndHeadRuleGap();
await testVariantThemeOptions();

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

async function testThemeOptionsAndHeadRuleGap() {
  const nodes = await dumpNodes(path.join(fixtures, "options-default"));
  const body = findTextNode(nodes, "SettingsBody");
  const heading = findTextNode(nodes, "SettingsHead");
  const coverTitle = findTextNode(nodes, "SettingsCover");
  const coverAuthor = findTextNode(nodes, "SettingsAuthor");
  const callout = findTextNode(nodes, "SettingsCallout");
  const original = findTextNode(nodes, "OriginalTheme");
  const fontOnly = findTextNode(nodes, "FontOnly");
  const pageNumber = nodes.find((node) => node.role === "pageno");
  const rule = nodes.find((node) => node.role === "rule" && node.width > 1000);

  assert(body.render?.text, `body text paint was not emitted: ${JSON.stringify(body.render)}`);
  assert(body.render.text.font.family === "Fixture Sans", `body font: ${body.render.text.font.family}`);
  assert(body.render.text.code_font.family === "Fixture Mono", `body code font: ${body.render.text.code_font.family}`);
  assertColor(body.render.text.color, [16 / 255, 32 / 255, 48 / 255], "body color");
  assertColor(body.render.text.link_color, [36 / 255, 104 / 255, 172 / 255], "body link color");
  assertColor(body.render.text.markdown_bold_color, [36 / 255, 104 / 255, 172 / 255], "body bold color");
  assertColor(body.render.text.markdown_headings?.h2?.color, [16 / 255, 32 / 255, 48 / 255], "markdown h2 color");

  assert(heading.render?.text?.font.family === "Fixture Sans", `head font: ${heading.render?.text?.font.family}`);
  assertColor(heading.render?.text?.color, [36 / 255, 104 / 255, 172 / 255], "head color");
  assert(rule?.render?.rule, `head rule paint was not emitted: ${JSON.stringify(rule)}`);
  assertColor(rule.render.rule.stroke, [36 / 255, 104 / 255, 172 / 255], "head rule color");
  assertNear(heading.y - (rule.y + rule.height), 12, "head rule gap");

  assert(coverTitle.render?.text?.font.family === "Fixture Sans", `cover title font: ${coverTitle.render?.text?.font.family}`);
  assertColor(coverTitle.render?.text?.color, [36 / 255, 104 / 255, 172 / 255], "cover title color");
  assertColor(coverAuthor.render?.text?.color, [36 / 255, 104 / 255, 172 / 255], "cover author color");
  assert(callout.render?.text?.font.family === "Fixture Sans", `callout font: ${callout.render?.text?.font.family}`);
  assert(callout.render?.text?.code_font.family === "Fixture Mono", `callout code font: ${callout.render?.text?.code_font.family}`);
  assert(pageNumber?.render?.text?.font.family === "Fixture Sans", `page number font: ${pageNumber?.render?.text?.font.family}`);
  assertColor(pageNumber?.render?.text?.color, [112 / 255, 128 / 255, 144 / 255], "page number color");

  assert(original.render?.text?.font.family === "Helvetica", `default theme was mutated: ${original.render?.text?.font.family}`);
  assert(fontOnly.render?.text?.font.family === "Fixture Sans", `font-only setting was not applied: ${fontOnly.render?.text?.font.family}`);
  assertColor(fontOnly.render?.text?.color, [0.07, 0.08, 0.10], "font-only preserved body color");
}

async function testVariantThemeOptions() {
  const cases = [
    {
      fixture: "options-academic",
      prefix: "Academic",
      font: "Academic Sans",
      codeFont: "Academic Mono",
      text: [24 / 255, 48 / 255, 72 / 255],
      accent: [40 / 255, 104 / 255, 168 / 255],
      muted: [104 / 255, 120 / 255, 136 / 255],
    },
    {
      fixture: "options-pop",
      prefix: "Pop",
      font: "Pop Sans",
      codeFont: "Pop Mono",
      text: [32 / 255, 56 / 255, 80 / 255],
      accent: [56 / 255, 120 / 255, 184 / 255],
      muted: [112 / 255, 128 / 255, 144 / 255],
    },
  ];

  for (const item of cases) {
    const nodes = await dumpNodes(path.join(fixtures, item.fixture));
    const body = findTextNode(nodes, `${item.prefix}Body`);
    const heading = findTextNodeWithRole(nodes, `${item.prefix}Head`, "title");
    const author = findTextNode(nodes, `${item.prefix}Author`);
    const callout = findTextNode(nodes, `${item.prefix}Callout`);
    const pageNumber = nodes.find((node) => node.role === "pageno");

    assert(body.render?.text?.font.family === item.font, `${item.fixture} body font`);
    assert(body.render.text.code_font.family === item.codeFont, `${item.fixture} code font`);
    assertColor(body.render.text.color, item.text, `${item.fixture} body color`);
    assertColor(heading.render?.text?.color, item.accent, `${item.fixture} head color`);
    assertColor(author.render?.text?.color, item.accent, `${item.fixture} author color`);
    assert(callout.render?.text?.font.family === item.font, `${item.fixture} callout font`);
    assertColor(callout.render?.text?.color, item.muted, `${item.fixture} callout color`);
    assert(pageNumber?.render?.text?.font.family === item.font, `${item.fixture} page number font`);
    assertColor(pageNumber?.render?.text?.color, item.muted, `${item.fixture} page number color`);
  }
}

async function dumpTextNode(fixture, contentFragment) {
  const nodes = await dumpNodes(fixture);
  const node = findTextNode(nodes, contentFragment);
  return node;
}

async function dumpNodes(fixture) {
  const output = await mkdtemp(path.join(os.tmpdir(), "ss-theme-dump-"));
  try {
    const dumpPath = path.join(output, "dump.json");
    await runSs(["dump", path.join(fixture, "slide.ss"), dumpPath], repository);
    const dump = JSON.parse(await readFile(dumpPath, "utf8"));
    return dump.nodes;
  } finally {
    await rm(output, { recursive: true, force: true });
  }
}

function findTextNode(nodes, contentFragment) {
  const node = nodes.find((candidate) => candidate.content?.includes(contentFragment));
  assert(node, `text node containing ${contentFragment} was not found: ${JSON.stringify(nodes)}`);
  return node;
}

function findTextNodeWithRole(nodes, contentFragment, role) {
  const node = nodes.find((candidate) => candidate.role === role && candidate.content?.includes(contentFragment));
  assert(node, `${role} node containing ${contentFragment} was not found: ${JSON.stringify(nodes)}`);
  return node;
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
