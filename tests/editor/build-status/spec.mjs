#!/usr/bin/env node
import assert from "node:assert/strict";
import {
  buildStatusPresentation,
  emptyPreviewMessage,
  formatBuildDuration,
} from "../../../editor/vscode/media/editor/workspace.js";
import {
  reconciliationFailureMessage,
} from "../../../editor/vscode/media/editor/diagnostics.js";

assert.equal(formatBuildDuration(0.4), "<1 ms");
assert.equal(formatBuildDuration(42.4), "42 ms");
assert.equal(formatBuildDuration(999.6), "1 s");
assert.equal(formatBuildDuration(1234), "1.2 s");
assert.equal(formatBuildDuration(12_340), "12.3 s");
assert.equal(formatBuildDuration(-1), null);
assert.equal(formatBuildDuration(Number.NaN), null);
assert.equal(
  emptyPreviewMessage("manual"),
  "Run “ss: Build WYSIWYG Preview” to build the preview.",
);
assert.deepEqual(
  buildStatusPresentation.manual,
  { label: "Build required", icon: "↻" },
);
assert.equal(reconciliationFailureMessage([
  { status: "applied" },
  {
    status: "failed",
    message: "The target shape changed before the edit could be applied.",
  },
]), "The target shape changed before the edit could be applied.");
assert.equal(reconciliationFailureMessage([
  { status: "failed", message: "The moved object is no longer present." },
  { status: "failed", message: "The target shape changed." },
]), "The moved object is no longer present.\nThe target shape changed.");
assert.equal(reconciliationFailureMessage([
  { status: "applied" },
  { status: "applied" },
]), null);
