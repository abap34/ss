#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

if (await commandAvailable("pdflatex")) {
  await testInlineMathKeepsBaseSizeAcrossScripts();
  await testLatexRendererUsesReferenceHeight();
  await testLatexRespectsFixedFrameHeight();
}

async function testInlineMathKeepsBaseSizeAcrossScripts() {
  const project = await mkdtempProject("ss-inline-math-size-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page inline_math_size
let body = text! <<
$x$
$x_i$
$x^i$
$x_i^j$
$x_i^j$
>>
~ body.left == page.left + 96
~ body.right == body.left + 35
end
`,
      "utf8",
    );

    const render = await runSs(["render", "--format", "html", "slide.ss", "out.html"], project);
    const output = combinedOutput(render);
    assert(render.code === 0, `LaTeX inline math render failed:\n${output}`);
    const document = await readFile(path.join(project, "out.html"), "utf8");
    const formulas = mathBoxes(document, "ss-item ss-latex ss-pdf");
    assert(formulas.length === 5, `expected five LaTeX inline formulas, got ${formulas.length}`);
    assert(formulas[3].height > formulas[0].height, `scripts did not increase LaTeX formula height: ${JSON.stringify(formulas)}`);
    const firstBoth = formulas[3];
    const secondBoth = formulas[4];
    assert(
      secondBoth.top + 0.01 >= firstBoth.top + firstBoth.height,
      `scripted inline math lines overlap: ${JSON.stringify({ firstBoth, secondBoth })}`,
    );
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testLatexRendererUsesReferenceHeight() {
  const project = await mkdtempProject("ss-inline-math-latex-size-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page inline_math_size
let body = text! <<
$\\FallbackMath{x}$
$\\FallbackMath{x_i^j}$
>>
~ body.left == page.left + 96
~ body.right == body.left + 35
end

document
  latex_preamble("\\newcommand{\\FallbackMath}[1]{#1}")
end
`,
      "utf8",
    );

    const render = await runSs(["render", "--format", "html", "slide.ss", "out.html"], project);
    const output = combinedOutput(render);
    assert(render.code === 0, `LaTeX inline math render failed:\n${output}`);
    const document = await readFile(path.join(project, "out.html"), "utf8");
    const formulas = mathBoxes(document, "ss-item ss-latex ss-pdf");
    assert(formulas.length === 2, `expected two LaTeX formulas, got ${formulas.length}`);
    assert(
      formulas[1].height > formulas[0].height * 1.1,
      `LaTeX rendering still normalizes scripted math by its outer height: ${JSON.stringify(formulas)}`,
    );
    assert(
      formulas[1].top + 0.01 >= formulas[0].top + formulas[0].height,
      `LaTeX inline math lines overlap: ${JSON.stringify(formulas)}`,
    );
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testLatexRespectsFixedFrameHeight() {
  const project = await mkdtempProject("ss-math-frame-height-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page latex_fixed_height
let formula = latex! <<
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
let formula = latex!("$x + y = z$", 1)
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

async function mkdtempProject(prefix) {
  return mkdtemp(path.join(os.tmpdir(), prefix));
}

async function commandAvailable(command) {
  return new Promise((resolve) => {
    const child = spawn(command, ["--version"], { stdio: "ignore" });
    child.on("error", () => resolve(false));
    child.on("exit", (code) => resolve(code === 0));
  });
}

async function runSs(args, cwd) {
  return spawnCollect(ssBin, args, cwd);
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

function mathBoxes(document, className) {
  const pattern = new RegExp(`<(?:span|div) class="${className}"[^>]*style="([^"]*)"`, "g");
  return [...document.matchAll(pattern)].map((match) => boxFromStyle(match[1]));
}

function boxFromStyle(style) {
  return {
    top: styleNumber(style, "top"),
    height: styleNumber(style, "height"),
  };
}

function styleNumber(style, name) {
  const match = new RegExp(`(?:^|;)${name}:([-0-9.]+)pt(?:;|$)`).exec(style);
  assert(match, `missing ${name} in style: ${style}`);
  return Number(match[1]);
}
