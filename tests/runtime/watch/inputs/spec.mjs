import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root } from "../../harness.mjs";
import { WatchProcess, settle } from "../harness.mjs";

const scratch = path.join(root, ".test-tmp", "watch-inputs");
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
  const output = path.join(project, "preview.html");
  watch = new WatchProcess(project, ["render", "--format", "html", "--quiet", "slide.ss", output]);
  const changes = () => watch.occurrences("watch: change detected");
  const waitForText = text => watch.waitForOutput(output, bytes => bytes.includes(text), text);
  await waitForText("First input");
  await settle();
  assert.equal(changes(), 0, watch.log);
  await writeFile(path.join(project, "unrelated.ss"), "page unused\nend\n");
  await writeFile(path.join(project, "unrelated.svg"), '<svg xmlns="http://www.w3.org/2000/svg"/>');
  await settle();
  assert.equal(changes(), 0, watch.log);

  await writeFile(first, "Changed input outside the asset directory");
  await waitForText("Changed input outside the asset directory");
  await settle();
  assert.equal(changes(), 1, watch.log);
  await writeFile(source, deck("second"));
  await waitForText("Second input");
  await settle();
  assert.equal(changes(), 2, watch.log);
  await writeFile(first, "No longer referenced");
  await settle();
  assert.equal(changes(), 2, watch.log);

  const errorsBefore = watch.occurrences("ReadlinesFailed:");
  await rm(second);
  await watch.waitFor(() => watch.occurrences("ReadlinesFailed:") > errorsBefore, "missing input diagnostic");
  assert((await readFile(output)).includes("Second input"), "a failed render replaced the preview");
  await writeFile(second, "Repaired input");
  await waitForText("Repaired input");
  await settle();

  const diagram = path.join(outside, "diagram.svg");
  await writeFile(diagram, svg("red"));
  const beforeDiagram = changes();
  const textPreview = await readFile(output);
  await writeFile(source,
    'import std:themes/default as *\npage main\nimage!("../outside/diagram.svg")\nend\n');
  await watch.waitForOutput(output, bytes => !bytes.equals(textPreview), "image preview");
  await settle();
  assert.equal(changes(), beforeDiagram + 1, watch.log);
  const redPreview = await readFile(output);
  await writeFile(diagram, svg("blue"));
  await watch.waitForOutput(output, bytes => !bytes.equals(redPreview), "changed image preview");
  console.log("Watch inputs: unused files, external reads, prepared images, replacement and recovery passed");
} finally {
  await watch?.close();
  await rm(directory, { recursive: true, force: true });
}

function svg(color) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="30"><rect width="40" height="30" fill="${color}"/></svg>`;
}
