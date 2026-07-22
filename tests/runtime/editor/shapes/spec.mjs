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

    const speechBubble = await client.request("ss/insertShape", {
      textDocument: { uri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      kind: "speech_bubble",
      bounds: { x: 80, y: 90, width: 180, height: 120 },
      fill: { enabled: true, color: "#e8f1ff", opacity: 1 },
      stroke: { enabled: true, color: "#2563eb", width: 1.6, style: "solid" },
    });
    assert(
      speechBubble.status === "ok" &&
        speechBubble.selection?.binding === "speech_bubble_item",
      `speech bubble insertion failed: ${JSON.stringify(speechBubble)}`,
    );
    const speechBubbleSource = applyProtocolEdits(
      source,
      speechBubble.workspaceEdit?.changes?.[uri] ?? [],
    );
    assert(
      speechBubbleSource.includes(
        "let speech_bubble_item = speech_bubble!(180, 120, VectorStyle",
      ) &&
        speechBubbleSource.includes(
          "~!~ speech_bubble_item.top == page.top - 90",
        ),
      `speech bubble insertion emitted unexpected source: ${speechBubbleSource}`,
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

  const lineSlide = path.join(project, "line-slide.ss");
  const lineUri = pathToFileURL(lineSlide).toString();
  let lineSource = `page lines
end
`;
  await writeFile(lineSlide, lineSource, "utf8");

  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    let diagnosticsPromise = client.waitForDiagnostics(lineUri);
    client.openDocument({ uri: lineUri, text: lineSource });
    assert(
      (await diagnosticsPromise).params.diagnostics.length === 0,
      "empty line page produced diagnostics",
    );
    const initial = await client.request("ss/editorSnapshot", {
      textDocument: { uri: lineUri },
    });
    const page = initial.layout.pages.find((candidate) => candidate.name === "lines");
    assert(page, `line page was omitted: ${JSON.stringify(initial.layout.pages)}`);

    const samePoint = await client.request("ss/insertShape", {
      textDocument: { uri: lineUri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      kind: "line",
      start: { x: 40, y: 50 },
      end: { x: 40, y: 50 },
      stroke: { enabled: true, color: "#2563eb", width: 2, style: "solid" },
    });
    assert(samePoint.status === "rejected", `a zero-length line was accepted: ${JSON.stringify(samePoint)}`);

    const outside = await client.request("ss/insertShape", {
      textDocument: { uri: lineUri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      kind: "line",
      start: { x: -1, y: 50 },
      end: { x: 80, y: 50 },
      stroke: { enabled: true, color: "#2563eb", width: 2, style: "solid" },
    });
    assert(outside.status === "rejected", `an out-of-page line was accepted: ${JSON.stringify(outside)}`);

    const invisible = await client.request("ss/insertShape", {
      textDocument: { uri: lineUri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      kind: "line",
      start: { x: 40, y: 50 },
      end: { x: 200, y: 50 },
      stroke: { enabled: false, color: "#2563eb", width: 2, style: "solid" },
    });
    assert(invisible.status === "rejected", `a line without a stroke was accepted: ${JSON.stringify(invisible)}`);

    const diagonal = await client.request("ss/insertShape", {
      textDocument: { uri: lineUri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      kind: "line",
      start: { x: 200, y: 150 },
      end: { x: 40, y: 50 },
      stroke: { enabled: true, color: "#2563eb", width: 2, style: "solid" },
    });
    assert(diagonal.status === "ok", `diagonal line insertion failed: ${JSON.stringify(diagonal)}`);
    const diagonalSource = applyProtocolEdits(
      lineSource,
      diagonal.workspaceEdit?.changes?.[lineUri] ?? [],
    );
    assert(
      diagonalSource.includes(
        "line!(160, 100, LineStyle { start_x = 1 start_y = 1 end_x = 0 end_y = 0 stroke = solid_stroke(c\"#2563eb\", 2) })",
      ),
      `diagonal line direction was lost: ${diagonalSource}`,
    );

    const vertical = await client.request("ss/insertShape", {
      textDocument: { uri: lineUri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      kind: "line",
      start: { x: 60, y: 40 },
      end: { x: 60, y: 200 },
      stroke: { enabled: true, color: "#2563eb", width: 2, style: "dotted" },
    });
    assert(vertical.status === "ok", `vertical line insertion failed: ${JSON.stringify(vertical)}`);
    const verticalSource = applyProtocolEdits(
      lineSource,
      vertical.workspaceEdit?.changes?.[lineUri] ?? [],
    );
    assert(
      verticalSource.includes(
        "line!(1, 160, LineStyle { start_x = 0.5 start_y = 0 end_x = 0.5 end_y = 1 stroke = dotted_stroke(c\"#2563eb\", 2) })",
      ),
      `vertical line coordinates were not preserved: ${verticalSource}`,
    );

    const insertion = await client.request("ss/insertShape", {
      textDocument: { uri: lineUri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      kind: "line",
      start: { x: 40, y: 50 },
      end: { x: 200, y: 50 },
      stroke: { enabled: true, color: "#2563eb", width: 2, style: "dashed" },
    });
    assert(insertion.status === "ok", `line insertion failed: ${JSON.stringify(insertion)}`);
    assert(
      insertion.selection?.binding === "line_item",
      `line insertion omitted its selection key: ${JSON.stringify(insertion)}`,
    );
    lineSource = applyProtocolEdits(
      lineSource,
      insertion.workspaceEdit?.changes?.[lineUri] ?? [],
    );
    assert(
      lineSource.includes(
        "let line_item = line!(160, 1, LineStyle { start_x = 0 start_y = 0.5 end_x = 1 end_y = 0.5 stroke = dashed_stroke(c\"#2563eb\", 2) })",
      ) &&
        lineSource.includes("~!~ line_item.left == page.left + 40") &&
        lineSource.includes("~!~ line_item.top == page.top - 49.5") &&
        !lineSource.includes("fill ="),
      `line insertion emitted unexpected source: ${lineSource}`,
    );

    diagnosticsPromise = client.waitForDiagnostics(lineUri);
    client.changeDocument({ uri: lineUri, version: 2, text: lineSource });
    assert(
      (await diagnosticsPromise).params.diagnostics.length === 0,
      "inserted line source produced diagnostics",
    );
    const afterInsertion = await client.request("ss/editorSnapshot", {
      textDocument: { uri: lineUri },
      baseSnapshotId: initial.snapshot_id,
    });
    assert(
      afterInsertion.display?.schema === 2 &&
        afterInsertion.display.html?.includes("ss-vector-path"),
      `inserted line was not rebuilt as a rendered vector path: ${JSON.stringify(afterInsertion.display)}`,
    );
    const line = afterInsertion.shape_editing?.find((target) =>
      target.binding === "line_item"
    );
    assert(line?.kind === "line", `inserted line was not style-editable: ${JSON.stringify(line)}`);
    assert(!Object.hasOwn(line, "fill"), `line capability exposed a fill: ${JSON.stringify(line)}`);
    assert(
      line.start?.x === 0 && line.start?.y === 0.5,
      `line start was not normalized: ${JSON.stringify(line.start)}`,
    );
    assert(
      line.end?.x === 1 && line.end?.y === 0.5,
      `line end was not normalized: ${JSON.stringify(line.end)}`,
    );
    const bounds = previewBounds(afterInsertion, line.node_id);
    assert(
      Math.abs(bounds.x - 40) < 0.1 && Math.abs(bounds.y - 49.5) < 0.1 &&
        Math.abs(bounds.width - 160) < 0.1 && Math.abs(bounds.height - 1) < 0.1,
      `inserted line had unexpected bounds: ${JSON.stringify(bounds)}`,
    );

    const staleGeometry = await client.request("ss/editLineGeometry", {
      textDocument: { uri: lineUri },
      snapshotId: initial.snapshot_id,
      pageId: line.page_id,
      nodeId: line.node_id,
      start: { x: 250, y: 80 },
      end: { x: 70, y: 80 },
    });
    assert(
      staleGeometry.status === "stale",
      `stale line geometry was accepted: ${JSON.stringify(staleGeometry)}`,
    );

    const sameGeometryPoint = await client.request("ss/editLineGeometry", {
      textDocument: { uri: lineUri },
      snapshotId: afterInsertion.snapshot_id,
      pageId: line.page_id,
      nodeId: line.node_id,
      start: { x: 80, y: 90 },
      end: { x: 80, y: 90 },
    });
    assert(
      sameGeometryPoint.status === "rejected",
      `zero-length line geometry was accepted: ${JSON.stringify(sameGeometryPoint)}`,
    );

    const outsideGeometry = await client.request("ss/editLineGeometry", {
      textDocument: { uri: lineUri },
      snapshotId: afterInsertion.snapshot_id,
      pageId: line.page_id,
      nodeId: line.node_id,
      start: { x: -1, y: 90 },
      end: { x: 80, y: 90 },
    });
    assert(
      outsideGeometry.status === "rejected",
      `out-of-page line geometry was accepted: ${JSON.stringify(outsideGeometry)}`,
    );

    const wrongPageGeometry = await client.request("ss/editLineGeometry", {
      textDocument: { uri: lineUri },
      snapshotId: afterInsertion.snapshot_id,
      pageId: line.page_id + 1,
      nodeId: line.node_id,
      start: { x: 250, y: 80 },
      end: { x: 70, y: 80 },
    });
    assert(
      wrongPageGeometry.status === "stale",
      `line geometry for the wrong page was accepted: ${JSON.stringify(wrongPageGeometry)}`,
    );

    const horizontalGeometry = await client.request("ss/editLineGeometry", {
      textDocument: { uri: lineUri },
      snapshotId: afterInsertion.snapshot_id,
      pageId: line.page_id,
      nodeId: line.node_id,
      start: { x: 250, y: 80 },
      end: { x: 70, y: 80 },
    });
    assert(
      horizontalGeometry.status === "ok",
      `horizontal line geometry edit failed: ${JSON.stringify(horizontalGeometry)}`,
    );
    const horizontalSource = applyProtocolEdits(
      lineSource,
      horizontalGeometry.workspaceEdit?.changes?.[lineUri] ?? [],
    );
    assert(
      horizontalSource.includes(
        "line!(180, 1, LineStyle { start_x = 1 start_y = 0.5 end_x = 0 end_y = 0.5",
      ) &&
        horizontalSource.includes("~!~ line_item.left == page.left + 70") &&
        horizontalSource.includes("~!~ line_item.top == page.top - 79.5"),
      `horizontal line geometry lost order or position: ${horizontalSource}`,
    );

    const verticalGeometry = await client.request("ss/editLineGeometry", {
      textDocument: { uri: lineUri },
      snapshotId: afterInsertion.snapshot_id,
      pageId: line.page_id,
      nodeId: line.node_id,
      start: { x: 60, y: 220 },
      end: { x: 60, y: 40 },
    });
    assert(
      verticalGeometry.status === "ok",
      `vertical line geometry edit failed: ${JSON.stringify(verticalGeometry)}`,
    );
    const editedVerticalSource = applyProtocolEdits(
      lineSource,
      verticalGeometry.workspaceEdit?.changes?.[lineUri] ?? [],
    );
    assert(
      editedVerticalSource.includes(
        "line!(1, 180, LineStyle { start_x = 0.5 start_y = 1 end_x = 0.5 end_y = 0",
      ) &&
        editedVerticalSource.includes("~!~ line_item.left == page.left + 59.5") &&
        editedVerticalSource.includes("~!~ line_item.top == page.top - 40"),
      `vertical line geometry lost order or position: ${editedVerticalSource}`,
    );

    const boundaryGeometry = await client.request("ss/editLineGeometry", {
      textDocument: { uri: lineUri },
      snapshotId: afterInsertion.snapshot_id,
      pageId: line.page_id,
      nodeId: line.node_id,
      start: { x: page.width, y: page.height },
      end: { x: 0, y: 0 },
    });
    assert(
      boundaryGeometry.status === "ok",
      `page-boundary line geometry edit failed: ${JSON.stringify(boundaryGeometry)}`,
    );
    const boundarySource = applyProtocolEdits(
      lineSource,
      boundaryGeometry.workspaceEdit?.changes?.[lineUri] ?? [],
    );
    assert(
      boundarySource.includes(
        `line!(${page.width}, ${page.height}, LineStyle { start_x = 1 start_y = 1 end_x = 0 end_y = 0`,
      ) &&
        /~!~ line_item\.left == page\.left\s*\n/.test(boundarySource) &&
        /~!~ line_item\.top == page\.top\s*\n/.test(boundarySource),
      `page-boundary line geometry changed its exact endpoints: ${boundarySource}`,
    );

    const invisibleStyle = await client.request("ss/shapeStyleEdit", {
      textDocument: { uri: lineUri },
      snapshotId: afterInsertion.snapshot_id,
      pageId: line.page_id,
      nodeId: line.node_id,
      stroke: { enabled: false, color: "#2563eb", width: 2, style: "solid" },
    });
    assert(
      invisibleStyle.status === "rejected",
      `a line style without a stroke was accepted: ${JSON.stringify(invisibleStyle)}`,
    );

    const style = await client.request("ss/shapeStyleEdit", {
      textDocument: { uri: lineUri },
      snapshotId: afterInsertion.snapshot_id,
      pageId: line.page_id,
      nodeId: line.node_id,
      stroke: { enabled: true, color: "#dc2626", width: 3, style: "dotted" },
    });
    assert(style.status === "ok", `line style edit failed: ${JSON.stringify(style)}`);
    const styleEdits = style.workspaceEdit?.changes?.[lineUri] ?? [];
    assert(styleEdits.length === 1, `line style edit changed more than its stroke: ${JSON.stringify(styleEdits)}`);
    lineSource = applyProtocolEdits(lineSource, styleEdits);
    assert(
      lineSource.includes("stroke = dotted_stroke(c\"#dc2626\", 3)") &&
        !lineSource.includes("fill ="),
      `line style edit changed unexpected source: ${lineSource}`,
    );
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
