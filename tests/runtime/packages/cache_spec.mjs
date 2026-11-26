import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rename, rm, stat, utimes, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { positionAt, root, ssBin, withLspClient } from "../harness.mjs";
import { applyProtocolEdits, editingTarget, previewBounds, requestEdit } from "../editor/support.mjs";
import { command, commit, git, repository, writeFiles } from "./harness.mjs";

const scratch = path.join(root, ".test-tmp/packages");
await mkdir(scratch, { recursive: true });
const work = await mkdtemp(path.join(scratch, "cache-"));
const deck = path.join(work, "deck");
const source = 'import pkg:wrapper\npage main\n  let item = text!(wrapper::caption())\n  ~!~ item.left == page.left + 20\n  ~!~ item.top == page.top - 40\n  ~ item.width == 300\n  ~ item.height == 80\nend\n';
const config = '[project]\nentry = "slide.ss"\n[editor.lsp]\ndebounce = 0\n';
const ss = (...args) => command(ssBin, args, deck);
const lockPath = path.join(deck, "ss.lock");
const uri = pathToFileURL(path.join(deck, "slide.ss")).href;
const query = { textDocument: { uri } };
async function replaceFile(file, text) {
  const previous = await stat(file);
  const replacement = `${file}.replacement`;
  await writeFile(replacement, text);
  await utimes(replacement, previous.atime, previous.mtime);
  await rename(replacement, file);
}
function assertContent(snapshot, content) {
  assert(!snapshot.stale, JSON.stringify(snapshot.build_diagnostics));
  assert(snapshot.display.html.includes(content), `missing ${content}: ${JSON.stringify(snapshot.display)}`);
}
function assertFailure(snapshot, code) {
  assert.equal(snapshot.stale, true);
  assert.match(JSON.stringify(snapshot.build_diagnostics), code);
}
async function open(client) {
  await client.initialize();
  const ready = client.waitForDiagnostics(uri);
  client.openDocument({ uri, text: source, version: 1 });
  assert.deepEqual((await ready).params.diagnostics, []);
}
try {
  const base = await repository(work, "base", {
    "ss.toml": '[package]\nname = "base"\n',
    "lib.ss": 'fn caption() -> String\n  return "Before"\nend\n',
  });
  const wrapper = await repository(work, "wrapper", {
    "ss.toml": `[package]\nname = "wrapper"\n[dependencies]\nbase = { git = ${JSON.stringify(base)}, branch = "main" }\n`,
    "lib.ss": 'import pkg:base\nfn caption() -> String\n  return base::caption()\nend\n',
  });
  await writeFiles(deck, { "ss.toml": config, "slide.ss": source });
  ss("add", "--git", wrapper, "--branch", "main");
  const firstLock = await readFile(lockPath, "utf8");
  await withLspClient({ cwd: deck }, async client => {
    await open(client);
    assertContent(await client.request("ss/editorSnapshot", query), "Before");
    await writeFile(path.join(base, "lib.ss"), 'fn caption() -> String\n  return "After"\nend\n');
    commit(base, "Update dependency");
    ss("update");
    const secondLock = await readFile(lockPath, "utf8");
    const first = JSON.parse(firstLock), second = JSON.parse(secondLock);
    assert.equal(first.packages.find(p => p.git === wrapper).id, second.packages.find(p => p.git === wrapper).id);
    // No workspace/didChangeWatchedFiles notifications are sent in this spec.
    assertContent(await client.request("ss/editorSnapshot", {}), "After");
    for (const [text, content] of [[firstLock, "Before"], [secondLock, "After"]]) {
      await replaceFile(lockPath, text);
      assertContent(await client.request("ss/editorSnapshot", query), content);
    }
    await replaceFile(lockPath, "{ invalid lock");
    assertFailure(await client.request("ss/editorSnapshot", query), /InvalidPackageLock/);
    await rm(lockPath);
    assertFailure(await client.request("ss/editorSnapshot", query), /PackageLockRequired/);
    await writeFile(lockPath, secondLock);
    assertContent(await client.request("ss/editorSnapshot", query), "After");
    await rm(path.join(deck, ".ss-cache/packages/sources"), { recursive: true });
    assertFailure(await client.request("ss/editorSnapshot", query), /PackageNotFetched/);
    ss("fetch", "--locked");
    assert.equal(await readFile(lockPath, "utf8"), secondLock);
    assertContent(await client.request("ss/editorSnapshot", query), "After");
    const basePackage = second.packages.find(p => p.git === base);
    const marker = path.join(deck, ".ss-cache/packages/sources", basePackage.id, ".git/ss-commit");
    await replaceFile(marker, "0".repeat(basePackage.commit.length));
    assertFailure(await client.request("ss/editorSnapshot", query), /PackageNotFetched/);
    await replaceFile(marker, basePackage.commit);
    assertContent(await client.request("ss/editorSnapshot", query), "After");
    // Equal-length configuration changes must invalidate when mtime is restored.
    git(wrapper, "branch", "next");
    const originalConfig = await readFile(path.join(deck, "ss.toml"), "utf8");
    const changedConfig = originalConfig.replace('branch = "main"', 'branch = "next"');
    assert.notEqual(changedConfig, originalConfig);
    assert.equal(changedConfig.length, originalConfig.length);
    await replaceFile(path.join(deck, "ss.toml"), changedConfig);
    assertFailure(await client.request("ss/editorSnapshot", query), /PackageLockRequired/);
    ss("fetch");
    assertContent(await client.request("ss/editorSnapshot", query), "After");
    await replaceFile(path.join(deck, "ss.toml"), originalConfig);
    ss("fetch");
    // A semantic query must stop using types from an older dependency graph.
    await writeFile(path.join(base, "lib.ss"), 'fn caption() -> Number\n  return 7\nend\n');
    commit(base, "Change return type");
    ss("update");
    await client.request("textDocument/hover", { ...query, position: positionAt(source, "wrapper::caption", 10) });
    assertFailure(await client.request("ss/editorSnapshot", query), /TypeMismatch/);
    await replaceFile(lockPath, secondLock);
    assertContent(await client.request("ss/editorSnapshot", query), "After");
  });
  // A generated geometry edit must not reuse state from the old lock graph.
  await replaceFile(lockPath, firstLock);
  ss("fetch", "--locked");
  await withLspClient({ cwd: deck, measureProfile: true }, async client => {
    await open(client);
    const initial = await client.request("ss/editorSnapshot", query);
    assertContent(initial, "Before");
    const target = editingTarget(initial, "item");
    const from = previewBounds(initial, target.node_id);
    const edit = await requestEdit(client, uri, initial, target, from, { ...from, x: 120 }, "absolute", target.page_id);
    const nextSource = applyProtocolEdits(source, edit.workspaceEdit.changes[uri]);
    await writeFile(path.join(base, "lib.ss"), 'fn caption() -> String\n  return "Latest"\nend\n');
    commit(base, "Restore string return type");
    ss("update");
    client.changeDocument({ uri, text: nextSource, version: 2 });
    const moved = await client.request("ss/editorSnapshot", { ...query, baseSnapshotId: initial.snapshot_id });
    assertContent(moved, "Latest");
    assert.equal(moved.display.schema, 2);
    const bounds = previewBounds(moved, editingTarget(moved, "item").node_id);
    assert(Math.abs(bounds.x - 120) < 0.1);
    // An edit requested against an already outdated analysis must be rejected.
    await replaceFile(lockPath, firstLock);
    const movedTarget = editingTarget(moved, "item");
    const outdated = await requestEdit(client, uri, moved, movedTarget, bounds, { ...bounds, x: 160 }, "absolute", movedTarget.page_id);
    assert.equal(outdated.status, "stale", JSON.stringify(outdated));
    assertContent(await client.request("ss/editorSnapshot", query), "Before");
    await client.close();
    assert(!/generated edit applied: [1-9]/.test(client.stderr), client.stderr);
  });
  console.log("Package cache: notification-free lock updates, restoration, semantic queries and generated edits passed");
} finally {
  await rm(work, { recursive: true, force: true });
}
