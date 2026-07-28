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
await testSignedZeroPositionEdits();
await testConnectorForcesFullDisplay();
await testPageSpaceFillForcesFullDisplay();
await testReadlinesForcesFullDisplay();
await testWatchedModuleChangeForcesFullDisplay();
await testExternalVectorAssetForcesFullDisplay();

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
      const secondBounds = { ...secondFrom, x: 155 };
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
      assertPosition(afterSecond, "item", 155, 140, `second edit with debounce ${debounceMs}`);
      assert(
        source.includes("~!~ item.left == page.left + 155") &&
          source.includes("~!~ item.top == page.top - 140"),
        `second manual position edit did not reach source with debounce ${debounceMs}: ${source}`,
      );

      const thirdTarget = editingTarget(afterSecond, "item");
      const thirdFrom = previewBounds(afterSecond, thirdTarget.node_id);
      const thirdBounds = { ...thirdFrom, x: 185 };
      const thirdEdit = await requestEdit(
        client,
        uri,
        afterSecond,
        thirdTarget,
        thirdFrom,
        thirdBounds,
        "absolute",
        thirdTarget.page_id,
      );
      assert(
        thirdEdit.status === "ok",
        `third manual position edit failed with debounce ${debounceMs}: ${JSON.stringify(thirdEdit)}`,
      );
      source = applyProtocolEdits(
        source,
        thirdEdit.workspaceEdit?.changes?.[uri] ?? [],
      );
      client.changeDocument({ uri, version: 4, text: source });

      const afterThird = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
        baseSnapshotId: afterSecond.snapshot_id,
      });
      assert(
        afterThird.display?.kind === "translation_patch" &&
          afterThird.display.base_snapshot_id === afterSecond.snapshot_id,
        `third manual position edit broke the single-axis patch chain with debounce ${debounceMs}: ${JSON.stringify(afterThird.display)}`,
      );
      assertPosition(afterThird, "item", 185, 140, `third edit with debounce ${debounceMs}`);
      assert(
        source.includes("~!~ item.left == page.left + 185") &&
          source.includes("~!~ item.top == page.top - 140"),
        `third manual position edit did not reach source with debounce ${debounceMs}: ${source}`,
      );
    });
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
}

