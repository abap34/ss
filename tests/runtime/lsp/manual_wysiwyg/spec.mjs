#!/usr/bin/env node
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../../harness.mjs";
import {
  applyProtocolEdits,
  editingTarget,
  previewBounds,
  requestEdit,
} from "../../editor/support.mjs";

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

    client.changeDocument({ uri, version: 2, text: initialSource });
    const unchanged = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: initial.snapshot_id,
    });
    assert(
      unchanged.snapshot_id === initial.snapshot_id &&
        unchanged.display?.kind === "translation_patch" &&
        unchanged.display?.base_snapshot_id === initial.snapshot_id &&
        unchanged.display?.translations?.length === 0,
      `identical content rebuilt the preview: ${JSON.stringify(unchanged)}`,
    );

    client.notify("textDocument/didSave", { textDocument: { uri } });
    client.notify("workspace/didChangeWatchedFiles", {
      changes: [{ uri, type: 2 }],
    });
    const afterSave = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: unchanged.snapshot_id,
    });
    assert(
      afterSave.snapshot_id === unchanged.snapshot_id &&
        afterSave.display?.kind === "translation_patch" &&
        afterSave.display?.translations?.length === 0,
      `save notifications rebuilt an unchanged open document: ${JSON.stringify(afterSave)}`,
    );

    client.changeDocument({ uri, version: 3, text: `${initialSource}\n` });
    const visuallyUnchanged = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: afterSave.snapshot_id,
    });
    assert(
      visuallyUnchanged.snapshot_id !== afterSave.snapshot_id &&
        visuallyUnchanged.display?.kind === "translation_patch" &&
        visuallyUnchanged.display?.base_snapshot_id === afterSave.snapshot_id &&
        visuallyUnchanged.display?.translations?.length === 0,
      `visually unchanged source resent the complete display: ${JSON.stringify(visuallyUnchanged)}`,
    );

    client.changeDocument({ uri, version: 4, text: pendingSource });
    const pending = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: visuallyUnchanged.snapshot_id,
    });
    assert(
      pending.kind === "ss-editor-snapshot" &&
        pending.layout?.pages?.length === 1 &&
        pending.snapshot_id !== initial.snapshot_id,
      `explicit build did not flush pending analysis: ${JSON.stringify(pending)}`,
    );

    const clearedDiagnostics = client.waitForDiagnostics(
      uri,
      (_diagnostics, message) => message.params.version === 5,
      "manual WYSIWYG cleared diagnostics",
    );
    client.changeDocument({ uri, version: 5, text: changedSource });
    await clearedDiagnostics;
    const rebuiltDiagnostics = client.waitForDiagnostics(
      uri,
      (_diagnostics, message) => message.params.version === 5,
      "manual WYSIWYG rebuilt diagnostics",
    );
    await rebuiltDiagnostics;

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
      editBeforeBuild.status === "stale" &&
        editBeforeBuild.message === "The document changed before the edit was applied.",
      `an unbuilt document did not request editor reconciliation: ${JSON.stringify(editBeforeBuild)}`,
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

await testContinuousPositionEdits(250);
await testContinuousPositionEdits(0);

async function testContinuousPositionEdits(debounceMs) {
  const fixture = await mkdtemp(
    path.join(os.tmpdir(), `ss-lsp-manual-position-${debounceMs}-`),
  );
  try {
    const slide = path.join(fixture, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    let source = `import std:themes/default as *

page demo
let item = text!("Move me")
end
`;
    await writeFile(path.join(fixture, "ss.toml"), `[project]
entry = "slide.ss"

[editor.lsp]
debounce = ${debounceMs}

[editor.wysiwyg.refresh]
automatic = false
`, "utf8");
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: fixture }, async (client) => {
      await client.initialize();
      const initialDiagnostics = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      assert(
        (await initialDiagnostics).params.diagnostics.length === 0,
        `manual position fixture produced diagnostics with debounce ${debounceMs}`,
      );

      const initial = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
      });
      const initialTarget = editingTarget(initial, "item");
      const initialBounds = previewBounds(initial, initialTarget.node_id);
      const firstBounds = { ...initialBounds, x: 120, y: 140 };
      const firstEdit = await requestEdit(
        client,
        uri,
        initial,
        initialTarget,
        initialBounds,
        firstBounds,
        "absolute",
        initialTarget.page_id,
      );
      assert(
        firstEdit.status === "ok",
        `first manual position edit failed with debounce ${debounceMs}: ${JSON.stringify(firstEdit)}`,
      );
      source = applyProtocolEdits(
        source,
        firstEdit.workspaceEdit?.changes?.[uri] ?? [],
      );
      client.changeDocument({ uri, version: 2, text: source });

      const afterFirst = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
        baseSnapshotId: initial.snapshot_id,
      });
      assert(
        afterFirst.display?.kind === "translation_patch" &&
          afterFirst.display.base_snapshot_id === initial.snapshot_id,
        `first manual position edit rebuilt the display with debounce ${debounceMs}: ${JSON.stringify(afterFirst.display)}`,
      );
      assertPosition(afterFirst, "item", 120, 140, `first edit with debounce ${debounceMs}`);

      const secondTarget = editingTarget(afterFirst, "item");
      const secondFrom = previewBounds(afterFirst, secondTarget.node_id);
      const secondBounds = { ...secondFrom, x: 155, y: 175 };
      const secondEdit = await requestEdit(
        client,
        uri,
        afterFirst,
        secondTarget,
        secondFrom,
        secondBounds,
        "absolute",
        secondTarget.page_id,
      );
      assert(
        secondEdit.status === "ok",
        `second manual position edit failed with debounce ${debounceMs}: ${JSON.stringify(secondEdit)}`,
      );
      source = applyProtocolEdits(
        source,
        secondEdit.workspaceEdit?.changes?.[uri] ?? [],
      );
      client.changeDocument({ uri, version: 3, text: source });

      const afterSecond = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
        baseSnapshotId: afterFirst.snapshot_id,
      });
      assert(
        afterSecond.display?.kind === "translation_patch" &&
          afterSecond.display.base_snapshot_id === afterFirst.snapshot_id,
        `second manual position edit broke the patch chain with debounce ${debounceMs}: ${JSON.stringify(afterSecond.display)}`,
      );
      assertPosition(afterSecond, "item", 155, 175, `second edit with debounce ${debounceMs}`);
      assert(
        source.includes("~!~ item.left == page.left + 155") &&
          source.includes("~!~ item.top == page.top - 175"),
        `second manual position edit did not reach source with debounce ${debounceMs}: ${source}`,
      );
    });
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
}

function assertPosition(snapshot, binding, x, y, label) {
  const target = editingTarget(snapshot, binding);
  const bounds = previewBounds(snapshot, target.node_id);
  assert(
    Math.abs(bounds.x - x) < 0.1 && Math.abs(bounds.y - y) < 0.1,
    `${label} was (${bounds.x}, ${bounds.y}), expected (${x}, ${y})`,
  );
}
