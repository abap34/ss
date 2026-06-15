#!/usr/bin/env node
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  assert,
  assertCompletionHas,
  functionDefinitionLocation,
  isDefinitionLocation,
  positionAt,
  root,
  withLspClient,
} from "./lsp_harness.mjs";

const defaultTheme = path.join(root, "stdlib", "themes", "default.ss");
const defaultThemeUri = pathToFileURL(defaultTheme).toString();
const defaultThemeSource = await readFile(defaultTheme, "utf8");
const coverDefinition = functionDefinitionLocation(defaultThemeUri, defaultThemeSource, "cover");

await testStdlibDefinitionOutsideWorkspace();
await testLspConfiguration();
await testLspDebouncesDocumentChanges();
await testConstraintConflictDiagnosticMatchesCli();
await testDependencyQueryDiagnostic();
await testBrokenProjectConfigKeepsCompletionAlive();

async function testStdlibDefinitionOutsideWorkspace() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-outside-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `import std:themes/default

page title
default::cover!(
  "Hello",
  "Subtitle",
  "Author"
)
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source });
      await diagnosticsPromise;
      const definition = await client.request("textDocument/definition", {
        textDocument: { uri },
        position: positionAt(source, "cover!", 2),
      });
      assert(Array.isArray(definition), `expected outside definition array, got ${JSON.stringify(definition)}`);
      assert(
        definition.some((location) => isDefinitionLocation(location, coverDefinition)),
        `outside workspace definition did not jump to default theme cover: ${JSON.stringify(definition)}`,
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testLspConfiguration() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-config-"));
  try {
    const slide = path.join(project, "slide.ss");

    await writeFile(path.join(project, "ss.toml"), `[project]
entry = "slide.ss"
asset_base_dir = "."

[editor.lsp]
diagnostics = false
completion = false

[editor.lsp.inlay_hints]
enabled = false
`, "utf8");
    const disabledSource = `import std:themes/default as *

pag broken
`;
    await writeFile(slide, disabledSource, "utf8");
    const disabled = await configuredResponses({
      cwd: project,
      fixture: slide,
      source: disabledSource,
      completionPosition: positionAt(disabledSource, "pag", 1),
    });
    assert(disabled.diagnostics.length === 0, `disabled diagnostics still published entries: ${JSON.stringify(disabled.diagnostics)}`);
    assert(disabled.completion.items?.length === 0, `disabled completion still returned entries: ${JSON.stringify(disabled.completion)}`);
    assert(Array.isArray(disabled.inlayHints) && disabled.inlayHints.length === 0, `disabled inlay hints still returned entries: ${JSON.stringify(disabled.inlayHints)}`);

    const validSource = `import std:themes/default as *

page configured
cover!(
  "Title",
  "Subtitle",
  "Author"
)
end
`;
    await writeFile(path.join(project, "ss.toml"), `[project]
entry = "slide.ss"
asset_base_dir = "."

[editor.lsp.inlay_hints]
enabled = true
arguments = false
positions = true
`, "utf8");
    await writeFile(slide, validSource, "utf8");
    const positionOnly = await configuredResponses({
      cwd: project,
      fixture: slide,
      source: validSource,
      completionPosition: positionAt(validSource, "cover!", 1),
    });
    assert(positionOnly.inlayHints.length > 0, "position-only inlay hints did not return any hints");
    assert(positionOnly.inlayHints.every((hint) => hint.kind !== 2), `argument hints were not filtered: ${JSON.stringify(positionOnly.inlayHints)}`);
    assert(positionOnly.inlayHints.some((hint) => hint.kind === 1), `position hints were not present: ${JSON.stringify(positionOnly.inlayHints)}`);

    await writeFile(path.join(project, "ss.toml"), `[project]
entry = "slide.ss"
asset_base_dir = "."

