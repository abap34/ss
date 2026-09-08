import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";
import { terminateProcessTree } from "../../process.mjs";
import { WatchProcess, settle } from "../harness.mjs";

const probe = await run("sh", ["-c", "command -v pdflatex"], root, true);
if (probe.code !== 0) {
  console.log("TeX input tracking: skipped because pdflatex is unavailable");
  process.exit(0);
}
const realPdflatex = probe.stdout.trim();
const scratch = path.join(root, ".ss-cache", "tests", "watch-latex");
await mkdir(scratch, { recursive: true });
const directory = await mkdtemp(path.join(scratch, "project-"));
const project = path.join(directory, "project with spaces");
const outside = path.join(directory, "outside");
const bin = path.join(directory, "bin");
await mkdir(project);
await mkdir(path.join(project, ".ss-cache"));
await mkdir(outside);
await mkdir(bin);
const callsFile = path.join(directory, "tex-calls");
const raceMarker = path.join(directory, "change-after-tex");
const previousPath = process.env.PATH;
let watch;
const source = String.raw`import std:themes/default as *
page dependencies
let formula = latex!("$\ProbeText$")
~ formula.left == page.left + 60
~ formula.top == page.top - 120
let inline = text!("Inline $\ProbeText$")
~ inline.left == formula.left
~ inline.top == formula.bottom - 50
end
document
latex_preamble_file("preamble.tex")
end
`;
const first = path.join(outside, "first.tex");
const second = path.join(outside, "second.tex");
const nested = path.join(project, "nested.tex");
const artifactDirectory = path.join(project, ".ss-cache", "render", "artifacts", "native");
try {
  const wrapper = path.join(bin, "pdflatex");
  await writeFile(wrapper, `#!/bin/sh
printf '%s\\n' "$$" >> ${quote(callsFile)}
if [ -f ${quote(raceMarker)} ]; then
  rm -f ${quote(raceMarker)}
  ${quote(realPdflatex)} "$@"
  status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\\n' ${quote(String.raw`\def\ProbeText{RACEFINISHED}`)} > ${quote(second)}
  fi
  exit "$status"
fi
exec ${quote(realPdflatex)} "$@"
`);
  await chmod(wrapper, 0o755);
  process.env.PATH = `${bin}${path.delimiter}${previousPath ?? ""}`;
  await writeFile(path.join(project, "slide.ss"), source);
  await writeFile(path.join(project, "preamble.tex"), String.raw`\input{nested.tex}`);
  await writeFile(nested, String.raw`\input{../outside/first.tex}`);
  await writeFile(first, String.raw`\def\ProbeText{A}`);
  await writeFile(second, String.raw`\def\ProbeText{CCC}`);
  const original = await dump("initial.json");
  const initialCalls = await calls();
  assert(initialCalls > 0, "Cold preparation did not execute TeX");
  const references = await readReferences();
  assert(references.length >= 2, "Standalone and inline TeX references were not generated");
  for (const reference of references) {
    const paths = reference.manifest.inputs.map((input) => input.path);
    assert(paths.includes(first), `External nested input was not recorded: ${paths}`);
    assert(paths.includes(nested), `Nested input was not recorded: ${paths}`);
    assert(paths.every((input) => !input.startsWith(artifactDirectory)), "Generated TeX files leaked into dependencies");
  }
  await dump("warm.json");
  assert.equal(await calls(), initialCalls, "Warm dependency validation executed TeX");
  await writeFile(path.join(project, "unused.tex"), "This file is never loaded");
  await dump("unrelated.json");
  assert.equal(await calls(), initialCalls, "An unused file invalidated the artifact");
  const originalPdfNames = references.map((reference) => reference.pdfName);
  const originalPdfBytes = await Promise.all(originalPdfNames.map((name) => readFile(path.join(artifactDirectory, name))));
  await writeFile(first, String.raw`\def\ProbeText{AAAAAAAAAAAAAAAA}`);
  const changed = await dump("changed.json");
  assert((await calls()) > initialCalls, "Changing a transitive TeX input did not execute TeX");
  const originalFormula = original.nodes.find((node) => node.content === "$\\ProbeText$");
  const changedFormula = changed.nodes.find((node) => node.content === "$\\ProbeText$");
  assert(changedFormula.width > originalFormula.width * 3, `The cached LaTeX width was reused: ${originalFormula.width} -> ${changedFormula.width}`);
  const replaced = await readReferences();
  assert(replaced.every((reference) => !originalPdfNames.includes(reference.pdfName)), "Changed TeX dependencies reused a published PDF path");
  for (let index = 0; index < originalPdfNames.length; index++) {
    assert.deepEqual(await readFile(path.join(artifactDirectory, originalPdfNames[index])), originalPdfBytes[index], "Replacing a reference mutated a retained PDF");
  }
  await run(ssBin, ["render", "--quiet", "slide.ss", ".ss-cache/final.pdf"], project);
  const beforeWatch = await calls();
  watch = new WatchProcess(project, ["check", "--quiet", "slide.ss"]);
  await watch.waitFor(() => checks() === 1, "warm watch initialization");
  await settle();
  assert.equal(checks(), 1, watch.log);
  assert.equal(await calls(), beforeWatch, "Warm watch initialization executed TeX");
  await writeFile(path.join(project, "unused.tex"), "Still unused");
  await settle();
  assert.equal(checks(), 1, `An unused TeX file triggered compilation:\n${watch.log}`);
  await writeFile(nested, String.raw`\input{../outside/second.tex}`);
  await watch.waitFor(() => checks() === 2, "replacement TeX dependency");
  await settle();
  assert.equal(checks(), 2, watch.log);
  await writeFile(first, String.raw`\def\ProbeText{OBSOLETE}`);
  await settle();
  assert.equal(checks(), 2, `An obsolete TeX input triggered compilation:\n${watch.log}`);
  await rm(second);
  await watch.waitFor(() => watch.occurrences("RenderFailed:") >= 4, "missing TeX input diagnostic");
  await settle();
  await writeFile(second, String.raw`\def\ProbeText{RESTORED}`);
  await watch.waitFor(() => checks() === 3, "restored external TeX input");
  await settle();
  assert.equal(checks(), 3, watch.log);
  assert(!watch.log.includes("ResourceChangedDuringRead"), watch.log);
  await writeFile(raceMarker, "change after the next successful TeX run");
  await writeFile(second, String.raw`\def\ProbeText{RACESTART}`);
  await watch.waitFor(() => checks() === 4, "input changed during TeX execution");
  await settle();
  assert.equal(checks(), 4, watch.log);
  assert(watch.log.includes("ResourceChangedDuringRead"), "An input changed during compilation was published as current");
  await watch.close();
  watch = null;

  for (const name of await readdir(artifactDirectory)) {
    if (name.endsWith(".ref")) await rm(path.join(artifactDirectory, name));
  }
  await writeFile(nested, String.raw`\input{../outside/new-input.tex}`);
  watch = new WatchProcess(project, ["check", "--quiet", "slide.ss"]);
  await watch.waitFor(() => watch.occurrences("RenderFailed:") >= 4, "cold missing external input");
  await settle();
  await writeFile(path.join(outside, "new-input.tex"), String.raw`\def\ProbeText{CREATED}`);
  await watch.waitFor(() => checks() === 1, "newly created external input");
  await settle();
  assert.equal(checks(), 1, watch.log);
  console.log("TeX input tracking: cold/warm manifests, nested external files, immutable PDFs, dimensions, replacement, concurrent changes and missing-input recovery passed");
} finally {
  await watch?.close();
  process.env.PATH = previousPath;
  if (process.env.SS_TEST_KEEP_TEMP === "1") console.log(`Retained TeX test directory: ${directory}`);
  else await rm(directory, { recursive: true, force: true });
}

