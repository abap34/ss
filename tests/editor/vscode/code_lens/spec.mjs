import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(new URL("../../../../editor/vscode/package.json", import.meta.url));
const esbuild = require("esbuild");
const output = await esbuild.build({
  entryPoints: [fileURLToPath(new URL("../../../../editor/vscode/src/codeLens.ts", import.meta.url))],
  bundle: true, write: false, platform: "node", format: "esm",
});
const { provideCurrentCodeLenses } = await import(`data:text/javascript;base64,${Buffer.from(output.outputFiles[0].text).toString("base64")}`);

const document = { version: 1 };
const token = { isCancellationRequested: false };
const pending = [];
let published = false;
const next = (receivedDocument, receivedToken) => {
  assert.equal(receivedDocument, document);
  assert.equal(receivedToken, token);
  return new Promise(resolve => pending.push(resolve));
};
const request = provideCurrentCodeLenses(document, token, next).then(value => {
  published = true;
  return value;
});
for (let i = 0; i < 40; i++) {
  document.version++;
  pending.shift()([{ range: { start: { line: i } }, command: { title: "Jump to slide" } }]);
  await new Promise(setImmediate);
  assert.equal(published, false, "an outdated result replaced tracked CodeLens positions");
  assert.equal(pending.length, 1, "a changed document did not trigger another request");
}
const current = [{ range: { start: { line: 80 } }, command: { title: "Jump to slide" } }];
pending.shift()(current);
assert.equal(await request, current);

const deleted = await provideCurrentCodeLenses(document, token, () => []);
assert.deepEqual(deleted, [], "a current empty result must remove deleted pages");

const cancellation = { isCancellationRequested: false };
const canceled = provideCurrentCodeLenses(document, cancellation, (receivedDocument, receivedToken) => {
  assert.equal(receivedDocument, document);
  assert.equal(receivedToken, cancellation);
  return new Promise(resolve => pending.push(resolve));
});
cancellation.isCancellationRequested = true;
document.version++;
pending.shift()(current);
assert.equal(await canceled, null);
assert.equal(pending.length, 0, "cancellation started another request");
assert.equal(await provideCurrentCodeLenses(document, cancellation, () => assert.fail("already canceled")), null);
await assert.rejects(provideCurrentCodeLenses(document, token, () => Promise.reject(new Error("Server stopped"))), /Server stopped/);
console.log("CodeLens middleware: 40 overlapping edits, current empty results and cancellation passed");
