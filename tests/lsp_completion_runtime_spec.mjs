#!/usr/bin/env node
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
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
} from "./lsp_harness.mjs";

const fixture = path.join(root, "tests", "fixtures", "project-basic", "slide.ss");
const partsFixture = path.join(root, "tests", "fixtures", "project-basic", "parts.ss");
const themeTempFixture = path.join(root, "tests", "fixtures", "project-basic", "theme-temp.ss");
const defaultTheme = path.join(root, "stdlib", "themes", "default.ss");
const uri = pathToFileURL(fixture).toString();
const partsUri = pathToFileURL(partsFixture).toString();
const themeTempUri = pathToFileURL(themeTempFixture).toString();
const defaultThemeUri = pathToFileURL(defaultTheme).toString();
const source = await readFile(fixture, "utf8");
const defaultThemeSource = await readFile(defaultTheme, "utf8");
const defaultThemeH2Definition = functionDefinitionLocation(defaultThemeUri, defaultThemeSource, "h2");

await testProjectCompletionLifecycle();
await testQualifiedModuleCompletion();
await testColdBrokenEntryCompletion();
await testMultilineEntryCompletion();

async function testProjectCompletionLifecycle() {
  await withLspClient({ cwd: root }, async (client) => {
    await client.initialize();

    const diagnosticsPromise = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source });
    const diagnostics = await diagnosticsPromise;
    assert(diagnostics.params.diagnostics.length === 0, `fixture diagnostics: ${JSON.stringify(diagnostics.params.diagnostics)}`);

    const globalCompletion = await client.request("textDocument/completion", {
      textDocument: { uri },
      position: positionAfter(source, "let heading = "),
    });
    assertUniqueCompletionLabels(globalCompletion, "global completion");
    assertCompletionHas(globalCompletion, "page", "global completion");
    assertCompletionHas(globalCompletion, "module_label!", "global completion");
    assertCompletionMissing(globalCompletion, ["place", "text_size"], "global completion");

    const libraryValidSource = `import std:themes/default
import std:themes/default as *

fn module_label!(text_value: String) -> Object
  return text!(text_value)
end

fn/! ultra_big(content: String) -> Object
  let t = default::h1(content)
  t.text_size = 40
  return t
end
`;
    const libraryDiagnosticsPromise = client.waitForDiagnostics(partsUri);
    client.openDocument({ uri: partsUri, text: libraryValidSource });
    const libraryDiagnostics = await libraryDiagnosticsPromise;
    assert(libraryDiagnostics.params.diagnostics.length === 0, `library valid diagnostics: ${JSON.stringify(libraryDiagnostics.params.diagnostics)}`);

    const libraryBrokenSource = libraryValidSource.replace("t.text_size = 40", "t.");
    client.changeDocument({ uri: partsUri, version: 2, text: libraryBrokenSource });
    const libraryMemberCompletion = await client.request("textDocument/completion", {
      textDocument: { uri: partsUri },
      position: positionAfter(libraryBrokenSource, "t."),
    });
    assertPropertyCompletion(libraryMemberCompletion, "imported library member completion");

    const repeatedLibraryCompletion = await client.request("textDocument/completion", {
      textDocument: { uri: partsUri },
      position: positionAfter(libraryBrokenSource, "t."),
    });
    assertSameLabels(libraryMemberCompletion, repeatedLibraryCompletion, "repeated imported library member completion");

    const libraryRestoredDiagnosticsPromise = client.waitForDiagnostics(partsUri);
    client.changeDocument({ uri: partsUri, version: 3, text: libraryValidSource });
    const libraryRestoredDiagnostics = await libraryRestoredDiagnosticsPromise;
    assert(libraryRestoredDiagnostics.params.diagnostics.length === 0, `library restored diagnostics: ${JSON.stringify(libraryRestoredDiagnostics.params.diagnostics)}`);

    const unimportedLibraryValidSource = `import std:themes/default

fn/! ultra_big(content: String) -> Object
  let t = default::h1(content)
  t.text_size = 40
  return t
end
`;
    const unimportedDiagnosticsPromise = client.waitForDiagnostics(themeTempUri);
    client.openDocument({ uri: themeTempUri, text: unimportedLibraryValidSource });
    const unimportedDiagnostics = await unimportedDiagnosticsPromise;
    assert(unimportedDiagnostics.params.diagnostics.length === 0, `unimported library valid diagnostics: ${JSON.stringify(unimportedDiagnostics.params.diagnostics)}`);

    const unimportedLibraryBrokenSource = unimportedLibraryValidSource.replace("t.text_size = 40", "t.");
    client.changeDocument({ uri: themeTempUri, version: 2, text: unimportedLibraryBrokenSource });
    const unimportedBrokenCompletion = await client.request("textDocument/completion", {
      textDocument: { uri: themeTempUri },
      position: positionAfter(unimportedLibraryBrokenSource, "t."),
    });
    assertPropertyCompletion(unimportedBrokenCompletion, "unimported library broken completion");

    const brokenDiagnosticsPromise = client.waitForDiagnostics(uri);
    client.changeDocumentRange({
      uri,
      version: 2,
      range: { start: { line: 3, character: 0 }, end: { line: 3, character: 4 } },
      text: "pag",
    });
    const brokenDiagnostics = await brokenDiagnosticsPromise;
    assert(brokenDiagnostics.params.diagnostics.length > 0, "ranged didChange did not publish diagnostics for broken source");

    const brokenCompletion = await client.request("textDocument/completion", {
      textDocument: { uri },
      position: positionAfter(source, "let heading = "),
    });
    assertUniqueCompletionLabels(brokenCompletion, "broken-source completion");
    assertCompletionHas(brokenCompletion, "module_label!", "broken-source completion");

    const fixedDiagnosticsPromise = client.waitForDiagnostics(uri);
    client.changeDocumentRange({
      uri,
      version: 3,
      range: { start: { line: 3, character: 0 }, end: { line: 3, character: 3 } },
      text: "page",
    });
    const fixedDiagnostics = await fixedDiagnosticsPromise;
    assert(fixedDiagnostics.params.diagnostics.length === 0, "ranged didChange did not clear diagnostics after restoring source");

    const addedBrokenMemberSource = `import std:themes/default

page ok
  let t = default::h1("body")
  t.
end
`;
    client.changeDocument({ uri, version: 4, text: addedBrokenMemberSource });
    const addedBrokenMemberCompletion = await client.request("textDocument/completion", {
      textDocument: { uri },
      position: positionAfter(addedBrokenMemberSource, "t."),
    });
    assertPropertyCompletion(addedBrokenMemberCompletion, "added broken member completion");

    const memberBrokenSource = `import std:themes/default
import std:themes/default as *

page ok
  let t = text! "body"
  t.
end
`;
    client.changeDocument({ uri, version: 5, text: memberBrokenSource });
    const memberCompletion = await client.request("textDocument/completion", {
      textDocument: { uri },
      position: positionAfter(memberBrokenSource, "t."),
    });
    assertPropertyCompletion(memberCompletion, "member completion");
    assertCompletionMissing(memberCompletion, ["Align"], "member completion");
  });
}

