#!/usr/bin/env node
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "./lsp_harness.mjs";

await testPreviewSnapshotReflectsOpenDocument();
await testPreviewSnapshotPreservesTextLineLayout();
await testPreviewSnapshotUsesTreeSitterCodeHighlighting();
await testPreviewSnapshotReturnsImageResources();
await testPreviewSnapshotReturnsLayoutRelations();
await testLayoutEditInsertsAbsoluteTopLeftConstraints();
await testLayoutEditUpdatesRelativeRelation();
await testLayoutEditMovesFlowObjectWithTableContent();
await testLayoutEditFindsGeneratedPageSourceBlock();
await testLayoutEditRejectsStaleAndUnsupportedRequests();
await testPreviewSnapshotReturnsDiagnostics();

async function testPreviewSnapshotReflectsOpenDocument() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-snapshot-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const initial = `import std:themes/default as *

page sample
let a = text!("A")
end
`;
    const changed = `import std:themes/default as *

page sample
let a = text!("A")
let b = text!("B")
end
`;
    await writeFile(slide, initial, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: initial, version: 1 });
      await diagnosticsPromise;

      const first = await previewSnapshot(client, uri, 1);
      assert(first.pages.length === 1, `snapshot did not include one page: ${JSON.stringify(first)}`);
      assert(first.objects.some((object) => object.label === "a"), `snapshot did not expose variable label a: ${JSON.stringify(first.objects)}`);
      assert(first.objects.every((object) => !Object.prototype.hasOwnProperty.call(object, "contentPreview")), "snapshot unexpectedly included contentPreview");
      assert(first.display?.pages?.length === 1, `snapshot did not include one display page: ${JSON.stringify(first.display)}`);
      assert(displayPageContainsText(first.display.pages[0], "A"), `snapshot display did not include text content A: ${JSON.stringify(first.display.pages[0].items)}`);
      assert(Array.isArray(first.display.resources), `snapshot display resources were missing: ${JSON.stringify(first.display)}`);

      client.changeDocument({ uri, version: 2, text: changed });
      const second = await previewSnapshot(client, uri, 2);
      assert(second.objects.some((object) => object.label === "b"), `snapshot did not reflect unsaved document text: ${JSON.stringify(second.objects)}`);
      assert(displayPageContainsText(second.display.pages[0], "B"), `snapshot display did not reflect unsaved text B: ${JSON.stringify(second.display.pages[0].items)}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testPreviewSnapshotPreservesTextLineLayout() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-lines-"));
  try {
    const slide = path.join(project, "slide.ss");
    const snippet = path.join(project, "snippet.txt");
    const uri = pathToFileURL(slide).toString();
    const source = `import std:themes/default as *

page sample
let c = code_file!("snippet.txt", "plain")
end
`;
    await writeFile(slide, source, "utf8");
    await writeFile(snippet, "one\n  two", "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      await diagnosticsPromise;

      const snapshot = await previewSnapshot(client, uri, 1);
      const target = snapshot.objects.find((object) => object.label === "c");
      assert(target, `code object c was missing: ${JSON.stringify(snapshot.objects)}`);
      const displayPage = snapshot.display?.pages?.[0];
      assert(displayPage, `snapshot did not include display page: ${JSON.stringify(snapshot.display)}`);
      const textItem = displayPage.items.find((item) => item.type === "text" && item.nodeId === target.id);
      assert(textItem, `display did not include code text item: ${JSON.stringify(displayPage.items)}`);
      assert(textItem.lines.length >= 2, `code text did not preserve physical lines: ${JSON.stringify(textItem)}`);
      const first = lineText(textItem.lines[0]);
      const second = lineText(textItem.lines[1]);
      assert(first.includes("one"), `first code line was wrong: ${JSON.stringify(textItem.lines)}`);
      assert(second.includes("two"), `second code line was wrong: ${JSON.stringify(textItem.lines)}`);
      assert(textItem.lines.every((line) => typeof line.lineHeight === "number" && line.lineHeight > 0), `lineHeight was not serialized: ${JSON.stringify(textItem.lines)}`);
      assert(near(textItem.lines[1].baselineY - textItem.lines[0].baselineY, textItem.lines[0].lineHeight), `baseline delta did not match lineHeight: ${JSON.stringify(textItem.lines)}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testPreviewSnapshotUsesTreeSitterCodeHighlighting() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-highlight-"));
  try {
    const slide = path.join(project, "slide.ss");
    const config = path.join(project, "ss.toml");
    const uri = pathToFileURL(slide).toString();
    const source = `import std:themes/default as *

document
  code_theme_all(code_theme_one_dark())
end

page sample
let c = code!("fn demo() -> Void\\n  return\\nend", "ss")
end
`;
    await writeFile(config, `[project]
entry = "slide.ss"

[highlight.languages.ss]
parser = "ss"
query = "builtin:ss"
`, "utf8");
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      await diagnosticsPromise;

      const snapshot = await previewSnapshot(client, uri, 1);
      const target = snapshot.objects.find((object) => object.label === "c");
      assert(target, `highlighted code object c was missing: ${JSON.stringify(snapshot.objects)}`);
      const displayPage = snapshot.display?.pages?.[0];
      assert(displayPage, `snapshot did not include display page: ${JSON.stringify(snapshot.display)}`);
      const textItem = displayPage.items.find((item) => item.type === "text" && item.nodeId === target.id);
      assert(textItem, `display did not include highlighted code text item: ${JSON.stringify(displayPage.items)}`);
      const firstCodeLine = textItem.lines.find((line) => lineText(line).includes("fn demo"));
      assert(firstCodeLine, `display did not include the first ss code line: ${JSON.stringify(textItem.lines)}`);
      const glyphs = glyphSpans(firstCodeLine);
      assert(glyphs.some((span) => span.text === "fn"), `ss keyword token was not split into its own span: ${JSON.stringify(firstCodeLine.spans)}`);
      const colors = new Set(glyphs.map((span) => colorKey(span.color)));
      assert(colors.size >= 2, `Tree-sitter highlighting did not produce multiple code colors: ${JSON.stringify(firstCodeLine.spans)}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testPreviewSnapshotReturnsImageResources() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-image-"));
  try {
    const slide = path.join(project, "slide.ss");
    const image = path.join(project, "image.svg");
    const uri = pathToFileURL(slide).toString();
    const source = `import std:themes/default as *

page sample
let img = image!("image.svg")
end
`;
    await writeFile(slide, source, "utf8");
    await writeFile(image, `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="32" viewBox="0 0 64 32"><rect width="64" height="32" fill="red"/></svg>`, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      await diagnosticsPromise;

      const snapshot = await previewSnapshot(client, uri, 1);
      const target = snapshot.objects.find((object) => object.label === "img");
      assert(target, `image object img was missing: ${JSON.stringify(snapshot.objects)}`);
      const displayPage = snapshot.display?.pages?.[0];
      assert(displayPage, `snapshot did not include display page: ${JSON.stringify(snapshot.display)}`);
      const item = displayPage.items.find((candidate) => candidate.type === "resource" && candidate.nodeId === target.id);
      assert(item, `display did not include image resource item: ${JSON.stringify(displayPage.items)}`);
      const resource = snapshot.display.resources.find((candidate) => candidate.id === item.resourceId);
      assert(resource, `image resource was missing: ${JSON.stringify(snapshot.display.resources)}`);
      assert(resource.kind === "svg", `image resource kind was not svg: ${JSON.stringify(resource)}`);
      assert(path.isAbsolute(resource.path), `image resource path was not absolute: ${JSON.stringify(resource)}`);
      assert(resource.path === image, `image resource path did not point to the source SVG: ${JSON.stringify(resource)}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testPreviewSnapshotReturnsLayoutRelations() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-relations-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `import std:themes/default as *

page sample
let a = text!("A")
let b = text!("B")
~ b.left == a.right + 10
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      await diagnosticsPromise;

      const snapshot = await previewSnapshot(client, uri, 1);
      const a = snapshot.objects.find((object) => object.label === "a");
      const b = snapshot.objects.find((object) => object.label === "b");
      assert(a && b, `objects were missing: ${JSON.stringify(snapshot.objects)}`);
      assert(Array.isArray(snapshot.relations), `relations were missing: ${JSON.stringify(snapshot)}`);
      assert(snapshot.relations.some((relation) =>
        relation.kind === "explicit" &&
        relation.targetNode === b.id &&
        relation.targetAnchor === "left" &&
        relation.sourceNode === a.id &&
        relation.sourceAnchor === "right"
      ), `explicit relation was missing: ${JSON.stringify(snapshot.relations)}`);
      assert(snapshot.relations.some((relation) => relation.kind === "fallback"), `fallback relation was missing: ${JSON.stringify(snapshot.relations)}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testLayoutEditInsertsAbsoluteTopLeftConstraints() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-edit-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `import std:themes/default as *

page sample
let a = text!("A")
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      await diagnosticsPromise;

      const snapshot = await previewSnapshot(client, uri, 1);
      const target = snapshot.objects.find((object) => object.label === "a");
      assert(target, `editable object a was missing: ${JSON.stringify(snapshot.objects)}`);
      assert(target.interaction?.movable === true, `object a was not movable: ${JSON.stringify(target)}`);

      const toBounds = { ...target.frame, x: 120, y: 80 };
      const result = await layoutEdit(client, uri, 1, snapshot.snapshotId, target, toBounds);
      assert(result.status === "ok", `layoutEdit did not return ok: ${JSON.stringify(result)}`);

      const edited = applyWorkspaceEdit(source, result.workspaceEdit, uri);
      assert(edited.includes("!~ a.horizontal"), `horizontal discard was not inserted: ${edited}`);
      assert(edited.includes("~ a.left == page.left + 120"), `left constraint was not inserted: ${edited}`);
      assert(edited.includes("!~ a.vertical"), `vertical discard was not inserted: ${edited}`);
      assert(edited.includes("~ a.top == page.top - 80"), `top constraint was not inserted: ${edited}`);

      client.changeDocument({ uri, version: 2, text: edited });
      const next = await previewSnapshot(client, uri, 2);
      const moved = next.objects.find((object) => object.label === "a");
      assert(moved, `moved object a was missing: ${JSON.stringify(next.objects)}`);
      assert(near(moved.frame.x, 120) && near(moved.frame.y, 80), `moved frame was not applied: ${JSON.stringify(moved.frame)}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testLayoutEditUpdatesRelativeRelation() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-relative-edit-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `import std:themes/default as *

page sample
let a = text!("A")
let b = text!("B")
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      await diagnosticsPromise;

      const snapshot = await previewSnapshot(client, uri, 1);
      const target = snapshot.objects.find((object) => object.label === "b");
      assert(target, `target b was missing: ${JSON.stringify(snapshot.objects)}`);
      assert(snapshot.relations.some((relation) => relation.kind === "fallback" && relation.targetNode === target.id && relation.axis === "vertical"), `vertical fallback relation was missing: ${JSON.stringify(snapshot.relations)}`);
      const toBounds = { ...target.frame, y: target.frame.y + 24 };
      const result = await layoutEdit(client, uri, 1, snapshot.snapshotId, target, toBounds, "relative");
      assert(result.status === "ok", `relative layoutEdit did not return ok: ${JSON.stringify(result)}`);

      const edited = applyWorkspaceEdit(source, result.workspaceEdit, uri);
      assert(edited.includes("!~ b.top"), `relative top discard was not inserted: ${edited}`);
      assert(/~ b\.top == a\.bottom [+-] /.test(edited), `relative top constraint was not inserted: ${edited}`);

      client.changeDocument({ uri, version: 2, text: edited });
      const next = await previewSnapshot(client, uri, 2);
      const moved = next.objects.find((object) => object.label === "b");
      assert(moved, `moved object b was missing: ${JSON.stringify(next.objects)}`);
      assert(near(moved.frame.y, toBounds.y), `relative edit did not move b to requested y: ${JSON.stringify(moved.frame)} expected=${JSON.stringify(toBounds)}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testLayoutEditMovesFlowObjectWithTableContent() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-table-edit-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `import std:themes/default as *

page sample
let t0 = text! <<
**render**
- a
- b
>>

let t2 = text! <<
| Phase | 初回 | 初回 (並列) | 2回目 | 1箇所変更 |
|--------|:------|:------  |:------| :----|
| Typecheck | 35 | 37 | 36 | 34 |
| Evaluate  | 33 | 29 | 30 | 30 |
| Solve  | 188 | 177 | 179 | 184 |
| Render  | 2320 | 911 | 82 | 84 |
>>

t2.text_markdown_table_cell_pad_x = 5
t2.text_markdown_table_cell_pad_y = 3
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      await diagnosticsPromise;

      const snapshot = await previewSnapshot(client, uri, 1);
      const target = snapshot.objects.find((object) => object.label === "t2");
      assert(target, `table object t2 was missing: ${JSON.stringify(snapshot.objects)}`);
      const toBounds = { ...target.frame, x: target.frame.x + 50, y: target.frame.y + 30 };
      const result = await layoutEdit(client, uri, 1, snapshot.snapshotId, target, toBounds);
      assert(result.status === "ok", `layoutEdit rejected table flow object: ${JSON.stringify(result)}`);

      const edited = applyWorkspaceEdit(source, result.workspaceEdit, uri);
      assert(edited.includes("!~ t2.horizontal"), `horizontal discard was not inserted for t2: ${edited}`);
      assert(edited.includes("~ t2.left == page.left + 146"), `left constraint was not inserted for t2: ${edited}`);
      assert(edited.includes("!~ t2.vertical"), `vertical discard was not inserted for t2: ${edited}`);
      assert(edited.includes("~ t2.top == page.top - 238.4"), `top constraint was not inserted for t2: ${edited}`);

      client.changeDocument({ uri, version: 2, text: edited });
      const next = await previewSnapshot(client, uri, 2);
      const moved = next.objects.find((object) => object.label === "t2");
      assert(moved, `moved table object t2 was missing: ${JSON.stringify(next.objects)}`);
      assert(near(moved.frame.x, toBounds.x) && near(moved.frame.y, toBounds.y), `moved table frame position was not applied: ${JSON.stringify(moved.frame)}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testLayoutEditFindsGeneratedPageSourceBlock() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-generated-page-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `import std:themes/default as *

page _
let a = text!("A")
end

page _
let b = text!("B")
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      await diagnosticsPromise;

      const snapshot = await previewSnapshot(client, uri, 1);
      const target = snapshot.objects.find((object) => object.label === "b");
      assert(target, `generated-page object b was missing: ${JSON.stringify(snapshot.objects)}`);

      const result = await layoutEdit(client, uri, 1, snapshot.snapshotId, target, { ...target.frame, x: 144, y: 96 });
      assert(result.status === "ok", `layoutEdit did not edit generated page source block: ${JSON.stringify(result)}`);
      const edited = applyWorkspaceEdit(source, result.workspaceEdit, uri);
      const secondPage = edited.slice(edited.indexOf("let b = text!"));
      assert(secondPage.includes("!~ b.horizontal"), `horizontal discard was not inserted into the second page block: ${edited}`);
      assert(secondPage.includes("~ b.left == page.left + 144"), `left constraint was not inserted into the second page block: ${edited}`);
      assert(secondPage.includes("!~ b.vertical"), `vertical discard was not inserted into the second page block: ${edited}`);
      assert(secondPage.includes("~ b.top == page.top - 96"), `top constraint was not inserted into the second page block: ${edited}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testLayoutEditRejectsStaleAndUnsupportedRequests() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-reject-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `import std:themes/default as *

page sample
let a = tl(text!("A"), 10, 10)
end
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      await diagnosticsPromise;

      const snapshot = await previewSnapshot(client, uri, 1);
      const target = snapshot.objects.find((object) => object.label === "a");
      assert(target, `helper object a was missing: ${JSON.stringify(snapshot.objects)}`);

      const staleSnapshot = await layoutEdit(client, uri, 1, "not-the-current-snapshot", target, { ...target.frame, x: 30, y: 30 });
      assert(staleSnapshot.status === "stale", `bad snapshotId was not stale: ${JSON.stringify(staleSnapshot)}`);

      const staleVersion = await layoutEdit(client, uri, 0, snapshot.snapshotId, target, { ...target.frame, x: 30, y: 30 });
      assert(staleVersion.status === "stale", `old document version was not stale: ${JSON.stringify(staleVersion)}`);

      const missingTarget = await layoutEdit(client, uri, 1, snapshot.snapshotId, { ...target, id: 99999 }, { ...target.frame, x: 30, y: 30 });
      assert(missingTarget.status === "unsupported", `missing target was not unsupported: ${JSON.stringify(missingTarget)}`);

      const helperEdit = await layoutEdit(client, uri, 1, snapshot.snapshotId, target, { ...target.frame, x: 30, y: 30 });
      assert(helperEdit.status === "ok", `helper-derived constraints were not editable through discard: ${JSON.stringify(helperEdit)}`);
      const edited = applyWorkspaceEdit(source, helperEdit.workspaceEdit, uri);
      assert(edited.includes("!~ a.horizontal"), `helper horizontal discard was not inserted: ${edited}`);
      assert(edited.includes("!~ a.vertical"), `helper vertical discard was not inserted: ${edited}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testPreviewSnapshotReturnsDiagnostics() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-wysiwyg-diagnostics-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = `pag broken
`;
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      client.openDocument({ uri, text: source, version: 1 });
      const snapshot = await previewSnapshot(client, uri, 1);
      assert(snapshot.diagnostics.length > 0, `previewSnapshot did not return diagnostics: ${JSON.stringify(snapshot)}`);
      assert(snapshot.display?.pages?.length === 0, `diagnostic snapshot should have an empty display: ${JSON.stringify(snapshot.display)}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function previewSnapshot(client, uri, version) {
  return client.request("ss/previewSnapshot", {
    schemaVersion: 1,
    textDocument: { uri, version },
  });
}

function layoutEdit(client, uri, version, snapshotId, target, toBounds, mode = "absolute") {
  return client.request("ss/layoutEdit", {
    schemaVersion: 1,
    textDocument: { uri, version },
    snapshotId,
    selection: {
      primaryNodeId: target.id,
      targets: [{ nodeId: target.id, pageId: target.pageId, initialFrame: target.frame }],
    },
    gesture: {
      kind: "translate",
      mode,
      coordinateSpace: "page",
      fromBounds: target.frame,
      toBounds,
      delta: { dx: toBounds.x - target.frame.x, dy: toBounds.y - target.frame.y },
    },
  });
}

function applyWorkspaceEdit(source, workspaceEdit, uri) {
  const edits = workspaceEdit?.changes?.[uri];
  assert(Array.isArray(edits), `workspaceEdit did not contain edits for ${uri}: ${JSON.stringify(workspaceEdit)}`);
  let result = source;
  for (const edit of [...edits].sort((a, b) => offsetAt(source, b.range.start) - offsetAt(source, a.range.start))) {
    const start = offsetAt(result, edit.range.start);
    const end = offsetAt(result, edit.range.end);
    result = `${result.slice(0, start)}${edit.newText}${result.slice(end)}`;
  }
  return result;
}

function offsetAt(source, position) {
  let line = 0;
  let character = 0;
  for (let i = 0; i < source.length; i += 1) {
    if (line === position.line && character === position.character) {
      return i;
    }
    if (source.charCodeAt(i) === 10) {
      line += 1;
      character = 0;
    } else {
      character += 1;
    }
  }
  return source.length;
}

function near(a, b) {
  return Math.abs(a - b) <= 0.5;
}

function displayPageContainsText(page, text) {
  return page.items.some((item) => {
    if (item.type !== "text") return false;
    return (item.lines || []).some((line) => {
      return (line.spans || []).some((span) => span.kind === "glyphs" && span.text === text);
    });
  });
}

function lineText(line) {
  return (line.spans || [])
    .filter((span) => span.kind === "glyphs")
    .map((span) => span.text || "")
    .join("");
}

function glyphSpans(line) {
  return (line.spans || []).filter((span) => span.kind === "glyphs");
}

function colorKey(color) {
  return Array.isArray(color) ? color.map((value) => Number(value).toFixed(4)).join(",") : "null";
}
