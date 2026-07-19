#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

const pdftotextAvailable = await commandAvailable("pdftotext");

if (pdftotextAvailable) {
  await testMarkdownTableRightAlignment();
}

async function testMarkdownTableRightAlignment() {
  const project = await mkdtempProject("ss-markdown-table-align-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page table_align
let body = text! <<
| Left | Right |
| :--- | ---: |
| L | R |
| Wide left text | 9 |
>>
body.layout.x = 120
body.layout.right_inset = 420
body.layout.wrap = WrapMode.on
~ body.top == page.top - 80
end
`,
      "utf8",
    );

    const render = await runSs(["render", "slide.ss", "out.pdf"], project);
    assert(render.code === 0, `render failed:\n${combinedOutput(render)}`);

    await runCommand("pdftotext", ["-bbox", "out.pdf", "out.bbox.html"], project);
    const words = parsePdfWords(await readFile(path.join(project, "out.bbox.html"), "utf8"));
    const leftHeader = requireWord(words, "Left");
    const leftBody = requireWord(words, "L");
    const rightHeader = requireWord(words, "Right");
    const rightBody = requireWord(words, "R");
    const rightNumber = requireWord(words, "9");

    assert(Math.abs(leftHeader.xMin - leftBody.xMin) < 2, `left column should stay left aligned: ${JSON.stringify({ leftHeader, leftBody })}`);
    assert(Math.abs(rightHeader.xMax - rightBody.xMax) < 2, `right header/body should share the right edge: ${JSON.stringify({ rightHeader, rightBody })}`);
    assert(Math.abs(rightBody.xMax - rightNumber.xMax) < 2, `right body cells should share the right edge: ${JSON.stringify({ rightBody, rightNumber })}`);
    assert(rightBody.xMin > leftBody.xMin + 300, `right-aligned cell was not placed in the right column: ${JSON.stringify({ leftBody, rightBody })}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function parsePdfWords(xml) {
  const words = [];
  const wordPattern = /<word xMin="([^"]+)" yMin="([^"]+)" xMax="([^"]+)" yMax="([^"]+)">([^<]+)<\/word>/g;
  for (const match of xml.matchAll(wordPattern)) {
    words.push({
      text: match[5],
      xMin: Number(match[1]),
      yMin: Number(match[2]),
      xMax: Number(match[3]),
      yMax: Number(match[4]),
    });
  }
  return words;
}

function requireWord(words, text) {
  const word = words.find((candidate) => candidate.text === text);
  assert(word, `missing PDF word ${text}; found ${words.map((candidate) => candidate.text).join(", ")}`);
  return word;
}

async function mkdtempProject(prefix) {
  return mkdtemp(path.join(os.tmpdir(), prefix));
}

async function commandAvailable(command) {
  return new Promise((resolve) => {
    const child = spawn(command, ["-v"], { stdio: "ignore" });
    child.on("error", () => resolve(false));
    child.on("exit", (code) => resolve(code === 0));
  });
}

async function runSs(args, cwd) {
  return spawnCollect(ssBin, args, cwd);
}

async function runCommand(command, args, cwd) {
  const result = await spawnCollect(command, args, cwd);
  assert(result.code === 0, `${command} failed:\n${combinedOutput(result)}`);
  return result;
}

async function spawnCollect(command, args, cwd, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
    }, timeoutMs);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, stdout, stderr, timedOut });
    });
  });
}

function combinedOutput(result) {
  const timeout = result.timedOut ? "\n[timed out]" : "";
  return `${result.stdout}\n${result.stderr}${timeout}`;
}
