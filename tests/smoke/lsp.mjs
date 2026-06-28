#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  assert,
  assertCompletionHas,
  assertCompletionMissing,
  assertUniqueCompletionLabels,
  functionDefinitionLocation,
  isDefinitionLocation,
  positionAfter,
  positionAt,
  root,
  withLspClient,
} from "../runtime/harness.mjs";

const fixture = path.join(root, "tests", "fixtures", "project-basic", "slide.ss");
const partsFixture = path.join(root, "tests", "fixtures", "project-basic", "parts.ss");
const defaultTheme = path.join(root, "stdlib", "themes", "default.ss");
const uri = pathToFileURL(fixture).toString();
const source = await readFile(fixture, "utf8");
const partsUri = pathToFileURL(partsFixture).toString();
const partsSource = await readFile(partsFixture, "utf8");
const defaultThemeUri = pathToFileURL(defaultTheme).toString();
const defaultThemeSource = await readFile(defaultTheme, "utf8");
const moduleLabelDefinition = functionDefinitionLocation(partsUri, partsSource, "module_label");
const coverDefinition = functionDefinitionLocation(defaultThemeUri, defaultThemeSource, "cover");

await withLspClient({ cwd: root }, async (client) => {
  const initialize = await client.initialize();
  assert(initialize.capabilities?.completionProvider, "initialize did not advertise completion");
  assert(initialize.capabilities?.textDocumentSync === 2, "initialize did not advertise incremental sync");

  const diagnosticsPromise = client.waitForDiagnostics(uri);
  client.openDocument({ uri, text: source });
  const diagnostics = await diagnosticsPromise;
  assert(Array.isArray(diagnostics.params.diagnostics), "diagnostics notification missing diagnostics array");
  assert(diagnostics.params.diagnostics.length === 0, `expected no diagnostics, got ${JSON.stringify(diagnostics.params.diagnostics)}`);

  const completion = await client.request("textDocument/completion", {
    textDocument: { uri },
    position: positionAfter(source, "let heading = "),
  });
  assertUniqueCompletionLabels(completion, "global completion");
  assertCompletionHas(completion, "page", "global completion");
  assertCompletionHas(completion, "module_label!", "global completion");
  assertCompletionMissing(completion, ["place", "text_size"], "global completion");

  const hover = await client.request("textDocument/hover", {
    textDocument: { uri },
    position: positionAt(source, "module_label!", 2),
  });
  assert(hover === null || hover.contents, "hover response was malformed");

  const definition = await client.request("textDocument/definition", {
    textDocument: { uri },
    position: positionAt(source, "module_label!", 2),
  });
  assert(Array.isArray(definition), `expected definition array, got ${JSON.stringify(definition)}`);
  assert(
    definition.some((location) => isDefinitionLocation(location, moduleLabelDefinition)),
    `definition did not jump to parts.ss: ${JSON.stringify(definition)}`,
  );

  const pairedDefinition = await client.request("textDocument/definition", {
    textDocument: { uri },
    position: positionAt(source, "cover!", 2),
  });
  assert(Array.isArray(pairedDefinition), `expected paired definition array, got ${JSON.stringify(pairedDefinition)}`);
  assert(
    pairedDefinition.some((location) => isDefinitionLocation(location, coverDefinition)),
    `definition did not jump to default theme cover: ${JSON.stringify(pairedDefinition)}`,
  );

  const brokenDiagnosticsPromise = client.waitForDiagnostics(uri);
  client.changeDocumentRange({
    uri,
    version: 2,
    range: { start: { line: 3, character: 0 }, end: { line: 3, character: 4 } },
    text: "pag",
  });
  const brokenDiagnostics = await brokenDiagnosticsPromise;
  assert(brokenDiagnostics.params.diagnostics.length > 0, "ranged didChange did not publish diagnostics for broken source");

  const fixedDiagnosticsPromise = client.waitForDiagnostics(uri);
  client.changeDocumentRange({
    uri,
    version: 3,
    range: { start: { line: 3, character: 0 }, end: { line: 3, character: 3 } },
    text: "page",
  });
  const fixedDiagnostics = await fixedDiagnosticsPromise;
  assert(fixedDiagnostics.params.diagnostics.length === 0, "ranged didChange did not clear diagnostics after restoring source");
});
