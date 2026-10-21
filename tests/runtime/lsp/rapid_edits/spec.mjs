#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { root, withLspClient } from "../../harness.mjs";

const scratch = path.join(root, ".ss-cache/lsp-rapid-edits");
await mkdir(scratch, { recursive: true });
const project = await mkdtemp(path.join(scratch, "run-"));
const slide = path.join(project, "slide.ss");
const uri = pathToFileURL(slide).href;
const source = `import std:themes/default as *
fn label(value: String) -> Text
  return text(value)
end
${Array.from({ length: 16 }, (_, i) => `page sample_${i}
  let caption = "Heading ${i}"
  let title = text!(caption)
  let body = place!(label(caption) |=| (label(caption) /=/ label(caption)))
  ~ body.width == 800
  ~ body.height == 300
end`).join("\n")}
`;

try {
  await writeFile(slide, source);
  await withLspClient({ cwd: project }, async client => {
    await client.initialize();
    const initial = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source, version: 1 });
    assert.deepEqual((await initial).params.diagnostics, []);
    await client.request("ss/editorSnapshot", { textDocument: { uri } });
    const outcomes = [];
    let version = 1;
    for (let i = 0; i < 160; i += 1) {
      const text = source.replace("Heading 0", `Heading ${i}`) +
        (i % 3 === 0 ? "page unfinished\nlet incomplete =\n" : "");
      client.changeDocument({ uri, text, version: ++version });
      const request = client.startRequest("ss/editorSnapshot", { textDocument: { uri } });
      outcomes.push(request.promise.then(() => null, error => error));
      if (i % 2 === 0) client.cancelRequest(request.id);
      await new Promise(resolve => setTimeout(resolve, 2));
    }
    const finalVersion = ++version;
    const final = client.waitForDiagnostics(uri, (_, message) => message.params.version === finalVersion);
    client.changeDocument({ uri, text: source, version: finalVersion });
    for (const error of await Promise.all(outcomes)) {
      if (error) assert(/-32800|-32801/.test(error.message), error.message);
    }
    assert.deepEqual((await final).params.diagnostics, []);
    const recovered = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert.equal(recovered.layout.pages.length, 16);
    assert(!recovered.stale);
    assert(!client.stderr.includes("error:"), client.stderr);
  });
  console.log("Rapid edits: cancellation, incomplete source and final preview recovery passed");
} finally {
  await rm(project, { recursive: true, force: true });
}
