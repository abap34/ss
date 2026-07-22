#!/usr/bin/env node
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../../harness.mjs";

const project = await mkdtemp(
  path.join(os.tmpdir(), "ss-editor-diagnostics-"),
);
try {
  const slide = path.join(project, "slide.ss");
  const uri = pathToFileURL(slide).toString();
  const initialSource = shapePreviewSource("#2563eb");
  const recoloredSource = shapePreviewSource("#f59e0b");
  const duplicateSource = `${recoloredSource}\npage preview\nend\n`;
  const removedSource = "page preview\nend\n";
  await writeFile(slide, initialSource, "utf8");

  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    let diagnosticsPromise = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: initialSource, version: 1 });
    assert(
      (await diagnosticsPromise).params.diagnostics.length === 0,
      "initial editor diagnostics fixture produced diagnostics",
    );
    const initial = await editorSnapshot(client, uri);
    const initialShape = shapeTarget(initial);

    diagnosticsPromise = client.waitForDiagnostics(uri);
    client.changeDocument({ uri, version: 2, text: recoloredSource });
    assert(
      (await diagnosticsPromise).params.diagnostics.length === 0,
      "recolored shape source produced diagnostics",
    );
    const recolored = await editorSnapshot(
      client,
      uri,
      initial.snapshot_id,
    );
    assert(
      recolored.display?.schema === 2 &&
        recolored.display.html !== initial.display.html &&
        shapeTarget(recolored).fill.color === "#f59e0b",
      `successful color change retained the old preview: ${JSON.stringify(recolored)}`,
    );

    diagnosticsPromise = client.waitForDiagnostics(
      uri,
      (diagnostics) => diagnostics.some(isDuplicatePage),
    );
    client.changeDocument({ uri, version: 3, text: duplicateSource });
    const duplicate = (await diagnosticsPromise).params.diagnostics.find(
      isDuplicatePage,
    );
    assertDuplicatePageDiagnostic(duplicate);

    const failed = await editorSnapshot(client, uri);
    assert(
      failed.stale === true &&
        failed.snapshot_id === recolored.snapshot_id,
      `failed build did not retain the last successful preview: ${JSON.stringify(failed)}`,
    );
    const buildDiagnostic = failed.build_diagnostics?.find(isDuplicatePage);
    assert(
      buildDiagnostic?.uri === uri,
      `WYSIWYG diagnostic used the wrong source: ${JSON.stringify(buildDiagnostic)}`,
    );
    assertDuplicatePageDiagnostic(buildDiagnostic);

    diagnosticsPromise = client.waitForDiagnostics(
      uri,
      (diagnostics) => diagnostics.length === 0,
    );
    client.changeDocument({ uri, version: 4, text: removedSource });
    await diagnosticsPromise;
    const removed = await editorSnapshot(
      client,
      uri,
      recolored.snapshot_id,
    );
    assert(
      removed.stale !== true &&
        removed.display?.schema === 2 &&
        !removed.shape_editing?.some((target) => target.binding === "shape") &&
        !removed.layout.objects.some((object) =>
          object.id === initialShape.node_id
        ) &&
        !removed.display.html.includes(
          `data-ss-node-id="${initialShape.node_id}"`,
        ),
      `successful recovery retained the deleted shape: ${JSON.stringify(removed)}`,
    );
  });
} finally {
  await rm(project, { recursive: true, force: true });
}

function editorSnapshot(client, uri, baseSnapshotId = "") {
  return client.request("ss/editorSnapshot", {
    textDocument: { uri },
    baseSnapshotId,
  });
}

function shapeTarget(snapshot) {
  const target = snapshot.shape_editing?.find((candidate) =>
    candidate.binding === "shape"
  );
  assert(target, `editor snapshot omitted the shape: ${JSON.stringify(snapshot)}`);
  return target;
}

function isDuplicatePage(diagnostic) {
  return diagnostic.code === "DuplicatePage";
}

function assertDuplicatePageDiagnostic(diagnostic) {
  assert(
    diagnostic?.message.includes("page 'preview' is already defined") &&
      diagnostic.range.start.line === 7,
    `duplicate page diagnostic was incomplete: ${JSON.stringify(diagnostic)}`,
  );
}

function shapePreviewSource(color) {
  return `page preview
let shape = rectangle!(120, 80, VectorStyle {
  fill = solid_fill(c"${color}", 1)
  stroke = no_stroke()
})
end
`;
}
