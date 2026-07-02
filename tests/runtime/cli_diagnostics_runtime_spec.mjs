#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

await testImportedModuleImportFailureReportsBothFiles();
await testFunctionBodyUnknownIdentifierReportsFunctionSource();
await testProjectConfigFailureReportsConfigLocation();
await testMultipleHoleParseDiagnostics();
await testMixedHoleParseDiagnostics();
await testHoleAndSemanticDiagnosticsTogether();
await testMultipleTypeDiagnostics();
await testTypeAnnotationHolesAndIndependentTypeDiagnostics();
await testHoleBoundCalleeSuppressesUnknownFunction();
await testHoleCallbackSuppressesInvalidCallback();
await testMemberNameHoleSuppressesEnumCaseDiagnostic();
await testRecordUpdatePathHoleSuppressesFieldDiagnostic();

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

async function testMultipleHoleParseDiagnostics() {
  const project = await mkdtempProject("ss-cli-hole-diagnostics-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `page broken
let first =
let second =
end
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail for missing expressions");
    assert(output.includes("slide.ss:2:"), `first missing expression did not point at line 2:\n${output}`);
    assert(output.includes("slide.ss:3:"), `second missing expression did not point at line 3:\n${output}`);
    assert((output.match(/ExpectedExpression/g) ?? []).length >= 2, `check did not print multiple expression diagnostics:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMixedHoleParseDiagnostics() {
  const project = await mkdtempProject("ss-cli-mixed-hole-diagnostics-");
  try {
    await writeFile(path.join(project, "slide.ss"), mixedHoleSource(), "utf8");

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail for mixed holes");
    assert(output.includes("slide.ss:1:"), `import hole did not point at line 1:\n${output}`);
    assert(output.includes("InvalidImportSpec"), `import hole diagnostic missing:\n${output}`);
    assert(output.includes("slide.ss:4:"), `expression hole did not point at line 4:\n${output}`);
    assert(output.includes("slide.ss:5:"), `member-name hole did not point at line 5:\n${output}`);
    assert(output.includes("ExpectedMemberName"), `member-name hole diagnostic missing:\n${output}`);
    assert(output.includes("slide.ss:6:"), `leading call-argument hole did not point at line 6:\n${output}`);
    assert(output.includes("slide.ss:7:"), `trailing call-argument hole did not point at line 7:\n${output}`);
    assert((output.match(/ExpectedExpression/g) ?? []).length >= 3, `mixed source did not print enough expression diagnostics:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testHoleAndSemanticDiagnosticsTogether() {
  const project = await mkdtempProject("ss-cli-hole-semantic-diagnostics-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `page broken
let x =
let y: Missing = 1
end
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail for a parse hole and an unknown type");
    assert(output.includes("slide.ss:2:"), `expression hole did not point at line 2:\n${output}`);
    assert(output.includes("ExpectedExpression"), `expression hole diagnostic missing:\n${output}`);
    assert(output.includes("slide.ss:3:"), `unknown type did not point at line 3:\n${output}`);
    assert(output.includes("UnknownType: unknown type: Missing"), `unknown type diagnostic missing:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMultipleTypeDiagnostics() {
  const project = await mkdtempProject("ss-cli-multiple-type-diagnostics-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `page typed
let first: String = 1
let second: Number = "wrong"
end
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail for multiple independent type errors");
    assert(output.includes("slide.ss:2:"), `first type diagnostic did not point at line 2:\n${output}`);
    assert(output.includes("slide.ss:3:"), `second type diagnostic did not point at line 3:\n${output}`);
    assert((output.match(/TypeMismatch/g) ?? []).length >= 2, `check did not print multiple type diagnostics:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testTypeAnnotationHolesAndIndependentTypeDiagnostics() {
  const project = await mkdtempProject("ss-cli-type-hole-diagnostics-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `page typed
let first: = 1
let second: = "ok"
let third: String = 2
end
record Broken {
  field:
}
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail for type holes and an independent type error");
    assert(output.includes("slide.ss:2:"), `first type hole did not point at line 2:\n${output}`);
    assert(output.includes("slide.ss:3:"), `second type hole did not point at line 3:\n${output}`);
    assert(output.includes("slide.ss:7:"), `field type hole did not point at line 7:\n${output}`);
    assert((output.match(/ExpectedTypeAnnotation/g) ?? []).length >= 3, `type hole diagnostics missing:\n${output}`);
    assert(output.includes("slide.ss:4:"), `independent type mismatch did not point at line 4:\n${output}`);
    assert((output.match(/^ERROR: .* TypeMismatch:/gm) ?? []).length === 1, `type annotation holes produced secondary type mismatches:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testHoleBoundCalleeSuppressesUnknownFunction() {
  const project = await mkdtempProject("ss-cli-hole-callee-diagnostics-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `page broken
let x =
x()
end
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail for a missing callee binding expression");
    assert(output.includes("ExpectedExpression"), `hole diagnostic missing:\n${output}`);
    assert(!output.includes("UnknownFunction"), `hole-bound callee produced a secondary UnknownFunction diagnostic:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testHoleCallbackSuppressesInvalidCallback() {
  const project = await mkdtempProject("ss-cli-hole-callback-diagnostics-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `page broken
set_repr(text!("body"), )
end
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail for a missing callback expression");
    assert(output.includes("ExpectedExpression"), `hole diagnostic missing:\n${output}`);
    assert(!output.includes("InvalidCallback"), `callback hole produced a secondary InvalidCallback diagnostic:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMemberNameHoleSuppressesEnumCaseDiagnostic() {
  const project = await mkdtempProject("ss-cli-hole-member-diagnostics-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `type Align = left | center | right
record TextStyle {
  math_align: Align
}

page broken
let style = TextStyle { math_align = Align. }
end
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail for a missing enum member name");
    assert(output.includes("ExpectedMemberName"), `member-name hole diagnostic missing:\n${output}`);
    assert(!output.includes("UnknownEnumCase"), `member-name hole produced a secondary UnknownEnumCase diagnostic:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testRecordUpdatePathHoleSuppressesFieldDiagnostic() {
  const project = await mkdtempProject("ss-cli-hole-record-update-diagnostics-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `record Inner {
  size: Number
}
record Theme {
  body: Inner
}

page broken
let theme = Theme { body = Inner { size = 1 } }
let changed = theme with {
  body.
}
end
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail for a missing record update path segment");
    assert(output.includes("ExpectedIdentifier"), `record update path hole diagnostic missing:\n${output}`);
    assert(!output.includes("UnknownRecordField"), `record update path hole produced a secondary UnknownRecordField diagnostic:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function mixedHoleSource() {
  return `import

page mixed
let first =
let member = text!("body").
let call = text!(,)
let trailing = text!("body",)
end
`;
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
