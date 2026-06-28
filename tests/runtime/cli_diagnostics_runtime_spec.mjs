#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

await testImportedModuleImportFailureReportsBothFiles();
await testFunctionBodyUnknownIdentifierReportsFunctionSource();
await testProjectConfigFailureReportsConfigLocation();

async function testImportedModuleImportFailureReportsBothFiles() {
  const project = await mkdtempProject("ss-cli-import-diagnostics-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import "./a" as *

page main
end
`,
      "utf8",
    );
    await writeFile(path.join(project, "ok.ss"), "fn ok() -> String\n  return \"ok\"\nend\n", "utf8");
    await writeFile(
      path.join(project, "a.ss"),
      `import "./ok" as *
import "./missing" as *
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail for an imported missing module");
    assert(output.includes("a.ss:2:1: UnknownImport:"), `missing imported-module diagnostic:\n${output}`);
    assert(output.includes('| import "./missing" as *'), `imported-module diagnostic omitted source excerpt:\n${output}`);
    assert(output.includes("slide.ss:1:1: ImportFailed:"), `missing importing-module diagnostic:\n${output}`);
    assert(output.includes('| import "./a" as *'), `importing-module diagnostic omitted source excerpt:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testFunctionBodyUnknownIdentifierReportsFunctionSource() {
  const project = await mkdtempProject("ss-cli-function-diagnostics-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import "./lib" as *

page main
f!()
end
`,
      "utf8",
    );
    await writeFile(
      path.join(project, "lib.ss"),
      `fn f!() -> Void
  let x = y
end
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail for an unknown identifier in a function body");
    assert(output.includes("lib.ss:2:3: UnknownIdentifier:"), `function diagnostic did not point at function body:\n${output}`);
    assert(output.includes("|   let x = y"), `function diagnostic omitted source excerpt:\n${output}`);
    assert(!output.includes("slide.ss:4:1: UnknownIdentifier:"), `function body error was reported only at the call site:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testProjectConfigFailureReportsConfigLocation() {
  const project = await mkdtempProject("ss-cli-project-config-diagnostics-");
  try {
    await writeFile(
      path.join(project, "ss.toml"),
      `[project]
entry = "slide.ss"

[highlight.languages.snippet]
parser = "python3"
query = "builtin:python"
`,
      "utf8",
    );
    await writeFile(path.join(project, "slide.ss"), "page main\nend\n", "utf8");

    const result = await runSs(["check", "--project", project], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail for an invalid project highlight parser");
    assert(output.includes("ss.toml:5:1: ProjectConfigFailed: UnknownHighlightParser"), `project config diagnostic did not point at parser line:\n${output}`);
    assert(output.includes('| parser = "python3"'), `project config diagnostic omitted source excerpt:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function mkdtempProject(prefix) {
  return mkdtemp(path.join(os.tmpdir(), prefix));
}

function combinedOutput(result) {
  return `${result.stdout}\n${result.stderr}`;
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
