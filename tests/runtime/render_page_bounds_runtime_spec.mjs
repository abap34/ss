#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

const canRasterizePdf = await commandAvailable("pdftoppm") && await commandAvailable("magick");

await testDiagnosticLevelControlsWarningDisplay();
await testProjectDiagnosticLevelCanBeOverridden();

if (canRasterizePdf) {
  await testOffPageObjectsAreNotScaledBackIntoView();
}

async function testDiagnosticLevelControlsWarningDisplay() {
  const project = await mkdtempProject("ss-render-diagnostic-level-");
  try {
    const slide = path.join(project, "slide.ss");
    const diagnosticsPath = path.join(project, "diagnostics.json");
    await writeOffPageSlide(slide);

    const defaultRender = await runSs(["render", "slide.ss", "default.pdf"], project);
    const defaultOutput = combinedOutput(defaultRender);
    assert(defaultRender.code === 0, `default render failed:\n${defaultOutput}`);
    assert(defaultOutput.includes("PageOverflow"), `default render should print the warning:\n${defaultOutput}`);

    const suppressed = await runSs([
      "render",
      "slide.ss",
      "suppressed.pdf",
      "--diagnostic-level",
      "error",
      "--diagnostics-json",
      diagnosticsPath,
    ], project);
    const suppressedOutput = combinedOutput(suppressed);
    assert(suppressed.code === 0, `suppressed render failed:\n${suppressedOutput}`);
    assert(!suppressedOutput.includes("PageOverflow"), `warning was printed despite diagnostic level error:\n${suppressedOutput}`);

    const payload = JSON.parse(await readFile(diagnosticsPath, "utf8"));
    const pageOverflow = payload.diagnostics.find((diagnostic) =>
      diagnostic.code === "PageOverflow" && diagnostic.severity === "warning");
    assert(pageOverflow, `diagnostics JSON should still include the suppressed warning: ${JSON.stringify(payload)}`);

    const warningsOff = await runSs([
      "render",
      "slide.ss",
      "warnings-off.pdf",
      "--warnings",
      "off",
    ], project);
    const warningsOffOutput = combinedOutput(warningsOff);
    assert(warningsOff.code === 0, `--warnings off render failed:\n${warningsOffOutput}`);
    assert(!warningsOffOutput.includes("PageOverflow"), `--warnings off should hide warnings:\n${warningsOffOutput}`);

    const quiet = await runSs(["render", "slide.ss", "quiet.pdf", "--quiet"], project);
    const quietOutput = combinedOutput(quiet);
    assert(quiet.code === 0, `quiet render failed:\n${quietOutput}`);
    assert(!quietOutput.includes("PageOverflow"), `--quiet should hide warnings:\n${quietOutput}`);
    assert(!quietOutput.includes("Read inputs"), `--quiet should hide progress output:\n${quietOutput}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testProjectDiagnosticLevelCanBeOverridden() {
  const project = await mkdtempProject("ss-render-project-diagnostic-level-");
  try {
    const slide = path.join(project, "slide.ss");
    await writeOffPageSlide(slide);
    await writeFile(
      path.join(project, "ss.toml"),
      `[project]
entry = "slide.ss"
asset_base_dir = "."

[cli]
diagnostic_level = "error"
`,
      "utf8",
    );

    const configured = await runSs(["render", "--project", ".", "--output", "configured.pdf"], project);
    const configuredOutput = combinedOutput(configured);
    assert(configured.code === 0, `project configured render failed:\n${configuredOutput}`);
    assert(!configuredOutput.includes("PageOverflow"), `project diagnostic level should hide warnings:\n${configuredOutput}`);

    const overridden = await runSs([
      "render",
      "--project",
      ".",
      "--output",
      "overridden.pdf",
      "--diagnostic-level",
      "warning",
    ], project);
    const overriddenOutput = combinedOutput(overridden);
    assert(overridden.code === 0, `CLI override render failed:\n${overriddenOutput}`);
    assert(overriddenOutput.includes("PageOverflow"), `CLI diagnostic level should override ss.toml:\n${overriddenOutput}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testOffPageObjectsAreNotScaledBackIntoView() {
  const project = await mkdtempProject("ss-render-page-bounds-");
  try {
    const slide = path.join(project, "slide.ss");
    const pdfPath = path.join(project, "out.pdf");
    await writeOffPageSlide(slide);

    const render = await runSs(["render", "slide.ss", pdfPath], project);
    const output = `${render.stdout}\n${render.stderr}`;
    assert(render.code === 0, `render failed:\n${output}`);
    assert(output.includes("PageOverflow"), `render should still warn about the off-page object:\n${output}`);

    await runCommand("pdftoppm", ["-png", "-singlefile", "-r", "72", pdfPath, "page"], project);
    const sample = await runCommand("magick", [
      "page.png",
      "-alpha",
      "off",
      "-colorspace",
      "RGB",
      "-format",
      "%[fx:mean.g] %[fx:mean.b]",
      "info:",
    ], project);
    const [greenMean, blueMean] = sample.stdout.trim().split(/\s+/).map(Number);
    assert(Number.isFinite(greenMean) && Number.isFinite(blueMean), `could not parse page color means: ${sample.stdout}`);
    assert(
      greenMean > 0.995 && blueMean > 0.995,
      `off-page red marker was scaled or translated into the page: green=${greenMean}, blue=${blueMean}`,
    );
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function mkdtempProject(prefix) {
  return mkdtemp(path.join(os.tmpdir(), prefix));
}

async function writeOffPageSlide(slide) {
  await writeFile(
    slide,
    `import std:core/prelude as *

page offpage
page_bg(c"1,1,1")
let marker = panel!()
marker.chrome.fill = c"1,0,0"
marker.chrome.stroke = none
marker.chrome.line_width = 0
place!(marker)
~ marker.left == page.right + 100
~ marker.bottom == page.bottom + 100
~ marker.width == 200
~ marker.height == 200
end
`,
    "utf8",
  );
}

async function commandAvailable(command) {
  const result = await spawnCollect(command, ["--version"], process.cwd());
  return result.code === 0;
}

async function runSs(args, cwd) {
  return spawnCollect(ssBin, args, cwd);
}

function combinedOutput(result) {
  return `${result.stdout}\n${result.stderr}`;
}

async function runCommand(command, args, cwd) {
  const result = await spawnCollect(command, args, cwd);
  if (result.code !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed with ${result.code}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  }
  return result;
}

async function spawnCollect(command, args, cwd) {
  return await new Promise((resolve) => {
    const child = spawn(command, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout?.setEncoding("utf8");
    child.stderr?.setEncoding("utf8");
    child.stdout?.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr?.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => resolve({ code: -1, stdout, stderr: `${stderr}${error.message}` }));
    child.on("close", (code) => resolve({ code: code ?? -1, stdout, stderr }));
  });
}
