#!/usr/bin/env node
import { spawn } from "node:child_process";
import { access, chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

const pdflatexAvailable = await commandAvailable("pdflatex");

if (pdflatexAvailable) {
  await testRenderFailureProducesDiagnostic();
  await testRenderFailureWritesStructuredDiagnostic();
  await testInlineMathRenderFailureLocatesFormula();
  await testConcatenatedMathRenderFailureLocatesSourceLiteral();
}
if (process.platform !== "win32") {
  await testExternalCommandOutputLimitsAreActionable();
  await testInvalidExternalExecutableIsActionable();
}
await testSvgAssetRenderFailureLocatesAssetReference();
await testDiagnosticsWriteFailurePreservesPrimaryDiagnostic();
await testHtmlWriteFailureStillWritesDiagnostics();
await testPdfOutputWriteFailureReportsDestination();
await testMismatchedPdfAssetReportsActionableDiagnostic();
await testPdfCacheAccessFailureReportsCachePath();
await testMissingAssetCheckLocatesPathLiteral();

async function testRenderFailureProducesDiagnostic() {
  const project = await mkdtempProject("ss-render-diagnostics-");
  try {
    const slide = path.join(project, "slide.ss");
    await writeFile(
      slide,
      `import std:themes/default as *

page bad
latex!("\\notacommand")
end
`,
      "utf8",
    );

    const result = await runSs(["render", "slide.ss", "out.pdf"], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "render should fail for an invalid artifact");
    assert(output.includes("RenderFailed:"), `render failure did not produce a render diagnostic:\n${output}`);
    assertLatexCommandSummary(output, "render diagnostic omitted command output summary");
    assert(output.includes("slide.ss:4:9"), `render diagnostic omitted formula source location:\n${output}`);
    assert(output.includes('| latex!("\\notacommand")'), `render diagnostic omitted formula source excerpt:\n${output}`);
    assert(!output.includes("panic:"), `render failure should not panic:\n${output}`);
    assert(!output.includes("native pdf:"), `render failure should not bypass diagnostics:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testExternalCommandOutputLimitsAreActionable() {
  const project = await mkdtempProject("ss-render-command-output-limit-");
  try {
    const fakeBin = path.join(project, "bin");
    await mkdir(fakeBin);
    const fakePdflatex = path.join(fakeBin, "pdflatex");
    await writeFile(
      fakePdflatex,
      `#!/usr/bin/env node
const stream = process.env.SS_TEST_COMMAND_STREAM === "stderr" ? process.stderr : process.stdout;
stream.write("x".repeat(140 * 1024));
`,
      "utf8",
    );
    await chmod(fakePdflatex, 0o755);
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page bad
latex!("x")
end
`,
      "utf8",
    );

    const baseEnv = { PATH: `${fakeBin}${path.delimiter}${process.env.PATH ?? ""}` };
    for (const testCase of [
      { stream: "stdout", limit: 64 },
      { stream: "stderr", limit: 128 },
    ]) {
      const result = await runSs(["render", "slide.ss", `out-${testCase.stream}.pdf`], project, {
        ...baseEnv,
        SS_TEST_COMMAND_STREAM: testCase.stream,
      });
      const output = `${result.stdout}\n${result.stderr}`;
      assert(result.code !== 0, `render should fail when ${testCase.stream} exceeds its capture limit`);
      assert(output.includes("RenderFailed:"), `${testCase.stream} limit did not produce a source diagnostic:\n${output}`);
      assert(output.includes(`more than ${testCase.limit} KiB to ${testCase.stream}`), `${testCase.stream} limit omitted its concrete bound:\n${output}`);
      assert(output.includes("fix repeated diagnostics in the LaTeX source or configured preamble"), `${testCase.stream} limit omitted corrective guidance:\n${output}`);
      assert(!output.includes("the file exceeds the supported size limit"), `${testCase.stream} limit was misreported as a file-size failure:\n${output}`);
    }
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testInvalidExternalExecutableIsActionable() {
  const project = await mkdtempProject("ss-render-invalid-executable-");
  try {
    const fakeBin = path.join(project, "bin");
    await mkdir(fakeBin);
    const fakePdflatex = path.join(fakeBin, "pdflatex");
    await writeFile(fakePdflatex, "this is not an executable image\n", "utf8");
    await chmod(fakePdflatex, 0o755);
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page bad
latex!("x")
end
`,
      "utf8",
    );

    const result = await runSs(["render", "slide.ss", "out.pdf"], project, {
      PATH: `${fakeBin}${path.delimiter}${process.env.PATH ?? ""}`,
    });
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "render should fail when latex_engine is not a runnable executable");
    assert(output.includes("RenderFailed:"), `invalid executable did not produce a source diagnostic:\n${output}`);
    assert(output.includes("is not runnable on this platform"), `invalid executable omitted the concrete cause:\n${output}`);
    assert(output.includes("install a compatible executable or select another latex_engine"), `invalid executable omitted corrective guidance:\n${output}`);
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
      "--diagnostics-json",
      diagnosticsPath,
    ], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "render should fail for invalid inline math");
    assert(output.includes("RenderFailed:"), `render failure did not print a render diagnostic:\n${output}`);

    const payload = JSON.parse(await readFile(diagnosticsPath, "utf8"));
    assert(payload.schema === 1, `unexpected diagnostics schema: ${JSON.stringify(payload)}`);
    assert(payload.kind === "ss-diagnostics", `unexpected diagnostics kind: ${JSON.stringify(payload)}`);
    assert(payload.diagnostics.length === 1, `unexpected diagnostics count: ${JSON.stringify(payload)}`);
    const diagnostic = payload.diagnostics[0];
    assert(diagnostic.phase === "render", `unexpected diagnostic phase: ${JSON.stringify(diagnostic)}`);
    assert(diagnostic.severity === "error", `unexpected diagnostic severity: ${JSON.stringify(diagnostic)}`);
    assert(diagnostic.code === "RenderFailed", `unexpected diagnostic code: ${JSON.stringify(diagnostic)}`);
    assert(diagnostic.path.endsWith("/slide.ss"), `unexpected diagnostic path: ${JSON.stringify(diagnostic)}`);
    assert(diagnostic.range.start.line === 3, `unexpected diagnostic start line: ${JSON.stringify(diagnostic)}`);
    assert(diagnostic.range.start.character === 25, `unexpected diagnostic start character: ${JSON.stringify(diagnostic)}`);
    assert(diagnostic.message.includes("Undefined control sequence"), `structured diagnostic omitted the LaTeX error: ${diagnostic.message}`);
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

    const result = await runSs(["render", "slide.ss", "out.pdf"], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "render should fail for invalid inline math");
    assert(output.includes("RenderFailed:"), `inline math failure did not produce a render diagnostic:\n${output}`);
    assertLatexCommandSummary(output, "inline math diagnostic omitted the LaTeX error");
    assert(output.includes("slide.ss:4:26"), `inline math diagnostic did not point at the failing formula:\n${output}`);
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

    const result = await runSs(["render", "slide.ss", "out.pdf"], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "render should fail for invalid concatenated inline math");
    assert(output.includes("RenderFailed:"), `concatenated math failure did not produce a render diagnostic:\n${output}`);
    assertLatexCommandSummary(output, "concatenated math diagnostic omitted the LaTeX error");
    assert(output.includes("slide.ss:5:19"), `concatenated math diagnostic did not point at the source literal:\n${output}`);
    assert(output.includes('| text!(prefix ++ "$\\notacommand$ third")'), `concatenated math diagnostic omitted source excerpt:\n${output}`);
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
      "--diagnostics-json",
      diagnosticsPath,
    ], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "render should fail for an invalid SVG asset");
    assert(output.includes("RenderFailed:"), `SVG asset failure did not produce a render diagnostic:\n${output}`);
    assert(output.includes("ImageDecodeFailed"), `SVG asset diagnostic omitted decode failure:\n${output}`);
    assert(output.includes("verify that its contents match a supported image format"), `SVG asset diagnostic omitted corrective guidance:\n${output}`);
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

async function testDiagnosticsWriteFailurePreservesPrimaryDiagnostic() {
  try {
    await access("/dev/full");
  } catch {
    return;
  }

  const project = await mkdtempProject("ss-render-diagnostics-write-failure-");
  try {
    await writeFile(path.join(project, "bad.svg"), "<svg><notclosed>\n", "utf8");
    await writeFile(
      path.join(project, "slide.ss"),
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
      "--diagnostics-json",
      "/dev/full",
    ], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "render should fail for an invalid SVG and an unwritable diagnostics destination");
    assert(output.includes("RenderFailed:"), `primary render diagnostic was lost:\n${output}`);
    assert(output.includes("ImageDecodeFailed:"), `primary decode cause was lost:\n${output}`);
    assert(output.includes("DiagnosticsOutputWriteFailed:"), `secondary diagnostics output failure was not reported:\n${output}`);
    assert(output.includes("/dev/full"), `secondary diagnostics output failure omitted its path:\n${output}`);
    assert(
      output.includes("no free space") || output.includes("permission denied"),
      `secondary diagnostics output failure omitted the operating-system reason:\n${output}`,
    );
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testHtmlWriteFailureStillWritesDiagnostics() {
  try {
    await access("/dev/full");
  } catch {
    return;
  }

  const project = await mkdtempProject("ss-html-output-write-failure-");
  try {
    const diagnosticsPath = path.join(project, "diagnostics.json");
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page ok
text!("hello")
end
`,
      "utf8",
    );

    const result = await runSs([
      "render",
      "--format",
      "html",
      "slide.ss",
      "/dev/full",
      "--diagnostics-json",
      diagnosticsPath,
    ], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "HTML render should fail for an unwritable output destination");
    assert(output.includes("HtmlOutputWriteFailed:"), `HTML output failure was not reported:\n${output}`);
    assert(output.includes("/dev/full"), `HTML output failure omitted its path:\n${output}`);

    const payload = JSON.parse(await readFile(diagnosticsPath, "utf8"));
    assert(payload.schema === 1, `unexpected diagnostics schema after HTML output failure: ${JSON.stringify(payload)}`);
    assert(payload.kind === "ss-diagnostics", `unexpected diagnostics kind after HTML output failure: ${JSON.stringify(payload)}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testPdfOutputWriteFailureReportsDestination() {
  try {
    await access("/dev/full");
  } catch {
    return;
  }

  const project = await mkdtempProject("ss-pdf-output-write-failure-");
  try {
    await writeFile(path.join(project, "slide.ss"), "page main\nend\n", "utf8");
    const result = await runSs(["render", "slide.ss", "/dev/full"], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "PDF render should fail for an unwritable output destination");
    assert(output.includes("PdfOutputWriteFailed:"), `PDF output failure omitted its operation:\n${output}`);
    assert(output.includes("/dev/full"), `PDF output failure omitted its destination:\n${output}`);
    assert(!output.includes("PdfCacheAccessFailed:"), `PDF output failure was mislabeled as a cache failure:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMismatchedPdfAssetReportsActionableDiagnostic() {
  const project = await mkdtempProject("ss-render-mismatched-pdf-asset-");
  try {
    const png = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
      "base64",
    );
    await writeFile(path.join(project, "asset.png"), png);
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page bad
pdf!("asset.png")
end
`,
      "utf8",
    );

    const result = await runSs(["render", "slide.ss", "out.pdf"], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "render should reject a PNG passed to pdf!");
    assert(output.includes("RenderFailed:"), `mismatched PDF asset did not produce a source diagnostic:\n${output}`);
    assert(output.includes("UnsupportedAssetType:"), `mismatched PDF asset omitted the format cause:\n${output}`);
    assert(output.includes("use image! for images and pdf! for PDF files"), `mismatched PDF asset omitted corrective guidance:\n${output}`);
    assert(output.includes('| pdf!("asset.png")'), `mismatched PDF asset diagnostic omitted the source excerpt:\n${output}`);
    assert(!output.includes("CommandFailed:"), `mismatched PDF asset escaped to the command boundary:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testPdfCacheAccessFailureReportsCachePath() {
  const project = await mkdtempProject("ss-render-pdf-cache-access-");
  try {
    const renderCache = path.join(project, ".ss-cache", "render");
    const pdfCache = path.join(renderCache, "ss-pdf-render-ir-v2");
    const pageCacheRelative = path.join(".ss-cache", "render", "ss-pdf-render-ir-v2", "pages");
    const pageCache = path.join(project, pageCacheRelative);
    await mkdir(pdfCache, { recursive: true });
    await writeFile(pageCache, "not a directory\n", "utf8");
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page main
text!("${project}")
end
`,
      "utf8",
    );

    const result = await runSs(["render", "slide.ss", "out.pdf"], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "render should fail when the PDF page-cache path is a file");
    assert(output.includes("PdfCacheAccessFailed:"), `PDF cache failure omitted its operation:\n${output}`);
    assert(output.includes(pageCacheRelative), `PDF cache failure omitted the cache path:\n${output}`);
    assert(output.includes("conflicting path"), `PDF cache failure omitted corrective guidance:\n${output}`);
    assert(!output.includes("PdfPageRenderFailed:"), `PDF cache access failure was mislabeled as page rendering:\n${output}`);
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

function assertLatexCommandSummary(output, label) {
  assert(output.includes("Undefined control sequence"), `${label}:\n${output}`);
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

async function runSs(args, cwd, env = {}) {
  return await new Promise((resolve, reject) => {
    const child = spawn(ssBin, args, {
      cwd,
      env: { ...process.env, NO_COLOR: "1", ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
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
