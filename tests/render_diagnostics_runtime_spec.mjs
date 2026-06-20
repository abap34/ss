#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./lsp_harness.mjs";

await testRenderFailureProducesDiagnostic();

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
    assert(output.includes("Undefined control sequence"), `render diagnostic omitted command output summary:\n${output}`);
    assert(output.includes("slide.ss:4:1"), `render diagnostic omitted source location:\n${output}`);
    assert(!output.includes("panic:"), `render failure should not panic:\n${output}`);
    assert(!output.includes("native pdf:"), `render failure should not bypass diagnostics:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function mkdtempProject(prefix) {
  return mkdtemp(path.join(os.tmpdir(), prefix));
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
