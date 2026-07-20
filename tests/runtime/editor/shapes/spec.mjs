#!/usr/bin/env node
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../../harness.mjs";
import { applyProtocolEdits, previewBounds } from "../support.mjs";

const project = await mkdtemp(path.join(os.tmpdir(), "ss-editor-shapes-"));
try {
  const slide = path.join(project, "slide.ss");
  const uri = pathToFileURL(slide).toString();
  let source = `page shapes
end
`;
  await writeFile(slide, source, "utf8");

  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    let diagnosticsPromise = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source });
    assert(
      (await diagnosticsPromise).params.diagnostics.length === 0,
      "empty shape page produced diagnostics",
    );

    const initial = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
    });
    const page = initial.layout.pages.find((candidate) =>
      candidate.name === "shapes"
    );
    assert(page, `shape page was omitted: ${JSON.stringify(initial.layout.pages)}`);
    assert(
      initial.page_editing?.some((target) =>
        target.page_id === page.id && target.insert_shapes
      ),
      `empty page omitted shape insertion capability: ${JSON.stringify(initial.page_editing)}`,
    );

    const invalidCircle = await client.request("ss/insertShape", {
      textDocument: { uri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      kind: "circle",
      bounds: { x: 10, y: 10, width: 80, height: 70 },
      fill: { enabled: true, color: "#ffffff", opacity: 1 },
      stroke: { enabled: true, color: "#000000", width: 1, style: "solid" },
    });
    assert(
      invalidCircle.status === "rejected",
      `a non-square circle was accepted: ${JSON.stringify(invalidCircle)}`,
    );

    const invisible = await client.request("ss/insertShape", {
      textDocument: { uri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      kind: "rectangle",
      bounds: { x: 10, y: 10, width: 80, height: 70 },
      fill: { enabled: false, color: "#ffffff", opacity: 1 },
      stroke: { enabled: false, color: "#000000", width: 1, style: "solid" },
    });
    assert(
      invisible.status === "rejected",
      `a shape without fill or stroke was accepted: ${JSON.stringify(invisible)}`,
    );

    const insertion = await client.request("ss/insertShape", {
      textDocument: { uri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      kind: "rectangle",
      bounds: { x: 120, y: 140, width: 180, height: 110 },
      fill: { enabled: true, color: "#e8f1ff", opacity: 0.75 },
      stroke: { enabled: true, color: "#2563eb", width: 2, style: "dashed" },
    });
    assert(insertion.status === "ok", `shape insertion failed: ${JSON.stringify(insertion)}`);
    assert(
      insertion.selection?.binding === "rectangle_item",
      `shape insertion omitted its selection key: ${JSON.stringify(insertion)}`,
    );
    source = applyProtocolEdits(
      source,
      insertion.workspaceEdit?.changes?.[uri] ?? [],
    );
    assert(
      source.includes("let rectangle_item = rectangle!(180, 110, VectorStyle") &&
        source.includes("fill = solid_fill(c\"#e8f1ff\", 0.75)") &&
        source.includes("stroke = dashed_stroke(c\"#2563eb\", 2)") &&
        source.includes("~!~ rectangle_item.top == page.top - 140"),
      `shape insertion emitted unexpected source: ${source}`,
    );

    diagnosticsPromise = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 2, text: source });
    assert(
      (await diagnosticsPromise).params.diagnostics.length === 0,
      "inserted shape source produced diagnostics",
    );
    const afterInsertion = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: initial.snapshot_id,
    });
    assert(
      afterInsertion.display?.schema === 2,
      `shape insertion incorrectly returned a translation patch: ${JSON.stringify(afterInsertion.display)}`,
    );
    const shape = afterInsertion.shape_editing?.find((target) =>
      target.binding === "rectangle_item"
    );
    assert(
      shape,
      `inserted rectangle was not style-editable: ${JSON.stringify({
        shape_editing: afterInsertion.shape_editing,
        editing: afterInsertion.editing,
        source,
      })}`,
    );
    assert(
      shape.stroke.style === "dashed",
      `inserted stroke style was not reflected in the snapshot: ${JSON.stringify(shape.stroke)}`,
    );
    const bounds = previewBounds(afterInsertion, shape.node_id);
    assert(
      Math.abs(bounds.x - 120) < 0.1 && Math.abs(bounds.y - 140) < 0.1 &&
        Math.abs(bounds.width - 180) < 0.1 && Math.abs(bounds.height - 110) < 0.1,
      `inserted rectangle had unexpected bounds: ${JSON.stringify(bounds)}`,
    );

    const style = await client.request("ss/shapeStyleEdit", {
      textDocument: { uri },
      snapshotId: afterInsertion.snapshot_id,
      pageId: shape.page_id,
      nodeId: shape.node_id,
      fill: { enabled: true, color: "#f59e0b", opacity: 0.4 },
      stroke: { enabled: true, color: "#2563eb", width: 2, style: "dotted" },
    });
    assert(style.status === "ok", `shape style edit failed: ${JSON.stringify(style)}`);
    source = applyProtocolEdits(source, style.workspaceEdit?.changes?.[uri] ?? []);
    assert(
      source.includes("fill = solid_fill(c\"#f59e0b\", 0.4)") &&
        source.includes("stroke = dotted_stroke(c\"#2563eb\", 2)"),
      `shape style edit changed unexpected source: ${source}`,
    );

    diagnosticsPromise = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 3, text: source });
    assert(
      (await diagnosticsPromise).params.diagnostics.length === 0,
      "shape style source edit produced diagnostics",
    );
    const afterStyle = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: afterInsertion.snapshot_id,
    });
    assert(
      afterStyle.display?.schema === 2,
      `shape style edit incorrectly returned a translation patch: ${JSON.stringify(afterStyle.display)}`,
    );
    const styled = afterStyle.shape_editing?.find((target) =>
      target.binding === "rectangle_item"
    );
    assert(
      styled?.fill.color === "#f59e0b" &&
        Math.abs(styled.fill.opacity - 0.4) < 0.001 &&
        styled.stroke.enabled === true &&
        styled.stroke.style === "dotted",
      `updated shape style was not reflected in the snapshot: ${JSON.stringify(styled)}`,
    );

    const stale = await client.request("ss/insertShape", {
      textDocument: { uri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      kind: "circle",
      bounds: { x: 40, y: 40, width: 80, height: 80 },
      fill: { enabled: true, color: "#ffffff", opacity: 1 },
      stroke: { enabled: true, color: "#000000", width: 1, style: "solid" },
    });
    assert(stale.status === "stale", `stale shape request was accepted: ${JSON.stringify(stale)}`);
  });

  const importedSlide = path.join(project, "imported-slide.ss");
  const importedPage = path.join(project, "imported-page.ss");
  const importedUri = pathToFileURL(importedSlide).toString();
  const importedPageUri = pathToFileURL(importedPage).toString();
  const importedSource = `import ./imported-page as *
`;
  await writeFile(importedSlide, importedSource, "utf8");
  await writeFile(importedPage, `page imported_shapes
  let arrow_shape_item = rectangle!(20, 20)
  ~ arrow_shape_item.left == page.left + 10
end
`, "utf8");

  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    const diagnosticsPromise = client.waitForDiagnostics(importedUri);
    client.openDocument({ uri: importedUri, text: importedSource });
    assert(
      (await diagnosticsPromise).params.diagnostics.length === 0,
      "imported shape page produced diagnostics",
    );

    const snapshot = await client.request("ss/editorSnapshot", {
      textDocument: { uri: importedUri },
    });
    const page = snapshot.layout.pages.find((candidate) =>
      candidate.name === "imported_shapes"
    );
    assert(page, `imported page was omitted: ${JSON.stringify(snapshot.layout.pages)}`);
    assert(
      snapshot.page_editing?.some((target) =>
        target.page_id === page.id && target.insert_shapes
      ),
      `imported page omitted shape insertion capability: ${JSON.stringify(snapshot.page_editing)}`,
    );

    const insertion = await client.request("ss/insertShape", {
      textDocument: { uri: importedUri },
      snapshotId: snapshot.snapshot_id,
      pageId: page.id,
      kind: "arrow",
      bounds: { x: 30, y: 50, width: 170, height: 90 },
      fill: { enabled: true, color: "#fef3c7", opacity: 1 },
      stroke: { enabled: true, color: "#92400e", width: 1.5, style: "dash_dot" },
    });
    assert(insertion.status === "ok", `imported page insertion failed: ${JSON.stringify(insertion)}`);
    assert(
      insertion.selection?.binding === "arrow_shape_item_2",
      `imported page insertion did not avoid a binding collision: ${JSON.stringify(insertion.selection)}`,
    );
    const edits = insertion.workspaceEdit?.changes ?? {};
    assert(
      !Object.hasOwn(edits, importedUri) && Object.hasOwn(edits, importedPageUri),
      `imported page edit targeted the wrong source: ${JSON.stringify(edits)}`,
    );
    const pageSource = await readFile(importedPage, "utf8");
    const edited = applyProtocolEdits(pageSource, edits[importedPageUri]);
    assert(
      edited.includes("let arrow_shape_item_2 = arrow_shape!(170, 90, VectorStyle"),
      `imported page received unexpected source: ${edited}`,
    );
    assert(
      edited.includes("dash_dot_stroke(c\"#92400e\", 1.5)"),
      `imported page omitted its dash-dot stroke: ${edited}`,
    );
    assert(
      edited.indexOf("let arrow_shape_item_2") <
        edited.indexOf("~ arrow_shape_item.left == page.left + 10"),
      `shape insertion followed an existing constraint: ${edited}`,
    );

    await writeFile(importedPage, `${pageSource}# changed after snapshot\n`, "utf8");
    const changedDependency = await client.request("ss/insertShape", {
      textDocument: { uri: importedUri },
      snapshotId: snapshot.snapshot_id,
      pageId: page.id,
      kind: "circle",
      bounds: { x: 220, y: 50, width: 80, height: 80 },
      fill: { enabled: true, color: "#ffffff", opacity: 1 },
      stroke: { enabled: true, color: "#000000", width: 1, style: "solid" },
    });
    assert(
      changedDependency.status === "stale",
      `an externally changed imported source was edited: ${JSON.stringify(changedDependency)}`,
    );
  });
} finally {
  await rm(project, { recursive: true, force: true });
}
