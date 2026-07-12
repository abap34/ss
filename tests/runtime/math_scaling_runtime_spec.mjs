#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

const canInspectRenderedMath =
  await commandAvailable("pdflatex") &&
  await commandAvailable("pdftoppm") &&
  await commandAvailable("magick");

if (canInspectRenderedMath) {
  await testTexFillsAvailableWidthAndMathScaleStillApplies();
  await testTexRespectsFixedFrameHeight();
}

async function testTexFillsAvailableWidthAndMathScaleStillApplies() {
  const project = await mkdtempProject("ss-math-scaling-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page tex_scale_one
let formula = tex!("x + y = z", 1)
~ formula.left == page.left + 96
~ formula.right == page.right - 96
~ formula.top == page.top - 240
end

page math_scale_one
let formula = math!("x + y = z", 1)
~ formula.left == page.left + 96
~ formula.right == page.right - 96
~ formula.top == page.top - 240
end

page math_scale_two
let formula = math!("x + y = z", 2)
~ formula.left == page.left + 96
~ formula.right == page.right - 96
~ formula.top == page.top - 240
end
`,
      "utf8",
    );

    const render = await runSs(["render", "slide.ss", "out.pdf", "--cache-id", "math-scaling"], project);
    assert(render.code === 0, `render failed:\n${combinedOutput(render)}`);

    await runCommand("pdftoppm", ["-png", "-r", "144", "out.pdf", "page"], project);
    const tex = await renderedGeometry(project, "page-1.png");
    const mathOne = await renderedGeometry(project, "page-2.png");
    const mathTwo = await renderedGeometry(project, "page-3.png");

    assert(tex.width > 1200, `tex should expand across the available frame width, got ${geometrySummary(tex)}`);
    assert(mathOne.width < tex.width * 0.25, `plain math should keep its natural scaled width, got tex=${geometrySummary(tex)}, math=${geometrySummary(mathOne)}`);
    assert(
      mathTwo.width > mathOne.width * 1.85 && mathTwo.width < mathOne.width * 2.15,
      `math scale should roughly double rendered width, got scale1=${geometrySummary(mathOne)}, scale2=${geometrySummary(mathTwo)}`,
    );
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testTexRespectsFixedFrameHeight() {
  const project = await mkdtempProject("ss-math-frame-height-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page tex_fixed_height
let formula = tex! <<
\\begin{tabular}{l}
alpha \\\\
beta \\\\
gamma \\\\
delta \\\\
epsilon \\\\
zeta \\\\
eta \\\\
theta \\\\
iota \\\\
kappa \\\\
lambda \\\\
mu \\\\
nu \\\\
xi \\\\
omicron \\\\
pi \\\\
rho \\\\
sigma \\\\
tau \\\\
upsilon
\\end{tabular}
>>
~ formula.left == page.left + 96
~ formula.right == page.right - 96
~ formula.top == page.top - 90
~ formula.bottom == page.bottom + 20
end

page oversized_math_frame
let formula = math!("x + y = z", 1)
~ formula.left == page.left + 96
~ formula.right == page.right - 96
~ formula.top == page.top + 120
~ formula.bottom == page.bottom + 20
end
`,
      "utf8",
    );

    const diagnosticsPath = path.join(project, "diagnostics.json");
    const render = await runSs([
      "render",
      "slide.ss",
      "out.pdf",
      "--cache-id",
      "math-frame-height",
      "--diagnostics-json",
      diagnosticsPath,
    ], project);
    const output = combinedOutput(render);
    assert(render.code === 0, `render failed:\n${output}`);
    assert(!output.includes("FrameTooSmall"), `tex should fit the fixed frame height when scaling down is required:\n${output}`);
    assert(!output.includes("PageOverflow"), `tex should not create a page overflow after fitting the fixed frame:\n${output}`);

    const payload = JSON.parse(await readFile(diagnosticsPath, "utf8"));
    const unexpected = payload.diagnostics.filter((diagnostic) =>
      diagnostic.code === "FrameTooSmall" ||
      diagnostic.code === "PageOverflow");
    assert(unexpected.length === 0, `unexpected layout diagnostics: ${JSON.stringify(unexpected)}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function renderedGeometry(project, imageName) {
  const result = await runCommand("magick", [
    imageName,
    "-alpha",
    "off",
    "-fuzz",
    "8%",
    "-trim",
    "-format",
    "%wx%h+%X+%Y",
    "info:",
  ], project);
  const match = /^(\d+)x(\d+)\+\+?(-?\d+)\+\+?(-?\d+)/.exec(result.stdout.trim());
  assert(match, `could not parse rendered geometry: ${result.stdout}`);
  return {
    width: Number(match[1]),
    height: Number(match[2]),
    x: Number(match[3]),
    y: Number(match[4]),
  };
}

function geometrySummary(geometry) {
  return `${geometry.width}x${geometry.height}+${geometry.x}+${geometry.y}`;
}

async function mkdtempProject(prefix) {
  return mkdtemp(path.join(os.tmpdir(), prefix));
}

async function commandAvailable(command) {
  return new Promise((resolve) => {
    const child = spawn(command, versionArgs(command), { stdio: "ignore" });
    child.on("error", () => resolve(false));
    child.on("exit", (code) => resolve(code === 0));
  });
}

function versionArgs(command) {
  return command === "pdftoppm" ? ["-v"] : ["--version"];
}

async function runSs(args, cwd) {
  return spawnCollect(ssBin, args, cwd);
}

async function runCommand(command, args, cwd) {
  const result = await spawnCollect(command, args, cwd);
  assert(result.code === 0, `${command} failed:\n${combinedOutput(result)}`);
  return result;
}

async function spawnCollect(command, args, cwd, timeoutMs = 30000) {
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
