#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

if (await commandAvailable("pdflatex")) {
  await testTexRespectsFixedFrameHeight();
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
