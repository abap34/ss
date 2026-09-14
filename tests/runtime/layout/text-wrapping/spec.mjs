#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, root, ssBin, withLspClient } from "../../harness.mjs";
import { editorSnapshot } from "../../editor/support.mjs";

const outputRoot = path.join(root, ".ss-cache", "tests", "text-wrapping");
await mkdir(outputRoot, { recursive: true });
const project = await mkdtemp(path.join(outputRoot, "run-"));
const slide = path.join(project, "slide.ss");
await copyFile(path.join(root, "tests", "fixtures", "layout", "text-wrapping", "slide.ss"), slide);
const source = await readFile(slide, "utf8");
const uri = pathToFileURL(slide).href;
const cases = [
  { text: "表示がすっきり整う", oneLine: true },
  { text: "silver green violet", oneLine: true },
  { text: "音色がやわらかに響く", oneLine: true },
  { text: "表示がすっきり整う", oneLine: false },
];

// Start a new language server for each pass to exercise persisted measurements
// as well as reuse within a running WYSIWYG session.
let previousGeometry;
for (const generation of ["first", "persisted"]) {
  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    const ready = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source });
    assert((await ready).params.diagnostics.length === 0, "wrapping fixture produced diagnostics");
    const snapshot = await editorSnapshot(client, uri);
    await writeFile(path.join(project, `${generation}-snapshot.json`), JSON.stringify(snapshot));
    const geometry = assertLines(snapshot.display.html);
    if (previousGeometry) {
      assert(JSON.stringify(geometry) === JSON.stringify(previousGeometry), "persisted measurements changed text lines");
    }
    previousGeometry = geometry;
    const repeated = await editorSnapshot(client, uri);
    assert(repeated.snapshot_id === snapshot.snapshot_id, "unchanged source rebuilt the snapshot");
  });
}

for (const args of [
  ["check", "--quiet", slide],
  ["dump", "--quiet", slide, path.join(project, "dump.json")],
  ["render", "--quiet", "--format", "html", slide, path.join(project, "slide.html")],
  ["render", "--quiet", slide, path.join(project, "slide.pdf")],
]) execFileSync(ssBin, args, { cwd: project, timeout: 60000, stdio: "pipe" });
assertLines(await readFile(path.join(project, "slide.html"), "utf8"));
console.log("text wrapping: natural and constrained widths passed in WYSIWYG, persisted snapshots, HTML, check, dump, and PDF render");

function assertLines(html) {
  const pages = [...html.matchAll(/<section class="ss-page"[^>]*>([\s\S]*?)<\/section>/g)];
  assert(pages.length === cases.length, `expected ${cases.length} pages, got ${pages.length}`);
  return pages.map((page, index) => {
    const items = [...page[1].matchAll(/<span class="ss-item ss-text"[^>]*style="([^"]*)">([\s\S]*?)(?=<(?:span|div|img) class="ss-item |<div class="ss-semantic-layer"|$)/g)];
    const lines = new Map();
    for (const item of items) {
      const text = [...item[2].matchAll(/class="ss-text-cluster"[^>]*>([^<]*)</g)].map((match) => match[1]).join("");
      if (!text || text === "•" || /^\d+\.$/.test(text)) continue;
      const top = Number(/(?:^|;)top:([\d.-]+)pt/.exec(item[1])?.[1]);
      const baseline = Number(/data-ss-baseline-y="([\d.-]+)"/.exec(item[2])?.[1]);
      assert(Number.isFinite(top + baseline), "text omitted its baseline");
      const y = (top + baseline).toFixed(4);
      lines.set(y, (lines.get(y) ?? "") + text);
    }
    const expected = cases[index];
    assert([...lines.values()].join("") === expected.text, `page ${index + 1} changed its text: ${JSON.stringify([...lines])}`);
    assert(expected.oneLine ? lines.size === 1 : lines.size > 1, `page ${index + 1} has unexpected wrapping: ${JSON.stringify([...lines])}`);
    return [...lines];
  });
}
