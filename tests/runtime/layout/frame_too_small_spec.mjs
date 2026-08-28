#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "../harness.mjs";

await testWrappedTextUsesConstrainedWidthForDiagnostics();
await testMarkdownTableUsesConstrainedWidthForDiagnostics();
await testChromeStrokeStaysInsideFrameForDiagnostics();
await testTooSmallFixedFrameReportsConstraints();

async function testWrappedTextUsesConstrainedWidthForDiagnostics() {
  const project = await mkdtempProject("ss-frame-too-small-wrapped-text-");
  try {
    await writeSlide(
      project,
      `import std:themes/default as *

page wrapped_ok
  let body = text!("This is a deliberately long paragraph that should wrap inside the fixed width frame without reporting frame too small.")
  body.text.size = 22
  body.text.line_height = 30
  ~ body.left == page.left + 100
  ~ body.right == body.left + 260
  ~ body.top == page.top - 120
end
`,
    );

    const diagnosticsPath = path.join(project, "diagnostics.json");
    const result = await render(project, "wrapped-ok.pdf", "wrapped-ok", diagnosticsPath);
    assertCleanFrameDiagnostics(result, diagnosticsPath, "wrapped text should not be compared against its unwrapped natural width");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMarkdownTableUsesConstrainedWidthForDiagnostics() {
  const project = await mkdtempProject("ss-frame-too-small-table-");
  try {
    await writeSlide(
      project,
      `import std:themes/default as *

page table_ok
  let body = text! <<
**Observed \`kernel_seidel_2d\` updates**

| Applications | Metric 1 | Metric 2 | Metric 3 |
| ---: | ---: | ---: | ---: |
| 630 | 475 | 472 | 335 |

Repeated updates continue along the same edge after the older state is processed.
>>
  body.text.size = 16
  body.text.line_height = 22
  body.text.markdown_table_cell_pad_x = 7
  body.text.markdown_table_cell_pad_y = 5
  body.text.markdown_table_line_width = 0.8

  ~ body.left == page.left + 642
  ~ body.right == page.right - 96
  ~ body.top == page.top - 160
end
`,
    );

    const diagnosticsPath = path.join(project, "diagnostics.json");
    const result = await render(project, "table-ok.pdf", "table-ok", diagnosticsPath);
    assertCleanFrameDiagnostics(result, diagnosticsPath, "markdown table borders and ink overhang should not create false frame warnings");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testChromeStrokeStaysInsideFrameForDiagnostics() {
  const project = await mkdtempProject("ss-frame-too-small-chrome-");
  try {
    await writeSlide(
      project,
      `import std:themes/default as *

page chrome_ok
  let panel = panel!()
  panel.chrome = ChromeStyle {
    fill = c"0.97,0.98,1"
    stroke = c"0.80,0.84,0.90"
    line_width = 2
    radius = 12
  }
  ~ panel.left == page.left + 52
  ~ panel.right == page.right - 52
  ~ panel.top == page.top - 160
  ~ panel.bottom == panel.top - 120
end
`,
    );

    const diagnosticsPath = path.join(project, "diagnostics.json");
    const result = await render(project, "chrome-ok.pdf", "chrome-ok", diagnosticsPath);
    assertCleanFrameDiagnostics(result, diagnosticsPath, "chrome stroke should be drawn inside the fixed frame");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testTooSmallFixedFrameReportsConstraints() {
  const project = await mkdtempProject("ss-frame-too-small-fixed-");
  try {
    await writeSlide(
      project,
      `import std:themes/default as *

page too_small
  let body = text!("SupercalifragilisticexpialidociousSupercalifragilisticexpialidocious")
  body.text.size = 24
  body.text.line_height = 30
  ~ body.left == page.left + 100
  ~ body.right == body.left + 120
  ~ body.top == page.top - 120
end
`,
    );

    const diagnosticsPath = path.join(project, "diagnostics.json");
    const result = await render(project, "too-small.pdf", "too-small", diagnosticsPath);
    const output = combinedOutput(result);
    assert(result.code === 0, `render should succeed with a layout warning:\n${output}`);
    assert(output.includes("FrameTooSmall"), `fixed undersized frame should report FrameTooSmall:\n${output}`);
    assert(!output.includes("ContentOverflow"), `diagnostic should not use the legacy ContentOverflow name:\n${output}`);
    assert(!/\breason\b/.test(output), `FrameTooSmall output should not include a fixed reason field:\n${output}`);
    assert(output.includes("horizontal frame fixed by"), `diagnostic should explain which horizontal constraints fixed the frame:\n${output}`);
    assert(output.includes("~ body.left == page.left + 100"), `diagnostic should cite the left constraint source:\n${output}`);
    assert(output.includes("~ body.right == body.left + 120"), `diagnostic should cite the right constraint source:\n${output}`);

    const payload = JSON.parse(await readFile(diagnosticsPath, "utf8"));
    const frameTooSmall = payload.diagnostics.find((diagnostic) => diagnostic.code === "FrameTooSmall");
    assert(frameTooSmall, `diagnostics JSON should contain FrameTooSmall: ${JSON.stringify(payload)}`);
    assert(frameTooSmall.severity === "warning", `FrameTooSmall should be a warning: ${JSON.stringify(frameTooSmall)}`);
    assert(frameTooSmall.message.includes("short by width="), `FrameTooSmall message should include the short width: ${frameTooSmall.message}`);
    assert(!payload.diagnostics.some((diagnostic) => diagnostic.code === "ContentOverflow"), `diagnostics JSON should not contain legacy ContentOverflow: ${JSON.stringify(payload)}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function assertCleanFrameDiagnostics(result, diagnosticsPath, label) {
  const output = combinedOutput(result);
  assert(result.code === 0, `render failed while checking ${label}:\n${output}`);
  assert(!output.includes("FrameTooSmall"), `${label}:\n${output}`);
  assert(!output.includes("PageOverflow"), `${label}:\n${output}`);
  assert(!output.includes("ContentOverflow"), `${label}:\n${output}`);

  const payload = JSON.parse(await readFile(diagnosticsPath, "utf8"));
  const unexpected = payload.diagnostics.filter((diagnostic) =>
    diagnostic.code === "FrameTooSmall" ||
    diagnostic.code === "PageOverflow" ||
    diagnostic.code === "ContentOverflow");
  assert(unexpected.length === 0, `${label}: unexpected diagnostics ${JSON.stringify(unexpected)}`);
}

async function render(project, outputName, cacheId, diagnosticsPath) {
  return await spawnCollect(ssBin, [
    "render",
    "slide.ss",
    outputName,
    "--diagnostics-json",
    diagnosticsPath,
  ], project);
}

async function writeSlide(project, source) {
  await writeFile(path.join(project, "slide.ss"), source, "utf8");
}

function combinedOutput(result) {
  return `${result.stdout}\n${result.stderr}`;
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
