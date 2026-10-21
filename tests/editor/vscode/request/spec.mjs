#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../..");
const require = createRequire(import.meta.url);
const ts = require(path.join(root, "editor", "vscode", "node_modules", "typescript"));
const source = await readFile(
  path.join(root, "editor", "vscode", "src", "editor", "request.ts"),
  "utf8",
);
const compiled = ts.transpileModule(source, {
  compilerOptions: {
    module: ts.ModuleKind.ES2020,
    target: ts.ScriptTarget.ES2020,
  },
}).outputText;
const { isRetryableSnapshotError, withRequestDeadline } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled).toString("base64")}`
);

assert.equal(isRetryableSnapshotError({ code: -32800 }), true);
assert.equal(isRetryableSnapshotError({ code: -32801 }), true);
assert.equal(isRetryableSnapshotError({ code: -32603 }), false);
assert.equal(isRetryableSnapshotError({ code: "-32801" }), false);
assert.equal(isRetryableSnapshotError(new Error("content modified")), false);
assert.equal(isRetryableSnapshotError(null), false);

const success = cancellationSource();
assert.equal(await withRequestDeadline(async () => 42, success), 42);
assert.equal(success.listeners.size, 0, "successful requests retained cancellation listeners");

const cancelled = cancellationSource();
const waiting = withRequestDeadline(() => new Promise(() => {}), cancelled);
cancelled.cancel();
await assert.rejects(waiting, (error) => error.code === -32800);
assert.equal(cancelled.listeners.size, 0);

const stalled = cancellationSource();
await assert.rejects(
  withRequestDeadline(() => new Promise(() => {}), stalled, 5),
  /Restart WYSIWYG/,
);
assert.equal(stalled.token.isCancellationRequested, true);
assert.equal(stalled.listeners.size, 0);

const failed = cancellationSource();
await assert.rejects(withRequestDeadline(() => { throw new Error("failed"); }, failed), /failed/);
assert.equal(failed.listeners.size, 0);

function cancellationSource() {
  const listeners = new Set();
  return {
    listeners,
    token: {
      isCancellationRequested: false,
      onCancellationRequested(listener) {
        listeners.add(listener);
        return { dispose: () => listeners.delete(listener) };
      },
    },
    cancel() {
      this.token.isCancellationRequested = true;
      for (const listener of listeners) listener();
    },
  };
}
