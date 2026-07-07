#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

await testPreludeMathtexUsesRawTexPayload();

async function testPreludeMathtexUsesRawTexPayload() {
  const project = await mkdtempProject("ss-stdlib-wrappers-");
  try {
    const source = "x";
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:core/prelude as *

page raw_tex
let raw = mathtex!("${source}")
place!(raw)
end
`,
      "utf8",
    );
    const dumpPath = path.join(project, "dump.json");
    await runSs(["dump", "slide.ss", dumpPath], project);

    const dump = JSON.parse(await readFile(dumpPath, "utf8"));
    const node = dump.nodes.find((candidate) => candidate.content === source);
    assert(node, `mathtex node was not found: ${JSON.stringify(dump.nodes)}`);
    assert(node.role === "math_tex", `mathtex should use math_tex role: ${JSON.stringify(node)}`);
    assert(node.object_kind === "asset", `mathtex should use asset object kind: ${JSON.stringify(node)}`);
    assert(node.payload_kind === "math_tex", `mathtex should use math_tex payload: ${JSON.stringify(node)}`);
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
