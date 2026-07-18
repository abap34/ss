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
const { isRetryableSnapshotError } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled).toString("base64")}`
);

assert.equal(isRetryableSnapshotError({ code: -32800 }), true);
assert.equal(isRetryableSnapshotError({ code: -32801 }), true);
assert.equal(isRetryableSnapshotError({ code: -32603 }), false);
assert.equal(isRetryableSnapshotError({ code: "-32801" }), false);
assert.equal(isRetryableSnapshotError(new Error("content modified")), false);
assert.equal(isRetryableSnapshotError(null), false);
