import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root } from "../../harness.mjs";
import { WatchProcess, settle } from "../harness.mjs";

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
let watch;

function deck(name) {
  return `import std:themes/default as *\npage main\ntext!(readlines("../outside/" ++ "${name}.data"))\nend\n`;
}

try {
  await writeFile(first, "First input");
  await writeFile(second, "Second input");
  await writeFile(source, deck("first"));
  watch = new WatchProcess(project, ["check", "--quiet", "slide.ss"]);
  await watch.waitFor(() => checks() >= 1, "initial check");
  await settle();
  const initialChecks = checks();
  await writeFile(path.join(project, "unrelated.ss"), "page unused\nend\n");
  await writeFile(path.join(project, "unrelated.svg"), '<svg xmlns="http://www.w3.org/2000/svg"/>');
  await settle();
  assert.equal(checks(), initialChecks, `Unused files caused a new check:\n${watch.log}`);

  await writeFile(first, "Changed input outside the asset directory");
  await watch.waitFor(() => checks() > initialChecks, "changed external input");
  await settle();
  const firstChecks = checks();
  await writeFile(source, deck("second"));
  await watch.waitFor(() => checks() > firstChecks, "replacement dependency");
  await settle();
  const replacementChecks = checks();
  await writeFile(first, "No longer referenced");
  await settle();
  assert.equal(checks(), replacementChecks, `An obsolete dependency caused a new check:\n${watch.log}`);

  const errorsBefore = watch.occurrences("ReadlinesFailed:");
  await rm(second);
  await watch.waitFor(() => watch.occurrences("ReadlinesFailed:") > errorsBefore, "missing input diagnostic");
  const beforeRecovery = checks();
  await writeFile(second, "Repaired input");
  await watch.waitFor(() => checks() > beforeRecovery, "missing input recovery");
  await settle();

  const diagram = path.join(outside, "diagram.svg");
  await writeFile(diagram, svg("red"));
  const beforeDiagram = checks();
  await writeFile(source,
    'import std:themes/default as *\npage main\nplace!(img_obj("../outside/diagram.svg"))\nend\n');
  await watch.waitFor(() => checks() > beforeDiagram, "prepared image dependency");
  await settle();
  const beforeImageChange = checks();
  await writeFile(diagram, svg("blue"));
  await watch.waitFor(() => checks() > beforeImageChange, "changed prepared image");
  console.log("Watch inputs: unused files, external reads, prepared images, replacement and recovery passed");
} finally {
  await watch?.close();
  await rm(directory, { recursive: true, force: true });
}

function svg(color) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="30"><rect width="40" height="30" fill="${color}"/></svg>`;
}

function checks() {
  return watch.occurrences("ok ");
}
