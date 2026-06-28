#!/usr/bin/env node
import { spawn } from "node:child_process";
import { assert, root, ssBin } from "./harness.mjs";

await testDoctorReportsTreeSitterHealth();

async function testDoctorReportsTreeSitterHealth() {
  const result = await spawnCollect(ssBin, ["doctor", "--project", "tests/fixtures/project-basic"], root);
  const output = `${result.stdout}\n${result.stderr}`;
  assert(result.code === 0, `doctor should exit successfully without --strict:\n${output}`);
  assert(output.includes("tree-sitter:"), `doctor output omitted tree-sitter section:\n${output}`);
  assert(output.includes("ok cache:"), `doctor output omitted tree-sitter cache:\n${output}`);
  assert(output.includes("ok manifest hash:"), `doctor output omitted tree-sitter manifest hash:\n${output}`);
  assert(output.includes("ok runtime ABI range:"), `doctor output omitted tree-sitter runtime ABI range:\n${output}`);
  assert(output.includes("ok configured names:"), `doctor output omitted configured language count:\n${output}`);
  assert(output.includes("ok ss: parser=ss, query=builtin:ss"), `doctor output omitted ss language health:\n${output}`);
  assert(output.includes("ok python: parser=python, query=builtin:python"), `doctor output omitted python language health:\n${output}`);
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
