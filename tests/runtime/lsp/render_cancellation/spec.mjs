#!/usr/bin/env node
import { access, chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../../harness.mjs";

const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-render-cancellation-"));
const originalPath = process.env.PATH;

try {
  const fakeBin = path.join(project, "bin");
  const marker = path.join(project, "pdflatex-started");
  const mode = path.join(project, "pdflatex-mode");
  const pidFile = path.join(project, "pdflatex-pid");
  const slide = path.join(project, "slide.ss");
  const uri = pathToFileURL(slide).toString();
  await mkdir(fakeBin);
  const fakePdflatex = path.join(fakeBin, "pdflatex");
  await writeFile(
    fakePdflatex,
    `#!/bin/sh
set -eu
printf '%s\n' "$$" > ${shellQuote(pidFile)}
: > ${shellQuote(marker)}
if [ "$(cat ${shellQuote(mode)})" = "closed-pipes" ]; then
  trap '' TERM
  exec >/dev/null 2>/dev/null
  while :; do /bin/sleep 30; done
fi
exec /bin/sleep 30
`,
    "utf8",
  );
  await chmod(fakePdflatex, 0o755);
  await writeFile(mode, "open-pipes\n", "utf8");
  await writeFile(path.join(project, "ss.toml"), `[project]
entry = "slide.ss"

[editor.wysiwyg.refresh]
automatic = false
`, "utf8");
  const source = `import std:prelude as *

page latex
let formula = latex!("$x$")
end
`;
  await writeFile(slide, source, "utf8");
  process.env.PATH = `${fakeBin}${path.delimiter}${originalPath ?? ""}`;

  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    const diagnostics = client.waitForDiagnostics(
      uri,
      (items, message) => items.length === 0 && message.params.version === 1,
      "LaTeX source diagnostics",
    );
    client.openDocument({ uri, text: source, version: 1 });
    await diagnostics;

    await interruptRenderSnapshot(client, uri, marker, pidFile, "open-pipe render");

    await writeFile(mode, "closed-pipes\n", "utf8");
    await interruptRenderSnapshot(client, uri, marker, pidFile, "closed-pipe render");

    await writeFile(mode, "open-pipes\n", "utf8");
    await interruptRenderSnapshot(client, uri, marker, pidFile, "superseded render", {
      interrupt: () => client.changeDocument({ uri, text: `${source};; latest revision\n`, version: 2 }),
      errorCode: -32801,
    });

    const auxiliary = path.join(project, "auxiliary.ss");
    const auxiliaryUri = pathToFileURL(auxiliary).toString();
    const auxiliarySource = "page auxiliary\nend\n";
    await writeFile(auxiliary, auxiliarySource);
    for (const notification of ["open-file-watch", "unrelated-watch", "close-other-document"]) {
      if (notification === "close-other-document") {
        const opened = client.waitForDiagnostics(auxiliaryUri);
        client.openDocument({ uri: auxiliaryUri, text: auxiliarySource, version: 1 });
        await opened;
      }
      // The child-start barrier makes the request genuinely in flight, so
      // these notifications must interrupt it rather than race its completion.
      await interruptRenderSnapshot(client, uri, marker, pidFile, notification, {
        interrupt: () => {
          if (notification === "close-other-document") {
            client.notify("textDocument/didClose", { textDocument: { uri: auxiliaryUri } });
          } else {
            client.notify("workspace/didChangeWatchedFiles", { changes: [{
              uri: notification === "open-file-watch" ? uri : pathToFileURL(path.join(project, "unrelated.txt")).toString(),
              type: 2,
            }] });
          }
        },
        errorCode: -32801,
      });
    }

    const completion = await client.request("textDocument/completion", {
      textDocument: { uri },
      position: { line: 3, character: 10 },
    });
    assert(Array.isArray(completion.items), "language server did not recover after render cancellation");
  });
} finally {
  process.env.PATH = originalPath;
  await rm(project, { recursive: true, force: true });
}

async function waitForFile(filePath, timeoutMs) {
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    try {
      await access(filePath);
      return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  }
  throw new Error(`timed out waiting for ${filePath}`);
}

function shellQuote(value) {
  return `'${value.replaceAll("'", `'"'"'`)}'`;
}

async function interruptRenderSnapshot(client, uri, marker, pidFile, label, {
  interrupt = (request) => client.cancelRequest(request.id), errorCode = -32800,
} = {}) {
  await rm(marker, { force: true });
  await rm(pidFile, { force: true });
  const snapshot = client.startRequest("ss/editorSnapshot", {
    textDocument: { uri },
    baseSnapshotId: "",
  });
  const outcome = snapshot.promise.then(() => null, (error) => error);
  const pid = await waitForRenderStart(marker, pidFile);
  const canceledAt = performance.now();
  interrupt(snapshot);
  const cancellationError = await outcome;
  const cancellationMs = performance.now() - canceledAt;
  assert(
    cancellationError instanceof Error && cancellationError.message.startsWith(`${errorCode}:`),
    `${label} snapshot returned an unexpected outcome: ${cancellationError}`,
  );
  assert(
    cancellationMs < 3_000,
    `${label} cancellation took ${Math.round(cancellationMs)} ms`,
  );
  await waitForProcessExit(pid, 2_000, label);
}

async function waitForRenderStart(marker, pidFile) {
  await waitForFile(marker, 3_000);
  const text = (await readFile(pidFile, "utf8")).trim();
  const pid = Number(text);
  assert(/^[1-9][0-9]*$/.test(text) && Number.isSafeInteger(pid), `invalid render process id: ${text}`);
  return pid;
}

async function waitForProcessExit(pid, timeoutMs, label) {
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    try {
      process.kill(pid, 0);
    } catch (error) {
      if (error?.code === "ESRCH") return;
      throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`${label} process ${pid} survived cancellation`);
}