async function testSignedZeroPositionEdits() {
  const fixture = await mkdtemp(
    path.join(os.tmpdir(), "ss-lsp-manual-signed-zero-"),
  );
  try {
    const slide = path.join(fixture, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    let source = `import std:themes/default as *

page demo
let item = text!("Move me")
~!~ item.left == page.left + 0
~!~ item.top == page.top - 0
end
`;
    await writeFile(path.join(fixture, "ss.toml"), `[project]
entry = "slide.ss"

[editor.lsp]
debounce = 0

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
        "signed-zero fixture produced diagnostics",
      );

      const initial = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
      });
      const target = editingTarget(initial, "item");
      const from = previewBounds(initial, target.node_id);
      const to = { ...from, x: 5, y: 5 };
      const edit = await requestEdit(
        client,
        uri,
        initial,
        target,
        from,
        to,
        "absolute",
        target.page_id,
      );
      assert(
        edit.status === "ok",
        `signed-zero position edit failed: ${JSON.stringify(edit)}`,
      );
      source = applyProtocolEdits(
        source,
        edit.workspaceEdit?.changes?.[uri] ?? [],
      );
      assert(
        source.includes("~!~ item.left == page.left + 5") &&
          source.includes("~!~ item.top == page.top - 5"),
        `signed-zero edit lost an offset sign: ${source}`,
      );

      const fastDiagnostics = client.waitForDiagnostics(
        uri,
        (_diagnostics, message) => message.params.version === 2,
        "signed-zero fast-path diagnostics",
      );
      client.changeDocument({ uri, version: 2, text: source });
      assert(
        (await fastDiagnostics).params.diagnostics.length === 0,
        "signed-zero fast path published stale diagnostics",
      );
      const moved = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
        baseSnapshotId: initial.snapshot_id,
      });
      assert(
        moved.display?.kind === "translation_patch" &&
          moved.display.base_snapshot_id === initial.snapshot_id,
        `signed-zero edit broke the patch chain: ${JSON.stringify(moved.display)}`,
      );
      assertPosition(moved, "item", 5, 5, "signed-zero edit");

      const invalidSource = source.replace(
        'text!("Move me")',
        'missing!("Move me")',
      );
      const invalidDiagnostics = client.waitForDiagnostics(
        uri,
        (diagnostics, message) =>
          message.params.version === 3 && diagnostics.length > 0,
        "diagnostics after a retained position edit",
      );
      client.changeDocument({ uri, version: 3, text: invalidSource });
      await invalidDiagnostics;
      const invalid = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
        baseSnapshotId: moved.snapshot_id,
      });
      assert(
        invalid.stale === true &&
          Array.isArray(invalid.build_diagnostics) &&
          invalid.build_diagnostics.length > 0,
        `semantic rebuild after a retained edit lost diagnostics: ${JSON.stringify(invalid)}`,
      );
    });
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
}

async function testConnectorForcesFullDisplay() {
  const fixture = await mkdtemp(
    path.join(os.tmpdir(), "ss-lsp-manual-connector-"),
  );
  try {
    const slide = path.join(fixture, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    let source = `import std:themes/default as *

page demo
let source_item = text!("Source")
let target_item = text!("Target")
let edge = connect!(source_item, target_item)
~!~ source_item.left == page.left + 40
~!~ source_item.top == page.top - 100
~!~ target_item.left == page.left + 200
~!~ target_item.top == page.top - 100
end
`;
    await writeFile(path.join(fixture, "ss.toml"), `[project]
entry = "slide.ss"

[editor.lsp]
debounce = 0

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
        "connector fixture produced diagnostics",
      );

      const initial = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
      });
      const edgeTarget = editingTarget(initial, "edge");
      assert(
        typeof initial.display?.html === "string" &&
          initial.display.html.includes("ss-vector-path") &&
          initial.display.html.includes(
            `data-ss-node-id="${edgeTarget.node_id}"`,
          ),
        `connector fixture did not render its connector: ${JSON.stringify(initial.display)}`,
      );
      const target = editingTarget(initial, "target_item");
      const from = previewBounds(initial, target.node_id);
      const to = { ...from, x: 220, y: 120 };
      const edit = await requestEdit(
        client,
        uri,
        initial,
        target,
        from,
        to,
        "absolute",
        target.page_id,
      );
      assert(
        edit.status === "ok",
        `connector endpoint edit failed: ${JSON.stringify(edit)}`,
      );
      source = applyProtocolEdits(
        source,
        edit.workspaceEdit?.changes?.[uri] ?? [],
      );
      client.changeDocument({ uri, version: 2, text: source });

      const moved = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
        baseSnapshotId: initial.snapshot_id,
      });
      assert(
        moved.display?.schema === 2 &&
          moved.display?.kind !== "translation_patch" &&
          typeof moved.display?.html === "string",
        `connector endpoint movement reused stale HTML: ${JSON.stringify(moved.display)}`,
      );
      assertPosition(moved, "target_item", 220, 120, "connector endpoint edit");
    });
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
}

