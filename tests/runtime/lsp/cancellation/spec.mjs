#!/usr/bin/env node
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../../harness.mjs";

const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-cancellation-"));

try {
  const slide = path.join(project, "slide.ss");
  const uri = pathToFileURL(slide).toString();
  const validSource = `page title
end
`;
  const filler = Array.from({ length: 100_000 }, (_, index) => `;; cancellation filler ${index}`).join("\n");
  const largeSource = `${validSource}${filler}\n`;
  const invalidLargeSource = `${largeSource}page broken\n  let value =\nend\n`;
  await writeFile(slide, validSource, "utf8");

  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();

    const openedDiagnostics = client.waitForDiagnostics(
      uri,
      (diagnostics, message) => diagnostics.length === 0 && message.params.version === 1,
      "version 1 diagnostics",
    );
    client.openDocument({ uri, text: validSource, version: 1 });
    await openedDiagnostics;

    client.changeDocument({ uri, version: 2, text: largeSource });
    const canceledRequest = client.startRequest("textDocument/completion", {
      textDocument: { uri },
      position: { line: 0, character: 0 },
    });
    const canceledOutcome = outcome(canceledRequest);
    client.cancelRequest(canceledRequest.id);
    expectOutcome(await canceledOutcome, -32800, isCompletion, "cancelled completion");

    const restoredDiagnostics = client.waitForDiagnostics(
      uri,
      (diagnostics, message) => diagnostics.length === 0 && message.params.version === 3,
      "version 3 diagnostics after cancellation",
    );
    client.changeDocument({ uri, version: 3, text: validSource });
    await restoredDiagnostics;

    client.changeDocument({ uri, version: 4, text: largeSource });
    const staleRequest = client.startRequest("textDocument/semanticTokens/full", {
      textDocument: { uri },
    });
    const staleOutcome = outcome(staleRequest);
    const latestDiagnostics = client.waitForDiagnostics(
      uri,
      (diagnostics, message) => diagnostics.length === 0 && message.params.version === 5,
      "version 5 diagnostics after rapid edits",
    );
    client.changeDocument({ uri, version: 5, text: validSource });

    const [staleResult] = await Promise.all([staleOutcome, latestDiagnostics]);
    expectOutcome(staleResult, -32801, (result) => Array.isArray(result?.data), "superseded semantic tokens");

    const completion = await client.request("textDocument/completion", {
      textDocument: { uri },
      position: { line: 0, character: 0 },
    });
    assert(Array.isArray(completion.items), `latest completion was unavailable: ${JSON.stringify(completion)}`);

    const baselineSnapshot = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: "",
    });
    client.changeDocument({ uri, version: 6, text: largeSource });
    const canceledSnapshot = client.startRequest("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: "",
    });
    const canceledSnapshotOutcome = outcome(canceledSnapshot);
    client.cancelRequest(canceledSnapshot.id);
    expectOutcome(await canceledSnapshotOutcome, -32800, isSnapshot, "cancelled editor snapshot");

    const recoveredSnapshot = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: baselineSnapshot.snapshot_id,
    });
    assert(
      recoveredSnapshot.kind === "ss-editor-snapshot" &&
        recoveredSnapshot.stale !== true &&
        recoveredSnapshot.generation > baselineSnapshot.generation &&
        recoveredSnapshot.snapshot_id !== baselineSnapshot.snapshot_id,
      `editor snapshot stayed stale after cancellation: ${JSON.stringify(recoveredSnapshot)}`,
    );

    const canceledBuildDiagnostics = client.waitForDiagnostics(
      uri,
      (diagnostics, message) => diagnostics.length > 0 && message.params.version === 7,
      "version 7 diagnostics after editor snapshot cancellation",
    );
    client.changeDocument({ uri, version: 7, text: invalidLargeSource });
    const canceledInvalidSnapshot = client.startRequest("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: recoveredSnapshot.snapshot_id,
    });
    const canceledInvalidOutcome = outcome(canceledInvalidSnapshot);
    client.cancelRequest(canceledInvalidSnapshot.id);
    const [invalidResult] = await Promise.all([canceledInvalidOutcome, canceledBuildDiagnostics]);
    expectOutcome(invalidResult, -32800, isSnapshot, "cancelled invalid editor snapshot");

    const finalDiagnostics = client.waitForDiagnostics(
      uri,
      (diagnostics, message) => diagnostics.length === 0 && message.params.version === 8,
      "version 8 diagnostics after editor snapshot cancellation",
    );
    client.changeDocument({ uri, version: 8, text: validSource });
    await finalDiagnostics;
    const snapshot = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: recoveredSnapshot.snapshot_id,
    });
    assert(
      snapshot.kind === "ss-editor-snapshot" && snapshot.layout?.pages?.length === 1,
      `editor snapshot did not recover after cancellation: ${JSON.stringify(snapshot)}`,
    );

    const auxiliary = path.join(project, "auxiliary.ss");
    const auxiliaryUri = pathToFileURL(auxiliary).toString();
    await writeFile(auxiliary, validSource);
    let version = 8;
    for (const notification of ["open-file-watch", "unrelated-watch", "close-other-document"]) {
      if (notification === "close-other-document") {
        const opened = client.waitForDiagnostics(auxiliaryUri);
        client.openDocument({ uri: auxiliaryUri, text: validSource, version: 1 });
        await opened;
      }
      version += 1;
      const baselineVersion = version;
      const baseline = client.waitForDiagnostics(uri,
        (diagnostics, message) => diagnostics.length === 0 && message.params.version === baselineVersion);
      client.changeDocument({ uri, version, text: `${validSource};; baseline ${notification}\n` });
      await baseline;

      version += 1;
      const changedVersion = version;
      const restored = client.waitForDiagnostics(uri,
        (diagnostics, message) => diagnostics.length > 0 && message.params.version === changedVersion,
        `diagnostics after ${notification} interrupted analysis`);
      client.changeDocument({ uri, version, text: `${invalidLargeSource};; ${notification}\n` });
      const request = client.startRequest("textDocument/completion", {
        textDocument: { uri }, position: { line: 0, character: 0 },
      });
      const interruptedOutcome = outcome(request);
      if (notification === "close-other-document") {
        client.notify("textDocument/didClose", { textDocument: { uri: auxiliaryUri } });
      } else {
        client.notify("workspace/didChangeWatchedFiles", { changes: [{
          uri: notification === "open-file-watch" ? uri : pathToFileURL(path.join(project, "unrelated.txt")).toString(),
          type: 2,
        }] });
      }
      const [interrupted] = await Promise.all([interruptedOutcome, restored]);
      expectOutcome(interrupted, -32801, isCompletion, `completion during ${notification}`);
    }

    // Also exercise notifications after a request has certainly completed.
    // Late cancellation must not poison the next request or document revision.
    const completed = client.startRequest("textDocument/completion", {
      textDocument: { uri }, position: { line: 0, character: 0 },
    });
    assert(isCompletion(await completed.promise), "completion before late cancellation was invalid");
    client.cancelRequest(completed.id);
    const afterLateCancel = await client.request("textDocument/completion", {
      textDocument: { uri }, position: { line: 0, character: 0 },
    });
    assert(isCompletion(afterLateCancel), "late cancellation affected the next request");
  });
} finally {
  await rm(project, { recursive: true, force: true });
}

// A request may finish before the ingress thread receives a later cancellation
// or invalidation. Both outcomes are valid; malformed results and other errors
// must still fail. In-flight cancellation itself is covered by query unit tests
// and render_cancellation, whose tool-start marker provides a real barrier.
function outcome(request) {
  return request.promise.then((result) => ({ result }), (error) => ({ error }));
}

function expectOutcome(value, errorCode, validResult, label) {
  if (value.error) {
    assert(value.error instanceof Error && value.error.message.startsWith(`${errorCode}:`),
      `${label} returned an unexpected error: ${value.error}`);
  } else {
    assert(validResult(value.result), `${label} returned an invalid result: ${JSON.stringify(value.result)}`);
  }
}

function isCompletion(result) { return Array.isArray(result?.items); }
function isSnapshot(result) { return result?.kind === "ss-editor-snapshot"; }
