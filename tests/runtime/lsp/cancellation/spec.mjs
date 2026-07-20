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
  const filler = Array.from({ length: 100_000 }, (_, index) => `# cancellation filler ${index}`).join("\n");
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
    const canceledOutcome = canceledRequest.promise.then(
      () => null,
      (error) => error,
    );
    await new Promise((resolve) => setTimeout(resolve, 10));
    client.cancelRequest(canceledRequest.id);
    const cancellationError = await canceledOutcome;
    assert(cancellationError instanceof Error, "cancelled completion unexpectedly returned a result");
    assert(
      cancellationError.message.includes("-32800"),
      `cancelled completion returned the wrong error: ${cancellationError.message}`,
    );

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
    const staleOutcome = staleRequest.promise.then(
      () => null,
      (error) => error,
    );
    const latestDiagnostics = client.waitForDiagnostics(
      uri,
      (diagnostics, message) => diagnostics.length === 0 && message.params.version === 5,
      "version 5 diagnostics after rapid edits",
    );
    client.changeDocument({ uri, version: 5, text: validSource });

    const staleError = await staleOutcome;
    assert(staleError instanceof Error, "stale semantic-token request unexpectedly returned a result");
    assert(
      staleError.message.includes("-32801"),
      `stale semantic-token request returned the wrong error: ${staleError.message}`,
    );
    await latestDiagnostics;

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
    const canceledSnapshotOutcome = canceledSnapshot.promise.then(
      () => null,
      (error) => error,
    );
    await new Promise((resolve) => setTimeout(resolve, 10));
    client.cancelRequest(canceledSnapshot.id);
    const snapshotCancellationError = await canceledSnapshotOutcome;
    assert(
      snapshotCancellationError instanceof Error,
      "cancelled editor snapshot unexpectedly returned a result",
    );
    assert(
      snapshotCancellationError.message.includes("-32800"),
      `cancelled editor snapshot returned the wrong error: ${snapshotCancellationError.message}`,
    );

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
    const canceledInvalidOutcome = canceledInvalidSnapshot.promise.then(
      () => null,
      (error) => error,
    );
    await new Promise((resolve) => setTimeout(resolve, 10));
    client.cancelRequest(canceledInvalidSnapshot.id);
    const invalidCancellationError = await canceledInvalidOutcome;
    assert(
      invalidCancellationError instanceof Error &&
        invalidCancellationError.message.includes("-32800"),
      `invalid editor snapshot was not cancelled: ${invalidCancellationError}`,
    );
    await canceledBuildDiagnostics;

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
  });
} finally {
  await rm(project, { recursive: true, force: true });
}
