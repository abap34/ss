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
  positionAfter,
  positionAt,
  root,
  withLspClient,
} from "./harness.mjs";

const defaultTheme = path.join(root, "stdlib", "themes", "default.ss");
const defaultThemeUri = pathToFileURL(defaultTheme).toString();
const defaultThemeSource = await readFile(defaultTheme, "utf8");
const coverDefinition = functionDefinitionLocation(defaultThemeUri, defaultThemeSource, "cover");

await testStdlibDefinitionOutsideWorkspace();
await testDefinitionAfterOpeningUnrelatedFile();
await testLspConfiguration();
await testLspDebouncesDocumentChanges();
await testConstraintConflictDiagnosticMatchesCli();
await testDependencyQueryDiagnostic();
await testUserReportDiagnosticCode();
await testDirectUnknownImportDiagnosticLocation();
await testImportedUnknownImportReportsBothFiles();
await testImportCycleDiagnosticLocation();
await testBrokenProjectConfigKeepsCompletionAlive();
await testLspFeatureSurface();

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

async function testDefinitionAfterOpeningUnrelatedFile() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-definition-snapshot-"));
  try {
    const slide = path.join(project, "slide.ss");
    const side = path.join(project, "side.ss");
    const slideUri = pathToFileURL(slide).toString();
    const sideUri = pathToFileURL(side).toString();
    const slideSource = `import std:themes/default

page title
default::cover!(
  "Hello",
  "Subtitle",
  "Author"
)
end
`;
    const sideSource = `page side
end
`;
    await writeFile(slide, slideSource, "utf8");
    await writeFile(side, sideSource, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      let diagnosticsPromise = client.waitForDiagnostics(slideUri);
      client.openDocument({ uri: slideUri, text: slideSource });
      await diagnosticsPromise;

      diagnosticsPromise = client.waitForDiagnostics(sideUri);
      client.openDocument({ uri: sideUri, text: sideSource });
      await diagnosticsPromise;

      const definition = await client.request("textDocument/definition", {
        textDocument: { uri: slideUri },
        position: positionAt(slideSource, "cover!", 2),
      });
      assert(Array.isArray(definition), `expected definition array after snapshot switch, got ${JSON.stringify(definition)}`);
      assert(
        definition.some((location) => isDefinitionLocation(location, coverDefinition)),
        `definition after snapshot switch did not jump to default theme cover: ${JSON.stringify(definition)}`,
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

async function testLspFeatureSurface() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-feature-surface-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = featureSource("Title", "0.2,0.4,0.6");
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      const initialize = await client.initialize();
      assert(initialize.capabilities?.completionProvider, `initialize missing completion capability: ${JSON.stringify(initialize)}`);
      assert(initialize.capabilities?.hoverProvider === true, `initialize missing hover capability: ${JSON.stringify(initialize)}`);
      assert(initialize.capabilities?.definitionProvider === true, `initialize missing definition capability: ${JSON.stringify(initialize)}`);
      assert(initialize.capabilities?.documentSymbolProvider === true, `initialize missing document symbol capability: ${JSON.stringify(initialize)}`);
      assert(initialize.capabilities?.foldingRangeProvider === true, `initialize missing folding capability: ${JSON.stringify(initialize)}`);
      assert(initialize.capabilities?.semanticTokensProvider?.full === true, `initialize missing semantic tokens capability: ${JSON.stringify(initialize)}`);
      assert(initialize.capabilities?.colorProvider === true, `initialize missing color capability: ${JSON.stringify(initialize)}`);

      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source });
      const diagnostics = (await diagnosticsPromise).params.diagnostics;
      assert(diagnostics.length === 0, `feature surface diagnostics: ${JSON.stringify(diagnostics)}`);

      const completion = await client.request("textDocument/completion", {
        textDocument: { uri },
        position: positionAfter(source, "let heading = "),
      });
      assertCompletionHas(completion, "text!", "feature surface completion");

      const hover = await client.request("textDocument/hover", {
        textDocument: { uri },
        position: positionAt(source, "text!", 1),
      });
      assert(hover?.contents?.value?.includes("text"), `feature surface hover missing text signature: ${JSON.stringify(hover)}`);

      const definition = await client.request("textDocument/definition", {
        textDocument: { uri },
        position: positionAt(source, "text!", 1),
      });
      assert(Array.isArray(definition) && definition.length > 0, `feature surface definition missing: ${JSON.stringify(definition)}`);

      const inlayHints = await client.request("textDocument/inlayHint", {
        textDocument: { uri },
        range: {
          start: { line: 0, character: 0 },
          end: { line: source.split("\n").length, character: 0 },
        },
      });
      assert(Array.isArray(inlayHints), `feature surface inlay hints were not an array: ${JSON.stringify(inlayHints)}`);

      const symbols = await client.request("textDocument/documentSymbol", { textDocument: { uri } });
      assert(
        Array.isArray(symbols) &&
          symbols.some((symbol) => symbol.name === "feature") &&
          symbols.some((symbol) => symbol.name === "LocalStyle") &&
          symbols.some((symbol) => symbol.name === "Badge"),
        `feature surface document symbols missing parsed declarations: ${JSON.stringify(symbols)}`,
      );

      const foldingRanges = await client.request("textDocument/foldingRange", { textDocument: { uri } });
      assert(Array.isArray(foldingRanges) && foldingRanges.length >= 3, `feature surface folding ranges missing parsed blocks: ${JSON.stringify(foldingRanges)}`);

      const semanticTokens = await client.request("textDocument/semanticTokens/full", { textDocument: { uri } });
      assert(Array.isArray(semanticTokens.data) && semanticTokens.data.length > 0, `feature surface semantic tokens missing: ${JSON.stringify(semanticTokens)}`);

      const colors = await client.request("textDocument/documentColor", { textDocument: { uri } });
      assert(Array.isArray(colors) && colors.length >= 2, `feature surface document colors missing: ${JSON.stringify(colors)}`);

      const presentations = await client.request("textDocument/colorPresentation", {
        textDocument: { uri },
        color: { red: 0.2, green: 0.4, blue: 0.6, alpha: 1 },
        range: colors[0].range,
      });
      assert(
        Array.isArray(presentations) && presentations.some((item) => item.label === 'c"#336699"'),
        `feature surface color presentation missing hex label: ${JSON.stringify(presentations)}`,
      );

      const projectInfo = await client.request("ss/projectInfo", { textDocument: { uri } });
      assert(projectInfo.entryPath === slide, `feature surface projectInfo entry mismatch: ${JSON.stringify(projectInfo)}`);
      assert(projectInfo.lsp?.completion === true, `feature surface projectInfo missing LSP settings: ${JSON.stringify(projectInfo)}`);

      const conflicts = await client.request("ss/layoutConflicts", { textDocument: { uri } });
      assert(conflicts.kind === "ss-layout-conflicts", `feature surface layout conflict response kind mismatch: ${JSON.stringify(conflicts)}`);
      assert(Array.isArray(conflicts.failures), `feature surface layout conflict failures missing: ${JSON.stringify(conflicts)}`);
    });
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
      assert(
        conflict.message.includes("reason: anchor_value_conflict"),
        `constraint conflict reason missing from LSP diagnostic: ${JSON.stringify(conflict)}`,
      );
      assert(conflict.message.includes("incoming value:"), `incoming propagation missing from LSP diagnostic: ${JSON.stringify(conflict)}`);
      assert(conflict.message.includes("→"), `propagation arrow missing from LSP diagnostic: ${JSON.stringify(conflict)}`);
      assert(
        conflict.relatedInformation?.some((item) => item.message === "current value source"),
        `current value related information missing from LSP diagnostic: ${JSON.stringify(conflict)}`,
      );
      assert(conflict.range.start.line === 5, `constraint diagnostic pointed at the wrong line: ${JSON.stringify(conflict)}`);

      const unsaved = source.replace("page.left + 20", "page.left + 30");
      client.changeDocument({ uri, version: 2, text: unsaved });
      const report = await client.request("ss/layoutConflicts", { textDocument: { uri } });
      assert(report.kind === "ss-layout-conflicts", `unexpected conflict report kind: ${JSON.stringify(report)}`);
      assert(report.failures?.length > 0, `conflict report missing failures: ${JSON.stringify(report)}`);
      assert(
        report.failures.some((failure) => failure.reason === "anchor_value_conflict" && Math.abs((failure.expected ?? 0) - 30) < 0.1),
        `conflict report did not reflect unsaved source: ${JSON.stringify(report.failures)}`,
      );
      assert(
        report.failures.every((failure) => !("difference" in failure)),
        `conflict report should not expose difference: ${JSON.stringify(report.failures)}`,
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
      assert(query.message.includes("write Variable(scope=page:sample, name=t)"), `dependency query message missing variable write: ${JSON.stringify(query)}`);
      assert(query.range.start.line === 4, `dependency query diagnostic pointed at wrong line: ${JSON.stringify(query)}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testUserReportDiagnosticCode() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-user-report-code-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `page bad
let x = "a"
let x = "b"
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source });
      const diagnostics = (await diagnosticsPromise).params.diagnostics;
      const duplicate = diagnostics.find((diagnostic) => diagnostic.code === "DuplicateBinding");
      assert(duplicate, `DuplicateBinding diagnostic code missing: ${JSON.stringify(diagnostics)}`);
      assert(duplicate.range.start.line === 2, `DuplicateBinding diagnostic pointed at wrong line: ${JSON.stringify(duplicate)}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDirectUnknownImportDiagnosticLocation() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-unknown-import-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `import "./missing" as *

page main
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source });
      const diagnostics = (await diagnosticsPromise).params.diagnostics;
      const missing = diagnostics.find((diagnostic) => diagnostic.code === "UnknownImport");
      assert(missing, `UnknownImport diagnostic missing: ${JSON.stringify(diagnostics)}`);
      assert(missing.message.startsWith("UnknownImport:"), `UnknownImport message missing code prefix: ${JSON.stringify(missing)}`);
      assert(missing.range.start.line === 0, `UnknownImport diagnostic pointed at wrong line: ${JSON.stringify(missing)}`);
      assert(missing.range.start.character === 0, `UnknownImport diagnostic pointed at wrong character: ${JSON.stringify(missing)}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testImportedUnknownImportReportsBothFiles() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-imported-unknown-import-"));
  try {
    const slide = path.join(project, "slide.ss");
    const imported = path.join(project, "a.ss");
    const slideUri = pathToFileURL(slide).toString();
    const importedUri = pathToFileURL(imported).toString();
    const slideSource = `import "./a" as *

page main
end
`;
    await writeFile(slide, slideSource, "utf8");
    await writeFile(imported, `import "./missing" as *\n`, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const importedDiagnosticsPromise = client.waitForDiagnostics(
        importedUri,
        (diagnostics) => diagnostics.some((diagnostic) => diagnostic.code === "UnknownImport"),
        "UnknownImport diagnostic for imported module",
      );
      const sourceDiagnosticsPromise = client.waitForDiagnostics(
        slideUri,
        (diagnostics) => diagnostics.some((diagnostic) => diagnostic.code === "ImportFailed"),
        "ImportFailed diagnostic for importing module",
      );
      client.openDocument({ uri: slideUri, text: slideSource });
      const importedDiagnostics = (await importedDiagnosticsPromise).params.diagnostics;
      const unknown = importedDiagnostics.find((diagnostic) => diagnostic.code === "UnknownImport");
      assert(unknown, `UnknownImport diagnostic missing: ${JSON.stringify(importedDiagnostics)}`);
      assert(unknown.range.start.line === 0, `UnknownImport diagnostic pointed at wrong line: ${JSON.stringify(unknown)}`);
      assert(unknown.range.start.character === 0, `UnknownImport diagnostic pointed at wrong character: ${JSON.stringify(unknown)}`);

      const sourceDiagnostics = (await sourceDiagnosticsPromise).params.diagnostics;
      const failed = sourceDiagnostics.find((diagnostic) => diagnostic.code === "ImportFailed");
      assert(failed, `ImportFailed diagnostic missing: ${JSON.stringify(sourceDiagnostics)}`);
      assert(failed.range.start.line === 0, `ImportFailed diagnostic pointed at wrong line: ${JSON.stringify(failed)}`);
      assert(failed.range.start.character === 0, `ImportFailed diagnostic pointed at wrong character: ${JSON.stringify(failed)}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testImportCycleDiagnosticLocation() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-import-cycle-"));
  try {
    const slide = path.join(project, "slide.ss");
    const a = path.join(project, "a.ss");
    const b = path.join(project, "b.ss");
    const slideUri = pathToFileURL(slide).toString();
    const bUri = pathToFileURL(b).toString();
    const slideSource = `import "./a" as *

page main
end
`;
    await writeFile(slide, slideSource, "utf8");
    await writeFile(a, `import "./b" as *\n`, "utf8");
    await writeFile(b, `import "./a" as *\n`, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const cycleDiagnosticsPromise = client.waitForDiagnostics(
        bUri,
        (diagnostics) => diagnostics.some((diagnostic) => diagnostic.code === "ImportCycle"),
        "ImportCycle diagnostic for imported module",
      );
      client.openDocument({ uri: slideUri, text: slideSource });
      const diagnostics = (await cycleDiagnosticsPromise).params.diagnostics;
      const cycle = diagnostics.find((diagnostic) => diagnostic.code === "ImportCycle");
      assert(cycle, `ImportCycle diagnostic missing: ${JSON.stringify(diagnostics)}`);
      assert(cycle.range.start.line === 0, `ImportCycle diagnostic pointed at wrong line: ${JSON.stringify(cycle)}`);
      assert(cycle.range.start.character === 0, `ImportCycle diagnostic pointed at wrong character: ${JSON.stringify(cycle)}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function featureSource(title, color) {
  return `import std:themes/default as *

record LocalStyle {
  color: Color = c"${color}"
}

type Badge = object {
  label: String = "badge"
}

page feature
let heading = text!("${title}", current_theme() with {
  body.text.color = c"${color}"
})
place!(heading)
end
`;
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
