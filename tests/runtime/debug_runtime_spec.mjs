#!/usr/bin/env node
import { spawn } from "node:child_process";
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

await testDebugScheduleJson();
await testDebugLayoutTraceJson();
await testDebugLayoutTraceJsonAfterLayoutFailure();
await testDebugLayoutTracePreservesPreambleReadFailure();
await testDebugOutputWriteFailures();
await testDebugLayoutConflictsJson();
await testDebugLayoutConflictsDerivedCurrentPath();

async function testDebugScheduleJson() {
  const project = await mkdtempProject("ss-debug-schedule-");
  try {
    await writeDeck(project);
    const output = path.join(project, "execution.json");
    await runSs(["debug", "schedule", "slide.ss", "--output", output], project);

    const payload = JSON.parse(await readFile(output, "utf8"));
    assert(payload.schema === 1, `unexpected schedule schema: ${JSON.stringify(payload)}`);
    assert(payload.kind === "ss-schedule-trace", `unexpected schedule kind: ${JSON.stringify(payload)}`);
    assert(Array.isArray(payload.units), "schedule trace should include units");
    assert(Array.isArray(payload.edges), "schedule trace should include edges");
    assert(Array.isArray(payload.execution_order), "schedule trace should include execution_order");
    assert(payload.units.length > 0, "schedule trace should include at least one scheduled unit");
    assert(payload.execution_order.length === payload.units.length, "execution order should cover all units");
    assert(payload.units.some((unit) => unit.source.includes("text!")), "schedule trace should include source text");
    const edgeKinds = new Set(payload.edges.map((edge) => edge.kind));
    assert(edgeKinds.has("dependency"), `schedule trace should include dependency edges: ${JSON.stringify(payload.edges)}`);
    for (const kind of edgeKinds) {
      assert(kind === "dependency", `unexpected schedule edge kind: ${kind}`);
    }
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDebugLayoutTraceJson() {
  const project = await mkdtempProject("ss-debug-layout-trace-");
  try {
    await writeDeck(project);
    const output = path.join(project, "layout-trace.json");
    await runSs(["debug", "layout", "trace", "slide.ss", "--output", output], project);

    const payload = JSON.parse(await readFile(output, "utf8"));
    assert(payload.schema === 1, `unexpected layout trace schema: ${JSON.stringify(payload)}`);
    assert(payload.kind === "ss-layout-trace", `unexpected layout trace kind: ${JSON.stringify(payload)}`);
    assert(Array.isArray(payload.events), "layout trace should include events");
    assert(payload.events.length > 0, "layout trace should include at least one event");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDebugLayoutTraceJsonAfterLayoutFailure() {
  const project = await mkdtempProject("ss-debug-layout-trace-failure-");
  try {
    await writeConflictDeck(project);
    const output = path.join(project, "layout-trace.json");
    const result = await spawnCollect(ssBin, ["debug", "layout", "trace", "slide.ss", "--output", output], project);
    const diagnostic = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "layout trace should preserve the layout failure");
    assert(diagnostic.includes("ConstraintConflict:"), `layout failure omitted its primary diagnostic:\n${diagnostic}`);

    const payload = JSON.parse(await readFile(output, "utf8"));
    assert(payload.schema === 1, `unexpected failed layout trace schema: ${JSON.stringify(payload)}`);
    assert(payload.kind === "ss-layout-trace", `unexpected failed layout trace kind: ${JSON.stringify(payload)}`);
    assert(Array.isArray(payload.events), "failed layout trace should include an events array");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDebugLayoutTracePreservesPreambleReadFailure() {
  const project = await mkdtempProject("ss-debug-layout-trace-preamble-failure-");
  try {
    const preamblePath = path.join(project, "preamble.tex");
    const outputPath = path.join(project, "layout-trace.json");
    await mkdir(preamblePath);
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page formula
text!("Inline $\\ArchiveMacro$ fallback")
end

document
  latex_preamble_file("preamble.tex")
end
`,
      "utf8",
    );

    const result = await spawnCollect(
      ssBin,
      ["debug", "layout", "trace", "slide.ss", "--output", outputPath],
      project,
    );
    const output = `${result.stdout}\n${result.stderr}`;
    assert(result.code !== 0, "layout trace should fail when its LaTeX preamble path is a directory");
    assert(output.includes("RenderFailed:"), `preamble failure did not produce a source diagnostic:\n${output}`);
    assert(output.includes("LaTeX preamble 'preamble.tex' could not be read"), `preamble failure omitted its operation:\n${output}`);
    assert(output.includes(preamblePath), `preamble failure omitted the resolved path:\n${output}`);
    assert(output.includes("file was expected"), `preamble failure omitted the actual cause:\n${output}`);
    assert(!output.includes("LayoutTraceWriteFailed:"), `preamble input failure was mislabeled as trace output failure:\n${output}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDebugOutputWriteFailures() {
  try {
    await access("/dev/full");
  } catch {
    return;
  }

  const project = await mkdtempProject("ss-debug-output-failure-");
  try {
    await writeDeck(project);
    for (const testCase of [
      {
        label: "schedule trace",
        args: ["debug", "schedule", "slide.ss", "--output", "/dev/full"],
        code: "ScheduleTraceWriteFailed:",
      },
      {
        label: "layout trace",
        args: ["debug", "layout", "trace", "slide.ss", "--output", "/dev/full"],
        code: "LayoutTraceWriteFailed:",
      },
    ]) {
      const result = await spawnCollect(ssBin, testCase.args, project);
      const output = `${result.stdout}\n${result.stderr}`;
      assert(result.code !== 0, `${testCase.label} should fail when the destination cannot accept data`);
      assert(output.includes(testCase.code), `${testCase.label} failure omitted its operation:\n${output}`);
      assert(output.includes("/dev/full"), `${testCase.label} failure omitted the output path:\n${output}`);
      assert(
        output.includes("no free space") || output.includes("permission denied"),
        `${testCase.label} failure omitted the operating-system reason:\n${output}`,
      );
      assert(!/\bTraceWriteFailed\b/.test(output), `${testCase.label} leaked the old internal error name:\n${output}`);
    }
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDebugLayoutConflictsJson() {
  const project = await mkdtempProject("ss-debug-layout-conflicts-json-");
  try {
    await writeConflictDeck(project);
    const output = path.join(project, "layout-conflicts.json");
    await runSs(["debug", "layout", "conflicts", "slide.ss", "--output", output], project);

    const payload = JSON.parse(await readFile(output, "utf8"));
    assert(payload.schema === 1, `unexpected conflict schema: ${JSON.stringify(payload)}`);
    assert(payload.kind === "ss-layout-conflicts", `unexpected conflict kind: ${JSON.stringify(payload)}`);
    assert(Array.isArray(payload.pages), "conflict report should include pages");
    assert(Array.isArray(payload.objects), "conflict report should include objects");
    assert(!("anchors" in payload), "conflict report should omit redundant anchor expansions");
    assert(Array.isArray(payload.relations), "conflict report should include relations");
    assert(Array.isArray(payload.failures), "conflict report should include failures");
    assert(payload.failures.length > 0, "conflict report should include at least one failure");
    assert(payload.failures.some((failure) => failure.reason === "anchor_value_conflict"), `expected anchor conflict: ${JSON.stringify(payload.failures)}`);
    assert(payload.failures.some((failure) => failure.propagation?.paths?.some((path) => path.lines?.some((line) => line.includes("→")))), `expected propagation path: ${JSON.stringify(payload.failures)}`);
    assert(payload.failures.every((failure) => !("difference" in failure)), `difference should not be exposed in conflict reports: ${JSON.stringify(payload.failures)}`);
    assert(payload.failures.some((failure) => failure.propagation?.paths?.some((path) => path.sources?.some((source) => typeof source === "string" && source.length > 0))), `expected propagation source: ${JSON.stringify(payload.failures)}`);
    assert(payload.failures.every((failure) => failure.propagation?.paths?.every((path) => path.lines?.every((line) => !line.includes("[source:"))) ?? true), `source markup leaked into propagation lines: ${JSON.stringify(payload.failures)}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDebugLayoutConflictsDerivedCurrentPath() {
  const project = await mkdtempProject("ss-debug-layout-conflicts-derived-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page broken
let a = text!("A")
~ a.left == page.left + 72
~ a.width == 300
~ a.right == page.right - 72
end
`,
      "utf8",
    );
    const output = path.join(project, "layout-conflicts.json");
    await runSs(["debug", "layout", "conflicts", "slide.ss", "--output", output], project);

    const payload = JSON.parse(await readFile(output, "utf8"));
    assert(payload.failures.length === 1, `derived current conflict should be merged: ${JSON.stringify(payload.failures)}`);
    const current = payload.failures[0].propagation?.paths?.find((path) => path.title === "current value");
    assert(current, `current value propagation missing: ${JSON.stringify(payload.failures[0])}`);
    assert(current.lines.some((line) => line.includes("page.left = 0.0")), `current propagation should start from page.left: ${JSON.stringify(current)}`);
    const leftIndex = current.lines.findIndex((line) => line.includes(".left = page.left + 72.0"));
    const rightIndex = current.lines.findIndex((line) => line.includes(".right =") && line.includes("+ 300.0"));
    assert(leftIndex >= 0 && typeof current.sources?.[leftIndex] === "string", `current propagation should include left constraint source: ${JSON.stringify(current)}`);
    assert(rightIndex >= 0 && typeof current.sources?.[rightIndex] === "string", `current propagation should include width-derived right source: ${JSON.stringify(current)}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function writeDeck(project) {
  await writeFile(
    path.join(project, "slide.ss"),
    `import std:themes/default as *

page one
text!("hello")
text!("world")
let item = text!("old")
item.link_id = "one"
text!(content(item))
end
`,
    "utf8",
  );
}

async function writeConflictDeck(project) {
  await writeFile(
    path.join(project, "slide.ss"),
    `import std:themes/default as *

page one
let item = text!("conflict")
~ item.left == page.left + 80
~ item.left == page.left + 120
end
`,
    "utf8",
  );
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
