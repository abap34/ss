#!/usr/bin/env node
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, positionAt, withLspClient } from "../../harness.mjs";

for (const independent of [false, true]) {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-sharing-"));
  try {
    const file = path.join(project, independent ? "notes.ss" : "slide.ss");
    const uri = pathToFileURL(file).toString();
    const initial = "page first\nlet value: Number = 1\nlet result = value\nend\n";
    const changed = ";; Changed positions\n\npage first\nlet value: Number = 2\nlet result = value\nend\n";
    await writeFile(path.join(project, "slide.ss"), "page entry\nend\n");
    await writeFile(file, initial);
    await writeFile(path.join(project, "ss.toml"), '[project]\nentry="slide.ss"\n[editor.lsp]\ndebounce=2000\n');
    await withLspClient({ cwd: project, measureProfile: true }, async (client) => {
      await client.initialize();
      const firstDiagnostics = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: initial });
      assert((await firstDiagnostics).params.diagnostics.length === 0, "invalid initial fixture");
      client.changeDocument({ uri, text: changed, version: 2 });
      const position = positionAt(changed, "result = value", "result = va".length);
      for (let i = 0; i < 3; i++) {
        const hover = await client.request("textDocument/hover", { textDocument: { uri }, position });
        assert(hover?.contents?.value?.includes("Number"), `missing fresh hover: ${JSON.stringify(hover)}`);
        const definition = await client.request("textDocument/definition", { textDocument: { uri }, position });
        assert(definition?.[0]?.range.start.line === 3, `stale definition position: ${JSON.stringify(definition)}`);
        const completion = await client.request("textDocument/completion", { textDocument: { uri }, position });
        assert(completion.items.some((item) => item.label === "value"), "missing shared completion");
        await client.request("textDocument/documentSymbol", { textDocument: { uri } });
        await client.request("textDocument/foldingRange", { textDocument: { uri } });
      }
      // A save flushes the queued layout stage using the same semantic result.
      const rebuilt = client.waitForDiagnostics(uri, (_, message) => message.params.version === 2);
      client.notify("textDocument/didSave", { textDocument: { uri } });
      assert((await rebuilt).params.diagnostics.length === 0, "invalid changed fixture");
      await client.close();
      const count = (name) => Number(client.stderr.match(new RegExp(`${name}: (\\d+) calls`))?.[1] ?? 0);
      // Independent notes and the configured entry each have two generations.
      const expected = independent ? 4 : 2;
      assert(count("analysis static semantics") === expected, `expected ${expected} semantic builds; got ${count("analysis static semantics")}\n${client.stderr}`);
      assert(count("WYSIWYG evaluate and solve") === 2, `queries unexpectedly performed layout\n${client.stderr}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-budget-"));
try {
  const file = path.join(project, "slide.ss");
  const uri = pathToFileURL(file).toString();
  const source = "page sample\nlet value: Number = 1\nlet result = value\nend\n";
  await writeFile(file, source);
  await writeFile(path.join(project, "ss.toml"), '[project]\nentry="slide.ss"\n[editor.lsp]\ndebounce=2000\n');
  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    const opened = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source });
    await opened;
    const large = `;; ${"padding ".repeat(2_000_000)}\n${source.replaceAll("value", "replacement")}`;
    client.changeDocument({ uri, text: large, version: 2 });
    const started = performance.now();
    const result = await client.request("textDocument/completion", {
      textDocument: { uri }, position: { line: 3, character: 18 },
    });
    assert(performance.now() - started < 5000, "completion did not stop within its cooperative budget");
    assert(result.isIncomplete || result.items.some((item) => item.label === "replacement"), "completion returned neither a bounded response nor current source facts");
    console.log(`large-source completion: incomplete=${result.isIncomplete}, elapsed=${Math.round(performance.now() - started)}ms`);
    assert(!result.items.some((item) => item.label === "value"), "budget fallback reused obsolete source positions");
    const restored = client.waitForDiagnostics(uri, (_, message) => message.params.version === 3);
    client.changeDocument({ uri, text: source, version: 3 });
    await restored;
    const hover = await client.request("textDocument/hover", {
      textDocument: { uri }, position: positionAt(source, "result = value", "result = va".length),
    });
    assert(hover?.contents?.value?.includes("Number"), "expired query poisoned subsequent analysis");
  });
} finally {
  await rm(project, { recursive: true, force: true });
}
