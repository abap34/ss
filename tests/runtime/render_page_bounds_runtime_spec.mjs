#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

const canRasterizePdf = await commandAvailable("pdftoppm") && await commandAvailable("magick");

if (canRasterizePdf) {
  await testOffPageObjectsAreNotScaledBackIntoView();
}

async function testOffPageObjectsAreNotScaledBackIntoView() {
  const project = await mkdtempProject("ss-render-page-bounds-");
  try {
    const slide = path.join(project, "slide.ss");
    const pdfPath = path.join(project, "out.pdf");
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

    const render = await runSs(["render", "slide.ss", pdfPath, "--cache-id", "page-bounds"], project);
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

async function commandAvailable(command) {
  const result = await spawnCollect(command, ["--version"], process.cwd());
  return result.code === 0;
}

async function runSs(args, cwd) {
  return spawnCollect(ssBin, args, cwd);
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
