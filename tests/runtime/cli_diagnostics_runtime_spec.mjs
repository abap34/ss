#!/usr/bin/env node
import { spawn } from "node:child_process";
import { access, link, mkdir, mkdtemp, readFile, rename, rm, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

await testColoredDiagnosticsHighlightProgramBody();
await testImportedModuleImportFailureReportsBothFiles();
await testFunctionBodyUnknownIdentifierReportsFunctionSource();
await testProjectConfigFailureReportsConfigLocation();
await testDirectoryInputSuggestsProjectOption();
await testMissingInputReportsPath();
await testInputPathComponentReportsNotDirectory();
await testMissingProjectConfigReportsPath();
await testProjectConfigPathComponentReportsNotDirectory();
await testWatchMissingProjectConfigReportsPath();
await testWatchProjectPathComponentRecovers();
await testDoctorMissingProjectConfigReportsPath();
await testDoctorDiscoveredConfigFailureReportsPath();
await testDoctorRejectsWrongProjectPathKinds();
await testMalformedProjectEntryIsActionable();
await testMissingProjectEntryReportsPath();
await testDirectoryImportReportsPath();
await testImportSymlinkLoopReportsReason();
await testReadlinesSymlinkLoopReportsReason();
await testStandardLibraryEvaluationReportsItsSource();
await testDirectoryOutputReportsPath();
await testDumpWriteFailureReportsPath();
await testOutputPathConflictPreservesInput();
await testOutputPathConflictPreservesImportedSource();
await testProjectImportsResolveFromEntryDirectory();
await testWatchAssetBaseFailureReportsPaths();
await testWatchFingerprintFailureIsDeduplicatedAndRecovers();
await testRenderCachePathConflictReportsReason();
await testMissingHighlightQueryReportsPath();
await testFontEnvironmentRefreshFailureIsActionable();
await testContextDiagnosticsDoNotLeakInternalErrors();
await testFunctionRecordFieldDiagnosticIsUniqueAndPrecise();
await testMultipleHoleParseDiagnostics();
await testMixedHoleParseDiagnostics();
await testHoleAndSemanticDiagnosticsTogether();
await testMultipleTypeDiagnostics();
await testTypeAnnotationHolesAndIndependentTypeDiagnostics();
await testHoleBoundCalleeSuppressesUnknownFunction();
await testHoleCallbackSuppressesInvalidCallback();
await testMemberNameHoleSuppressesEnumCaseDiagnostic();
await testRecordUpdatePathHoleSuppressesFieldDiagnostic();

async function testColoredDiagnosticsHighlightProgramBody() {
  const project = await mkdtempProject("ss-cli-colored-diagnostics-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `page broken
let title = text!("hello", color = c"#ff0033")
let call = box!(title) ?? text!("fallback")
let multiline = """hello
world"""
let raw = <<
plain text
>>
let missing =
end
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss", "--color", "always"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail for a missing expression");
    assert(output.includes("\u001b[36mtext!\u001b[0m"), `callable identifier should include the bang in one highlighted token:\n${output}`);
    assert(output.includes('\u001b[32mc"#ff0033"\u001b[0m'), `color string should be highlighted as one string token:\n${output}`);
    assert(output.includes('\u001b[32m"""hello\u001b[0m'), `triple-quoted string start should be highlighted as one string token:\n${output}`);
    assert(output.includes("\u001b[33m??\u001b[0m"), `operator should be highlighted:\n${output}`);
    assert(output.includes("\u001b[32mplain text\u001b[0m"), `chevron block body should be highlighted as string content:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

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
    assert(output.includes("lib.ss:2:11: UnknownIdentifier:"), `function diagnostic did not point at the unknown identifier:\n${output}`);
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
    assert(output.includes("ss.toml:5:1: UnknownHighlightParser:"), `project config diagnostic did not point at parser line:\n${output}`);
    assert(output.includes("supported built-in tree-sitter parser"), `project config diagnostic omitted corrective guidance:\n${output}`);
    assert(output.includes('| parser = "python3"'), `project config diagnostic omitted source excerpt:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDirectoryInputSuggestsProjectOption() {
  const project = await mkdtempProject("ss-cli-directory-input-diagnostics-");
  try {
    await writeFile(
      path.join(project, "ss.toml"),
      `[project]
entry = "slide.ss"
`,
      "utf8",
    );
    await writeFile(path.join(project, "slide.ss"), "page main\nend\n", "utf8");

    const result = await runSs(["check", project], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should reject a directory passed as its input file");
    assert(output.includes(project), `directory-input diagnostic omitted the input path:\n${output}`);
    assert(output.includes("--project"), `directory-input diagnostic omitted the --project guidance:\n${output}`);
    assert(!/^error: IsDir\s*$/m.test(output), `directory input leaked a bare IsDir error:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMissingInputReportsPath() {
  const project = await mkdtempProject("ss-cli-missing-input-diagnostics-");
  try {
    const missing = path.join(project, "missing.ss");
    const result = await runSs(["check", missing], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail for a missing input file");
    assert(output.includes(missing), `missing-input diagnostic omitted the input path:\n${output}`);
    assert(output.toLowerCase().includes("not found"), `missing-input diagnostic did not explain that the file was not found:\n${output}`);
    assert(!/^error: FileNotFound\s*$/m.test(output), `missing input leaked a bare FileNotFound error:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testInputPathComponentReportsNotDirectory() {
  if (process.platform === "win32") return;
  const project = await mkdtempProject("ss-cli-input-component-not-directory-");
  try {
    const blocker = path.join(project, "not-a-directory");
    const input = path.join(blocker, "slide.ss");
    await writeFile(blocker, "file blocks the input path\n", "utf8");

    const result = await runSs(["check", input], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail when an input path component is a file");
    assert(output.includes("InputAccessFailed:"), `input path-component diagnostic omitted its operation:\n${output}`);
    assert(output.includes(input), `input path-component diagnostic omitted the input path:\n${output}`);
    assert(output.includes("not a directory"), `input path-component diagnostic omitted the actual cause:\n${output}`);
    assert(!output.includes("InputNotFound:"), `input path-component failure was misreported as a missing file:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMissingProjectConfigReportsPath() {
  const project = await mkdtempProject("ss-cli-missing-project-config-diagnostics-");
  try {
    const missingProject = path.join(project, "missing-project");
    const missingConfig = path.join(project, "missing-custom.toml");
    for (const testCase of [
      { argument: missingProject, expected: path.join(missingProject, "ss.toml") },
      { argument: missingConfig, expected: missingConfig },
    ]) {
      const result = await runSs(["check", "--project", testCase.argument], project);
      const output = combinedOutput(result);
      assert(result.code !== 0, "check should fail when the requested project config is missing");
      assert(output.includes(testCase.expected), `missing-project diagnostic omitted the resolved configuration path:\n${output}`);
      assert(output.includes("project configuration file was not found"), `missing-project diagnostic omitted the cause:\n${output}`);
      assert(!output.includes(`${missingConfig}${path.sep}ss.toml`), `custom project file incorrectly gained an ss.toml suffix:\n${output}`);
      assert(!/^error: FileNotFound\s*$/m.test(output), `missing project leaked a bare FileNotFound error:\n${output}`);
    }
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testProjectConfigPathComponentReportsNotDirectory() {
  if (process.platform === "win32") return;
  const project = await mkdtempProject("ss-cli-project-component-not-directory-");
  try {
    const blocker = path.join(project, "not-a-directory");
    const requestedProject = path.join(blocker, "nested-project");
    const configPath = path.join(requestedProject, "ss.toml");
    await writeFile(blocker, "file blocks the project path\n", "utf8");

    const result = await runSs(["check", "--project", requestedProject], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail when a project path component is a file");
    assert(output.includes("ProjectConfigReadFailed:"), `project path-component diagnostic omitted its operation:\n${output}`);
    assert(output.includes(configPath), `project path-component diagnostic omitted the resolved configuration path:\n${output}`);
    assert(output.includes("not a directory"), `project path-component diagnostic omitted the actual cause:\n${output}`);
    assert(!output.includes("ProjectConfigNotFound:"), `project path-component failure was misreported as a missing file:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testWatchMissingProjectConfigReportsPath() {
  const project = await mkdtempProject("ss-cli-watch-missing-project-config-");
  try {
    const missingProject = path.join(project, "missing-project");
    const configPath = path.join(missingProject, "ss.toml");
    const entryPath = path.join(missingProject, "slide.ss");
    const temporaryConfig = path.join(missingProject, "ss.toml.tmp");
    const result = await runSsUntilOutputs(
      ["watch", "check", "--project", missingProject, "--interval-ms", "50"],
      project,
      [
        {
          text: "waiting every 50ms",
          action: async () => {
            await mkdir(missingProject, { recursive: true });
            await writeFile(entryPath, "page main\nend\n", "utf8");
            await writeFile(temporaryConfig, '[project]\nentry = "slide.ss"\n', "utf8");
            await rename(temporaryConfig, configPath);
          },
        },
        { text: "watch: project configuration is valid" },
        { text: `watch: check ${entryPath} every 50ms` },
      ],
    );
    const output = combinedOutput(result);
    assert(output.includes("ProjectConfigNotFound:"), `watch missing-project diagnostic omitted its operation:\n${output}`);
    assert(output.includes(configPath), `watch missing-project diagnostic omitted the resolved ss.toml path:\n${output}`);
    assert(output.toLowerCase().includes("not found"), `watch missing-project diagnostic omitted the cause:\n${output}`);
    assert(output.includes("watch: project configuration is valid"), `watch did not resume after the configuration was created:\n${output}`);
    assert(output.includes(`watch: check ${entryPath} every 50ms`), `watch did not start checking the repaired project:\n${output}`);
    assert(!output.includes("CommandFailed:"), `watch missing-project diagnostic escaped to the command boundary:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testWatchProjectPathComponentRecovers() {
  if (process.platform === "win32") return;
  const project = await mkdtempProject("ss-cli-watch-project-component-not-directory-");
  try {
    const blocker = path.join(project, "not-a-directory");
    const requestedProject = path.join(blocker, "nested-project");
    const configPath = path.join(requestedProject, "ss.toml");
    const entryPath = path.join(requestedProject, "slide.ss");
    const temporaryConfig = path.join(requestedProject, "ss.toml.tmp");
    await writeFile(blocker, "file blocks the project path\n", "utf8");

    const result = await runSsUntilOutputs(
      ["watch", "check", "--project", requestedProject, "--interval-ms", "50"],
      project,
      [
        {
          text: "waiting every 50ms",
          action: async () => {
            await rm(blocker);
            await mkdir(requestedProject, { recursive: true });
            await writeFile(entryPath, "page main\nend\n", "utf8");
            await writeFile(temporaryConfig, '[project]\nentry = "slide.ss"\n', "utf8");
            await rename(temporaryConfig, configPath);
          },
        },
        { text: "watch: project configuration is valid" },
        { text: `watch: check ${entryPath} every 50ms` },
      ],
    );
    const output = combinedOutput(result);
    assert(output.includes("ProjectConfigReadFailed:"), `watch path-component diagnostic omitted its operation:\n${output}`);
    assert(output.includes(configPath), `watch path-component diagnostic omitted the configuration path:\n${output}`);
    assert(output.includes("not a directory"), `watch path-component diagnostic omitted the actual cause:\n${output}`);
    assert(output.includes("watch: project configuration is valid"), `watch did not resume after the path was repaired:\n${output}`);
    assert(output.includes(`watch: check ${entryPath} every 50ms`), `watch did not start checking the repaired project:\n${output}`);
    assert(!output.includes("CommandFailed:"), `watch path-component diagnostic escaped to the command boundary:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDoctorMissingProjectConfigReportsPath() {
  const project = await mkdtempProject("ss-cli-doctor-missing-project-config-");
  try {
    const missingProject = path.join(project, "missing-project");
    const missingConfig = path.join(project, "missing-custom.toml");
    for (const testCase of [
      { argument: missingProject, expected: path.join(missingProject, "ss.toml") },
      { argument: missingConfig, expected: missingConfig },
    ]) {
      const result = await runSs(["doctor", "--project", testCase.argument, "--strict"], project);
      const output = combinedOutput(result);
      assert(result.code !== 0, "doctor --strict should fail when the requested project config is missing");
      assert(output.includes(`fail resolve ${testCase.expected}:`), `doctor missing-project diagnostic omitted the resolved configuration path:\n${output}`);
      assert(output.toLowerCase().includes("not found"), `doctor missing-project diagnostic omitted the cause:\n${output}`);
      assert(!output.includes(`${missingConfig}${path.sep}ss.toml`), `doctor incorrectly appended ss.toml to a custom project file:\n${output}`);
    }
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDoctorDiscoveredConfigFailureReportsPath() {
  const project = await mkdtempProject("ss-cli-doctor-discovered-config-");
  try {
    const configPath = path.join(project, "ss.toml");
    await writeFile(configPath, "[project]\nentry = slide.ss\n", "utf8");

    const result = await runSs(["doctor", "--strict"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "doctor --strict should fail for a malformed discovered project config");
    assert(output.includes(`fail project configuration ${configPath}:`), `doctor discovered-config diagnostic omitted its path:\n${output}`);
    assert(output.includes("MissingProjectEntry:"), `doctor discovered-config diagnostic omitted its cause:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDoctorRejectsWrongProjectPathKinds() {
  const project = await mkdtempProject("ss-cli-doctor-project-path-kinds-");
  try {
    const entryPath = path.join(project, "slides");
    const assetBasePath = path.join(project, "assets");
    await mkdir(entryPath);
    await writeFile(assetBasePath, "not a directory\n", "utf8");
    await writeFile(
      path.join(project, "ss.toml"),
      `[project]
entry = "slides"
asset_base_dir = "assets"
`,
      "utf8",
    );

    const result = await runSs(["doctor", "--project", project, "--strict"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "doctor --strict should reject invalid entry and asset-base path kinds");
    assert(output.includes(`fail entry: ${entryPath}: expected a file, but found a directory`), `doctor accepted a directory as its entry:\n${output}`);
    assert(output.includes(`fail asset base: ${assetBasePath}: expected a directory`), `doctor accepted a file as its asset base:\n${output}`);
    assert(!output.includes(`ok entry: ${entryPath}`), `doctor reported the directory entry as valid:\n${output}`);
    assert(!output.includes(`ok asset base: ${assetBasePath}`), `doctor reported the file asset base as valid:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMalformedProjectEntryIsActionable() {
  const project = await mkdtempProject("ss-cli-malformed-project-entry-");
  try {
    await writeFile(path.join(project, "ss.toml"), "[project]\nentry = slide.ss\n", "utf8");

    const result = await runSs(["check", "--project", project], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should reject an unquoted project entry");
    assert(output.includes("MissingProjectEntry:"), `malformed project entry omitted its diagnostic code:\n${output}`);
    assert(output.includes("add or set"), `malformed project entry incorrectly assumed the key was absent:\n${output}`);
    assert(output.includes("using a quoted path"), `malformed project entry omitted corrective guidance:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMissingProjectEntryReportsPath() {
  const project = await mkdtempProject("ss-cli-missing-project-entry-diagnostics-");
  try {
    const missingEntry = path.join(project, "slides", "missing.ss");
    await writeFile(
      path.join(project, "ss.toml"),
      `[project]
entry = "slides/missing.ss"
asset_base_dir = "."
`,
      "utf8",
    );

    const result = await runSs(["check", "--project", project], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail when the configured project entry is missing");
    assert(output.includes(missingEntry), `missing-project-entry diagnostic omitted the resolved entry path:\n${output}`);
    assert(output.toLowerCase().includes("not found"), `missing-project-entry diagnostic did not explain that the file was not found:\n${output}`);
    assert(!/^error: FileNotFound\s*$/m.test(output), `missing project entry leaked a bare FileNotFound error:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDirectoryImportReportsPath() {
  const project = await mkdtempProject("ss-cli-directory-import-diagnostics-");
  try {
    const importedPath = path.join(project, "parts.ss");
    await mkdir(importedPath);
    await writeFile(
      path.join(project, "slide.ss"),
      `import "./parts" as *

page main
end
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail when an import resolves to a directory");
    assert(output.includes("slide.ss:1:1: ImportReadFailed:"), `directory-import diagnostic did not point at the import:\n${output}`);
    assert(output.includes(importedPath), `directory-import diagnostic omitted the resolved module path:\n${output}`);
    assert(output.toLowerCase().includes("directory"), `directory-import diagnostic did not explain the path kind:\n${output}`);
    assert(!/^error: IsDir\s*$/m.test(output), `directory import leaked a bare IsDir error:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testImportSymlinkLoopReportsReason() {
  const project = await mkdtempProject("ss-cli-import-symlink-loop-");
  try {
    const loopPath = path.join(project, "loop.ss");
    await symlink(loopPath, loopPath);
    await writeFile(
      path.join(project, "slide.ss"),
      `import "./loop" as *

page main
end
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail for an import with a symbolic-link cycle");
    assert(output.includes("slide.ss:1:1: ImportReadFailed:"), `symlink-loop import diagnostic did not point at the import:\n${output}`);
    assert(output.includes(loopPath), `symlink-loop import diagnostic omitted the resolved path:\n${output}`);
    assert(output.includes("symbolic-link cycle"), `symlink-loop import diagnostic omitted the actual cause:\n${output}`);
    assert(!/^error: SymLinkLoop\s*$/m.test(output), `symlink-loop import leaked a bare internal error:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testReadlinesSymlinkLoopReportsReason() {
  const project = await mkdtempProject("ss-cli-readlines-symlink-loop-");
  try {
    const loopPath = path.join(project, "loop.txt");
    await symlink(loopPath, loopPath);
    await writeFile(
      path.join(project, "slide.ss"),
      `page main
let contents = readlines("loop.txt")
end
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail when readlines encounters a symbolic-link cycle");
    assert(output.includes("ReadlinesFailed:"), `readlines diagnostic omitted its operation:\n${output}`);
    assert(output.includes(loopPath), `readlines diagnostic omitted the resolved path:\n${output}`);
    assert(output.includes("symbolic-link cycle"), `readlines diagnostic omitted the actual cause:\n${output}`);
    assert(!output.includes("FileNotFound"), `readlines misdiagnosed a symbolic-link cycle as a missing file:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testStandardLibraryEvaluationReportsItsSource() {
  const project = await mkdtempProject("ss-cli-stdlib-evaluation-diagnostic-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page main
code_file!("missing.txt")
end
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail when a standard-library helper cannot read its input");
    const diagnostic = output.split("\n").find((line) => line.includes("ReadlinesFailed:"));
    assert(diagnostic?.includes("std:themes/default:"), `standard-library diagnostic used the wrong source path:\n${output}`);
    assert(
      output.includes("|   return code(readlines(path_value), language_name, theme)"),
      `standard-library diagnostic omitted its source excerpt:\n${output}`,
    );
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDirectoryOutputReportsPath() {
  const project = await mkdtempProject("ss-cli-directory-output-diagnostics-");
  try {
    await writeFile(path.join(project, "slide.ss"), "page main\nend\n", "utf8");

    const result = await runSs(["dump", "slide.ss", "--output", project], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "dump should reject a directory as its output path");
    assert(output.includes(project), `directory-output diagnostic omitted the output path:\n${output}`);
    assert(output.toLowerCase().includes("directory"), `directory-output diagnostic did not explain the path kind:\n${output}`);
    assert(!/^error: (?:IsDir|OutputPathNotFile)\s*$/m.test(output), `directory output leaked a bare internal error:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDumpWriteFailureReportsPath() {
  try {
    await access("/dev/full");
  } catch {
    return;
  }

  const project = await mkdtempProject("ss-cli-dump-write-failure-");
  try {
    await writeFile(path.join(project, "slide.ss"), "page main\nend\n", "utf8");

    const result = await runSs(["dump", "slide.ss", "--output", "/dev/full"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "dump should fail when the destination cannot accept data");
    assert(output.includes("DumpOutputWriteFailed:"), `dump write failure omitted the output operation:\n${output}`);
    assert(output.includes("/dev/full"), `dump write failure omitted the output path:\n${output}`);
    assert(
      output.includes("no free space") || output.includes("permission denied"),
      `dump write failure omitted the operating-system reason:\n${output}`,
    );
    assert(!/^error: (?:NoSpaceLeft|InputOutput)\s*$/m.test(output), `dump write failure leaked a bare internal error:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testOutputPathConflictPreservesInput() {
  const project = await mkdtempProject("ss-cli-output-conflict-");
  try {
    const slide = path.join(project, "slide.ss");
    const source = "page main\nend\n";
    await writeFile(slide, source, "utf8");

    const direct = await runSs(["dump", "slide.ss", "--output", "slide.ss"], project);
    const directOutput = combinedOutput(direct);
    assert(direct.code !== 0, "dump should reject its input file as the output");
    assert(directOutput.includes("OutputPathConflictsWithInput:"), `direct output conflict was not explained:\n${directOutput}`);
    assert((await readFile(slide, "utf8")) === source, "direct output conflict modified the input file");

    const alias = path.join(project, "slide-alias.ss");
    await symlink(slide, alias);
    const linked = await runSs(["dump", "slide.ss", "--output", alias], project);
    const linkedOutput = combinedOutput(linked);
    assert(linked.code !== 0, "dump should reject a symlink to its input file as the output");
    assert(linkedOutput.includes("OutputPathConflictsWithInput:"), `symlink output conflict was not explained:\n${linkedOutput}`);
    assert((await readFile(slide, "utf8")) === source, "symlink output conflict modified the input file");

    const shared = path.join(project, "shared.pdf");
    const duplicate = await runSs([
      "render",
      "slide.ss",
      "--output",
      shared,
      "--diagnostics-json",
      shared,
    ], project);
    const duplicateOutput = combinedOutput(duplicate);
    assert(duplicate.code !== 0, "render should reject identical primary and diagnostics outputs");
    assert(duplicateOutput.includes("OutputPathsConflict:"), `duplicate render outputs were not explained:\n${duplicateOutput}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testOutputPathConflictPreservesImportedSource() {
  const project = await mkdtempProject("ss-cli-import-output-conflict-");
  try {
    const imported = path.join(project, "parts.ss");
    const importedSource = `fn helper() -> String
  return "loaded"
end
`;
    await writeFile(imported, importedSource, "utf8");
    await writeFile(
      path.join(project, "slide.ss"),
      `import "./parts" as *

page main
text!(helper())
end
`,
      "utf8",
    );

    const direct = await runSs(["dump", "slide.ss", "--output", "parts.ss"], project);
    const directOutput = combinedOutput(direct);
    assert(direct.code !== 0, "dump should reject an imported source file as the output");
    assert(directOutput.includes("OutputPathConflictsWithSource:"), `imported source conflict was not explained:\n${directOutput}`);
    assert(directOutput.includes(imported), `imported source conflict omitted the protected path:\n${directOutput}`);
    assert((await readFile(imported, "utf8")) === importedSource, "direct imported-source conflict modified the module");

    const alias = path.join(project, "parts-hardlink.ss");
    await link(imported, alias);
    const linked = await runSs(["dump", "slide.ss", "--output", alias], project);
    const linkedOutput = combinedOutput(linked);
    assert(linked.code !== 0, "dump should reject a hard link to an imported source file as the output");
    assert(linkedOutput.includes("OutputPathConflictsWithSource:"), `hard-link imported source conflict was not explained:\n${linkedOutput}`);
    assert((await readFile(imported, "utf8")) === importedSource, "hard-link imported-source conflict modified the module");

    const diagnostics = await runSs([
      "render",
      "slide.ss",
      "out.pdf",
      "--diagnostics-json",
      "parts.ss",
    ], project);
    const diagnosticsOutput = combinedOutput(diagnostics);
    assert(diagnostics.code !== 0, "render should reject an imported source file as diagnostics output");
    assert(diagnosticsOutput.includes("OutputPathConflictsWithSource:"), `diagnostics imported source conflict was not explained:\n${diagnosticsOutput}`);
    assert((await readFile(imported, "utf8")) === importedSource, "diagnostics output conflict modified the module");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testProjectImportsResolveFromEntryDirectory() {
  const project = await mkdtempProject("ss-cli-project-entry-imports-");
  try {
    const slides = path.join(project, "slides");
    await mkdir(slides);
    await mkdir(path.join(project, "assets"));
    await writeFile(
      path.join(project, "ss.toml"),
      `[project]
entry = "slides/slide.ss"
asset_base_dir = "assets"
`,
      "utf8",
    );
    await writeFile(
      path.join(slides, "parts.ss"),
      `fn helper() -> String
  return "loaded"
end
`,
      "utf8",
    );
    await writeFile(
      path.join(slides, "slide.ss"),
      `import "./parts" as *

page main
end
`,
      "utf8",
    );

    const result = await runSs(["check", "--project", project], project);
    const output = combinedOutput(result);
    assert(result.code === 0, `project-relative import resolved from asset_base_dir instead of the entry directory:\n${output}`);
    assert(!output.includes("UnknownImport"), `project-relative import produced an import diagnostic:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testWatchAssetBaseFailureReportsPaths() {
  const project = await mkdtempProject("ss-cli-watch-asset-base-failure-");
  try {
    const entry = path.join(project, "slide.ss");
    const assetBase = path.join(project, "asset-base");
    await writeFile(
      path.join(project, "ss.toml"),
      `[project]
entry = "slide.ss"
asset_base_dir = "asset-base"
`,
      "utf8",
    );
    await writeFile(entry, "page main\nend\n", "utf8");
    await writeFile(assetBase, "not a directory\n", "utf8");

    const result = await runSs(["watch", "check", "--project", project, "--interval-ms", "50"], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "watch should fail when the asset base is not a directory");
    assert(output.includes("could not inspect asset base directory"), `watch fingerprint failure omitted the failing path category:\n${output}`);
    assert(output.includes(assetBase), `watch fingerprint failure omitted the asset base path:\n${output}`);
    assert(output.includes("not a directory"), `watch fingerprint failure omitted the actual cause:\n${output}`);
    assert(!output.includes("CommandFailed:"), `watch fingerprint failure escaped to the command boundary:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testWatchFingerprintFailureIsDeduplicatedAndRecovers() {
  const project = await mkdtempProject("ss-cli-watch-fingerprint-recovery-");
  try {
    const entry = path.join(project, "slide.ss");
    const assetBase = path.join(project, "assets");
    await writeFile(entry, "page main\nend\n", "utf8");
    await mkdir(assetBase);

    const result = await runSsUntilOutputs(
      ["watch", "check", entry, "--asset-base-dir", assetBase, "--interval-ms", "50"],
      project,
      [
        {
          text: `watch: check ${entry} every 50ms`,
          action: async () => {
            await rm(assetBase, { recursive: true, force: true });
            await writeFile(assetBase, "not a directory\n", "utf8");
          },
        },
        {
          text: "could not inspect asset base directory",
          action: async () => {
            await new Promise((resolve) => setTimeout(resolve, 250));
            await rm(assetBase);
            await mkdir(assetBase);
          },
        },
        { text: "recovered access to asset base directory" },
      ],
    );
    const output = combinedOutput(result);
    const failures = [...output.matchAll(/could not inspect asset base directory/g)].length;
    assert(failures === 1, `watch repeated the same fingerprint failure ${failures} times:\n${output}`);
    assert(output.includes(assetBase), `watch fingerprint recovery omitted the repaired path:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testRenderCachePathConflictReportsReason() {
  const project = await mkdtempProject("ss-cli-render-cache-conflict-");
  try {
    const cachePath = path.join(project, ".ss-cache");
    await writeFile(cachePath, "not a directory\n", "utf8");
    await writeFile(path.join(project, "slide.ss"), "page main\nend\n", "utf8");

    for (const testCase of [
      { label: "check", args: ["check", "slide.ss"] },
      { label: "dump", args: ["dump", "slide.ss", "--output", "out.json"] },
      { label: "render", args: ["render", "slide.ss", "--output", "out.pdf"] },
    ]) {
      const result = await runSs(testCase.args, project);
      const output = combinedOutput(result);
      assert(result.code !== 0, `${testCase.label} should fail when .ss-cache is a file`);
      assert(output.includes("RenderCacheAccessFailed:"), `${testCase.label} cache failure omitted its operation:\n${output}`);
      assert(output.includes(path.join(".ss-cache", "render")), `${testCase.label} cache failure omitted the cache path:\n${output}`);
      assert(output.includes("not a directory"), `${testCase.label} cache failure omitted the path conflict:\n${output}`);
      assert(!/^error: NotDir\s*$/m.test(output), `${testCase.label} cache failure leaked a bare internal error:\n${output}`);
    }
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMissingHighlightQueryReportsPath() {
  const project = await mkdtempProject("ss-cli-highlight-query-missing-");
  try {
    const queryPath = path.join(project, "missing-highlights.scm");
    await writeFile(
      path.join(project, "ss.toml"),
      `[project]
entry = "slide.ss"

[highlight.languages.snippet]
parser = "python"
query = "missing-highlights.scm"
`,
      "utf8",
    );
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page main
code!("print('hello')", "snippet")
end
`,
      "utf8",
    );

    const result = await runSs(["check", "--project", project], project);
    const output = combinedOutput(result);
    assert(result.code !== 0, "check should fail when a configured highlight query is missing");
    assert(output.includes("RenderFailed:"), `missing highlight query did not produce a source diagnostic:\n${output}`);
    assert(output.includes(queryPath), `missing highlight query diagnostic omitted the resolved path:\n${output}`);
    assert(output.includes("path was not found"), `missing highlight query diagnostic omitted the actual cause:\n${output}`);
    assert(output.includes('| code!("print(\'hello\')", "snippet")'), `missing highlight query diagnostic omitted the code block source:\n${output}`);
    assert(!/^error: FileNotFound\s*$/m.test(output), `missing highlight query leaked a bare internal error:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testFontEnvironmentRefreshFailureIsActionable() {
  const project = await mkdtempProject("ss-cli-font-environment-diagnostics-");
  try {
    const fontLoop = path.join(project, "font-loop");
    const cacheDir = path.join(project, "font-cache");
    const fontsConfPath = path.join(project, "fonts.conf");
    await symlink(fontLoop, fontLoop);
    await mkdir(cacheDir);
    await writeFile(
      fontsConfPath,
      `<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>${fontLoop}</dir>
  <cachedir>${cacheDir}</cachedir>
</fontconfig>
`,
      "utf8",
    );
    await writeFile(path.join(project, "slide.ss"), "page main\nend\n", "utf8");

    const env = { FONTCONFIG_FILE: fontsConfPath };
    const cases = [
      { label: "check", args: ["check", "slide.ss"] },
      { label: "render", args: ["render", "slide.ss", "out.pdf"] },
      {
        label: "layout conflict report",
        args: ["debug", "layout", "conflicts", "slide.ss", "--output", "conflicts.json"],
      },
    ];
    for (const testCase of cases) {
      const result = await runSs(testCase.args, project, env);
      const output = combinedOutput(result);
      assert(result.code !== 0, `${testCase.label} should fail when the font environment cannot be refreshed`);
      assert(output.includes("FontSetupFailed:"), `${testCase.label} font environment diagnostic omitted its explanation:\n${output}`);
      assert(output.includes("fc-list"), `${testCase.label} font environment diagnostic omitted the Fontconfig probe:\n${output}`);
      assert(output.includes("FONTCONFIG_FILE"), `${testCase.label} font environment diagnostic omitted FONTCONFIG_FILE guidance:\n${output}`);
      assert(output.includes("FONTCONFIG_PATH"), `${testCase.label} font environment diagnostic omitted FONTCONFIG_PATH guidance:\n${output}`);
      assert(!/^error: FontEnvironmentRefreshFailed\s*$/m.test(output), `${testCase.label} leaked a bare internal error:\n${output}`);
    }
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testContextDiagnosticsDoNotLeakInternalErrors() {
  const cases = [
    {
      prefix: "ss-cli-invalid-field-default-",
      source: `type Card = object {
  accent: Color = "red"
}

page main
end
`,
      diagnostic: "InvalidFieldDefault:",
      bare: /^error: InvalidType\s*$/m,
    },
    {
      prefix: "ss-cli-duplicate-page-",
      source: `page repeated
end

page repeated
end
`,
      diagnostic: "DuplicatePage:",
      bare: /^error: DuplicatePage\s*$/m,
    },
    {
      prefix: "ss-cli-page-constraint-target-",
      source: `page main
~ page.width == 100
end
`,
      diagnostic: "PageCannotBeConstraintTarget:",
      message: "PageCannotBeConstraintTarget: page dimensions cannot be constraint targets; constrain an object dimension to a page anchor instead",
      bare: /^error: PageCannotBeConstraintTarget\s*$/m,
    },
  ];

  for (const testCase of cases) {
    const project = await mkdtempProject(testCase.prefix);
    try {
      await writeFile(path.join(project, "slide.ss"), testCase.source, "utf8");
      const result = await runSs(["check", "slide.ss"], project);
      const output = combinedOutput(result);
      assert(result.code !== 0, `${testCase.diagnostic} fixture should fail`);
      assert(output.includes(testCase.diagnostic), `contextual diagnostic was not printed:\n${output}`);
      if (testCase.message) {
        assert(output.includes(testCase.message), `contextual diagnostic did not match its complete user-facing message:\n${output}`);
      }
      assert(!testCase.bare.test(output), `contextual diagnostic was followed by a bare internal error:\n${output}`);
    } finally {
      await rm(project, { recursive: true, force: true });
    }
  }
}

async function testFunctionRecordFieldDiagnosticIsUniqueAndPrecise() {
  const project = await mkdtempProject("ss-cli-function-record-field-diagnostics-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import "./theme" as *

page main
end
`,
      "utf8",
    );
    await writeFile(
      path.join(project, "theme.ss"),
      `import std:themes/default as default

fn/! success_text(content: String) -> Object
  return default::text(content, default::current_theme() with {
    body.text.cjk_bold_passes = 3
  })
end

fn/! danger_text(content: String) -> Object
  return default::text(content, default::current_theme() with {
    body.text.cjk_bold_passes = 3
  })
end
`,
      "utf8",
    );

    const result = await runSs(["check", "slide.ss"], project);
    const output = combinedOutput(result);
    const headers = output.match(/^ERROR: .*UnknownRecordField:/gm) ?? [];
    assert(result.code !== 0, "check should fail for an unknown record field in a placing function");
    assert(headers.length === 2, `two unknown record fields produced ${headers.length} diagnostic headers instead of two:\n${output}`);
    assert(output.includes("theme.ss:5:15: UnknownRecordField:"), `first unknown record field diagnostic did not point at the field token:\n${output}`);
    assert(output.includes("theme.ss:11:15: UnknownRecordField:"), `second unknown record field diagnostic did not point at the field token:\n${output}`);
    assert(output.includes("|     body.text.cjk_bold_passes = 3"), `unknown record field diagnostic omitted its source excerpt:\n${output}`);
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

async function runSs(args, cwd, env = {}) {
  return await new Promise((resolve, reject) => {
    const child = spawn(ssBin, args, {
      cwd,
      env: { ...process.env, NO_COLOR: "1", ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
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

async function runSsUntilOutputs(args, cwd, steps, env = {}, timeoutMs = 5000) {
  return await new Promise((resolve, reject) => {
    const child = spawn(ssBin, args, {
      cwd,
      detached: process.platform !== "win32",
      env: { ...process.env, NO_COLOR: "1", ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let stepIndex = 0;
    let advancing = false;
    let matchedAll = false;
    let settled = false;
    let failure = null;
    let killTimer = null;
    let closeDeadline = null;

    const signalProcess = (signal) => {
      try {
        if (process.platform !== "win32" && child.pid != null) {
          process.kill(-child.pid, signal);
        } else {
          child.kill(signal);
        }
      } catch {
        // The process may have exited between the output event and the signal.
      }
    };

    const clearTimers = () => {
      clearTimeout(timeoutTimer);
      if (killTimer != null) clearTimeout(killTimer);
      if (closeDeadline != null) clearTimeout(closeDeadline);
    };

    const rejectWithoutClose = () => {
      if (settled) return;
      settled = true;
      clearTimers();
      reject(failure ?? new Error("ss did not terminate after being killed"));
    };

    const stopProcess = (initialSignal) => {
      signalProcess(initialSignal);
      if (initialSignal !== "SIGKILL") {
        killTimer = setTimeout(() => signalProcess("SIGKILL"), 500);
      }
      closeDeadline = setTimeout(rejectWithoutClose, 1500);
    };

    const timeoutTimer = setTimeout(() => {
      if (settled) return;
      const expected = steps[stepIndex]?.text ?? "all expected output";
      failure = new Error(`ss did not emit '${expected}' within ${timeoutMs}ms:\n${stdout}\n${stderr}`);
      stopProcess("SIGKILL");
    }, timeoutMs);

    const advanceSteps = async () => {
      if (advancing || matchedAll || failure != null || settled) return;
      advancing = true;
      try {
        while (stepIndex < steps.length && `${stdout}\n${stderr}`.includes(steps[stepIndex].text)) {
          const step = steps[stepIndex];
          stepIndex += 1;
          if (step.action) await step.action();
        }
        if (stepIndex === steps.length) {
          matchedAll = true;
          clearTimeout(timeoutTimer);
          stopProcess("SIGTERM");
        }
      } catch (error) {
        failure = error;
        clearTimeout(timeoutTimer);
        stopProcess("SIGKILL");
      } finally {
        advancing = false;
      }
    };

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      void advanceSteps();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
      void advanceSteps();
    });
    child.on("error", (error) => {
      if (settled) return;
      settled = true;
      clearTimers();
      reject(error);
    });
    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      clearTimers();
      const result = { code: code ?? -1, stdout, stderr };
      if (failure != null) {
        reject(failure);
        return;
      }
      if (matchedAll) {
        resolve(result);
        return;
      }
      const expected = steps[stepIndex]?.text ?? "all expected output";
      const reason = `ss exited before emitting '${expected}'`;
      reject(new Error(`${reason}:\n${combinedOutput(result)}`));
    });
  });
}
