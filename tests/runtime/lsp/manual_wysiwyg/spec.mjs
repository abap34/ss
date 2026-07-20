#!/usr/bin/env node
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../../harness.mjs";

const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-manual-wysiwyg-"));

try {
  const slide = path.join(project, "slide.ss");
  const uri = pathToFileURL(slide).toString();
  const initialSource = `page initial
end
`;
  const pendingSource = `page pending
end
`;
  const changedSource = `page changed
end
`;
  await writeFile(path.join(project, "ss.toml"), `[project]
entry = "slide.ss"

[editor.lsp]
debounce = 250

[editor.wysiwyg.refresh]
automatic = false
`, "utf8");
  await writeFile(slide, initialSource, "utf8");

  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    const initialDiagnostics = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: initialSource, version: 1 });
    assert(
      (await initialDiagnostics).params.diagnostics.length === 0,
      "manual WYSIWYG fixture produced diagnostics",
    );

    const initial = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
    });
    assert(
      initial.kind === "ss-editor-snapshot" && initial.layout?.pages?.length === 1,
      `explicit manual build did not produce a snapshot: ${JSON.stringify(initial)}`,
    );

    client.changeDocument({ uri, version: 2, text: pendingSource });
    const pending = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: initial.snapshot_id,
    });
    assert(
      pending.kind === "ss-editor-snapshot" &&
        pending.layout?.pages?.length === 1 &&
        pending.snapshot_id !== initial.snapshot_id,
      `explicit build did not flush pending analysis: ${JSON.stringify(pending)}`,
    );

    const changedDiagnostics = client.waitForDiagnostics(
      uri,
      (_diagnostics, message) => message.params.version === 3,
      "manual WYSIWYG changed diagnostics",
    );
    client.changeDocument({ uri, version: 3, text: changedSource });
    await changedDiagnostics;

    const editBeforeBuild = await client.request("ss/layoutEdit", {
      textDocument: { uri },
      snapshotId: pending.snapshot_id,
      nodeId: 1,
      pageId: 1,
      mode: "absolute",
      fromBounds: { x: 0, y: 0, width: 10, height: 10 },
      toBounds: { x: 10, y: 10, width: 10, height: 10 },
    });
    assert(
      editBeforeBuild.status === "unsupported" &&
        editBeforeBuild.message === "No solved layout is available.",
      `automatic reanalysis retained a WYSIWYG layout: ${JSON.stringify(editBeforeBuild)}`,
    );

    const rebuilt = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: pending.snapshot_id,
    });
    assert(
      rebuilt.kind === "ss-editor-snapshot" &&
        rebuilt.layout?.pages?.length === 1 &&
        rebuilt.snapshot_id !== pending.snapshot_id,
      `explicit rebuild did not restore the WYSIWYG snapshot: ${JSON.stringify(rebuilt)}`,
    );
  });
} finally {
  await rm(project, { recursive: true, force: true });
}
