import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../../harness.mjs";
import { applyProtocolEdits, previewBounds, requestEdit } from "../support.mjs";

const directory = await mkdtemp(path.join(os.tmpdir(), "ss-editor-staging-"));
try {
  const file = path.join(directory, "slide.ss");
  const uri = pathToFileURL(file).href;
  let source = `import std:themes/default as *
page Demo
  let item = text! "Always drawn"
  ~!~ item.left == page.left + 20
  ~!~ item.top == page.top - 40
  ~ item.width == 200
  show s >= s.second
    let detail = text! "STAGED_DETAIL"
  end
  ~ detail.width == 220
  stages s { first second third }
end
`;
  await writeFile(file, source);
  await withLspClient({ cwd: directory }, async (client) => {
    await client.initialize();
    let diagnostics = client.waitForDiagnostics(uri);
    client.openDocument({ uri, version: 1, text: source });
    assert((await diagnostics).params.diagnostics.length === 0, "valid staged source produced diagnostics");
    let snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert(!snapshot.stale, "staged preview failed to build");
    assert(snapshot.layout.pages.length === 3, "preview must contain one physical page per stage");
    // Editing targets preserve the common source binding on every stage copy.
    let targets = snapshot.editing.filter((target) => target.binding === "item");
    assert(targets.length === 3, `missing staged editing targets: ${JSON.stringify(snapshot.editing)}`);
    const ordered = snapshot.layout.pages.map((page) => targets.find((target) => target.page_id === page.id));
    const hiddenCounts = snapshot.layout.pages.map((page) => snapshot.layout.objects.filter((object) => object.page_id === page.id && !object.drawn).length);
    assert(JSON.stringify(hiddenCounts) === "[1,0,0]", `incorrect preview visibility: ${JSON.stringify(hiddenCounts)}`);
    assert(JSON.stringify(ordered.map((target) => target.page_name)) === JSON.stringify(["Demo / first", "Demo / second", "Demo / third"]), "editing targets lost their stage labels");
    const previewPages = snapshot.display.html.match(/<section class="ss-page"[^>]*>[\s\S]*?<\/section>/g) ?? [];
    assert(previewPages.length === 3, "preview HTML must contain one section per stage");
    assert(JSON.stringify(previewPages.map((page) => page.includes("STAGED_DETAIL"))) === "[false,true,true]",
      "preview HTML must contain staged text only on the visible stages");
    const details = snapshot.editing.filter((item) => item.binding === "detail");
    assert(details.length === 3, "flattened show bindings must remain editable on every stage");
    assert(details.every((item) => Math.abs(previewBounds(snapshot, item.node_id).width - 220) < 0.1),
      "constraints outside show must resolve its bindings");

    const bodyCallLine = source.split("\n").findIndex((line) => line.includes('let detail = text!'));
    const hover = await client.request("textDocument/hover", { textDocument: { uri }, position: { line: bodyCallLine, character: 19 } });
    assert(hover && !JSON.stringify(hover).includes("draw_when"), "generated drawing calls must not replace source hover targets");

    const target = ordered[1];
    const bounds = previewBounds(snapshot, target.node_id);
    const edit = await requestEdit(client, uri, snapshot, target, bounds, { ...bounds, x: 140, y: 160 }, "absolute", target.page_id);
    assert(edit.status === "ok", `staged layout edit failed: ${JSON.stringify(edit)}`);
    source = applyProtocolEdits(source, edit.workspaceEdit.changes[uri]);
    diagnostics = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 2, text: source });
    assert((await diagnostics).params.diagnostics.length === 0, "shared source edit produced diagnostics");
    snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    targets = snapshot.editing.filter((item) => item.binding === "item");
    assert(targets.length === 3, "shared source edit lost a stage copy");
    for (const item of targets) {
      const updated = previewBounds(snapshot, item.node_id);
      assert(Math.abs(updated.x - 140) < 0.1 && Math.abs(updated.y - 160) < 0.1,
        `source edit did not update every stage: ${JSON.stringify(updated)}`);
    }

    const invalid = source.replace("s.second\n", "s.missing\n");
    diagnostics = client.waitForDiagnostics(uri, (reports) => reports.length > 0);
    client.changeDocument({ uri, version: 3, text: invalid });
    const reports = (await diagnostics).params.diagnostics;
    const unknown = reports.find((entry) => entry.code === "UnknownStage");
    assert(unknown && unknown.range.start.line === source.split("\n").findIndex((line) => line.includes("show s >= s.second")) && unknown.range.start.character === 14,
      `unknown stage must point to its source name: ${JSON.stringify(reports)}`);
    diagnostics = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 4, text: source });
    assert((await diagnostics).params.diagnostics.length === 0, "fixing a stage name did not clear diagnostics");
    snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert(!snapshot.stale && snapshot.layout.pages.length === 3, "preview did not recover after a stage error");

    source = source.replace("stages s { first second third }", "stages s { 1:3 }").replaceAll("s.second", "2");
    diagnostics = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 5, text: source });
    assert((await diagnostics).params.diagnostics.length === 0, "integer range stages produced diagnostics");
    snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert(!snapshot.stale && snapshot.layout.pages.length === 3, "integer range preview failed to build");
    targets = snapshot.editing.filter((item) => item.binding === "item");
    assert(JSON.stringify(snapshot.layout.pages.map(page => targets.find(item => item.page_id === page.id)?.page_name)) ===
      JSON.stringify(["Demo / 1", "Demo / 2", "Demo / 3"]), "integer stages lost their value labels");
    const numericTarget = targets[1];
    const numericBounds = previewBounds(snapshot, numericTarget.node_id);
    const numericEdit = await requestEdit(client, uri, snapshot, numericTarget, numericBounds,
      { ...numericBounds, x: 180, y: 190 }, "absolute", numericTarget.page_id);
    assert(numericEdit.status === "ok", "integer stage source edit failed");
    source = applyProtocolEdits(source, numericEdit.workspaceEdit.changes[uri]);
    diagnostics = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 6, text: source });
    assert((await diagnostics).params.diagnostics.length === 0, "integer stage shared edit produced diagnostics");
    snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    targets = snapshot.editing.filter((item) => item.binding === "item");
    assert(targets.length === 3, "integer stage edit lost a page copy");
    for (const item of targets) {
      const bounds = previewBounds(snapshot, item.node_id);
      assert(Math.abs(bounds.x - 180) < 0.1 && Math.abs(bounds.y - 190) < 0.1, "integer stage edit did not update every page");
    }
    source = source.replace("stages s { 1:3 }", "stages s { 1:2:5 }");
    diagnostics = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 7, text: source });
    assert((await diagnostics).params.diagnostics.length === 0, "integer stage list produced diagnostics");
    snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    targets = snapshot.editing.filter((item) => item.binding === "item");
    assert(!snapshot.stale && JSON.stringify(snapshot.layout.pages.map(page => targets.find(item => item.page_id === page.id)?.page_name)) ===
      JSON.stringify(["Demo / 1", "Demo / 3", "Demo / 5"]), "integer stage range lost its step");
    source = source.replace("stages s { 1:2:5 }", "stages s { 7:-2:3 1 }");
    diagnostics = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 8, text: source });
    assert((await diagnostics).params.diagnostics.length === 0, "combined integer stages produced diagnostics");
    snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    targets = snapshot.editing.filter((item) => item.binding === "item");
    assert(!snapshot.stale && JSON.stringify(snapshot.layout.pages.map(page => targets.find(item => item.page_id === page.id)?.page_name)) ===
      JSON.stringify(["Demo / 7", "Demo / 5", "Demo / 3", "Demo / 1"]), "combined integer stages lost their order");
    diagnostics = client.waitForDiagnostics(uri, reports => reports.some(report => report.code === "InvalidStageRange"));
    client.changeDocument({ uri, version: 9, text: source.replace("7:-2:3 1", "7:0:3 1") });
    assert((await diagnostics).params.diagnostics.some(report => report.code === "InvalidStageRange"), "zero step must produce a source diagnostic");
    diagnostics = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 10, text: source });
    assert((await diagnostics).params.diagnostics.length === 0, "fixing a stage step did not clear diagnostics");
    snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert(!snapshot.stale && snapshot.layout.pages.length === 4, "preview did not recover after a stage step error");

    let version = 10;
    const malformed = [
      ["1::3", "InvalidStageInteger"],
      ["1:2:", "InvalidStageInteger"],
      ["1:16777217:3", "InvalidStageInteger"],
      ["1:-1:3", "InvalidStageRange"],
      ["1:3 2", "DuplicateStageValue"],
      ["0 -0", "DuplicateStageValue"],
      ["1 first", "MixedStageEntries"],
      ["", "EmptyStages"],
    ];
    for (const [entries, code] of malformed) {
      const lastGoodId = snapshot.snapshot_id;
      diagnostics = client.waitForDiagnostics(uri, reports => reports.some(report => report.code === code));
      client.changeDocument({ uri, version: ++version, text: source.replace("7:-2:3 1", entries) });
      assert((await diagnostics).params.diagnostics.some(report => report.code === code), `${entries}: missing ${code}`);
      const stale = await client.request("ss/editorSnapshot", { textDocument: { uri } });
      assert(stale.stale && stale.snapshot_id === lastGoodId && stale.layout.pages.length === 4,
        `${entries}: invalid stages must retain the last valid preview`);
      diagnostics = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, version: ++version, text: source });
      assert((await diagnostics).params.diagnostics.length === 0, `${entries}: repaired stages retained diagnostics`);
      snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
      assert(!snapshot.stale && snapshot.layout.pages.length === 4, `${entries}: repaired stages did not rebuild`);
    }
  });
} finally {
  await rm(directory, { recursive: true, force: true });
}
console.log("Staging editor: drawing, shared source edits, source diagnostics, and recovery passed");
