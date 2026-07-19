#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "../../harness.mjs";

const project = await mkdtemp(path.join(os.tmpdir(), "ss-markdown-underline-"));
try {
  await writeFile(path.join(project, "slide.ss"), `import std:themes/default as *

page underline
let body = text!("before _custom_ after")
body.text.size = 32
body.text.line_height = 42
md_underline(body, md_underline_style(c"#cc3366", 0.35, 5, 3, "7,3"))
~ body.left == page.left + 80
~ body.top == page.top - 80
end
`, "utf8");

  expectSuccess(await runSs(["render", "--format", "html", "slide.ss", "deck.html"], project));
  const html = await readFile(path.join(project, "deck.html"), "utf8");
  assert(html.includes("opacity:0.350000;"), "HTML omitted the Markdown underline opacity");
  assert(html.includes("height:5.000000pt;"), "HTML omitted the Markdown underline width");
  assert(/rgb\(80\.[0-9]+% 20\.[0-9]+% 40\.[0-9]+%\)/.test(html), "HTML omitted the Markdown underline color");
  assert(html.includes("7.000000pt,transparent 7.000000pt,transparent 10.000000pt)"), "HTML omitted the Markdown underline dash pattern");
} finally {
  await rm(project, { recursive: true, force: true });
}

function runSs(args, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(ssBin, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (code, signal) => resolve({ code: code ?? -1, signal, stdout, stderr }));
  });
}

function expectSuccess(result) {
  assert(result.code === 0, `Markdown underline render failed with ${result.code ?? result.signal}:\n${result.stdout}\n${result.stderr}`);
}
