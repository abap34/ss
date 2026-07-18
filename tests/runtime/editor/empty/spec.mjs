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
    assert(
      snapshot.stale === true && snapshot.build_diagnostics?.length > 0,
      `initial build failure omitted its diagnostics: ${JSON.stringify(snapshot)}`,
    );

    const missing = path.join(project, "missing.ss");
    const missingUri = pathToFileURL(missing).toString();
    const missingSnapshot = await client.request("ss/editorSnapshot", {
      textDocument: { uri: missingUri },
    });
    const missingDiagnostic = missingSnapshot.build_diagnostics?.find(
      (item) => item.code === "ProjectReadFailed",
    );
    assert(
      missingSnapshot.stale === true &&
        missingDiagnostic?.uri === missingUri &&
        missingDiagnostic.range.start.line === 0 &&
        missingDiagnostic.range.start.character === 0,
      `unlocated build failure was omitted: ${JSON.stringify(missingSnapshot)}`,
    );
  });
} finally {
  await rm(project, { recursive: true, force: true });
}
