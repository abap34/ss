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
const baseTheme = path.join(root, "stdlib", "themes", "base.ss");
const baseThemeUri = pathToFileURL(baseTheme).toString();
const baseThemeSource = await readFile(baseTheme, "utf8");
const themeDefinition = typeDefinitionLocation(baseThemeUri, baseThemeSource, "record", "Theme");

await testStdlibDefinitionOutsideWorkspace();
await testDefinitionAfterOpeningUnrelatedFile();
await testLargeDocumentDefinitionUsesSnapshotFallback();
await testLspConfiguration();
await testLspDebouncesDocumentChanges();
await testConstraintConflictDiagnosticMatchesCli();
await testDependencyQueryDiagnostic();
await testUserReportDiagnosticCode();
await testDirectUnknownImportDiagnosticLocation();
await testImportedUnknownImportReportsBothFiles();
await testImportCycleDiagnosticLocation();
await testBrokenProjectConfigKeepsCompletionAlive();
await testMultipleHoleParseDiagnostics();
await testMixedHoleParseDiagnosticsAfterEdit();
await testHoleAndSemanticDiagnosticsTogether();
await testMultipleTypeDiagnostics();
await testLspFeatureSurface();
await testRandomizedLspOperationsAreStable();

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
      const importDefinition = await client.request("textDocument/definition", {
        textDocument: { uri },
        position: positionAt(source, "std:themes/default", 1),
      });
      assert(Array.isArray(importDefinition), `expected import definition array, got ${JSON.stringify(importDefinition)}`);
      assert(
        importDefinition.some((location) =>
          location.uri === defaultThemeUri &&
          location.range?.start?.line === 0 &&
          location.range?.start?.character === 0
        ),
        `import spec definition did not jump to default theme file: ${JSON.stringify(importDefinition)}`,
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

async function testLargeDocumentDefinitionUsesSnapshotFallback() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-large-definition-"));
  try {
    const slide = path.join(project, "slide.ss");
    const theme = path.join(project, "theme.ss");
    const slideUri = pathToFileURL(slide).toString();
    const themeUri = pathToFileURL(theme).toString();
    const themeSource = `import std:themes/default

fn/! ultra_big(content: String) -> Object
  return default::h1(content)
end
`;
    const filler = Array.from({ length: 8000 }, (_, index) => `# filler ${index}`).join("\n");
    const slideSource = `import "./theme" as *

page title
  let t1 = ultra_big! "Title"
  ~ t1.left == page.left
end

${filler}
`;
    await writeFile(theme, themeSource, "utf8");
    await writeFile(slide, slideSource, "utf8");
    const ultraBigDefinition = functionDefinitionLocation(themeUri, themeSource, "ultra_big");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(slideUri);
      client.openDocument({ uri: slideUri, text: slideSource });
      const diagnostics = await diagnosticsPromise;
      assert(diagnostics.params.diagnostics.length === 0, `large definition diagnostics: ${JSON.stringify(diagnostics.params.diagnostics)}`);

      const functionDefinition = await client.request("textDocument/definition", {
        textDocument: { uri: slideUri },
        position: positionAt(slideSource, "ultra_big!", 1),
      });
      assert(Array.isArray(functionDefinition), `expected large function definition array, got ${JSON.stringify(functionDefinition)}`);
      assert(
        functionDefinition.some((location) => isDefinitionLocation(location, ultraBigDefinition)),
        `large function definition did not jump to local theme: ${JSON.stringify(functionDefinition)}`,
      );

      const localDefinition = await client.request("textDocument/definition", {
        textDocument: { uri: slideUri },
        position: positionAt(slideSource, "t1.left", 1),
      });
      assert(Array.isArray(localDefinition), `expected large local definition array, got ${JSON.stringify(localDefinition)}`);
      assert(
        isDefinitionLocation(localDefinition[0], { uri: slideUri, line: 3, character: 6 }),
        `large local definition did not jump to let binding: ${JSON.stringify(localDefinition)}`,
      );

      const hover = await client.request("textDocument/hover", {
        textDocument: { uri: slideUri },
        position: positionAt(slideSource, "ultra_big!", 1),
      });
      assert(
        hover.contents?.value?.includes("ultra_big!(content: String) -> Object"),
        `large hover did not use local theme signature: ${JSON.stringify(hover)}`,
      );

      const completion = await client.request("textDocument/completion", {
        textDocument: { uri: slideUri },
        position: positionAfter(slideSource, "let t1 = "),
      });
      assertCompletionHas(completion, "ultra_big!", "large source completion");
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

async function testMultipleHoleParseDiagnostics() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-hole-diagnostics-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `page broken
let first =
let second =
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(
        uri,
        (diagnostics) => diagnostics.filter((diagnostic) => diagnostic.code === "ExpectedExpression").length >= 2,
        "multiple hole parse diagnostics",
      );
      client.openDocument({ uri, text: source });
      const diagnostics = (await diagnosticsPromise).params.diagnostics;
      const expressionDiagnostics = diagnostics.filter((diagnostic) => diagnostic.code === "ExpectedExpression");
      assert(expressionDiagnostics.length >= 2, `expected multiple hole diagnostics: ${JSON.stringify(diagnostics)}`);
      assert(
        expressionDiagnostics.some((diagnostic) => diagnostic.range.start.line === 1),
        `missing first expression hole diagnostic: ${JSON.stringify(expressionDiagnostics)}`,
      );
      assert(
        expressionDiagnostics.some((diagnostic) => diagnostic.range.start.line === 2),
        `missing second expression hole diagnostic: ${JSON.stringify(expressionDiagnostics)}`,
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMixedHoleParseDiagnosticsAfterEdit() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-mixed-hole-diagnostics-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const valid = `page stable
let first = "ok"
end
`;
    const broken = mixedHoleSource();
    await writeFile(slide, valid, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      let diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: valid });
      let diagnostics = (await diagnosticsPromise).params.diagnostics;
      assert(diagnostics.length === 0, `mixed-hole initial diagnostics were not empty: ${JSON.stringify(diagnostics)}`);

      diagnosticsPromise = client.waitForDiagnostics(
        uri,
        (items) =>
          items.some((diagnostic) => diagnostic.code === "InvalidImportSpec") &&
          items.some((diagnostic) => diagnostic.code === "ExpectedMemberName") &&
          items.filter((diagnostic) => diagnostic.code === "ExpectedExpression").length >= 3,
        "mixed hole diagnostics after full edit",
      );
      client.changeDocument({ uri, version: 2, text: broken });
      diagnostics = (await diagnosticsPromise).params.diagnostics;
      assertUniqueDiagnosticLocations(diagnostics, "mixed hole diagnostics");
      assertDiagnosticAt(diagnostics, "InvalidImportSpec", 0, "mixed import hole");
      assertDiagnosticAt(diagnostics, "ExpectedExpression", 3, "mixed expression hole");
      assertDiagnosticAt(diagnostics, "ExpectedMemberName", 4, "mixed member-name hole");
      assertDiagnosticAt(diagnostics, "ExpectedExpression", 5, "mixed leading call-argument hole");
      assertDiagnosticAt(diagnostics, "ExpectedExpression", 6, "mixed trailing call-argument hole");

      const rangeFixed = broken.replace("let first =", 'let first = "fixed"');
      diagnosticsPromise = client.waitForDiagnostics(
        uri,
        (items) =>
          !items.some((diagnostic) => diagnostic.range.start.line === 3) &&
          items.some((diagnostic) => diagnostic.code === "ExpectedMemberName") &&
          items.filter((diagnostic) => diagnostic.code === "ExpectedExpression").length >= 2,
        "mixed hole diagnostics after range fix",
      );
      client.changeDocumentRange({
        uri,
        version: 3,
        range: {
          start: positionAfter(broken, "let first ="),
          end: positionAfter(broken, "let first ="),
        },
        text: ' "fixed"',
      });
      diagnostics = (await diagnosticsPromise).params.diagnostics;
      assert(!diagnostics.some((diagnostic) => diagnostic.range.start.line === 3), `range fix left stale line 4 diagnostic: ${JSON.stringify(diagnostics)}`);
      assertDiagnosticAt(diagnostics, "ExpectedMemberName", 4, "mixed member-name hole after range fix");
      assertDiagnosticAt(diagnostics, "ExpectedExpression", 5, "mixed leading call-argument hole after range fix");
      assertDiagnosticAt(diagnostics, "ExpectedExpression", 6, "mixed trailing call-argument hole after range fix");
      assert(rangeFixed.includes('let first = "fixed"'), "range-fixed fixture construction failed");
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testHoleAndSemanticDiagnosticsTogether() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-hole-semantic-diagnostics-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `page broken
let x =
let y: Missing = 1
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(
        uri,
        (items) =>
          items.some((diagnostic) => diagnostic.code === "ExpectedExpression") &&
          items.some((diagnostic) => diagnostic.code === "UnknownType"),
        "hole and semantic diagnostics together",
      );
      client.openDocument({ uri, text: source });
      const diagnostics = (await diagnosticsPromise).params.diagnostics;
      assertDiagnosticAt(diagnostics, "ExpectedExpression", 1, "hole and semantic expression hole");
      assertDiagnosticAt(diagnostics, "UnknownType", 2, "hole and semantic unknown type");
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMultipleTypeDiagnostics() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-multiple-type-diagnostics-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `page typed
let first: String = 1
let second: Number = "wrong"
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(
        uri,
        (items) => items.filter((diagnostic) => diagnostic.code === "TypeMismatch").length >= 2,
        "multiple type diagnostics",
      );
      client.openDocument({ uri, text: source });
      const diagnostics = (await diagnosticsPromise).params.diagnostics;
      assertDiagnosticAt(diagnostics, "TypeMismatch", 1, "first type mismatch");
      assertDiagnosticAt(diagnostics, "TypeMismatch", 2, "second type mismatch");
    });
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

      const themeDefinitionResult = await client.request("textDocument/definition", {
        textDocument: { uri },
        position: positionAt(source, "Theme", 0),
      });
      assert(Array.isArray(themeDefinitionResult), `feature surface type definition was not an array: ${JSON.stringify(themeDefinitionResult)}`);
      assert(
        themeDefinitionResult.some((location) => isDefinitionLocation(location, themeDefinition)),
        `feature surface Theme definition did not jump to stdlib base: ${JSON.stringify(themeDefinitionResult)}`,
      );

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

async function testRandomizedLspOperationsAreStable() {
  const seed = 0x5eed2026;
  const random = makePrng(seed);
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-random-"));
  try {
    const slide = path.join(project, "slide.ss");
    const lib = path.join(project, "lib.ss");
    const slideUri = pathToFileURL(slide).toString();
    const libUri = pathToFileURL(lib).toString();
    await writeFile(path.join(project, "ss.toml"), `[project]
entry = "slide.ss"
asset_base_dir = "."
`, "utf8");
    const libSource = `import std:themes/default as *

fn label!(value: String) -> Object
  return text!(value)
end
`;
    let slideSource = randomizedSource("Main", "0.1,0.2,0.3");
    await writeFile(slide, slideSource, "utf8");
    await writeFile(lib, libSource, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      let diagnosticsPromise = client.waitForDiagnostics(slideUri);
      client.openDocument({ uri: slideUri, text: slideSource });
      let diagnostics = (await diagnosticsPromise).params.diagnostics;
      assert(diagnostics.length === 0, `random initial diagnostics: ${JSON.stringify(diagnostics)}`);

      diagnosticsPromise = client.waitForDiagnostics(slideUri);
      client.openDocument({ uri: libUri, text: libSource, version: 1 });
      diagnostics = (await diagnosticsPromise).params.diagnostics;
      assert(diagnostics.length === 0, `random library open changed project diagnostics: ${JSON.stringify(diagnostics)}`);

      let version = 1;
      for (let step = 0; step < 32; step += 1) {
        const op = Math.floor(random() * 10);
        if (op === 0) {
          slideSource = randomizedSource(`Main ${step}`, "0.1,0.2,0.3");
          version += 1;
          const wait = client.waitForDiagnostics(slideUri);
          client.changeDocument({ uri: slideUri, version, text: slideSource });
          await wait;
        } else if (op === 1) {
          slideSource = `import "./lib" as *

page random
let title = label!("after hole")
let broken =
end
`;
          version += 1;
          const wait = client.waitForDiagnostics(
            slideUri,
            (items) => items.some((diagnostic) => diagnostic.code === "ExpectedExpression"),
            `random hole diagnostics at step ${step}`,
          );
          client.changeDocument({ uri: slideUri, version, text: slideSource });
          await wait;
        } else if (op === 2) {
          if (!slideSource.includes("Main")) {
            slideSource = randomizedSource(`Main ${step}`, "0.1,0.2,0.3");
            version += 1;
            const wait = client.waitForDiagnostics(slideUri);
            client.changeDocument({ uri: slideUri, version, text: slideSource });
            await wait;
            continue;
          }
          const next = slideSource.replace(/Main(?: \d+)?/, `Main ${step}`);
          version += 1;
          const wait = client.waitForDiagnostics(slideUri);
          client.changeDocumentRange({
            uri: slideUri,
            version,
            range: {
              start: positionAt(slideSource, "Main", 0),
              end: positionAt(slideSource, "Main", "Main".length),
            },
            text: `Main ${step}`,
          });
          slideSource = next;
          await wait;
        } else if (op === 3) {
          const completion = await client.request("textDocument/completion", {
            textDocument: { uri: slideUri },
            position: completionPositionFor(slideSource),
          });
          assert(Array.isArray(completion.items), `random completion did not return items at step ${step}: ${JSON.stringify(completion)}`);
        } else if (op === 4) {
          const hover = await client.request("textDocument/hover", {
            textDocument: { uri: slideUri },
            position: positionAt(slideSource, "label!", 1),
          });
          assert(hover === null || typeof hover === "object", `random hover returned invalid value at step ${step}: ${JSON.stringify(hover)}`);
        } else if (op === 5) {
          const definition = await client.request("textDocument/definition", {
            textDocument: { uri: slideUri },
            position: positionAt(slideSource, "label!", 1),
          });
          assert(definition === null || Array.isArray(definition), `random definition returned invalid value at step ${step}: ${JSON.stringify(definition)}`);
        } else if (op === 6) {
          const inlayHints = await client.request("textDocument/inlayHint", {
            textDocument: { uri: slideUri },
            range: {
              start: { line: 0, character: 0 },
              end: { line: slideSource.split("\n").length, character: 0 },
            },
          });
          assert(Array.isArray(inlayHints), `random inlay hints did not return an array at step ${step}: ${JSON.stringify(inlayHints)}`);
        } else if (op === 7) {
          const symbols = await client.request("textDocument/documentSymbol", { textDocument: { uri: slideUri } });
          assert(Array.isArray(symbols), `random symbols did not return an array at step ${step}: ${JSON.stringify(symbols)}`);
          const foldingRanges = await client.request("textDocument/foldingRange", { textDocument: { uri: slideUri } });
          assert(Array.isArray(foldingRanges), `random folding did not return an array at step ${step}: ${JSON.stringify(foldingRanges)}`);
        } else if (op === 8) {
          const semanticTokens = await client.request("textDocument/semanticTokens/full", { textDocument: { uri: slideUri } });
          assert(Array.isArray(semanticTokens.data), `random semantic tokens did not return data at step ${step}: ${JSON.stringify(semanticTokens)}`);
          const colors = await client.request("textDocument/documentColor", { textDocument: { uri: slideUri } });
          assert(Array.isArray(colors), `random document colors did not return an array at step ${step}: ${JSON.stringify(colors)}`);
        } else {
          const projectInfo = await client.request("ss/projectInfo", { textDocument: { uri: slideUri } });
          assert(projectInfo.entryPath === slide, `random projectInfo entry mismatch at step ${step}: ${JSON.stringify(projectInfo)}`);
          const conflicts = await client.request("ss/layoutConflicts", { textDocument: { uri: slideUri } });
          assert(conflicts.kind === "ss-layout-conflicts", `random layout conflicts response mismatch at step ${step}: ${JSON.stringify(conflicts)}`);
        }
      }
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

      client.changeDocument({ uri, version: 3, text: "page broken\nlet x =\nend\n" });
      const staleReport = await client.request("ss/layoutConflicts", { textDocument: { uri } });
      assert(staleReport.kind === "ss-layout-conflicts", `stale conflict report kind mismatch: ${JSON.stringify(staleReport)}`);
      assert(
        staleReport.failures?.some((failure) => failure.reason === "anchor_value_conflict" && Math.abs((failure.expected ?? 0) - 30) < 0.1),
        `layout conflict fallback did not return the last successful report: ${JSON.stringify(staleReport.failures)}`,
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

fn themed!(theme: Theme) -> Object
  return text!("typed", theme)
end

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

function typeDefinitionLocation(uri, text, keyword, name) {
  const needle = `${keyword} ${name}`;
  const lines = text.split("\n");
  const line = lines.findIndex((lineText) => lineText.includes(needle));
  assert(line >= 0, `fixture did not contain ${needle}`);
  const character = lines[line].indexOf(name);
  assert(character >= 0, `fixture did not contain ${name} on ${needle} line`);
  return { uri, line, character };
}

function randomizedSource(title, color) {
  return `import "./lib" as *

page random
let title = label!("${title}")
let colored = label!("colored")
let accent = c"${color}"
place!(title)
place!(colored)
end
`;
}

function mixedHoleSource() {
  return `import

page mixed
let first =
let member = text!("body").
let call = text!(,)
let trailing = text!("body",)
end
`;
}

function assertDiagnosticAt(diagnostics, code, line, context) {
  assert(
    diagnostics.some((diagnostic) => diagnostic.code === code && diagnostic.range?.start?.line === line),
    `${context} did not include ${code} at line ${line}: ${JSON.stringify(diagnostics)}`,
  );
}

function assertUniqueDiagnosticLocations(diagnostics, context) {
  const seen = new Set();
  for (const diagnostic of diagnostics) {
    const key = `${diagnostic.code}:${diagnostic.range?.start?.line}:${diagnostic.range?.start?.character}`;
    assert(!seen.has(key), `${context} contained duplicate diagnostic ${key}: ${JSON.stringify(diagnostics)}`);
    seen.add(key);
  }
}

function completionPositionFor(source) {
  if (source.includes("let title = ")) return positionAfter(source, "let title = ");
  if (source.includes("let title =")) return positionAfter(source, "let title =");
  return { line: 0, character: 0 };
}

function makePrng(seed) {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x100000000;
  };
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
