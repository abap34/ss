#!/usr/bin/env node
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../../harness.mjs";
import {
  applyProtocolEdits,
  editingTarget,
} from "../support.mjs";

const project = await mkdtemp(path.join(os.tmpdir(), "ss-editor-deletion-"));
try {
  const slide = path.join(project, "slide.ss");
  const uri = pathToFileURL(slide).toString();
  let source = `page components
  let anchor = rectangle!(80, 60)
  let removed = rectangle!(120, 70)
  let keep = rectangle!(90, 50)
  ~ anchor.left == page.left + 20
  ~ anchor.top == page.top - 20
  ~ removed.left == anchor.right + 30
  ~!~ removed.top == page.top - 90
  ~ keep.left == removed.right + 40
  ~ keep.top == page.top - 180
end
`;
  await writeFile(slide, source, "utf8");

  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    let diagnosticsPromise = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source });
    assert(
      (await diagnosticsPromise).params.diagnostics.length === 0,
      "component deletion fixture produced diagnostics",
    );
    const initial = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
    });
    const removed = editingTarget(initial, "removed");
    const deletion = await client.request("ss/deleteComponent", {
      textDocument: { uri },
      snapshotId: initial.snapshot_id,
      nodeId: removed.node_id,
      pageId: removed.page_id,
    });
    assert(
      deletion.status === "ok",
      `component deletion failed: ${JSON.stringify(deletion)}`,
    );
    source = applyProtocolEdits(
      source,
      deletion.workspaceEdit?.changes?.[uri] ?? [],
    );
    assert(
      !source.includes("let removed =") &&
        !source.includes("removed.left") &&
        !source.includes("removed.top") &&
        !source.includes("removed.right"),
      `component deletion left a dependent constraint behind:\n${source}`,
    );
    assert(
      source.includes("let anchor =") && source.includes("let keep =") &&
        source.includes("~ keep.top == page.top - 180"),
      `component deletion removed unrelated source:\n${source}`,
    );

    diagnosticsPromise = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 2, text: source });
    assert(
      (await diagnosticsPromise).params.diagnostics.length === 0,
      `deleted component source did not rebuild:\n${source}`,
    );
    const rebuilt = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: initial.snapshot_id,
    });
    assert(
      !rebuilt.editing.some((target) => target.binding === "removed"),
      `deleted component remained in the rebuilt preview: ${JSON.stringify(rebuilt.editing)}`,
    );
    assert(
      rebuilt.editing.some((target) => target.binding === "keep"),
      `unrelated component disappeared after deletion: ${JSON.stringify(rebuilt.editing)}`,
    );

    const stale = await client.request("ss/deleteComponent", {
      textDocument: { uri },
      snapshotId: initial.snapshot_id,
      nodeId: removed.node_id,
      pageId: removed.page_id,
    });
    assert(
      stale.status === "stale",
      `stale component deletion was accepted: ${JSON.stringify(stale)}`,
    );

    source = source.replace("end\n", "  let keep_alias = keep\nend\n");
    diagnosticsPromise = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 3, text: source });
    assert(
      (await diagnosticsPromise).params.diagnostics.length === 0,
      `component reference fixture did not build:\n${source}`,
    );
    const referencedSnapshot = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: rebuilt.snapshot_id,
    });
    const keep = editingTarget(referencedSnapshot, "keep");
    const referenced = await client.request("ss/deleteComponent", {
      textDocument: { uri },
      snapshotId: referencedSnapshot.snapshot_id,
      nodeId: keep.node_id,
      pageId: keep.page_id,
    });
    assert(
      referenced.status === "rejected" &&
        referenced.message?.includes("non-constraint page statement"),
      `component deletion did not report a non-constraint dependency: ${JSON.stringify(referenced)}`,
    );
  });
} finally {
  await rm(project, { recursive: true, force: true });
}
