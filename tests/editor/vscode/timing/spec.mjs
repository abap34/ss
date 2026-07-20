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
  path.join(root, "editor", "vscode", "src", "editor", "timing.ts"),
  "utf8",
);
const compiled = ts.transpileModule(source, {
  compilerOptions: {
    module: ts.ModuleKind.ES2020,
    target: ts.ScriptTarget.ES2020,
  },
}).outputText;
const { refreshTiming, shouldStartPendingRefresh } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled).toString("base64")}`
);

const first = refreshTiming(1_000, undefined, 140, 700);
assert.deepEqual(first, { pendingSinceMs: 1_000, delayMs: 140 });

const continued = refreshTiming(1_400, first.pendingSinceMs, 140, 700);
assert.deepEqual(continued, { pendingSinceMs: 1_000, delayMs: 140 });

const bounded = refreshTiming(1_650, first.pendingSinceMs, 140, 700);
assert.deepEqual(bounded, { pendingSinceMs: 1_000, delayMs: 50 });

const due = refreshTiming(1_700, first.pendingSinceMs, 140, 700);
assert.deepEqual(due, { pendingSinceMs: 1_000, delayMs: 0 });

const immediate = refreshTiming(2_000, undefined, 140, 0);
assert.deepEqual(immediate, { pendingSinceMs: 2_000, delayMs: 0 });

assert.equal(
  shouldStartPendingRefresh(true, true),
  false,
  "an existing debounce timer should own the pending refresh",
);
assert.equal(
  shouldStartPendingRefresh(true, false),
  true,
  "an elapsed debounce timer should refresh after the request finishes",
);
assert.equal(
  shouldStartPendingRefresh(false, false),
  false,
  "a completed request should not create an unrequested refresh",
);
