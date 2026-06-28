#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

const pdflatexAvailable = await commandAvailable("pdflatex");

await testRenderFailureProducesDiagnostic();
await testRenderFailureWritesStructuredDiagnostic();
await testInlineMathRenderFailureLocatesFormula();
await testConcatenatedMathRenderFailureLocatesSourceLiteral();
await testSvgAssetRenderFailureLocatesAssetReference();
await testMissingAssetCheckLocatesPathLiteral();

async function testRenderFailureProducesDiagnostic() {
  const project = await mkdtempProject("ss-render-diagnostics-");
  try {
    const slide = path.join(project, "slide.ss");
    await writeFile(
      slide,
      `import std:themes/default as *

page bad
tex!("\\notacommand")
end
`,
      "utf8",
    );

    const result = await runSs(["render", "slide.ss", "out.pdf", "--cache-id", "render-diagnostics"], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "render should fail for an invalid artifact");
    assert(output.includes("RenderFailed:"), `render failure did not produce a render diagnostic:\n${output}`);
    assertMathCommandSummary(output, "render diagnostic omitted command output summary");
    assert(output.includes("slide.ss:4:7"), `render diagnostic omitted formula source location:\n${output}`);
    assert(output.includes('| tex!("\\notacommand")'), `render diagnostic omitted formula source excerpt:\n${output}`);
    assert(!output.includes("panic:"), `render failure should not panic:\n${output}`);
    assert(!output.includes("native pdf:"), `render failure should not bypass diagnostics:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testRenderFailureWritesStructuredDiagnostic() {
  const project = await mkdtempProject("ss-render-diagnostics-json-");
  try {
    const slide = path.join(project, "slide.ss");
    const diagnosticsPath = path.join(project, "diagnostics.json");
    await writeFile(
      slide,
      `import std:themes/default as *

page bad
text!("first $x$ second $\\notacommand$ third")
end
`,
      "utf8",
    );

    const result = await runSs([
      "render",
      "slide.ss",
      "out.pdf",
      "--cache-id",
      "render-diagnostics-json",
      "--diagnostics-json",
      diagnosticsPath,
    ], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "render should fail for invalid inline math");
    assert(output.includes("RenderFailed:"), `render failure did not print a render diagnostic:\n${output}`);

    const payload = JSON.parse(await readFile(diagnosticsPath, "utf8"));
    assert(payload.schema === 1, `unexpected diagnostics schema: ${JSON.stringify(payload)}`);
    assert(payload.kind === "ss-diagnostics", `unexpected diagnostics kind: ${JSON.stringify(payload)}`);
    if (!pdflatexAvailable) {
      assert(payload.diagnostics.length === 2, `unexpected diagnostics count: ${JSON.stringify(payload)}`);
      const firstFormula = diagnosticAt(payload.diagnostics, 3, 14);
      const secondFormula = diagnosticAt(payload.diagnostics, 3, 25);
      assert(firstFormula, `missing diagnostic for first inline formula: ${JSON.stringify(payload)}`);
      assert(secondFormula, `missing diagnostic for second inline formula: ${JSON.stringify(payload)}`);
      assertMathCommandSummary(firstFormula.message, `structured diagnostic omitted command output summary: ${firstFormula.message}`);
      assertMathCommandSummary(secondFormula.message, `structured diagnostic omitted command output summary: ${secondFormula.message}`);
      return;
    }

    assert(payload.diagnostics.length === 1, `unexpected diagnostics count: ${JSON.stringify(payload)}`);
    const diagnostic = payload.diagnostics[0];
    assert(diagnostic.phase === "render", `unexpected diagnostic phase: ${JSON.stringify(diagnostic)}`);
    assert(diagnostic.severity === "error", `unexpected diagnostic severity: ${JSON.stringify(diagnostic)}`);
    assert(diagnostic.code === "RenderFailed", `unexpected diagnostic code: ${JSON.stringify(diagnostic)}`);
    assert(diagnostic.path.endsWith("/slide.ss"), `unexpected diagnostic path: ${JSON.stringify(diagnostic)}`);
    assert(diagnostic.range.start.line === 3, `unexpected diagnostic start line: ${JSON.stringify(diagnostic)}`);
    assert(diagnostic.range.start.character === 25, `unexpected diagnostic start character: ${JSON.stringify(diagnostic)}`);
    assertMathCommandSummary(diagnostic.message, `structured diagnostic omitted command output summary: ${diagnostic.message}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testInlineMathRenderFailureLocatesFormula() {
  const project = await mkdtempProject("ss-inline-math-diagnostics-");
  try {
    const slide = path.join(project, "slide.ss");
    await writeFile(
      slide,
      `import std:themes/default as *

page bad
text!("first $x$ second $\\notacommand$ third")
end
`,
      "utf8",
    );

    const result = await runSs(["render", "slide.ss", "out.pdf", "--cache-id", "inline-math-diagnostics"], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "render should fail for invalid inline math");
    assert(output.includes("RenderFailed:"), `inline math failure did not produce a render diagnostic:\n${output}`);
    assertMathCommandSummary(output, "inline math diagnostic omitted command output summary");
    if (pdflatexAvailable) {
      assert(output.includes("slide.ss:4:26"), `inline math diagnostic did not point at the failing formula:\n${output}`);
    } else {
      assert(output.includes("slide.ss:4:15"), `inline math diagnostic did not point at the first formula:\n${output}`);
    }
    assert(output.includes('| text!("first $x$ second $\\notacommand$ third")'), `inline math diagnostic omitted source excerpt:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testConcatenatedMathRenderFailureLocatesSourceLiteral() {
  const project = await mkdtempProject("ss-concat-math-diagnostics-");
  try {
    const slide = path.join(project, "slide.ss");
    await writeFile(
      slide,
      `import std:themes/default as *

page bad
let prefix = "first $x$ second "
text!(prefix ++ "$\\notacommand$ third")
end
`,
      "utf8",
    );

    const result = await runSs(["render", "slide.ss", "out.pdf", "--cache-id", "concat-math-diagnostics"], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "render should fail for invalid concatenated inline math");
    assert(output.includes("RenderFailed:"), `concatenated math failure did not produce a render diagnostic:\n${output}`);
    assertMathCommandSummary(output, "concatenated math diagnostic omitted command output summary");
    if (pdflatexAvailable) {
      assert(output.includes("slide.ss:5:19"), `concatenated math diagnostic did not point at the source literal:\n${output}`);
      assert(output.includes('| text!(prefix ++ "$\\notacommand$ third")'), `concatenated math diagnostic omitted source excerpt:\n${output}`);
    } else {
      assert(output.includes("slide.ss:4:22"), `concatenated math diagnostic did not point at the first formula source:\n${output}`);
      assert(output.includes('| let prefix = "first $x$ second "'), `concatenated math diagnostic omitted prefix source excerpt:\n${output}`);
    }
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testSvgAssetRenderFailureLocatesAssetReference() {
  const project = await mkdtempProject("ss-svg-asset-diagnostics-");
  try {
    const slide = path.join(project, "slide.ss");
    const diagnosticsPath = path.join(project, "diagnostics.json");
    await writeFile(path.join(project, "bad.svg"), "<svg><notclosed>\n", "utf8");
    await writeFile(
      slide,
      `import std:themes/default as *

page bad
image!("bad.svg")
end
`,
      "utf8",
    );

    const result = await runSs([
      "render",
      "slide.ss",
      "out.pdf",
      "--cache-id",
      "svg-asset-diagnostics",
      "--diagnostics-json",
      diagnosticsPath,
    ], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "render should fail for an invalid SVG asset");
    assert(output.includes("RenderFailed:"), `SVG asset failure did not produce a render diagnostic:\n${output}`);
    assert(output.includes("ImageDecodeFailed"), `SVG asset diagnostic omitted decode failure:\n${output}`);
    assert(output.includes("slide.ss:4:9"), `SVG asset diagnostic did not point at the asset reference:\n${output}`);
    assert(output.includes('| image!("bad.svg")'), `SVG asset diagnostic omitted source excerpt:\n${output}`);

    const payload = JSON.parse(await readFile(diagnosticsPath, "utf8"));
    assert(payload.diagnostics.length === 1, `unexpected SVG diagnostics count: ${JSON.stringify(payload)}`);
    const diagnostic = payload.diagnostics[0];
    assert(diagnostic.code === "RenderFailed", `unexpected SVG diagnostic code: ${JSON.stringify(diagnostic)}`);
    assert(diagnostic.range.start.line === 3, `unexpected SVG diagnostic start line: ${JSON.stringify(diagnostic)}`);
    assert(diagnostic.range.start.character === 8, `unexpected SVG diagnostic start character: ${JSON.stringify(diagnostic)}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMissingAssetCheckLocatesPathLiteral() {
  const project = await mkdtempProject("ss-missing-asset-diagnostics-");
  try {
    const slide = path.join(project, "slide.ss");
    await writeFile(
      slide,
      `import std:themes/default as *

page bad
image!("missing.svg")
end
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "check should fail for a missing asset");
    assert(output.includes("AssetNotFound:"), `missing asset did not produce a diagnostic:\n${output}`);
    assert(output.includes("slide.ss:4:9"), `missing asset diagnostic did not point at the path literal:\n${output}`);
    assert(output.includes('| image!("missing.svg")'), `missing asset diagnostic omitted source excerpt:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function mkdtempProject(prefix) {
  return mkdtemp(path.join(os.tmpdir(), prefix));
}

function assertMathCommandSummary(output, label) {
  if (pdflatexAvailable) {
    assert(output.includes("Undefined control sequence"), `${label}:\n${output}`);
  } else {
    assert(output.includes("failed to run command (FileNotFound): pdflatex"), `${label}:\n${output}`);
  }
}

function diagnosticAt(diagnostics, line, character) {
  return diagnostics.find((diagnostic) =>
    diagnostic.range?.start?.line === line &&
    diagnostic.range?.start?.character === character);
}

async function commandAvailable(command) {
  return await new Promise((resolve) => {
    let settled = false;
    const finish = (available) => {
      if (settled) return;
      settled = true;
      resolve(available);
    };
    const child = spawn(command, ["--version"], { stdio: "ignore" });
    child.on("error", () => finish(false));
    child.on("close", (code) => finish(code === 0));
  });
}

async function runSs(args, cwd) {
  return await new Promise((resolve, reject) => {
    const child = spawn(ssBin, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code: code ?? -1, stdout, stderr }));
  });
}
