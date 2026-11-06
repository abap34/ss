import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { withLspClient } from "../../harness.mjs";

const directory = await mkdtemp(path.join(os.tmpdir(), "ss-page-code-lens-"));
const entry = path.join(directory, "slide.ss");
const included = path.join(directory, "included pages.ss");
const uri = pathToFileURL(entry).href;
const includedUri = pathToFileURL(included).href;
const source = `import std:themes/default as *
;; page Comment
const source_example: String = "page String"
enum Example { first second }
page Before
  text! "Before"
end
include "included pages.ss"
page "After"
  text! "After"
end
`;
const body = `;; Unicode before the declaration: 日本語
page Demo
  stages s { first second third }
  text! "Common"
end
`;
try {
  await writeFile(path.join(directory, "ss.toml"), '[project]\nentry = "slide.ss"\n');
  await writeFile(entry, source);
  await writeFile(included, body);
  await withLspClient({ cwd: directory }, async (client) => {
    const initialized = await client.initialize();
    assert.deepEqual(initialized.capabilities.codeLensProvider, { resolveProvider: false });
    const ready = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source });
    assert.deepEqual((await ready).params.diagnostics, []);
    const entryLenses = await client.request("textDocument/codeLens", { textDocument: { uri } });
    assert.equal(entryLenses.length, 2, "only page declarations in this physical file need lenses");
    for (const [lens, name] of entryLenses.map((lens, i) => [lens, ["Before", '"After"'][i]])) {
      const start = Buffer.byteLength(source.slice(0, source.indexOf(`page ${name}`)));
      assert.equal(lens.command.command, "ss.editor.revealPage");
      assert.equal(lens.command.title, "Jump to slide");
      assert.deepEqual(lens.command.arguments, [{ uri, start, version: 1 }]);
      assert.equal(source.split("\n")[lens.range.start.line].trim(), `page ${name}`);
    }
    const childReady = client.waitForDiagnostics(includedUri);
    client.openDocument({ uri: includedUri, text: body, version: 4 });
    assert.deepEqual((await childReady).params.diagnostics, []);
    const lenses = await client.request("textDocument/codeLens", { textDocument: { uri: includedUri } });
    assert.equal(lenses.length, 1, "stages must share the source declaration's lens");
    const target = lenses[0].command.arguments[0];
    assert.deepEqual(target, {
      uri: includedUri, start: Buffer.byteLength(body.slice(0, body.indexOf("page Demo"))), version: 4,
    });
    assert.equal(lenses[0].range.start.line, 1);
    const snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert(!snapshot.stale);
    const pages = snapshot.layout.pages.filter((page) =>
      page.location?.path === included && page.location.start === target.start
    );
    assert.deepEqual(pages.map((page) => page.name), ["Demo / first", "Demo / second", "Demo / third"],
      JSON.stringify({ target, pages: snapshot.layout.pages }));

    const changed = client.waitForDiagnostics(includedUri);
    const edited = `;; Added before the page\n${body}`;
    client.changeDocument({ uri: includedUri, text: edited, version: 5 });
    assert.deepEqual((await changed).params.diagnostics, []);
    const updated = await client.request("textDocument/codeLens", { textDocument: { uri: includedUri } });
    assert.equal(updated.length, 1);
    assert.equal(updated[0].range.start.line, 2);
    assert.deepEqual(updated[0].command.arguments, [{
      uri: includedUri, start: Buffer.byteLength(edited.slice(0, edited.indexOf("page Demo"))), version: 5,
    }]);
  });
  console.log("Page CodeLens declarations and expanded preview targets passed");
} finally {
  await rm(directory, { recursive: true, force: true });
}
