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
  stages s { first second third }
  let item = text! "Always drawn"
  ~!~ item.left == page.left + 20
  ~!~ item.top == page.top - 40
  ~ item.width == 200
  show s >= s.second
    text! "STAGED_DETAIL"
  end
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
    assert((snapshot.display.html.match(/STAGED_DETAIL/g) ?? []).length === 2, "hidden text must not appear in preview HTML");

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
    assert(unknown && unknown.range.start.line === 7 && unknown.range.start.character === 14,
      `unknown stage must point to its source name: ${JSON.stringify(reports)}`);
    diagnostics = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 4, text: source });
    assert((await diagnostics).params.diagnostics.length === 0, "fixing a stage name did not clear diagnostics");
    snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert(!snapshot.stale && snapshot.layout.pages.length === 3, "preview did not recover after a stage error");
  });
} finally {
  await rm(directory, { recursive: true, force: true });
}
console.log("Staging editor: drawing, shared source edits, source diagnostics, and recovery passed");
