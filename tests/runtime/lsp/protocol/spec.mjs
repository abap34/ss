#!/usr/bin/env node
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../../harness.mjs";

const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-protocol-"));

try {
  const slide = path.join(project, "slide.ss");
  const uri = pathToFileURL(slide).toString();
  const originalSource = `page original
end
`;
  const recoveredSource = `page recovered
end
`;
  await writeFile(slide, originalSource, "utf8");

  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    const openedDiagnostics = client.waitForDiagnostics(
      uri,
      (diagnostics, message) => diagnostics.length === 0 && message.params.version === 1,
      "initial protocol fixture diagnostics",
    );
    client.openDocument({ uri, text: originalSource, version: 1 });
    await openedDiagnostics;

    const invalidPosition = await client.request("textDocument/hover", {
      textDocument: { uri },
      position: { line: 1e100, character: 0 },
    }).then(
      () => null,
      (error) => error,
    );
    assert(
      invalidPosition instanceof Error && invalidPosition.message.includes("-32602: Invalid params"),
      `invalid position did not return Invalid params: ${invalidPosition}`,
    );

    client.notify("textDocument/didChange", {
      textDocument: { uri, version: 2 },
      contentChanges: [
        {
          range: { start: { line: 0, character: 5 }, end: { line: 0, character: 13 } },
          text: "mutated",
        },
        {
          range: { start: { line: 1, character: 1 }, end: { line: 0, character: 0 } },
          text: "invalid",
        },
      ],
    });

    const unchangedSnapshot = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: "",
    });
    assert(
      unchangedSnapshot.layout?.pages?.[0]?.name === "original",
      `invalid didChange was partially applied: ${JSON.stringify(unchangedSnapshot.layout?.pages)}`,
    );

    const invalidNode = await client.request("ss/layoutEdit", {
      textDocument: { uri },
      snapshotId: unchangedSnapshot.snapshot_id,
      pageId: unchangedSnapshot.layout.pages[0].id,
      nodeId: 4294967296,
    }).then(
      () => null,
      (error) => error,
    );
    assert(
      invalidNode instanceof Error && invalidNode.message.includes("-32602: Invalid params"),
      `out-of-range nodeId did not return Invalid params: ${invalidNode}`,
    );

    const recoveredDiagnostics = client.waitForDiagnostics(
      uri,
      (diagnostics, message) => diagnostics.length === 0 && message.params.version === 2,
      "diagnostics after a rejected change",
    );
    client.changeDocument({ uri, version: 2, text: recoveredSource });
    await recoveredDiagnostics;
    const recoveredSnapshot = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: unchangedSnapshot.snapshot_id,
    });
    assert(
      recoveredSnapshot.layout?.pages?.[0]?.name === "recovered",
      `language server did not recover after invalid input: ${JSON.stringify(recoveredSnapshot.layout?.pages)}`,
    );
  });
} finally {
  await rm(project, { recursive: true, force: true });
}
