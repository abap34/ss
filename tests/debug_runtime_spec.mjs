#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./lsp_harness.mjs";

await testDebugScheduleJson();
await testDebugLayoutTraceJson();

async function testDebugScheduleJson() {
  const project = await mkdtempProject("ss-debug-schedule-");
  try {
    await writeDeck(project);
    const output = path.join(project, "schedule.json");
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
    assert(edgeKinds.has("write_order"), `schedule trace should include write_order edges: ${JSON.stringify(payload.edges)}`);
    for (const kind of edgeKinds) {
      assert(kind === "dependency" || kind === "write_order", `unexpected schedule edge kind: ${kind}`);
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
    await runSs(["debug", "layout-trace", "slide.ss", "--output", output], project);

    const payload = JSON.parse(await readFile(output, "utf8"));
    assert(payload.schema === 1, `unexpected layout trace schema: ${JSON.stringify(payload)}`);
    assert(payload.kind === "ss-layout-trace", `unexpected layout trace kind: ${JSON.stringify(payload)}`);
    assert(Array.isArray(payload.events), "layout trace should include events");
    assert(payload.events.length > 0, "layout trace should include at least one event");
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
let item = new("old", "note", "text")
set_content(item, "one")
set_content(item, "two")
let observed = new(content(item), "label", "text")
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
