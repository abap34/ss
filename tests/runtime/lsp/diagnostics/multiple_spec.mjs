#!/usr/bin/env node
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../../harness.mjs";

for (const configured of [false, true]) {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-multiple-"));
  try {
    const first = path.join(project, "first.ss");
    const second = path.join(project, "notes.ss");
    const shared = path.join(project, "shared.ss");
    const firstUri = pathToFileURL(first).toString();
    const secondUri = pathToFileURL(second).toString();
    const sharedUri = pathToFileURL(shared).toString();
    const source = (name, invalid) => `import ./shared as *\npage ${name}\n  let common: Number = value\n${invalid ? `  let bad = missing_${name}\n` : ""}end\n`;
    if (configured) await writeFile(path.join(project, "ss.toml"), '[project]\nentry = "first.ss"\nasset_base_dir = "."\n');
    await writeFile(first, source("first", true));
    await writeFile(second, source("second", true));
    await writeFile(shared, "const value: Number = 1\n");
    await withLspClient({ cwd: project }, async (client) => {
      const notifications = [];
      const handleMessage = client.handleMessage.bind(client);
      client.handleMessage = (message) => {
        if (message.method === "textDocument/publishDiagnostics") notifications.push(message);
        handleMessage(message);
      };
      await client.initialize();
      const initial = client.waitForDiagnostics(firstUri, (items) => items.some((item) => item.message.includes("missing_first")));
      client.openDocument({ uri: firstUri, text: source("first", true) });
      await initial;
      const start = notifications.length;
      const firstAgain = client.waitForDiagnostics(firstUri, (items) => items.length > 0);
      const secondOpened = client.waitForDiagnostics(secondUri, (items) => items.some((item) => item.message.includes("missing_second")));
      client.openDocument({ uri: secondUri, text: source("second", true) });
      await Promise.all([firstAgain, secondOpened]);
      const firstAfterEdit = client.waitForDiagnostics(firstUri, (items) => items.length > 0);
      const secondCleared = client.waitForDiagnostics(secondUri, (items, message) => items.length === 0 && message.params.version === 2);
      client.changeDocument({ uri: secondUri, text: source("second", false), version: 2 });
      await Promise.all([firstAfterEdit, secondCleared]);
      assert(!notifications.slice(start).some((message) => message.params.uri === firstUri && message.params.diagnostics.length === 0), "editing another entry erased the first entry's diagnostics");

      const mismatch = (items) => items.some((item) => item.message.includes("Number") && item.message.includes("String"));
      const firstChanged = client.waitForDiagnostics(firstUri, mismatch);
      const secondChanged = client.waitForDiagnostics(secondUri, mismatch);
      await writeFile(shared, 'const value: String = "changed"\n');
      client.notify("workspace/didChangeWatchedFiles", { changes: [{ uri: sharedUri, type: 2 }] });
      await Promise.all([firstChanged, secondChanged]);

      const firstRepaired = client.waitForDiagnostics(firstUri, (items) => items.length === 1 && items[0].message.includes("missing_first"));
      const secondRepaired = client.waitForDiagnostics(secondUri, (items) => items.length === 0);
      await writeFile(shared, "const value: Number = 1\n");
      client.notify("workspace/didChangeWatchedFiles", { changes: [{ uri: sharedUri, type: 2 }] });
      await Promise.all([firstRepaired, secondRepaired]);

      const firstAfterClose = client.waitForDiagnostics(firstUri, (items) => items.some((item) => item.message.includes("missing_first")));
      client.notify("textDocument/didClose", { textDocument: { uri: secondUri } });
      await firstAfterClose;
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}
