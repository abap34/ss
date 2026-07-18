#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, root, withLspClient } from "../../harness.mjs";

const fixture = path.join(root, "tests", "fixtures", "runtime", "lsp", "diagnostics", "stale");
const slide = path.join(fixture, "slide.ss");
const uri = pathToFileURL(slide).toString();
const initialSource = await readFile(slide, "utf8");
const changedSource = await readFile(path.join(fixture, "changed.ss"), "utf8");

await withLspClient({ cwd: fixture }, async (client) => {
  await client.initialize();

  const initialDiagnostics = client.waitForDiagnostics(
    uri,
    (diagnostics, message) => diagnostics.length > 0 && message.params.version === 1,
    "initial invalid diagnostics",
  );
  client.openDocument({ uri, text: initialSource, version: 1 });
  await initialDiagnostics;

  const clearedDiagnostics = client.waitForDiagnostics(
    uri,
    (diagnostics, message) => diagnostics.length === 0 && message.params.version === 2,
    "cleared diagnostics for changed source",
  );
  const changedDiagnostics = client.waitForDiagnostics(
    uri,
    (diagnostics, message) => diagnostics.length > 0 && message.params.version === 2,
    "diagnostics rebuilt for changed source",
  );
  client.changeDocument({ uri, text: changedSource, version: 2 });

  const cleared = await clearedDiagnostics;
  assert(cleared.params.diagnostics.length === 0, "the previous diagnostics remained visible while rebuilding");
  const rebuilt = await changedDiagnostics;
  assert(rebuilt.params.diagnostics.length > 0, "the changed invalid source was not diagnosed after rebuilding");
});