async function testReadlinesForcesFullDisplay() {
  const fixture = await mkdtemp(
    path.join(os.tmpdir(), "ss-lsp-manual-readlines-"),
  );
  try {
    const slide = path.join(fixture, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    let source = `import std:themes/default as *

page demo
let item = code_file!("snippet.txt", "plain")
~!~ item.left == page.left + 20
~!~ item.top == page.top - 40
end
`;
    const snippet = path.join(fixture, "snippet.txt");
    await writeFile(snippet, "ORIGINAL_EXTERNAL_INPUT\n", "utf8");
    await writeFile(path.join(fixture, "ss.toml"), `[project]
entry = "slide.ss"

[editor.lsp]
debounce = 0

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
        "readlines fixture produced diagnostics",
      );

      const initial = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
      });
      const target = editingTarget(initial, "item");
      const from = previewBounds(initial, target.node_id);
      const to = { ...from, x: 60, y: 80 };
      const edit = await requestEdit(
        client,
        uri,
        initial,
        target,
        from,
        to,
        "absolute",
        target.page_id,
      );
      assert(
        edit.status === "ok",
        `readlines position edit failed: ${JSON.stringify(edit)}`,
      );
      source = applyProtocolEdits(
        source,
        edit.workspaceEdit?.changes?.[uri] ?? [],
      );
      await writeFile(snippet, "UPDATED_EXTERNAL_INPUT\n", "utf8");
      client.changeDocument({ uri, version: 2, text: source });

      const moved = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
        baseSnapshotId: initial.snapshot_id,
      });
      assert(
        moved.display?.schema === 2 &&
          moved.display?.kind !== "translation_patch" &&
          typeof moved.display?.html === "string" &&
          moved.display.html.includes("UPDATED_EXTERNAL_INPUT"),
        `external evaluation input reused retained state: ${JSON.stringify(moved.display)}`,
      );
      assertPosition(moved, "item", 60, 80, "readlines edit");
    });
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
}

async function testPageSpaceFillForcesFullDisplay() {
  const fixture = await mkdtemp(
    path.join(os.tmpdir(), "ss-lsp-manual-page-fill-"),
  );
  try {
    const slide = path.join(fixture, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    let source = `import std:themes/default as *

page demo
let item = place!(rounded_rectangle(
  180,
  100,
  0.15,
  vector_style(
    linear_gradient_fill(
      c"#38bdf8",
      c"#4f46e5",
      gradient_down_right(),
      GradientSpread.pad,
      1,
      PaintSpace.page
    ),
    vector_stroke(c"#1e3a8a", 2)
  )
))
~!~ item.left == page.left + 40
~!~ item.top == page.top - 60
end
`;
    await writeFile(path.join(fixture, "ss.toml"), `[project]
entry = "slide.ss"

[editor.lsp]
debounce = 0

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
        "page-space fill fixture produced diagnostics",
      );

      const initial = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
      });
      assert(
        initial.display?.html?.includes("<linearGradient"),
        "page-space fill fixture did not render its gradient",
      );
      const target = editingTarget(initial, "item");
      const from = previewBounds(initial, target.node_id);
      const to = { ...from, x: 80, y: 100 };
      const edit = await requestEdit(
        client,
        uri,
        initial,
        target,
        from,
        to,
        "absolute",
        target.page_id,
      );
      assert(
        edit.status === "ok",
        `page-space fill position edit failed: ${JSON.stringify(edit)}`,
      );
      source = applyProtocolEdits(
        source,
        edit.workspaceEdit?.changes?.[uri] ?? [],
      );
      client.changeDocument({ uri, version: 2, text: source });

      const moved = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
        baseSnapshotId: initial.snapshot_id,
      });
      assert(
        moved.display?.schema === 2 &&
          moved.display?.kind !== "translation_patch" &&
          moved.display?.html?.includes("<linearGradient"),
        `page-space fill movement reused translated HTML: ${
          JSON.stringify(moved.display)
        }`,
      );
      assertPosition(moved, "item", 80, 100, "page-space fill edit");
    });
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
}

async function testWatchedModuleChangeForcesFullDisplay() {
  const fixture = await mkdtemp(
    path.join(os.tmpdir(), "ss-lsp-manual-watched-module-"),
  );
  try {
    const slide = path.join(fixture, "slide.ss");
    const module = path.join(fixture, "parts.ss");
    const uri = pathToFileURL(slide).toString();
    const moduleUri = pathToFileURL(module).toString();
    let source = `import std:themes/default as *
import "./parts" as *

page demo
let item = watched_item!()
~!~ item.left == page.left + 20
~!~ item.top == page.top - 40
end
`;
    const initialModuleSource = `import std:themes/default as *

fn watched_item!() -> Object
  return text!("Watched module", current_theme() with {
    body.text.color = c"#ff0000"
  })
end
`;
    const updatedModuleSource = initialModuleSource.replace(
      'c"#ff0000"',
      'c"#0000ff"',
    );
    await writeFile(path.join(fixture, "ss.toml"), `[project]
entry = "slide.ss"

[editor.lsp]
debounce = 5000

[editor.wysiwyg.refresh]
automatic = false
`, "utf8");
    await writeFile(slide, source, "utf8");
    await writeFile(module, initialModuleSource, "utf8");

    await withLspClient({ cwd: fixture }, async (client) => {
      await client.initialize();
      const initialDiagnostics = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      assert(
        (await initialDiagnostics).params.diagnostics.length === 0,
        "watched-module fixture produced diagnostics",
      );

      const initial = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
      });
      assert(
        initial.display?.html?.includes(
          "rgb(100.000000% 0.000000% 0.000000%)",
        ),
        `watched-module fixture did not render its initial color: ${JSON.stringify(initial.display)}`,
      );
      const target = editingTarget(initial, "item");
      const from = previewBounds(initial, target.node_id);
      const to = { ...from, x: 60, y: 80 };
      const edit = await requestEdit(
        client,
        uri,
        initial,
        target,
        from,
        to,
        "absolute",
        target.page_id,
      );
      assert(
        edit.status === "ok",
        `watched-module position edit failed: ${JSON.stringify(edit)}`,
      );
      source = applyProtocolEdits(
        source,
        edit.workspaceEdit?.changes?.[uri] ?? [],
      );

      await writeFile(module, updatedModuleSource, "utf8");
      client.notify("workspace/didChangeWatchedFiles", {
        changes: [{ uri: moduleUri, type: 2 }],
      });
      client.changeDocument({ uri, version: 2, text: source });

      const moved = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
        baseSnapshotId: initial.snapshot_id,
      });
      assert(
        moved.display?.schema === 2 &&
          moved.display?.kind !== "translation_patch" &&
          typeof moved.display?.html === "string" &&
          moved.display.html.includes(
            "rgb(0.000000% 0.000000% 100.000000%)",
          ) &&
          !moved.display.html.includes(
            "rgb(100.000000% 0.000000% 0.000000%)",
          ),
        `watched module change reused stale HTML: ${JSON.stringify(moved.display)}`,
      );
      assertPosition(moved, "item", 60, 80, "watched-module edit");
    });
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
}

