#!/usr/bin/env node
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../..");
const require = createRequire(import.meta.url);
const esbuild = require(path.join(root, "editor/vscode/node_modules/esbuild"));
const files = new Map();
const reads = new Map();
let searches = 0;
const watches = new Set();
let failingDirectory;
const workspaceChanges = event();
const Uri = { file: (fsPath) => ({ scheme: "file", fsPath: path.resolve(fsPath) }) };
class RelativePattern {
  constructor(baseUri, pattern) { this.baseUri = baseUri; this.pattern = pattern; }
}
const workspace = {
  workspaceFolders: [],
  onDidChangeWorkspaceFolders: workspaceChanges.subscribe,
  createFileSystemWatcher(pattern) {
    if (pattern.baseUri.fsPath === failingDirectory) throw new Error("watch unavailable");
    const events = { change: event(), create: event(), delete: event() };
    const watcher = {
      pattern,
      events,
      onDidChange: events.change.subscribe,
      onDidCreate: events.create.subscribe,
      onDidDelete: events.delete.subscribe,
      dispose() { watches.delete(watcher); },
    };
    watches.add(watcher);
    return watcher;
  },
};
globalThis.__ssProjectConfigTest = {
  workspace, Uri, RelativePattern,
  existsSync(file) { searches++; return files.has(file); },
  readFileSync(file) {
    reads.set(file, (reads.get(file) ?? 0) + 1);
    const source = files.get(file);
    if (source === undefined || source instanceof Error) throw source ?? new Error("missing file");
    return source;
  },
};
const output = await esbuild.build({
  entryPoints: [path.join(root, "editor/vscode/src/projectConfig.ts")],
  bundle: true, write: false, format: "esm", platform: "node",
  plugins: [{
    name: "mock-project-configuration-io",
    setup(build) {
      build.onResolve({ filter: /^(vscode|fs)$/ }, ({ path }) => ({ path, namespace: "ss-test" }));
      build.onLoad({ filter: /.*/, namespace: "ss-test" }, ({ path }) => ({
        contents: path === "vscode"
          ? "export const { workspace, Uri, RelativePattern } = globalThis.__ssProjectConfigTest;"
          : "export const { existsSync, readFileSync } = globalThis.__ssProjectConfigTest;",
      }));
    },
  }],
});
const config = await import(`data:text/javascript;base64,${Buffer.from(output.outputFiles[0].text).toString("base64")}`);
const lifetime = config.initializeProjectSettings();
try {
  files.set("/one/ss.toml", source("first.ss", 150));
  const firstUri = Uri.file("/one/slides/slide.ss");
  workspace.workspaceFolders = [{ uri: Uri.file("/one/slides") }];
  const first = config.projectSettings(firstUri);
  const firstSearches = searches;
  for (let index = 0; index < 1000; index++) {
    assert.equal(config.projectSettings(firstUri), first);
    assert.equal(config.projectEntryUri(firstUri).fsPath, "/one/first.ss");
  }
  assert.equal(searches, firstSearches, "unchanged lookups searched the filesystem again");
  assert.equal(reads.get("/one/ss.toml"), 1);
  assert.equal(config.projectSettings(Uri.file("/one/other/slide.ss")), first);
  assert.equal(reads.get("/one/ss.toml"), 1, "folders sharing a project parsed separate copies");
  assert.throws(() => { first.lsp.enabled = false; }, TypeError);
  assert.throws(() => { first.wysiwyg.maxWaitMs = 1; }, TypeError);

  let observed;
  const changes = config.onDidChangeProjectSettings(() => { observed = config.projectSettings(firstUri); });
  files.set("/one/ss.toml", source("second.ss", 250));
  fire("/one", "change");
  assert.equal(observed.wysiwyg.debounceMs, 250, "listeners received old settings");
  assert.equal(config.projectEntryUri(firstUri).fsPath, "/one/second.ss");
  assert.equal(reads.get("/one/ss.toml"), 2);
  files.set("/one/slides/ss.toml", source("nested.ss", 350));
  fire("/one/slides", "create");
  assert.equal(config.projectSettings(firstUri).wysiwyg.debounceMs, 350);
  assert.equal(config.projectEntryUri(firstUri).fsPath, "/one/slides/nested.ss");
  files.delete("/one/slides/ss.toml");
  fire("/one/slides", "delete");
  assert.equal(config.projectSettings(firstUri).wysiwyg.debounceMs, 250);
  assert.equal(config.projectEntryUri(firstUri).fsPath, "/one/second.ss");
  changes.dispose();

  files.set("/two/ss.toml", source("two.ss", 450));
  const secondUri = Uri.file("/two/slide.ss");
  const second = config.projectSettings(secondUri);
  files.set("/one/ss.toml", source("third.ss", 550));
  fire("/one", "change");
  assert.equal(config.projectSettings(secondUri), second, "an unrelated project was discarded");
  assert.equal(reads.get("/two/ss.toml"), 1);
  workspace.workspaceFolders = [{ uri: Uri.file("/two") }];
  workspaceChanges.fire({ added: workspace.workspaceFolders, removed: [] });
  assert.equal(config.projectEntryUri(undefined).fsPath, "/two/two.ss");
  assert.equal(config.projectSettings(undefined).wysiwyg.debounceMs, 450);

  const missingUri = Uri.file("/missing/deck/slide.ss");
  const defaults = config.projectSettings(missingUri);
  const missingSearches = searches;
  assert.equal(config.projectSettings(missingUri), defaults);
  assert.equal(searches, missingSearches);
  files.set("/missing/ss.toml", new Error("temporarily unreadable"));
  fire("/missing", "create");
  assert.equal(config.projectSettings(missingUri), defaults);
  files.set("/missing/ss.toml", source("recovered.ss", 650));
  fire("/missing", "change");
  assert.equal(config.projectSettings(missingUri).wysiwyg.debounceMs, 650);

  files.set("/folder/ss.toml", source("outer.ss", 700));
  files.set("/folder/child/ss.toml", source("inner.ss", 800));
  const childUri = Uri.file("/folder/child/slide.ss");
  assert.equal(config.projectSettings(childUri).wysiwyg.debounceMs, 800);
  const beforeUnrelatedChange = searches;
  fire("/folder", "change", "/folder/unrelated.txt");
  assert.equal(config.projectSettings(childUri).wysiwyg.debounceMs, 800);
  assert.equal(searches, beforeUnrelatedChange);
  files.delete("/folder/child/ss.toml");
  fire("/folder", "delete", "/folder/child");
  assert.equal(config.projectSettings(childUri).wysiwyg.debounceMs, 700);
  files.set("/folder/child/ss.toml", source("restored.ss", 900));
  fire("/folder", "create", "/folder/child");
  assert.equal(config.projectSettings(childUri).wysiwyg.debounceMs, 900);

  files.set("/failed/ss.toml", source("fresh.ss", 1100));
  const failedUri = Uri.file("/failed/sub/deep/slide.ss");
  const watchesBeforeFailure = watches.size;
  failingDirectory = "/failed/sub";
  assert.equal(config.projectSettings(failedUri).wysiwyg.debounceMs, 1100);
  assert.equal(watches.size, watchesBeforeFailure, "partial observation setup leaked watches");
  files.set("/failed/ss.toml", source("fresh.ss", 1200));
  assert.equal(config.projectSettings(failedUri).wysiwyg.debounceMs, 1200);
  assert.equal(watches.size, watchesBeforeFailure);
  failingDirectory = undefined;

  for (let index = 0; index < 160; index++) {
    const directory = `/bounded/p${index}`;
    files.set(`${directory}/ss.toml`, source("slide.ss", index));
    assert.equal(config.projectSettings(Uri.file(`${directory}/slide.ss`)).wysiwyg.debounceMs, index);
    assert.ok(watches.size <= 256, `retained ${watches.size} directory watches`);
  }
  const recent = config.projectSettings(Uri.file("/bounded/p159/slide.ss"));
  assert.equal(reads.get("/bounded/p159/ss.toml"), 1);
  config.projectSettings(Uri.file("/bounded/p0/slide.ss"));
  assert.equal(reads.get("/bounded/p0/ss.toml"), 2, "old lookup was never evicted");
  assert.equal(config.projectSettings(Uri.file("/bounded/p159/slide.ss")), recent);
  assert.equal(reads.get("/bounded/p159/ss.toml"), 1);

  const deep = `/deep/${Array(260).fill("child").join("/")}/slide.ss`;
  files.set("/deep/ss.toml", source("deep.ss", 750));
  const previousWatches = watches.size;
  assert.equal(config.projectSettings(Uri.file(deep)).wysiwyg.debounceMs, 750);
  files.set("/deep/ss.toml", source("deep.ss", 850));
  assert.equal(config.projectSettings(Uri.file(deep)).wysiwyg.debounceMs, 850);
  assert.equal(watches.size, previousWatches, "unretained deep path leaked watches");
} finally {
  lifetime.dispose();
  assert.equal(watches.size, 0);
  assert.equal(workspaceChanges.listeners.size, 0);
  delete globalThis.__ssProjectConfigTest;
}
console.log("Project settings cache tests passed: 2,000 repeated settings/entry requests used one read and no repeated discovery");

function source(entry, debounce) {
  return `[project]\nentry = "${entry}"\n[editor.wysiwyg]\ndebounce = ${debounce}\n`;
}
function event() {
  const listeners = new Set();
  return {
    listeners,
    subscribe(listener) { listeners.add(listener); return { dispose: () => listeners.delete(listener) }; },
    fire(value) { for (const listener of [...listeners]) listener(value); },
  };
}
function fire(directory, kind, changedPath = `${directory}/ss.toml`) {
  const targets = [...watches].filter((watcher) => watcher.pattern.baseUri.fsPath === directory);
  assert.ok(targets.length > 0, `no configuration watch for ${directory}`);
  for (const watcher of targets) watcher.events[kind].fire(Uri.file(changedPath));
}