[editor.lsp.inlay_hints]
enabled = true
arguments = true
positions = false
`, "utf8");
    const argumentOnly = await configuredResponses({
      cwd: project,
      fixture: slide,
      source: validSource,
      completionPosition: positionAt(validSource, "cover!", 1),
    });
    assert(argumentOnly.inlayHints.length > 0, "argument-only inlay hints did not return any hints");
    assert(argumentOnly.inlayHints.some((hint) => hint.kind === 2), `argument hints were not present: ${JSON.stringify(argumentOnly.inlayHints)}`);
    assert(argumentOnly.inlayHints.every((hint) => hint.kind !== 1), `position hints were not filtered: ${JSON.stringify(argumentOnly.inlayHints)}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testBrokenProjectConfigKeepsCompletionAlive() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-broken-config-"));
  try {
    const slide = path.join(project, "slide.ss");
    const source = `page alive
end
`;
    await writeFile(path.join(project, "ss.toml"), `[project]
asset_base_dir = "."
`, "utf8");
    await writeFile(slide, source, "utf8");
    const broken = await configuredResponses({
      cwd: project,
      fixture: slide,
      source,
      completionPosition: { line: 0, character: 0 },
    });
    assertCompletionHas(broken.completion, "page", "broken ss.toml completion");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testLspDebouncesDocumentChanges() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-debounce-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    await writeFile(path.join(project, "ss.toml"), `[project]
entry = "slide.ss"
asset_base_dir = "."

[editor.lsp]
debounce = 120
`, "utf8");
    const initial = `page initial
end
`;
    const invalid = `pag broken
`;
    const fixed = `page fixed
end
`;
    await writeFile(slide, initial, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const initialDiagnostics = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: initial });
      await initialDiagnostics;

      const debouncedDiagnostics = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, version: 2, text: invalid });
      client.changeDocument({ uri, version: 3, text: fixed });
      const message = await debouncedDiagnostics;
      assert(
        message.params.diagnostics.length === 0,
        `debounced diagnostics used an intermediate source: ${JSON.stringify(message.params.diagnostics)}`,
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testConstraintConflictDiagnosticMatchesCli() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-constraint-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `import std:themes/default as *

page broken
let a = text!("A")
~ a.left == page.left + 10
~ a.left == page.left + 20
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source });
      const diagnostics = (await diagnosticsPromise).params.diagnostics;
      const conflict = diagnostics.find((diagnostic) => diagnostic.code === "ConstraintConflict");
      assert(conflict, `constraint conflict diagnostic missing: ${JSON.stringify(diagnostics)}`);
      assert(
        conflict.message.includes("ConstraintConflict: constraint conflict"),
        `constraint conflict message did not match CLI classification: ${JSON.stringify(conflict)}`,
      );
      assert(conflict.message.includes("constraint:"), `constraint text missing from LSP diagnostic: ${JSON.stringify(conflict)}`);
      assert(conflict.range.start.line === 4, `constraint diagnostic pointed at the wrong line: ${JSON.stringify(conflict)}`);
      assert(
        !diagnostics.some((diagnostic) => diagnostic.code === "unresolved_frame"),
        `secondary unresolved frame diagnostics leaked through: ${JSON.stringify(diagnostics)}`,
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDependencyQueryDiagnostic() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-dep-query-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `import std:themes/default as *

page sample
let t = title!("A")
;; ^dep?
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source });
      const diagnostics = (await diagnosticsPromise).params.diagnostics;
      const query = diagnostics.find((diagnostic) => diagnostic.code === "DependencyQuery");
      assert(query, `dependency query diagnostic missing: ${JSON.stringify(diagnostics)}`);
      assert(query.message.includes("DependencyQuery:"), `dependency query message missing header: ${JSON.stringify(query)}`);
      assert(query.message.includes("write Variable(*, t)"), `dependency query message missing variable write: ${JSON.stringify(query)}`);
      assert(query.range.start.line === 4, `dependency query diagnostic pointed at wrong line: ${JSON.stringify(query)}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function configuredResponses({ cwd, fixture, source, completionPosition }) {
  const uri = pathToFileURL(fixture).toString();
  return withLspClient({ cwd }, async (client) => {
    await client.initialize();
    const diagnosticsPromise = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source });
    const diagnostics = await diagnosticsPromise;
    const completion = await client.request("textDocument/completion", {
      textDocument: { uri },
      position: completionPosition,
    });
    const inlayHints = await client.request("textDocument/inlayHint", {
      textDocument: { uri },
      range: {
        start: { line: 0, character: 0 },
        end: { line: source.split("\n").length, character: 0 },
      },
    });
    return { diagnostics: diagnostics.params.diagnostics, completion, inlayHints };
  });
}
