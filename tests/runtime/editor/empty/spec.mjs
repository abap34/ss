#!/usr/bin/env node
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../../harness.mjs";

const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-empty-"));
try {
  const slide = path.join(project, "slide.ss");
  const uri = pathToFileURL(slide).toString();
  const source = `page broken
unknown!(
end
`;
  await writeFile(slide, source, "utf8");

  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    const diagnosticsPromise = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source });
    await diagnosticsPromise;
    const snapshot = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
    });
    assert(
      snapshot.display?.schema === 2 &&
        snapshot.display.html === "" &&
        snapshot.display.css === "" &&
        snapshot.display.has_pdf === false &&
        Array.isArray(snapshot.display.assets),
      `empty snapshot used an obsolete display schema: ${JSON.stringify(snapshot)}`,
    );
  });
} finally {
  await rm(project, { recursive: true, force: true });
}
