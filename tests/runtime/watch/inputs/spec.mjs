import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";

const scratch = path.join(root, ".ss-cache", "tests", "watch-inputs");
await mkdir(scratch, { recursive: true });
const directory = await mkdtemp(path.join(scratch, "project-"));
const project = path.join(directory, "project");
const outside = path.join(directory, "outside");
await mkdir(project);
await mkdir(outside);
const source = path.join(project, "slide.ss");
const first = path.join(outside, "first.data");
const second = path.join(outside, "second.data");
let child;
let log = "";
let exit;
let deadline;

function deck(name) {
  return `import std:themes/default as *\npage main\ntext!(readlines("../outside/" ++ "${name}.data"))\nend\n`;
}

try {
  await writeFile(first, "First input");
  await writeFile(second, "Second input");
  await writeFile(source, deck("first"));
  child = spawn(ssBin, ["watch", "check", "--quiet", "--interval-ms", "50", "slide.ss"], {
    cwd: project, detached: true, stdio: ["ignore", "ignore", "pipe"],
  });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { log += chunk; });
  exit = new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (code, signal) => resolve({ code, signal }));
  });
  deadline = setTimeout(() => kill(), 30_000);
  await waitFor(() => checks() >= 1, "initial check");
  await settle();
  const initialChecks = checks();
  await writeFile(path.join(project, "unrelated.ss"), "page unused\nend\n");
  await writeFile(path.join(project, "unrelated.svg"), '<svg xmlns="http://www.w3.org/2000/svg"/>');
  await settle();
  assert.equal(checks(), initialChecks, `Unused files caused a new check:\n${log}`);

  await writeFile(first, "Changed input outside the asset directory");
  await waitFor(() => checks() > initialChecks, "changed external input");
  await settle();
  const firstChecks = checks();
  await writeFile(source, deck("second"));
  await waitFor(() => checks() > firstChecks, "replacement dependency");
  await settle();
  const replacementChecks = checks();
  await writeFile(first, "No longer referenced");
  await settle();
  assert.equal(checks(), replacementChecks, `An obsolete dependency caused a new check:\n${log}`);

  const errorsBefore = occurrences("ReadlinesFailed:");
  await rm(second);
  await waitFor(() => occurrences("ReadlinesFailed:") > errorsBefore, "missing input diagnostic");
  const beforeRecovery = checks();
  await writeFile(second, "Repaired input");
  await waitFor(() => checks() > beforeRecovery, "missing input recovery");
  await settle();

  const diagram = path.join(outside, "diagram.svg");
  await writeFile(diagram, svg("red"));
  const beforeDiagram = checks();
  await writeFile(source,
    'import std:themes/default as *\npage main\nplace!(img_obj("../outside/diagram.svg"))\nend\n');
  await waitFor(() => checks() > beforeDiagram, "prepared image dependency");
  await settle();
  const beforeImageChange = checks();
  await writeFile(diagram, svg("blue"));
  await waitFor(() => checks() > beforeImageChange, "changed prepared image");
  console.log("Watch inputs: unused files, external reads, prepared images, replacement and recovery passed");
} finally {
  clearTimeout(deadline);
  kill();
  await exit;
  await rm(directory, { recursive: true, force: true });
}

function occurrences(text) {
  return log.split(text).length - 1;
}

function svg(color) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="30"><rect width="40" height="30" fill="${color}"/></svg>`;
}

function checks() {
  return occurrences("ok ");
}

function settle() {
  return new Promise((resolve) => setTimeout(resolve, 300));
}

async function waitFor(predicate, description) {
  const limit = Date.now() + 5_000;
  while (Date.now() < limit) {
    if (predicate()) return;
    if (child.exitCode !== null || child.signalCode !== null) break;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`Timed out waiting for ${description}:\n${log}`);
}

function kill() {
  if (!child?.pid) return;
  try { process.kill(-child.pid, "SIGKILL"); } catch (error) {
    if (error.code !== "ESRCH") throw error;
  }
}
