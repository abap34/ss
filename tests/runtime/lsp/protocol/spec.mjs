#!/usr/bin/env node
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, LspClient, withLspClient } from "../../harness.mjs";
import { editingTarget, previewBounds, requestEdit } from "../../editor/support.mjs";

const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-protocol-"));

try {
  const slide = path.join(project, "slide.ss");
  const uri = pathToFileURL(slide).toString();
  const originalSource = `page original
end
`;
  const recoveredSource = `page recovered
end
`;
  await writeFile(slide, originalSource, "utf8");

  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();

    const parseErrorResponse = client.waitForNotification(
      (message) => message.id === null && message.error?.code === -32700,
      "parse error response",
    );
    client.sendRawBody('{"jsonrpc":"2.0",');
    const parseError = await parseErrorResponse;
    assert(parseError.error.message === "Parse error", `unexpected parse error response: ${JSON.stringify(parseError)}`);

    const nonObjectResponse = client.waitForNotification(
      (message) => message.id === null && message.error?.code === -32600,
      "non-object request response",
    );
    client.sendRawBody("[]");
    const nonObjectError = await nonObjectResponse;
    assert(nonObjectError.error.message === "Invalid Request", `unexpected invalid request response: ${JSON.stringify(nonObjectError)}`);

    const missingMethodResponse = client.waitForNotification(
      (message) => message.id === 9001 && message.error?.code === -32600,
      "missing method response",
    );
    client.sendRawBody('{"jsonrpc":"2.0","id":9001}');
    const missingMethodError = await missingMethodResponse;
    assert(missingMethodError.error.message === "Invalid Request", `unexpected missing method response: ${JSON.stringify(missingMethodError)}`);

    const openedDiagnostics = client.waitForDiagnostics(
      uri,
      (diagnostics, message) => diagnostics.length === 0 && message.params.version === 1,
      "initial protocol fixture diagnostics",
    );
    client.openDocument({ uri, text: originalSource, version: 1 });
    await openedDiagnostics;

    const invalidPosition = await client.request("textDocument/hover", {
      textDocument: { uri },
      position: { line: 1e100, character: 0 },
    }).then(
      () => null,
      (error) => error,
    );
    assert(
      invalidPosition instanceof Error && invalidPosition.message.includes("-32602: Invalid params"),
      `invalid position did not return Invalid params: ${invalidPosition}`,
    );

    client.notify("textDocument/didChange", {
      textDocument: { uri, version: 2 },
      contentChanges: [
        {
          range: { start: { line: 0, character: 5 }, end: { line: 0, character: 13 } },
          text: "mutated",
        },
        {
          range: { start: { line: 1, character: 1 }, end: { line: 0, character: 0 } },
          text: "invalid",
        },
      ],
    });

    const unchangedSnapshot = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: "",
    });
    assert(
      unchangedSnapshot.layout?.pages?.[0]?.name === "original",
      `invalid didChange was partially applied: ${JSON.stringify(unchangedSnapshot.layout?.pages)}`,
    );

    const invalidNode = await client.request("ss/layoutEdit", {
      textDocument: { uri },
      snapshotId: unchangedSnapshot.snapshot_id,
      pageId: unchangedSnapshot.layout.pages[0].id,
      nodeId: 4294967296,
    }).then(
      () => null,
      (error) => error,
    );
    assert(
      invalidNode instanceof Error && invalidNode.message.includes("-32602: Invalid params"),
      `out-of-range nodeId did not return Invalid params: ${invalidNode}`,
    );

    // Disk edits invalidate cached snapshots even without change notifications.
    // Reject an edit from the old preview without overwriting the external edit,
    // then allow editing again after valid source is restored and reloaded.
    const externalSlide = path.join(project, "external.ss");
    const externalUri = pathToFileURL(externalSlide).toString();
    const externalSource = `import std:themes/default as *
page external
let item = text!("External")
~ item.left == page.left + 40
~ item.top == page.top - 60
end
`;
    await writeFile(externalSlide, externalSource);
    const external = await client.request("ss/editorSnapshot", { textDocument: { uri: externalUri } });
    const target = editingTarget(external, "item");
    const from = previewBounds(external, target.node_id);
    const to = { ...from, x: from.x + 20, y: from.y + 10 };
    const changedSource = externalSource.replace("+ 40", "% 40");
    await writeFile(externalSlide, changedSource);
    const rejectedEdit = await requestEdit(client, externalUri, external, target, from, to, "relative", target.page_id);
    assert(rejectedEdit.status === "stale", `external edit did not invalidate the snapshot: ${JSON.stringify(rejectedEdit)}`);
    assert(await readFile(externalSlide, "utf8") === changedSource, "stale request overwrote the external edit");
    await writeFile(externalSlide, externalSource);
    const refreshed = await client.request("ss/editorSnapshot", { textDocument: { uri: externalUri } });
    const refreshedTarget = editingTarget(refreshed, "item");
    const refreshedFrom = previewBounds(refreshed, refreshedTarget.node_id);
    const refreshedTo = { ...refreshedFrom, x: refreshedFrom.x + 20, y: refreshedFrom.y + 10 };
    const nextEdit = await requestEdit(client, externalUri, refreshed, refreshedTarget, refreshedFrom, refreshedTo, "relative", refreshedTarget.page_id);
    assert(nextEdit.status === "ok", `stale request broke later edits: ${JSON.stringify(nextEdit)}`);

    const recoveredDiagnostics = client.waitForDiagnostics(
      uri,
      (diagnostics, message) => diagnostics.length === 0 && message.params.version === 2,
      "diagnostics after a rejected change",
    );
    client.changeDocument({ uri, version: 2, text: recoveredSource });
    await recoveredDiagnostics;
    const recoveredSnapshot = await client.request("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: unchangedSnapshot.snapshot_id,
    });
    assert(
      recoveredSnapshot.layout?.pages?.[0]?.name === "recovered",
      `language server did not recover after invalid input: ${JSON.stringify(recoveredSnapshot.layout?.pages)}`,
    );
  });
} finally {
  await rm(project, { recursive: true, force: true });
}

