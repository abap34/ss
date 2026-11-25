import assert from "node:assert/strict";
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { root, ssBin, withLspClient } from "../harness.mjs";
import { command } from "./harness.mjs";

// Explicit network integration test against the public example package.
const repository = "https://github.com/abap34/arrows.git";
const scratch = path.join(root, ".test-tmp/packages-remote");
await mkdir(scratch, { recursive: true });
const work = await mkdtemp(path.join(scratch, "arrows-"));
const deck = path.join(work, "deck");
const restored = path.join(work, "restored");
const offline = { ...process.env, GIT_ALLOW_PROTOCOL: "file" };
const shapes = ["straight", "curve", "elbow", "bend", "arc", "u_turn", "loop", "wave", "zigzag", "step", "block", "double_block", "chevron", "taper", "swoosh", "bent_block"];
const source = `import pkg:arrows as a
page gallery
${shapes.map((name, i) => `  let label_${i} = text!("${name}", default_text_style with { size = 20 line_height = 24 })
  ~ label_${i}.left == page.left + ${40 + i % 4 * 310}
  ~ label_${i}.top == page.top - ${35 + Math.floor(i / 4) * 165}
  let arrow_${i} = a::${name}!(${name === "straight" ? "180" : "180, 65"})
  ~ arrow_${i}.left == label_${i}.left
  ~ arrow_${i}.top == label_${i}.bottom - 12`).join("\n")}
end
page customized
  a::curve!(220, 90, a::StrokeStyle { color = c"#b5485d" width = 5 head = a::stealth ends = a::both }, a::CurveStyle { bend = 0.5 })
  a::zigzag!(220, 90, a::StrokeStyle { direction = a::down }, a::ZigZagStyle { amplitude = 0.6 })
  a::block!(220, 70, a::SolidStyle { color = c"#16806a" }, a::BlockStyle { shaft = 0.2 })
end
`;
const ss = (cwd, ...args) => command(ssBin, args, cwd);
const ssOffline = (cwd, ...args) => command(ssBin, args, cwd, 0, offline);
try {
  await mkdir(deck);
  await writeFile(path.join(deck, "ss.toml"), '[project]\nentry = "slide.ss"\n');
  await writeFile(path.join(deck, "slide.ss"), source);
  ss(deck, "add", "--git", repository);
  const manifest = await readFile(path.join(deck, "ss.toml"), "utf8");
  const locked = await readFile(path.join(deck, "ss.lock"), "utf8");
  const lock = JSON.parse(locked);
  assert.equal(lock.packages.length, 1);
  assert.equal(lock.packages[0].git, repository);
  assert.equal(lock.packages[0].name, "arrows");
  assert.match(lock.packages[0].commit, /^[0-9a-f]{40}$/);
  assert.match(manifest, /\[dependencies\.arrows\]/);

  ssOffline(deck, "dump", "--quiet", "--output", "dump.json");
  const dump = JSON.parse(await readFile(path.join(deck, "dump.json"), "utf8"));
  assert.deepEqual(dump.diagnostics, []);
  assert.equal(dump.page_order.length, 2);
  assert.equal(dump.nodes.filter(n => n.placement?.input.type.name === "PathShape").length, 19);
  ssOffline(deck, "render", "--quiet", "--output", "arrows.pdf");
  assert.equal((await readFile(path.join(deck, "arrows.pdf"))).subarray(0, 5).toString(), "%PDF-");

  await withLspClient({ cwd: deck, env: offline }, async client => {
    await client.initialize();
    const uri = pathToFileURL(path.join(deck, "slide.ss")).href;
    const ready = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source });
    assert.deepEqual((await ready).params.diagnostics, []);
    const lines = source.split("\n");
    const line = lines.findIndex(line => line.includes("a::straight!"));
    const character = lines[line].indexOf("straight!");
    const completion = await client.request("textDocument/completion", { textDocument: { uri }, position: { line, character } });
    const items = completion.items ?? completion;
    assert(items.some(item => item.label === "straight!"), JSON.stringify(items));
    const definition = await client.request("textDocument/definition", { textDocument: { uri }, position: { line, character: character + 1 } });
    assert(definition.some(location => location.uri.includes("/.ss-cache/packages/sources/")), JSON.stringify(definition));
    const snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert(!snapshot.stale);
    assert.equal(snapshot.layout.pages.length, 2);
    for (const object of snapshot.layout.objects) assert.equal(object.location?.path, path.join(deck, "slide.ss"));
  });

  // A fresh consumer restores exactly the locked commit from GitHub.
  await mkdir(restored);
  for (const name of ["ss.toml", "ss.lock", "slide.ss"]) await copyFile(path.join(deck, name), path.join(restored, name));
  ss(restored, "fetch", "--locked");
  assert.equal(await readFile(path.join(restored, "ss.lock"), "utf8"), locked);
  // Retained Git objects must also restore source snapshots without network access.
  await rm(path.join(restored, ".ss-cache/packages/sources"), { recursive: true });
  ssOffline(restored, "fetch", "--locked");
  ssOffline(restored, "dump", "--quiet", "--output", "dump.json");
  const again = JSON.parse(await readFile(path.join(restored, "dump.json"), "utf8"));
  const paint = document => document.nodes.filter(n => n.render).map(n => n.render);
  assert.deepEqual(paint(again), paint(dump));
  assert.equal(await readFile(path.join(restored, "ss.lock"), "utf8"), locked);
  await copyFile(path.join(deck, "arrows.pdf"), path.join(scratch, "arrows.pdf"));
  console.log(`Public arrows package ${lock.packages[0].commit}: 16 shapes, customization, PDF, LSP, locked and offline restoration passed`);
} finally {
  await rm(work, { recursive: true, force: true });
}
