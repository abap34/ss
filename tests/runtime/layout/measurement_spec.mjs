#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "../harness.mjs";

const pdflatexAvailable = await commandAvailable("pdflatex");

await testNaturalTitleWidthDoesNotSelfWrap();
await testCheckReportsRasterMeasurementFailure();
if (pdflatexAvailable) {
  await testPanelHeightUsesRenderedIconMeasurement();
  await testCheckReportsInlineMathMeasurementFailure();
  await testPanelHeightUsesRenderedMathMeasurement();
}
if (pdflatexAvailable && await commandAvailable("pdftoppm") && await commandAvailable("magick")) {
  await testVectorMathKeepsAspectRatio();
}

async function testNaturalTitleWidthDoesNotSelfWrap() {
  const project = await mkdtempProject("ss-layout-measure-title-");
  try {
    const slide = path.join(project, "slide.ss");
    const dumpPath = path.join(project, "dump.json");
    await writeFile(
      slide,
      `import std:themes/default as *

page title
head! "original inline math"
end
`,
      "utf8",
    );

    const dump = await dumpSlide(project, dumpPath);
    const title = nodeByContent(dump, "original inline math");
    assert(title.height <= 50, `title should fit on one line, got ${frameSummary(title)}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testPanelHeightUsesRenderedIconMeasurement() {
  const project = await mkdtempProject("ss-layout-measure-icon-");
  try {
    const slide = path.join(project, "slide.ss");
    const dumpPath = path.join(project, "dump.json");
    await writeFile(
      slide,
      `${bodyBoxSource()}

page icon_panel
body_box! <<
aaaasifgsousgvfohsvdfou agdfoubvadkfnvadofygaskhbasdkhgasdohgvadkhvasdouags dkhasvdihasgdohvfihvaf asihgasdfkhavf asdghvasfd ![](fa-solid:star)
>>
end
`,
      "utf8",
    );

    const dump = await dumpSlide(project, dumpPath);
    const body = nodeByContentPrefix(dump, "aaaasifgsousgvfohsvdfou");
    assert(body.height >= 55, `icon body should be measured as wrapped rendered text, got ${frameSummary(body)}`);
    assertPanelContainsBody(dump, body);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testPanelHeightUsesRenderedMathMeasurement() {
  const project = await mkdtempProject("ss-layout-measure-math-");
  try {
    const slide = path.join(project, "slide.ss");
    const dumpPath = path.join(project, "dump.json");
    await writeFile(
      slide,
      `${bodyBoxSource()}

page inline_math_panel
body_box! <<
aaaasifgsousgvfohsvdfou agdfoubvadkfnvadofygaskhbasdkhgasdohgvadkhvasdouags dkhasvdihasgdohvfihvaf asihgasdfkhavf asdghvasfd $f$
>>
end

page display_math_panel
body_box! <<
prefix text

$$
\\frac{a+b}{c+d} = \\sqrt{x^2 + y^2}
$$

suffix text
>>
end

page table_math_panel
body_box! <<
| item | value |
| --- | --- |
| long wrapped text with inline math $x_i + y_i = z_i$ and an icon ![](fa-solid:circle) near the end | $f$ |
| another row | $\\alpha + \\beta$ |
>>
end
`,
      "utf8",
    );

    const dump = await dumpSlide(project, dumpPath);
    const inlineBody = nodeByContentPrefix(dump, "aaaasifgsousgvfohsvdfou");
    assert(inlineBody.height >= 55, `inline math body should be measured as wrapped rendered text, got ${frameSummary(inlineBody)}`);
    assertPanelContainsBody(dump, inlineBody);

    const displayBody = nodeByContentPrefix(dump, "prefix text");
    assert(displayBody.height >= 100, `display math body should include rendered display math height, got ${frameSummary(displayBody)}`);
    assertPanelContainsBody(dump, displayBody);

    const tableBody = nodeByContentPrefix(dump, "| item | value |");
    assert(tableBody.height >= 150, `table math body should include rendered table height, got ${frameSummary(tableBody)}`);
    assertPanelContainsBody(dump, tableBody);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testCheckReportsInlineMathMeasurementFailure() {
  const project = await mkdtempProject("ss-layout-measure-math-failure-");
  try {
    const slide = path.join(project, "slide.ss");
    await writeFile(
      slide,
      `import std:themes/default as *

page bad
text!("$\\notacommand$")
end
`,
      "utf8",
    );

    const result = await spawnCollect(ssBin, ["check", "slide.ss"], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "check should fail when virtual render measurement fails");
    assert(output.includes("RenderFailed:"), `measurement failure did not produce a render diagnostic:\n${output}`);
    assert(output.includes("Undefined control sequence"), `measurement diagnostic omitted command output summary:\n${output}`);
    assert(output.includes("slide.ss:4:9"), `measurement diagnostic did not point at the failing formula:\n${output}`);
    assert(output.includes('| text!("$\\notacommand$")'), `measurement diagnostic omitted source excerpt:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testCheckReportsRasterMeasurementFailure() {
  const project = await mkdtempProject("ss-layout-measure-raster-failure-");
  try {
    const slide = path.join(project, "slide.ss");
    await writeFile(path.join(project, "bad.jpg"), Buffer.from("not a jpeg"));
    await writeFile(
      slide,
      `import std:themes/default as *

page bad
image!("bad.jpg")
end
`,
      "utf8",
    );

    const result = await spawnCollect(ssBin, ["check", "slide.ss"], project);
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "check should fail when virtual raster measurement fails");
    assert(output.includes("RenderFailed:"), `raster measurement failure did not produce a render diagnostic:\n${output}`);
    assert(output.includes("slide.ss:4:9"), `raster measurement diagnostic did not point at the asset source:\n${output}`);
    assert(output.includes('| image!("bad.jpg")'), `raster measurement diagnostic omitted source excerpt:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testVectorMathKeepsAspectRatio() {
  const project = await mkdtempProject("ss-layout-measure-vector-math-");
  try {
    const slide = path.join(project, "slide.ss");
    const pdfPath = path.join(project, "out.pdf");
    await writeFile(
      slide,
      `import std:themes/default as *

page math_aspect
let formula = tex!("x + y = z")
~ formula.left == page.left + 96
~ formula.right == page.right - 96
~ formula.top == page.top - 320
end
`,
      "utf8",
    );

    await runSs(["render", "slide.ss", pdfPath, "--cache-id", "math-aspect"], project);
    await runCommand("pdftoppm", ["-png", "-r", "144", pdfPath, "page"], project);
    const geometry = await runCommand("magick", [
      "page-1.png",
      "-alpha",
      "off",
      "-fuzz",
      "8%",
      "-trim",
      "-format",
      "%wx%h",
      "info:",
    ], project);
    const match = /^(\d+)x(\d+)/.exec(geometry.stdout.trim());
    assert(match, `could not parse trimmed math geometry: ${geometry.stdout}`);
    const width = Number(match[1]);
    const height = Number(match[2]);
    assert(width / height > 3, `vector math should keep a wide aspect ratio, got ${width}x${height}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function bodyBoxSource() {
  return `import std:themes/default as *

fn body_box!(body_text: String) -> Object
  let chrome = panel!()
  chrome.chrome = ChromeStyle {
    fill = c"0.97,0.98,1"
    stroke = c"0.80,0.84,0.90"
    line_width = 2
    radius = 12
  }

  let box = text!(body_text)

  ~ chrome.left == page.left + 52
  ~ chrome.right == page.right - 52
  ~ chrome.top == box.top + 16
  ~ chrome.bottom == box.bottom - 16
  ~ box.left == page.left + 72
  ~ box.right == page.right - 72

  return box
end`;
}

async function dumpSlide(project, dumpPath) {
  await runSs(["dump", "slide.ss", dumpPath], project);
  return JSON.parse(await readFile(dumpPath, "utf8"));
}

function nodeByContent(dump, content) {
  const node = dump.nodes.find((candidate) => candidate.content === content);
  assert(node, `node with content ${JSON.stringify(content)} was not found`);
  return node;
}

function nodeByContentPrefix(dump, prefix) {
  const node = dump.nodes.find((candidate) => typeof candidate.content === "string" && candidate.content.startsWith(prefix));
  assert(node, `node with content prefix ${JSON.stringify(prefix)} was not found`);
  return node;
}

function assertPanelContainsBody(dump, body) {
  const panel = dump.nodes.find((candidate) =>
    candidate.render?.kind === "chrome_only" &&
    close(candidate.x, body.x - 20) &&
    close(candidate.y, body.y - 16) &&
    close(candidate.width, body.width + 40));
  assert(panel, `panel for body was not found: ${frameSummary(body)}`);
  assert(close(panel.height, body.height + 32), `panel height should track body height, panel ${frameSummary(panel)}, body ${frameSummary(body)}`);
}

function frameSummary(node) {
  return `x=${node.x}, y=${node.y}, width=${node.width}, height=${node.height}`;
}

function close(left, right) {
  return Math.abs(left - right) <= 0.01;
}

async function runSs(args, cwd) {
  const result = await spawnCollect(ssBin, args, cwd);
  if (result.code !== 0) {
    throw new Error(`ss ${args.join(" ")} failed with ${result.code}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  }
  return result;
}

async function runCommand(command, args, cwd) {
  const result = await spawnCollect(command, args, cwd);
  if (result.code !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed with ${result.code}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  }
  return result;
}

async function spawnCollect(command, args, cwd) {
  return await new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
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

async function mkdtempProject(prefix) {
  return mkdtemp(path.join(os.tmpdir(), prefix));
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
    child.on("exit", (code) => finish(code === 0));
  });
}
