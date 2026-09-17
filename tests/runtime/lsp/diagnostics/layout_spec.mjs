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

const source = `page example
let t = text!("Main text")
let t1 = text!("Following text")
~ t.width == 240
~ t1.width == 240
~ t1.left == t.right + 10
~ t1.top == t.bottom - 10
~!~ t.left == page.left + 120
~!~ t.top == page.top - 400
end
`;

await testDraggingPublishesAndClearsFollowerOverflow();
await testManualPreviewPublishesWarningsAfterMeasurement();
await testFrameDiagnosticsRespectFitPolicy();

async function testDraggingPublishesAndClearsFollowerOverflow() {
  await withProject(source, null, async (client, uri) => {
    let diagnostics = await open(client, uri, source);
    assert(diagnostics.length === 0, `initial layout warnings: ${JSON.stringify(diagnostics)}`);
    let currentSource = source;
    let snapshot = await editorSnapshot(client, uri);
    let version = 1;

    // Equal-length numeric edits exercise reuse of evaluated layout state too.
    for (const top of [680, 400, 500, 690, 400]) {
      const target = editingTarget(snapshot, "t");
      const from = previewBounds(snapshot, target.node_id);
      const to = { ...from, y: top };
      const edit = await requestEdit(client, uri, snapshot, target, from, to, "absolute", target.page_id);
      assert(edit.status === "ok", `drag rejected: ${JSON.stringify(edit)}`);
      currentSource = applyProtocolEdits(currentSource, edit.workspaceEdit.changes[uri]);
      version += 1;
      // Opening the snapshot flushes the rebuild. Capture its final diagnostics,
      // rather than the empty notification sent while analysis is pending.
      diagnostics = await collectDiagnostics(client, uri, async () => {
        client.changeDocument({ uri, text: currentSource, version });
        snapshot = await editorSnapshot(client, uri);
      });
      assert(snapshot.stale !== true, "a warning prevented the updated preview");
      const main = previewBounds(snapshot, editingTarget(snapshot, "t").node_id);
      const follower = previewBounds(snapshot, editingTarget(snapshot, "t1").node_id);
      assert(Math.abs(main.y - top) < 0.1, "drag did not move the main text");
      assert(Math.abs(follower.y - main.y - main.height - 10) < 0.1, "the relative text did not follow");
      const overflow = diagnostics.filter(item => item.code === "PageOverflow");
      if (top >= 680) {
        assert(overflow.some(item => item.severity === 2 && item.range.start.line === 2),
          `missing follower overflow warning: ${JSON.stringify(diagnostics)}`);
      } else {
        assert(diagnostics.length === 0, `returning inside retained diagnostics: ${JSON.stringify(diagnostics)}`);
      }
    }
  });
}

async function testManualPreviewPublishesWarningsAfterMeasurement() {
  const outside = source.replace("page.top - 400", "page.top - 680");
  await withProject(outside, `[project]
entry = "slide.ss"

[editor.wysiwyg.refresh]
automatic = false
`, async (client, uri) => {
    const initial = await open(client, uri, outside);
    assert(initial.length === 0, `analysis without layout reported overflow: ${JSON.stringify(initial)}`);
    const measured = await collectDiagnostics(client, uri, () => editorSnapshot(client, uri));
    assert(measured.some(item => item.code === "PageOverflow" && item.severity === 2),
      `explicit measured build omitted overflow: ${JSON.stringify(measured)}`);
  });
}

async function testFrameDiagnosticsRespectFitPolicy() {
  for (const policy of [null, "ignore", "error"]) {
    const frameSource = `page example
let body = text!("SupercalifragilisticexpialidociousSupercalifragilisticexpialidocious")
body.text.size = 24
body.text.line_height = 30
${policy ? `body.layout.fit = FitPolicy.${policy}\n` : ""}~ body.left == page.left + 100
~ body.width == 120
~ body.top == page.top - 120
end
`;
    await withProject(frameSource, null, async (client, uri) => {
      const diagnostics = await open(client, uri, frameSource);
      if (policy === "ignore") {
        assert(diagnostics.length === 0, `ignored fit produced diagnostics: ${JSON.stringify(diagnostics)}`);
      } else {
        assert(diagnostics.some(item => item.code === "FrameTooSmall" && item.severity === (policy === "error" ? 1 : 2)),
          `wrong ${policy ?? "default"} fit diagnostics: ${JSON.stringify(diagnostics)}`);
      }
    });
  }
}

async function withProject(text, config, run) {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-layout-diagnostics-"));
  try {
    const slide = path.join(project, "slide.ss");
    await writeFile(slide, text);
    if (config) await writeFile(path.join(project, "ss.toml"), config);
    await withLspClient({ cwd: project }, async client => {
      await client.initialize();
      await run(client, pathToFileURL(slide).toString());
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function open(client, uri, text) {
  const pending = client.waitForDiagnostics(uri);
  client.openDocument({ uri, text, version: 1 });
  return (await pending).params.diagnostics;
}

function editorSnapshot(client, uri) {
  return client.request("ss/editorSnapshot", { textDocument: { uri } });
}

async function collectDiagnostics(client, uri, run) {
  const handleMessage = client.handleMessage;
  let latest = null;
  client.handleMessage = function (message) {
    if (message.method === "textDocument/publishDiagnostics" && message.params.uri === uri) {
      latest = message.params.diagnostics;
    }
    return handleMessage.call(this, message);
  };
  try {
    await run();
    assert(latest !== null, "layout rebuild did not publish diagnostics");
    return latest;
  } finally {
    client.handleMessage = handleMessage;
  }
}
