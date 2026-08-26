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
: > ${shellQuote(marker)}
printf '%s\n' "$$" > ${shellQuote(pidFile)}
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
  const source = `import std:core/prelude as *

page latex
let formula = latex!("$x$")
place!(formula)
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

    await cancelRenderSnapshot(client, uri, marker, pidFile, "open-pipe render");

    await rm(marker, { force: true });
    await rm(pidFile, { force: true });
    await writeFile(mode, "closed-pipes\n", "utf8");
    await cancelRenderSnapshot(client, uri, marker, pidFile, "closed-pipe render");

    await rm(marker, { force: true });
    await rm(pidFile, { force: true });
    await writeFile(mode, "open-pipes\n", "utf8");
    const superseded = client.startRequest("ss/editorSnapshot", {
      textDocument: { uri },
      baseSnapshotId: "",
    });
    await waitForFile(marker, 3_000);
    const supersededPid = Number.parseInt(await readFile(pidFile, "utf8"), 10);
    const changedAt = performance.now();
    client.changeDocument({ uri, text: `${source}# latest revision\n`, version: 2 });
    const contentModifiedError = await superseded.promise.then(
      () => null,
      (error) => error,
    );
    const contentModifiedMs = performance.now() - changedAt;
    assert(
      contentModifiedError instanceof Error && contentModifiedError.message.includes("-32801"),
      `superseded render returned the wrong result: ${contentModifiedError}`,
    );
    assert(
      contentModifiedMs < 3_000,
      `superseded render took ${Math.round(contentModifiedMs)} ms to stop`,
    );
    await waitForProcessExit(supersededPid, 2_000, "superseded render");

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

async function cancelRenderSnapshot(client, uri, marker, pidFile, label) {
  const snapshot = client.startRequest("ss/editorSnapshot", {
    textDocument: { uri },
    baseSnapshotId: "",
  });
  await waitForFile(marker, 3_000);
  const pid = Number.parseInt(await readFile(pidFile, "utf8"), 10);
  const canceledAt = performance.now();
  client.cancelRequest(snapshot.id);
  const cancellationError = await snapshot.promise.then(
    () => null,
    (error) => error,
  );
  const cancellationMs = performance.now() - canceledAt;
  assert(
    cancellationError instanceof Error && cancellationError.message.includes("-32800"),
    `${label} snapshot was not cancelled: ${cancellationError}`,
  );
  assert(
    cancellationMs < 3_000,
    `${label} cancellation took ${Math.round(cancellationMs)} ms`,
  );
  await waitForProcessExit(pid, 2_000, label);
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
