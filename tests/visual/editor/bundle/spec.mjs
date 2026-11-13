#!/usr/bin/env node
import assert from "node:assert/strict";
import { cp, mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { pdfAsset } from "../../render/assets.mjs";
import { withBrowser } from "../../render/capture.mjs";
import { editorSnapshot, testDocument } from "../fixture.mjs";
import { exercisePdfUpdates } from "../updates.mjs";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../..");
const output = path.join(repository, ".test-tmp/editor-bundle-test");
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await cp(path.join(repository, "editor/vscode/out"), path.join(output, "out"), { recursive: true });
await cp(path.join(repository, "editor/vscode/media/editor/main.css"), path.join(output, "main.css"));
await writeFile(path.join(output, "asset.pdf"), pdfAsset());
await writeFile(path.join(output, "index.html"), testDocument().replace('src="main.js"', 'src="out/editor/main.js"'));
// A stale separate runtime must never be used by the compiled editor.
await writeFile(path.join(output, "out/render/pdf.js"), 'throw new Error("A stale PDF runtime was loaded");\n');

const separateRuntimes = [];
await withBrowser(output, async (browser, baseUrl) => {
  const recordRequest = (request) => {
    if (new URL(request.url()).pathname.endsWith("/out/render/pdf.js")) {
      separateRuntimes.push(request.url());
    }
  };
  const observedBrowser = {
    async newPage(options) {
      const page = await browser.newPage(options);
      page.on("request", recordRequest);
      return page;
    },
  };
  await exercisePdfUpdates(observedBrowser, baseUrl, editorSnapshot());
});
assert.deepEqual(separateRuntimes, [], "the compiled editor loaded a separately built PDF runtime");
console.log("Compiled editor PDF checks passed.");