async function testExternalVectorAssetForcesFullDisplay() {
  const fixture = await mkdtemp(
    path.join(os.tmpdir(), "ss-lsp-manual-vector-asset-"),
  );
  try {
    const slide = path.join(fixture, "slide.ss");
    const asset = path.join(fixture, "asset.svg");
    const uri = pathToFileURL(slide).toString();
    let source = `import std:themes/default as *

page demo
let item = image!("asset.svg")
~!~ item.left == page.left + 20
~!~ item.top == page.top - 40
~!~ item.width == 120
~!~ item.height == 60
end
`;
    const initialSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60" viewBox="0 0 120 60"><rect width="120" height="60" fill="#ff0000"/></svg>
`;
    const updatedSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60" viewBox="0 0 120 60"><rect width="120" height="60" fill="#0000ff"/><circle cx="60" cy="30" r="8" fill="#ffffff"/></svg>
`;
    await writeFile(path.join(fixture, "ss.toml"), `[project]
entry = "slide.ss"

[editor.lsp]
debounce = 0

[editor.wysiwyg.refresh]
automatic = false
`, "utf8");
    await writeFile(slide, source, "utf8");
    await writeFile(asset, initialSvg, "utf8");

    await withLspClient({ cwd: fixture }, async (client) => {
      await client.initialize();
      const initialDiagnostics = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      assert(
        (await initialDiagnostics).params.diagnostics.length === 0,
        "external-vector fixture produced diagnostics",
      );

      const initial = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
      });
      const initialAsset = initial.display?.assets?.find(
        (entry) => entry.kind === "svg",
      );
      assert(
        initialAsset &&
          typeof initial.display?.html === "string" &&
          initial.display.html.includes(initialAsset.relative_path),
        `external-vector fixture did not publish its SVG: ${JSON.stringify(initial.display)}`,
      );
      const target = editingTarget(initial, "item");
      const from = previewBounds(initial, target.node_id);
      const to = { ...from, x: 60, y: 80 };
      const edit = await requestEdit(
        client,
        uri,
        initial,
        target,
        from,
        to,
        "absolute",
        target.page_id,
      );
      assert(
        edit.status === "ok",
        `external-vector position edit failed: ${JSON.stringify(edit)}`,
      );
      source = applyProtocolEdits(
        source,
        edit.workspaceEdit?.changes?.[uri] ?? [],
      );
      await writeFile(asset, updatedSvg, "utf8");
      client.changeDocument({ uri, version: 2, text: source });

      const moved = await client.request("ss/editorSnapshot", {
        textDocument: { uri },
        baseSnapshotId: initial.snapshot_id,
      });
      const movedAsset = moved.display?.assets?.find(
        (entry) => entry.kind === "svg",
      );
      assert(
        moved.display?.schema === 2 &&
          moved.display?.kind !== "translation_patch" &&
          typeof moved.display?.html === "string" &&
          movedAsset &&
          movedAsset.digest !== initialAsset.digest &&
          moved.display.html.includes(movedAsset.relative_path),
        `external vector asset reused stale HTML: ${JSON.stringify(moved.display)}`,
      );
      assertPosition(moved, "item", 60, 80, "external-vector edit");
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
