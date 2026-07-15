#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

const pdflatexAvailable = await commandSucceeds("pdflatex", ["--version"]);
const pdftotextAvailable = await commandSucceeds("pdftotext", ["-v"]);

if (pdflatexAvailable && pdftotextAvailable) {
  await testInlineMathRemainsSelectable();
  if (await commandSucceeds("kpsewhich", ["algorithm2e.sty"])) {
    await testAlgorithm2eRemainsSelectable();
  }
}

async function testInlineMathRemainsSelectable() {
  const project = await mkdtempProject("ss-math-pdf-selectable-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page formula
let formula = math!("\\mathrm{SelectableMathToken}")
~ formula.left == page.left + 120
~ formula.top == page.top - 180
end
`,
      "utf8",
    );

    await renderAndExtract(project, "math-pdf-selectable");
    const text = await readFile(path.join(project, "out.txt"), "utf8");
    assert(text.includes("SelectableMathToken"), `TeX math text was not selectable:\n${text}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testAlgorithm2eRemainsSelectable() {
  const project = await mkdtempProject("ss-algorithm2e-pdf-selectable-");
  try {
    await writeFile(path.join(project, "preamble.tex"), "\\usepackage[ruled,vlined]{algorithm2e}\n", "utf8");
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page algorithm
let algorithm = tex! <<
\\DontPrintSemicolon
\\begin{algorithm}[H]
  \\KwData{SelectableAlgorithmInput}
  \\KwResult{SelectableAlgorithmResult}
  \\While{condition}{update state\\;}
\\end{algorithm}
>>
~ algorithm.left == page.left + 120
~ algorithm.right == page.right - 120
~ algorithm.top == page.top - 100
~ algorithm.bottom == page.bottom + 100
end

document
  tex_preamble_file("preamble.tex")
end
`,
      "utf8",
    );

    await renderAndExtract(project, "algorithm2e-pdf-selectable");
    const text = await readFile(path.join(project, "out.txt"), "utf8");
    assert(text.includes("SelectableAlgorithmInput"), `algorithm2e input text was not selectable:\n${text}`);
    assert(text.includes("SelectableAlgorithmResult"), `algorithm2e result text was not selectable:\n${text}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function renderAndExtract(project, cacheId) {
  const render = await spawnCollect(ssBin, ["render", "slide.ss", "out.pdf"], project);
  assert(render.code === 0, `render failed:\n${combinedOutput(render)}`);
  const extraction = await spawnCollect("pdftotext", ["out.pdf", "out.txt"], project);
  assert(extraction.code === 0, `pdftotext failed:\n${combinedOutput(extraction)}`);
}

function mkdtempProject(prefix) {
  return mkdtemp(path.join(os.tmpdir(), prefix));
}

async function commandSucceeds(command, args) {
  try {
    const result = await spawnCollect(command, args, process.cwd(), 10000);
    return result.code === 0;
  } catch {
    return false;
  }
}

function spawnCollect(command, args, cwd, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => child.kill("SIGTERM"), timeoutMs);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, stdout, stderr });
    });
  });
}

function combinedOutput(result) {
  return `${result.stdout}${result.stderr}`;
}
