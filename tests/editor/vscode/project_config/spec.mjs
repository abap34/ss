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
const Uri = {
  file: (fsPath) => ({ scheme: "file", fsPath: path.resolve(fsPath), toString() { return this.fsPath; } }),
  parse: (value) => ({ toString: () => value }),
};
const documentChanges = event();
const documentSaves = event();
const activeEditors = event();
const visibleEditors = event();
const decorations = new Set();
const window = {
  visibleTextEditors: [],
  onDidChangeActiveTextEditor: activeEditors.subscribe,
  onDidChangeVisibleTextEditors: visibleEditors.subscribe,
  createTextEditorDecorationType(options) {
    const decoration = { options, dispose() { decorations.delete(decoration); } };
    decorations.add(decoration);
    return decoration;
  },
};
class RelativePattern {
  constructor(baseUri, pattern) { this.baseUri = baseUri; this.pattern = pattern; }
}
const workspace = {
  workspaceFolders: [],
  onDidChangeWorkspaceFolders: workspaceChanges.subscribe,
  onDidChangeTextDocument: documentChanges.subscribe,
  onDidSaveTextDocument: documentSaves.subscribe,
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
  workspace, window, Uri, RelativePattern,
  DecorationRangeBehavior: { ClosedClosed: 1 }, OverviewRulerLane: { Left: 1 },
  existsSync(file) { searches++; return files.has(file); },
  readFileSync(file) {
    reads.set(file, (reads.get(file) ?? 0) + 1);
    const source = files.get(file);
    if (source === undefined || source instanceof Error) throw source ?? new Error("missing file");
    return source;
  },
};
const output = await esbuild.build({
  stdin: {
    contents: `export * from './editor/vscode/src/projectConfig';
      export { PageGuideDecorations } from './editor/vscode/src/pageGuide';`,
    resolveDir: root,
    loader: "ts",
  },
  bundle: true, write: false, format: "esm", platform: "node",
  plugins: [{
    name: "mock-project-configuration-io",
    setup(build) {
      build.onResolve({ filter: /^(vscode|fs)$/ }, ({ path }) => ({ path, namespace: "ss-test" }));
      build.onLoad({ filter: /.*/, namespace: "ss-test" }, ({ path }) => ({
        contents: path === "vscode"
          ? "export const { workspace, window, Uri, RelativePattern, DecorationRangeBehavior, OverviewRulerLane } = globalThis.__ssProjectConfigTest;"
          : "export const { existsSync, readFileSync } = globalThis.__ssProjectConfigTest;",
      }));
    },
  }],
});
const config = await import(`data:text/javascript;base64,${Buffer.from(output.outputFiles[0].text).toString("base64")}`);
const lifetime = config.initializeProjectSettings();
config.setProjectSettingsProvider(async (file) => {
  if (!file) return source(null, 140);
  reads.set(file, (reads.get(file) ?? 0) + 1);
  const value = files.get(file);
  if (!value || value instanceof Error) return source(null, 140);
  return { ...value, entryPath: value.entryPath ? path.resolve(path.dirname(file), value.entryPath) : null };
});
try {
  files.set("/one/ss.toml", source("first.ss", 150));
  const firstUri = Uri.file("/one/slides/slide.ss");
  workspace.workspaceFolders = [{ uri: Uri.file("/one/slides") }];
  const first = (await config.projectSettings(firstUri));
  const firstSearches = searches;
  for (let index = 0; index < 1000; index++) {
    assert.equal((await config.projectSettings(firstUri)), first);
    assert.equal((await config.projectEntryUri(firstUri)).fsPath, "/one/first.ss");
  }
  assert.equal(searches, firstSearches, "unchanged lookups searched the filesystem again");
  assert.equal(reads.get("/one/ss.toml"), 1);
  assert.equal((await config.projectSettings(Uri.file("/one/other/slide.ss"))), first);
  assert.equal(reads.get("/one/ss.toml"), 1, "folders sharing a project parsed separate copies");
  assert.throws(() => { first.lsp.enabled = false; }, TypeError);
  assert.throws(() => { first.wysiwyg.maxWaitMs = 1; }, TypeError);

  let observed;
  let changedFiles;
  const changes = config.onDidChangeProjectSettings(async (files) => {
    changedFiles = files;
    observed = await config.projectSettings(firstUri);
  });
  files.set("/one/ss.toml", source("second.ss", 250));
  fire("/one", "change");
  await config.projectSettings(firstUri);
  assert.equal(observed.wysiwyg.debounceMs, 250, "listeners received old settings");
  assert.ok(changedFiles.includes("/one/ss.toml"), "configuration changes did not report the server input");
  assert.equal((await config.projectEntryUri(firstUri)).fsPath, "/one/second.ss");
  assert.equal(reads.get("/one/ss.toml"), 2);
  files.set("/one/slides/ss.toml", source("nested.ss", 350));
  fire("/one/slides", "create");
  assert.equal((await config.projectSettings(firstUri)).wysiwyg.debounceMs, 350);
  assert.equal((await config.projectEntryUri(firstUri)).fsPath, "/one/slides/nested.ss");
  files.delete("/one/slides/ss.toml");
  fire("/one/slides", "delete");
  assert.equal((await config.projectSettings(firstUri)).wysiwyg.debounceMs, 250);
  assert.equal((await config.projectEntryUri(firstUri)).fsPath, "/one/second.ss");
  changes.dispose();

  files.set("/two/ss.toml", source("two.ss", 450));
  const secondUri = Uri.file("/two/slide.ss");
  const second = (await config.projectSettings(secondUri));
  files.set("/one/ss.toml", source("third.ss", 550));
  fire("/one", "change");
  assert.equal((await config.projectSettings(secondUri)), second, "an unrelated project was discarded");
  assert.equal(reads.get("/two/ss.toml"), 1);
  workspace.workspaceFolders = [{ uri: Uri.file("/two") }];
  workspaceChanges.fire({ added: workspace.workspaceFolders, removed: [] });
  assert.equal((await config.projectEntryUri(undefined)).fsPath, "/two/two.ss");
  assert.equal((await config.projectSettings(undefined)).wysiwyg.debounceMs, 450);

  const missingUri = Uri.file("/missing/deck/slide.ss");
  const defaults = (await config.projectSettings(missingUri));
  const missingSearches = searches;
  assert.equal((await config.projectSettings(missingUri)), defaults);
  assert.equal(searches, missingSearches);
  files.set("/missing/ss.toml", new Error("temporarily unreadable"));
  fire("/missing", "create");
  assert.deepEqual((await config.projectSettings(missingUri)), defaults);
  files.set("/missing/ss.toml", source("recovered.ss", 650));
  fire("/missing", "change");
  assert.equal((await config.projectSettings(missingUri)).wysiwyg.debounceMs, 650);

  files.set("/folder/ss.toml", source("outer.ss", 700));
  files.set("/folder/child/ss.toml", source("inner.ss", 800));
  const childUri = Uri.file("/folder/child/slide.ss");
  assert.equal((await config.projectSettings(childUri)).wysiwyg.debounceMs, 800);
  const beforeUnrelatedChange = searches;
  fire("/folder", "change", "/folder/unrelated.txt");
  assert.equal((await config.projectSettings(childUri)).wysiwyg.debounceMs, 800);
  assert.equal(searches, beforeUnrelatedChange);
  files.delete("/folder/child/ss.toml");
  fire("/folder", "delete", "/folder/child");
  assert.equal((await config.projectSettings(childUri)).wysiwyg.debounceMs, 700);
  files.set("/folder/child/ss.toml", source("restored.ss", 900));
  fire("/folder", "create", "/folder/child");
  assert.equal((await config.projectSettings(childUri)).wysiwyg.debounceMs, 900);

  files.set("/failed/ss.toml", source("fresh.ss", 1100));
  const failedUri = Uri.file("/failed/sub/deep/slide.ss");
  const watchesBeforeFailure = watches.size;
  failingDirectory = "/failed/sub";
  assert.equal((await config.projectSettings(failedUri)).wysiwyg.debounceMs, 1100);
  assert.equal(watches.size, watchesBeforeFailure, "partial observation setup leaked watches");
  files.set("/failed/ss.toml", source("fresh.ss", 1200));
  assert.equal((await config.projectSettings(failedUri)).wysiwyg.debounceMs, 1200);
  assert.equal(watches.size, watchesBeforeFailure);
  failingDirectory = undefined;

  for (let index = 0; index < 160; index++) {
    const directory = `/bounded/p${index}`;
    files.set(`${directory}/ss.toml`, source("slide.ss", index));
    assert.equal((await config.projectSettings(Uri.file(`${directory}/slide.ss`))).wysiwyg.debounceMs, index);
    assert.ok(watches.size <= 256, `retained ${watches.size} directory watches`);
  }
  const recent = (await config.projectSettings(Uri.file("/bounded/p159/slide.ss")));
  assert.equal(reads.get("/bounded/p159/ss.toml"), 1);
  (await config.projectSettings(Uri.file("/bounded/p0/slide.ss")));
  assert.equal(reads.get("/bounded/p0/ss.toml"), 2, "old lookup was never evicted");
  assert.equal((await config.projectSettings(Uri.file("/bounded/p159/slide.ss"))), recent);
  assert.equal(reads.get("/bounded/p159/ss.toml"), 1);

  const deep = `/deep/${Array(260).fill("child").join("/")}/slide.ss`;
  files.set("/deep/ss.toml", source("deep.ss", 750));
  const previousWatches = watches.size;
  assert.equal((await config.projectSettings(Uri.file(deep))).wysiwyg.debounceMs, 750);
  files.set("/deep/ss.toml", source("deep.ss", 850));
  assert.equal((await config.projectSettings(Uri.file(deep))).wysiwyg.debounceMs, 850);
  assert.equal(watches.size, previousWatches, "unretained deep path leaked watches");
  const concurrent = Array.from({ length: 200 }, (_, index) => {
    const directory = `/concurrent/p${index}`;
    files.set(`${directory}/ss.toml`, source("slide.ss", index));
    return config.projectSettings(Uri.file(`${directory}/slide.ss`));
  });
  const concurrentSettings = await Promise.all(concurrent);
  for (let index = 0; index < concurrentSettings.length; index++) {
    assert.equal(concurrentSettings[index].wysiwyg.debounceMs, index);
    assert.equal(reads.get(`/concurrent/p${index}/ss.toml`), 1, "capacity eviction retried a live request");
  }
  assert.ok(watches.size <= 256);

  const paints = [];
  const editor = {
    document: {
      uri: Uri.file("/guide/slide.ss"), languageId: "ss-slide", lineCount: 2,
      lineAt(index) { return { text: index === 0 ? "page demo" : "end", range: { line: index } }; },
    },
    setDecorations(decoration, ranges) {
      assert.ok(decorations.has(decoration), "page guide used an absent or disposed decoration");
      paints.push(ranges);
    },
  };
  files.set("/guide/ss.toml", source("slide.ss", 140));
  window.visibleTextEditors = [editor];
  let releaseGuide;
  config.setProjectSettingsProvider(() => new Promise((resolve) => { releaseGuide = resolve; }));
  const disposedGuide = new config.PageGuideDecorations();
  const delayedPaint = disposedGuide.refreshEditor(editor);
  disposedGuide.dispose();
  releaseGuide(source("/guide/slide.ss", 140));
  await delayedPaint;
  assert.equal(decorations.size, 0, "late settings recreated disposed page guides");
  assert.equal(paints.length, 0);

  config.setProjectSettingsProvider(async () => source("/guide/slide.ss", 140));
  const guide = new config.PageGuideDecorations();
  await guide.refreshEditor(editor);
  assert.ok(paints.some((ranges) => ranges.length > 0), "loaded settings did not paint page guides");
  paints.length = 0;
  config.setProjectSettingsProvider(async () => {
    const disabled = source("/guide/slide.ss", 140);
    disabled.settings.pageGuide.enabled = false;
    return disabled;
  });
  await guide.refreshEditor(editor);
  assert.ok(paints.every((ranges) => ranges.length === 0), "disabled page guides were painted");
  guide.dispose();
  window.visibleTextEditors = [];
  assert.equal(decorations.size, 0);

  const pending = [];
  files.set("/async/ss.toml", source("pending.ss", 1));
  const asyncUri = Uri.file("/async/slide.ss");
  config.setProjectSettingsProvider((file) => new Promise((resolve, reject) => pending.push({ file, resolve, reject })));
  const firstRequest = config.projectSettings(asyncUri);
  const sameRequest = config.projectSettings(asyncUri);
  assert.equal(pending.length, 1, "concurrent settings lookups sent duplicate requests");
  fire("/async", "change");
  const latestRequest = config.projectSettings(asyncUri);
  assert.equal(pending.length, 2);
  pending[1].resolve(source("/async/new.ss", 200));
  assert.equal((await latestRequest).wysiwyg.debounceMs, 200);
  pending[0].resolve(source("/async/old.ss", 100));
  assert.equal((await firstRequest).wysiwyg.debounceMs, 200, "stale response replaced current settings");
  assert.equal(await sameRequest, await latestRequest);

  fire("/async", "change");
  const failedOldRequest = config.projectSettings(asyncUri);
  fire("/async", "change");
  const recoveredRequest = config.projectSettings(asyncUri);
  pending[3].resolve(source("/async/recovered.ss", 300));
  pending[2].reject(new Error("stale request failed"));
  assert.equal((await failedOldRequest).wysiwyg.debounceMs, 300);
  assert.equal(await failedOldRequest, await recoveredRequest);

  fire("/async", "change");
  const priorServerRequest = config.projectSettings(asyncUri);
  config.setProjectSettingsProvider(async () => source("/async/restarted.ss", 400));
  pending[4].resolve(source("/async/previous-server.ss", 350));
  assert.equal((await priorServerRequest).wysiwyg.debounceMs, 400, "previous server response survived restart");

  config.setProjectSettingsProvider((file) => new Promise((resolve, reject) => pending.push({ file, resolve, reject })));
  const disposedRequest = config.projectSettings(asyncUri);
  lifetime.dispose();
  pending[5].resolve(source("/async/disposed.ss", 500));
  assert.equal(await disposedRequest, undefined, "disposed provider published late settings");
} finally {
  lifetime.dispose();
  assert.equal(watches.size, 0);
  assert.equal(workspaceChanges.listeners.size, 0);
  for (const channel of [documentChanges, documentSaves, activeEditors, visibleEditors]) assert.equal(channel.listeners.size, 0);
  delete globalThis.__ssProjectConfigTest;
}
console.log("Project settings cache tests passed: 2,000 repeated settings/entry requests used one read and no repeated discovery");

function source(entry, debounce) {
  return {
    schema: 1,
    entryPath: entry,
    settings: {
      lsp: { enabled: true, debounceMs: 120, diagnostics: true, completion: true, hover: true, definition: true, documentSymbols: true, foldingRanges: true, semanticTokens: true, colors: true },
      wysiwyg: { enabled: true, debounceMs: debounce, maxWaitMs: 700, refreshAutomatically: true, refreshOnDependencyChange: true },
      pageGuide: { enabled: true, bodyBackground: true, boundary: true, boundaryBackground: true, gutterIcon: true, overviewRuler: true },
    },
  };
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
