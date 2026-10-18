#!/usr/bin/env node
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../../harness.mjs";
import { applyProtocolEdits, previewBounds, requestEdit } from "../support.mjs";

const project = await mkdtemp(path.join(os.tmpdir(), "ss-editor-icons-"));
try {
  const slide = path.join(project, "slide.ss");
  const uri = pathToFileURL(slide).toString();
  let source = `page icons
end
`;
  await writeFile(slide, source, "utf8");

  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    const catalog = await client.request("ss/iconCatalog", {
      query: "github",
      style: "brands",
      category: "all",
      offset: 0,
    });
    assert(
      catalog.collection === "fontawesome-free" &&
        typeof catalog.version === "string" && catalog.version.length > 0 &&
        catalog.offset === 0 &&
        catalog.total_available >= catalog.icons.length &&
        catalog.icons.some((entry) =>
          entry.id === "fa-brands:github" && entry.svg.includes("<svg")
        ),
      `icon catalog returned unexpected data: ${JSON.stringify(catalog)}`,
    );
    const firstPage = await client.request("ss/iconCatalog", {
      query: "",
      style: "all",
      category: "all",
      offset: 0,
    });
    const secondPage = await client.request("ss/iconCatalog", {
      query: "",
      style: "all",
      category: "all",
      offset: firstPage.icons.length,
    });
    const firstIds = new Set(firstPage.icons.map((entry) => entry.id));
    assert(
      firstPage.icons.length > 0 && firstPage.has_more &&
        secondPage.offset === firstPage.icons.length &&
        secondPage.icons.length > 0 &&
        secondPage.icons.every((entry) => !firstIds.has(entry.id)),
      `icon catalog paging overlapped or stopped early: ${JSON.stringify({ firstPage, secondPage })}`,
    );
    const animals = await client.request("ss/iconCatalog", {
      query: "",
      style: "solid",
      category: "animals",
      offset: 0,
    });
    assert(
      animals.category === "animals" &&
        animals.categories.some((entry) =>
          entry.id === "animals" && entry.label === "Animals"
        ) &&
        animals.icons.some((entry) => entry.id === "fa-solid:cat") &&
        animals.icons.some((entry) => entry.id === "fa-solid:dog"),
      `icon category metadata was not applied: ${JSON.stringify(animals)}`,
    );

    let diagnosticsPromise = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source });
    assert(
      (await diagnosticsPromise).params.diagnostics.length === 0,
      "empty icon page produced diagnostics",
    );
    const initial = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
    });
    const page = initial.layout.pages.find((candidate) => candidate.name === "icons");
    assert(page, `icon page was omitted: ${JSON.stringify(initial.layout.pages)}`);
    assert(
      initial.page_editing?.some((target) =>
        target.page_id === page.id && target.insert_icons
      ),
      `empty page omitted icon insertion capability: ${JSON.stringify(initial.page_editing)}`,
    );

    const unknown = await client.request("ss/insertIcon", {
      textDocument: { uri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      source: "fa-solid:not-an-icon",
      bounds: { x: 10, y: 10, width: 72, height: 72 },
      color: "#2563eb",
    });
    assert(unknown.status === "rejected", `an unknown icon was accepted: ${JSON.stringify(unknown)}`);

    const invalidColor = await client.request("ss/insertIcon", {
      textDocument: { uri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      source: "fa-solid:star",
      bounds: { x: 10, y: 10, width: 72, height: 72 },
      color: "blue",
    });
    assert(invalidColor.status === "rejected", `an invalid icon color was accepted: ${JSON.stringify(invalidColor)}`);

    const outsidePage = await client.request("ss/insertIcon", {
      textDocument: { uri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      source: "fa-solid:star",
      bounds: { x: 1240, y: 680, width: 72, height: 72 },
      color: "#2563eb",
    });
    assert(outsidePage.status === "rejected", `out-of-page icon bounds were accepted: ${JSON.stringify(outsidePage)}`);

    const insertion = await client.request("ss/insertIcon", {
      textDocument: { uri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      source: "fas:star",
      bounds: { x: 120, y: 140, width: 72, height: 80 },
      color: "#f59e0b",
    });
    assert(insertion.status === "ok", `icon insertion failed: ${JSON.stringify(insertion)}`);
    assert(
      insertion.selection?.binding === "icon_item",
      `icon insertion omitted its selection key: ${JSON.stringify(insertion)}`,
    );
    source = applyProtocolEdits(source, insertion.workspaceEdit?.changes?.[uri] ?? []);
    assert(
      source.includes('let icon_item = icon!("fa-solid:star", AssetBlockStyle {} with { asset.tint = c"#f59e0b" })') &&
        source.includes("~!~ icon_item.width == 72") &&
        source.includes("~!~ icon_item.height == 80") &&
        source.includes("~!~ icon_item.left == page.left + 120") &&
        source.includes("~!~ icon_item.top == page.top - 140"),
      `icon insertion emitted unexpected source: ${source}`,
    );

    diagnosticsPromise = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 2, text: source });
    assert(
      (await diagnosticsPromise).params.diagnostics.length === 0,
      "inserted icon source produced diagnostics",
    );
    const after = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: initial.snapshot_id,
    });
    const editing = after.editing?.find((target) => target.binding === "icon_item");
    assert(editing, `inserted icon was not editable: ${JSON.stringify(after)}`);
    const bounds = previewBounds(after, editing.node_id);
    assert(
      Math.abs(bounds.x - 120) < 0.1 && Math.abs(bounds.y - 140) < 0.1 &&
        Math.abs(bounds.width - 72) < 0.1 && Math.abs(bounds.height - 80) < 0.1,
      `inserted icon had unexpected bounds: ${JSON.stringify(bounds)}`,
    );
    assert(
      after.display.assets.some((asset) => asset.kind === "svg") &&
        after.display.html.includes("mask:url(") &&
        after.display.html.includes("background:rgb("),
      `icon display omitted its SVG resource or tint: ${JSON.stringify(after.display)}`,
    );

    const stale = await client.request("ss/insertIcon", {
      textDocument: { uri },
      snapshotId: initial.snapshot_id,
      pageId: page.id,
      source: "fa-regular:circle",
      bounds: { x: 220, y: 140, width: 72, height: 72 },
      color: "#2563eb",
    });
    assert(stale.status === "stale", `a stale icon insertion was accepted: ${JSON.stringify(stale)}`);

    const resizedBounds = { ...bounds, x: 200, y: 100 };
    const resize = await requestEdit(client, uri, after, editing, bounds, resizedBounds, "absolute", page.id);
    assert(resize.status === "ok", `typed icon resize failed: ${JSON.stringify(resize)}`);
    source = applyProtocolEdits(source, resize.workspaceEdit?.changes?.[uri] ?? []);
    assert(source.includes('asset.tint = c"#f59e0b"'), "resizing changed the immutable icon style");
    diagnosticsPromise = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 3, text: source });
    assert((await diagnosticsPromise).params.diagnostics.length === 0, "resized icon produced diagnostics");
    const resized = await client.request("ss/editorSnapshot", {
      textDocument: { uri }, baseSnapshotId: after.snapshot_id,
    });
    const target = resized.editing.find(item => item.binding === "icon_item");
    assert(target, "resized icon lost its editing target");
    const actual = previewBounds(resized, target.node_id);
    for (const key of ["x", "y", "width", "height"]) {
      assert(Math.abs(actual[key] - resizedBounds[key]) < 0.1, `resized icon ${key}: ${actual[key]}`);
    }
    const wider = { ...actual, width: 108 };
    const widthEdit = await requestEdit(client, uri, resized, target, actual, wider, "width", page.id);
    assert(widthEdit.status === "ok", `typed icon width edit failed: ${JSON.stringify(widthEdit)}`);
    source = applyProtocolEdits(source, widthEdit.workspaceEdit?.changes?.[uri] ?? []);
    assert(source.includes("~!~ icon_item.width == 108"), `icon width constraint was not updated: ${source}`);
    diagnosticsPromise = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 4, text: source });
    assert((await diagnosticsPromise).params.diagnostics.length === 0, "width-edited icon produced diagnostics");
    const final = await client.request("ss/editorSnapshot", {
      textDocument: { uri }, baseSnapshotId: resized.snapshot_id,
    });
    const finalTarget = final.editing.find(item => item.binding === "icon_item");
    assert(finalTarget, "width-edited icon lost its editing target");
    const finalBounds = previewBounds(final, finalTarget.node_id);
    for (const key of ["x", "y", "width", "height"]) {
      assert(Math.abs(finalBounds[key] - wider[key]) < 0.1, `width-edited icon ${key}: ${finalBounds[key]}`);
    }
  });
} finally {
  await rm(project, { recursive: true, force: true });
}
