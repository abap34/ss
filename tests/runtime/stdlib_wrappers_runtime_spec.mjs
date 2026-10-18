#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

const pdflatexAvailable = await commandAvailable("pdflatex");

if (pdflatexAvailable) await testPreludeLatexUsesLiteralPayload();
await testExplicitThemeValues();

async function testPreludeLatexUsesLiteralPayload() {
  const project = await mkdtempProject("ss-stdlib-wrappers-");
  try {
    const source = "$x$";
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:prelude as *

page latex
let formula = latex!("${source}")
end
`,
      "utf8",
    );
    const dumpPath = path.join(project, "dump.json");
    await runSs(["dump", "slide.ss", dumpPath], project);

    const dump = JSON.parse(await readFile(dumpPath, "utf8"));
    const node = dump.nodes.find((candidate) => candidate.content === source);
    assert(node, `latex node was not found: ${JSON.stringify(dump.nodes)}`);
    assert(!Object.hasOwn(node, "role"), `unexpected role field: ${JSON.stringify(node)}`);
    assert(node.placement?.input.type.name === "Latex", `latex constructor lost its input type: ${JSON.stringify(node)}`);
    assert(node.placement?.display.kind === "latex", `latex constructor lost its display: ${JSON.stringify(node)}`);
    assert(node.render.kind === "latex", `latex should render its literal body: ${JSON.stringify(node)}`);
    assert(node.blocks === null && node.inline_lines === null, `latex body was parsed as Markdown: ${JSON.stringify(node)}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testExplicitThemeValues() {
  const project = await mkdtempProject("ss-theme-values-");
  try {
    await writeFile(path.join(project, "slide.ss"), `import std:themes/default as *
const custom: Theme = default_theme() with { body.text.size = 31 }
page styled
  text!("Custom", custom.body)
  text!("Local", custom.body with { text.size = 19 })
  text!("Unchanged", custom.body)
  text!("Default")
end
`);
    const dumpPath = path.join(project, "dump.json");
    await runSs(["dump", "slide.ss", dumpPath], project);
    const dump = JSON.parse(await readFile(dumpPath, "utf8"));
    for (const [content, size] of [["Custom", 31], ["Local", 19], ["Unchanged", 31], ["Default", 20]]) {
      const node = dump.nodes.find(candidate => candidate.content === content);
      assert(node?.placement?.input.type.name === "Text", `missing typed text: ${content}`);
      assert(node.render.text.font_size === size, `incorrect explicit style for ${content}: ${JSON.stringify(node.render.text)}`);
    }
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function mkdtempProject(prefix) {
  return mkdtemp(path.join(os.tmpdir(), prefix));
}

async function runSs(args, cwd) {
  const result = await spawnCollect(ssBin, args, cwd);
  if (result.code !== 0) {
    throw new Error(`ss ${args.join(" ")} failed with ${result.code}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
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