await expectProtocolExit(
  "oversized header",
  "X".repeat(16 * 1024 + 1),
);
await expectProtocolExit(
  "oversized message",
  `Content-Length: ${64 * 1024 * 1024 + 1}\r\n\r\n`,
);
await expectProtocolExit(
  "duplicate Content-Length",
  "Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
);

async function expectProtocolExit(label, bytes) {
  const client = new LspClient();
  client.child.stdin.write(bytes);
  let failure = null;
  try {
    await client.waitForExit();
  } catch (error) {
    failure = error;
  } finally {
    if (!client.exitStatus) client.child.kill();
  }
  assert(
    failure instanceof Error && !failure.message.includes("did not exit"),
    `${label} did not terminate the language server promptly: ${failure}`,
  );
}


// A failed response must cancel the stdin reader even when the peer keeps its
// input open with an incomplete next frame.
for (const writeAfterExit of [false, true]) {
  const client = new LspClient();
  const inputErrors = [];
  // This case deliberately closes the server's output. Its input may close
  // before either write finishes; other protocol tests still reject pipe errors.
  client.child.stdin.on("error", (error) => inputErrors.push(error));
  try {
    await client.initialize();
    client.child.stdout.destroy();
    client.send({ jsonrpc: "2.0", id: 9002, method: "shutdown", params: null });
    const exited = client.waitForExit().then(() => null, (failure) => failure);
    if (writeAfterExit) await exited;
    await new Promise((resolve) => client.child.stdin.write("Content-Length: 100\r\n\r\n{", (error) => {
      if (error) inputErrors.push(error);
      resolve();
    }));
    const error = await exited;
    assert(error instanceof Error && client.exitStatus?.code === 1 && client.stderr.includes("output writer could not write"),
      `failed worker left the server running: ${error}; ${client.stderr}`);
    for (const inputError of inputErrors) {
      assert(["EPIPE", "ERR_STREAM_DESTROYED"].includes(inputError.code),
        `unexpected input failure after closing server output: ${inputError}`);
    }
  } finally {
    if (!client.exitStatus) client.child.kill();
  }
}
