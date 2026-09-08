#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, rename, rm, stat, utimes, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, root, withLspClient } from "../../harness.mjs";
import { applyProtocolEdits, editingTarget, previewBounds, requestEdit } from "../../editor/support.mjs";

const fontProbe = spawnSync("fc-match", ["--format=%{file}", "sans-serif"], { encoding: "utf8", timeout: 5000 });
if (fontProbe.error?.code === "ENOENT") {
  console.log("Skipping font environment edit case: fc-match is unavailable.");
} else {
  assert(fontProbe.status === 0 && fontProbe.stdout.trim().length > 0, `fc-match failed: ${fontProbe.error ?? fontProbe.stderr}`);
  await testFontEnvironmentChange(path.dirname(fontProbe.stdout.trim()));
}

const texProbe = spawnSync("pdflatex", ["--version"], { encoding: "utf8", timeout: 5000 });
if (texProbe.error?.code === "ENOENT") {
  console.log("Skipping TeX dependency edit case: pdflatex is unavailable.");
} else {
  assert(texProbe.status === 0, `pdflatex failed: ${texProbe.error ?? texProbe.stderr}`);
  await testLatexInputChange();
}

function xml(text) {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

async function testFontEnvironmentChange(fontDirectory) {
  const fixture = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-generated-font-environment-"));
  const previousConfig = process.env.FONTCONFIG_FILE;
  try {
    const slide = path.join(fixture, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const config = path.join(fixture, "fonts.conf");
    const fontCache = path.join(fixture, "font-cache");
    await mkdir(fontCache);
    const configuration = `<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd"><fontconfig><dir>${xml(fontDirectory)}</dir><cachedir>${xml(fontCache)}</cachedir><!-- a --></fontconfig>\n`;
    await writeFile(config, configuration);
    process.env.FONTCONFIG_FILE = config;
    let source = `import std:themes/default as *
page demo
let item = text!("Move me")
end
`;
    await writeFile(slide, source);
    await writeFile(path.join(fixture, "ss.toml"), `[project]
entry = "slide.ss"
[editor.lsp]
debounce = 0
[editor.wysiwyg.refresh]
automatic = false
`);
    await withLspClient({ cwd: fixture }, async (client) => {
      await client.initialize();
      const opened = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      assert((await opened).params.diagnostics.length === 0, "font environment fixture produced diagnostics");
      let snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
      for (let version = 2; version <= 3; version++) {
        const target = editingTarget(snapshot, "item");
        const from = previewBounds(snapshot, target.node_id);
        const to = { ...from, x: version * 30, y: version * 40 };
        const edit = await requestEdit(client, uri, snapshot, target, from, to, "absolute", target.page_id);
        assert(edit.status === "ok", `font environment position edit failed: ${JSON.stringify(edit)}`);
        source = applyProtocolEdits(source, edit.workspaceEdit?.changes?.[uri] ?? []);
        if (version === 3) {
          const original = await stat(config);
          const replacement = `${config}.replacement`;
          await writeFile(replacement, configuration.replace("<!-- a -->", "<!-- b -->"));
          await utimes(replacement, original.atime, original.mtime);
          await rename(replacement, config);
        }
        client.changeDocument({ uri, version, text: source });
        const moved = await client.request("ss/editorSnapshot", { textDocument: { uri }, baseSnapshotId: snapshot.snapshot_id });
        if (version === 3) {
          assert(moved.display?.schema === 2 && moved.display?.kind !== "translation_patch" && typeof moved.display?.html === "string",
            `changed font environment reused the previous display: ${JSON.stringify(moved.display)}`);
        }
        const movedTarget = editingTarget(moved, "item");
        const bounds = previewBounds(moved, movedTarget.node_id);
        assert(Math.abs(bounds.x - to.x) < 0.01 && Math.abs(bounds.y - to.y) < 0.01, "font environment rebuild lost the generated position");
        snapshot = moved;
      }
    });
  } finally {
    if (previousConfig === undefined) delete process.env.FONTCONFIG_FILE;
    else process.env.FONTCONFIG_FILE = previousConfig;
    await rm(fixture, { recursive: true, force: true });
  }
}


async function testLatexInputChange() {
  const scratch = path.join(root, ".ss-cache", "tests", "generated-latex-inputs");
  await mkdir(scratch, { recursive: true });
  const fixture = await mkdtemp(path.join(scratch, "project-"));
  try {
    const slide = path.join(fixture, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const input = path.join(fixture, "fragment.tex");
    await writeFile(input, String.raw`\color{red}\rule{12pt}{10pt}`);
    let source = String.raw`import std:themes/default as *
page demo
let item = text!("$\input{fragment.tex}$")
end
`;
    await writeFile(slide, source);
    await writeFile(path.join(fixture, "ss.toml"), `[project]
entry = "slide.ss"
[editor.lsp]
debounce = 0
[editor.wysiwyg.refresh]
automatic = false
`);
    await withLspClient({ cwd: fixture }, async (client) => {
      await client.initialize();
      const opened = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source, version: 1 });
      assert((await opened).params.diagnostics.length === 0, "TeX input fixture produced diagnostics");
      let snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
      for (let version = 2; version <= 3; version++) {
        const target = editingTarget(snapshot, "item");
        const from = previewBounds(snapshot, target.node_id);
        const to = { ...from, x: version * 30, y: version * 40 };
        const edit = await requestEdit(client, uri, snapshot, target, from, to, "absolute", target.page_id);
        assert(edit.status === "ok", `TeX position edit failed: ${JSON.stringify(edit)}`);
        source = applyProtocolEdits(source, edit.workspaceEdit?.changes?.[uri] ?? []);
        if (version === 3) await writeFile(input, String.raw`\color{blue}\rule{12pt}{10pt}`);
        client.changeDocument({ uri, version, text: source });
        const moved = await client.request("ss/editorSnapshot", { textDocument: { uri }, baseSnapshotId: snapshot.snapshot_id });
        if (version === 3) {
          assert(moved.display?.schema === 2 && moved.display?.kind !== "translation_patch" && typeof moved.display?.html === "string",
            `changed TeX input reused the previous display: ${JSON.stringify(moved.display)}`);
        }
        const bounds = previewBounds(moved, editingTarget(moved, "item").node_id);
        assert(Math.abs(bounds.x - to.x) < 0.01 && Math.abs(bounds.y - to.y) < 0.01, "TeX rebuild lost the generated position");
        snapshot = moved;
      }
    });
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
}
