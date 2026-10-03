#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, rename, rm, stat, utimes, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, positionAt, root, withLspClient } from "../../harness.mjs";
import { applyProtocolEdits, editingTarget, previewBounds, requestEdit } from "../../editor/support.mjs";

const scratch = path.join(root, ".ss-cache", "tests", "generated-edit-reuse");
await mkdir(scratch, { recursive: true });
for (const kind of ["text", "module", "readlines", "svg", "raster"]) await testReuse(kind);
const tex = spawnSync("pdflatex", ["--version"], { encoding: "utf8", timeout: 5000 });
if (tex.status === 0) await testReuse("math");
else console.log("Skipping unchanged TeX input case: pdflatex is unavailable.");

async function testReuse(kind) {
  const project = await mkdtemp(path.join(scratch, `${kind}-`));
  try {
    const uri = pathToFileURL(path.join(project, "slide.ss")).toString();
    const expression = {
      text: 'text!("Move me")',
      module: 'watched_item!()',
      readlines: 'code_file!("snippet.txt", "plain")',
      svg: 'image!("asset.svg")',
      raster: 'image!("asset.png")',
      math: String.raw`text!("$\input{fragment.tex}$")`,
    }[kind];
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60"><rect width="120" height="60" fill="#ff0000"/></svg>';
    await writeFile(path.join(project, "asset.svg"), svg);
    await writeFile(path.join(project, "asset.png"), Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=", "base64"));
    await writeFile(path.join(project, "snippet.txt"), "UNCHANGED_EXTERNAL_INPUT\n");
    await writeFile(path.join(project, "fragment.tex"), String.raw`\rule{12pt}{10pt}`);
    const moduleSource = 'import std:themes/default as *\nfn watched_item!() -> Object\nreturn text!("Module input")\nend\n';
    await writeFile(path.join(project, "parts.ss"), moduleSource);
    let source = `import std:themes/default as *
${kind === "module" ? 'import "./parts" as *\n' : ""}page first
let marker = "👋"
let item = ${expression}
~!~ item.left == page.left + 20
~!~ item.top == page.top - 40
~ item.right == item.left + 360
~ item.bottom == item.top - 80
let after = text!("After")
~ after.left == item.left
~ after.top == item.bottom - 20
end
page second
let next = text!("Next")
~!~ next.left == page.left + 20
~!~ next.top == page.top - 40
~ next.right == next.left + 160
end
`;
    await writeFile(path.join(project, "slide.ss"), source);
    await writeFile(path.join(project, "ss.toml"), '[project]\nentry="slide.ss"\n[editor.lsp]\ndebounce=0\n[editor.wysiwyg.refresh]\nautomatic=false\n');
    await withLspClient({ cwd: project, measureProfile: true }, async (client) => {
      await client.initialize();
      const diagnostics = client.waitForDiagnostics(uri);
      client.openDocument({ uri, version: 1, text: source });
      assert((await diagnostics).params.diagnostics.length === 0, `${kind}: initial diagnostics`);
      let snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
      assert(!snapshot.stale, `${kind}: initial build failed ${JSON.stringify(snapshot.build_diagnostics)}`);
      let version = 1;
      for (const [binding, x, y] of [["item", 120, 140], ["item", 9.25, 8.5], ["item", 0, 0], ["item", 40, 50], ["next", 120, 140]]) {
        const target = editingTarget(snapshot, binding);
        const from = previewBounds(snapshot, target.node_id);
        const edit = await requestEdit(client, uri, snapshot, target, from, { ...from, x, y }, "absolute", target.page_id);
        assert(edit.status === "ok", `${kind}: ${binding} edit failed ${JSON.stringify(edit)}`);
        source = applyProtocolEdits(source, edit.workspaceEdit.changes[uri]);
        client.changeDocument({ uri, version: ++version, text: source });
        const moved = await client.request("ss/editorSnapshot", { textDocument: { uri }, baseSnapshotId: snapshot.snapshot_id });
        assert(moved.display?.kind === "translation_patch", `${kind}: unexpected full display at ${x},${y}: ${JSON.stringify(moved.build_diagnostics)}\n${client.stderr}`);
        const bounds = previewBounds(moved, editingTarget(moved, binding).node_id);
        assert(Math.abs(bounds.x - x) < 0.01 && Math.abs(bounds.y - y) < 0.01, `${kind}: wrong position`);
        const after = editingTarget(moved, "after");
        const statement = Buffer.from(source).subarray(after.statement_start, after.statement_end).toString();
        assert(statement.includes('let after = text!("After")'), `${kind}: stale statement span ${statement}`);
        const symbols = await client.request("textDocument/documentSymbol", { textDocument: { uri } });
        assert(symbols.some((entry) => entry.name === "second"), `${kind}: lost later page symbol`);
        const reference = positionAt(source, "~ after.left", 3);
        const definition = await client.request("textDocument/definition", { textDocument: { uri }, position: reference });
        const declaration = positionAt(source, 'let after = text!("After")', 4);
        assert(definition.some((entry) => entry.uri === uri && entry.range.start.line === declaration.line && entry.range.start.character === declaration.character), `${kind}: stale definition ${JSON.stringify(definition)}`);
        const hover = await client.request("textDocument/hover", { textDocument: { uri }, position: reference });
        assert(hover?.contents?.value?.includes("after"), `${kind}: lost hover after offset changes`);
        snapshot = moved;
      }
      if (kind === "svg" || kind === "module") {
        // Atomic replacement with equal length and restored mtime must invalidate.
        const asset = path.join(project, kind === "svg" ? "asset.svg" : "parts.ss");
        const previous = await stat(asset);
        const replacement = `${asset}.replacement`;
        await writeFile(replacement, kind === "svg" ? svg.replace("#ff0000", "#0000ff") : moduleSource.replace("Module input", "Module other"));
        await utimes(replacement, previous.atime, previous.mtime);
        await rename(replacement, asset);
        const target = editingTarget(snapshot, "item");
        const from = previewBounds(snapshot, target.node_id);
        const edit = await requestEdit(client, uri, snapshot, target, from, { ...from, x: 60 }, "absolute", target.page_id);
        source = applyProtocolEdits(source, edit.workspaceEdit.changes[uri]);
        client.changeDocument({ uri, version: ++version, text: source });
        const moved = await client.request("ss/editorSnapshot", { textDocument: { uri }, baseSnapshotId: snapshot.snapshot_id });
        assert(moved.display?.schema === 2, `${kind}: changed input must rebuild its display`);
      }
      await client.close();
      const applied = Number(client.stderr.match(/generated edit applied: (\d+) calls/)?.[1] ?? 0);
      assert(applied === 5, `${kind}: expected five retained-state updates, got ${applied}\n${client.stderr}`);
      console.log(`${kind}: ${client.stderr.match(/generated edit inputs: [^\n]+/)?.[0]}`);
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}
