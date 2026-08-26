#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

const pdflatexAvailable = await commandAvailable("pdflatex");

if (pdflatexAvailable) await testPreludeLatexUsesLiteralPayload();
await testThemeStoredThemeOverride("academic");
await testThemeStoredThemeOverride("pop");

async function testPreludeLatexUsesLiteralPayload() {
  const project = await mkdtempProject("ss-stdlib-wrappers-");
  try {
    const source = "$x$";
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:core/prelude as *

page latex
let formula = latex!("${source}")
place!(formula)
end
`,
      "utf8",
    );
    const dumpPath = path.join(project, "dump.json");
    await runSs(["dump", "slide.ss", dumpPath], project);

    const dump = JSON.parse(await readFile(dumpPath, "utf8"));
    const node = dump.nodes.find((candidate) => candidate.content === source);
    assert(node, `latex node was not found: ${JSON.stringify(dump.nodes)}`);
    assert(node.role === "latex", `latex should use latex role: ${JSON.stringify(node)}`);
    assert(node.object_kind === "asset", `latex should use asset object kind: ${JSON.stringify(node)}`);
    assert(node.payload_kind === "latex", `latex should use latex payload: ${JSON.stringify(node)}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testThemeStoredThemeOverride(themeName) {
  const project = await mkdtempProject(`ss-theme-${themeName}-`);
  try {
    const content = `${themeName} override`;
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/${themeName} as *

document
theme!(default_theme() with {
  body.text.size = 31
})
end

page styled
text!("${content}")
end
`,
      "utf8",
    );
    const dumpPath = path.join(project, "dump.json");
    await runSs(["dump", "slide.ss", dumpPath], project);

    const dump = JSON.parse(await readFile(dumpPath, "utf8"));
    const node = dump.nodes.find((candidate) => candidate.content === content);
    assert(node, `theme text node was not found: ${JSON.stringify(dump.nodes)}`);
    const textStyle = JSON.parse(node.fields.text);
    const size = taggedRecordField(textStyle, "size");
    assert(size?.kind === "number" && size.value === 31, `${themeName} theme override did not reach text!: ${JSON.stringify(textStyle)}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function taggedRecordField(record, name) {
  assert(record.kind === "record", `expected tagged record: ${JSON.stringify(record)}`);
  return record.fields.find((field) => field.name === name)?.value;
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