async function testQualifiedModuleCompletion() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-qualified-"));
  try {
    const slide = path.join(project, "slide.ss");
    const localUri = pathToFileURL(slide).toString();
    const qualifiedSource = `import std:themes/default

page title
  default::h2!("Qualified")
end
`;
    await writeFile(slide, qualifiedSource, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(localUri);
      client.openDocument({ uri: localUri, text: qualifiedSource });
      const diagnostics = await diagnosticsPromise;
      assert(diagnostics.params.diagnostics.length === 0, `qualified diagnostics: ${JSON.stringify(diagnostics.params.diagnostics)}`);

      const completion = await client.request("textDocument/completion", {
        textDocument: { uri: localUri },
        position: positionAfter(qualifiedSource, "default::"),
      });
      assertUniqueCompletionLabels(completion, "qualified completion");
      assertCompletionHas(completion, "h2", "qualified completion");
      assertCompletionHas(completion, "h2!", "qualified completion");
      assertCompletionMissing(completion, ["page", "text_size"], "qualified completion");

      const definition = await client.request("textDocument/definition", {
        textDocument: { uri: localUri },
        position: positionAt(qualifiedSource, "h2!", 1),
      });
      assert(Array.isArray(definition), `expected qualified definition array, got ${JSON.stringify(definition)}`);
      assert(
        definition.some((location) => isDefinitionLocation(location, defaultThemeH2Definition)),
        `qualified definition did not jump to default h2: ${JSON.stringify(definition)}`,
      );

      const semanticTokens = await client.request("textDocument/semanticTokens/full", {
        textDocument: { uri: localUri },
      });
      assert(
        semanticTokens.data?.some((_, index, data) => index % 5 === 3 && data[index] === 7),
        `semantic tokens did not include :: operator: ${JSON.stringify(semanticTokens)}`,
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testColdBrokenEntryCompletion() {
  const coldBrokenSource = `import std:themes/default

page ok
  let t = default::h1("body")
  t.
end
`;
  const completion = await completionInTempProject("ss-lsp-cold-broken-", coldBrokenSource, positionAfter(coldBrokenSource, "t."));
  assertPropertyCompletion(completion, "cold broken entry completion");
}

async function testMultilineEntryCompletion() {
  const multilineBrokenSource = `import std:themes/default
import std:themes/default as *

fn/! ultra_big(content: String) -> Object
  let t = default::h1(content)
  t.text_size = 40
  return t
end

page title

let t1 = ultra_big! <<
前段解析の収束過程を利用した
複数段階のデータフロー解析の効率化
>>


let t2 = h2! <<
情報工学系渡部研究室  山口悠地
>>

t2.

end
`;
  const completion = await completionInTempProject("ss-lsp-multiline-broken-", multilineBrokenSource, positionAfter(multilineBrokenSource, "t2."));
  assertPropertyCompletion(completion, "multiline broken entry completion");
}

async function completionInTempProject(prefix, sourceText, position) {
  const project = await mkdtemp(path.join(os.tmpdir(), prefix));
  try {
    const slide = path.join(project, "slide.ss");
    const localUri = pathToFileURL(slide).toString();
    await writeFile(path.join(project, "ss.toml"), `[project]
entry = "slide.ss"
asset_base_dir = "."
`, "utf8");
    await writeFile(slide, sourceText, "utf8");

    return await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(localUri);
      client.openDocument({ uri: localUri, text: sourceText });
      await diagnosticsPromise;
      return client.request("textDocument/completion", {
        textDocument: { uri: localUri },
        position,
      });
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function assertPropertyCompletion(completion, label) {
  assertUniqueCompletionLabels(completion, label);
  assertCompletionHas(completion, "text_size", label);
  assertCompletionMissing(completion, ["page", "add"], label);
}

function assertSameLabels(left, right, label) {
  const leftLabels = (left.items ?? []).map((item) => item.label).sort();
  const rightLabels = (right.items ?? []).map((item) => item.label).sort();
  assert(
    JSON.stringify(leftLabels) === JSON.stringify(rightLabels),
    `${label} changed labels between identical requests: ${JSON.stringify({ left: leftLabels, right: rightLabels })}`,
  );
}