function checks() { return watch.occurrences("ok "); }
function quote(text) { return `'${text.replaceAll("'", "'\\''")}'`; }
async function calls() { return (await readFile(callsFile, "utf8")).trim().split("\n").length; }
async function dump(name) {
  await run(ssBin, ["dump", "--quiet", "slide.ss", `.ss-cache/${name}`], project);
  return JSON.parse(await readFile(path.join(project, ".ss-cache", name), "utf8"));
}
async function readReferences() {
  const names = (await readdir(artifactDirectory)).filter((name) => name.endsWith(".ref"));
  return Promise.all(names.map(async (name) => {
    const [geometry, ...manifest] = (await readFile(path.join(artifactDirectory, name), "utf8")).split("\n");
    return { pdfName: geometry.split("\t")[5], manifest: JSON.parse(manifest.join("\n")) };
  }));
}
function run(command, args, cwd, allowFailure = false) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, detached: true, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "", timedOut = false;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const deadline = setTimeout(() => {
      timedOut = true;
      terminateProcessTree(child.pid);
    }, 20_000);
    child.on("error", (error) => { clearTimeout(deadline); reject(error); });
    child.on("close", (code) => {
      clearTimeout(deadline);
      if (timedOut || (code !== 0 && !allowFailure)) reject(new Error(`${command} ${args.join(" ")} failed (${code}, timeout=${timedOut}):\n${stdout}\n${stderr}`));
      else resolve({ code, stdout, stderr });
    });
  });
}
