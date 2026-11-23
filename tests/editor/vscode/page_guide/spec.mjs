import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const root = fileURLToPath(new URL("../../../../", import.meta.url));
const esbuild = require(`${root}editor/vscode/node_modules/esbuild`);
const decorations = new Set();
const paints = new Map();
const subscribe = () => ({ dispose() {} });
let selectedPalette;
let onConfigurationChange;
let enabled = true;
let settingsAvailable = true;
let provide;
const errors = [];
class CancellationTokenSource {
  listeners = new Set();
  token = {
    isCancellationRequested: false,
    onCancellationRequested: (listener) => {
      this.listeners.add(listener);
      return { dispose: () => this.listeners.delete(listener) };
    },
  };
  cancel() {
    this.token.isCancellationRequested = true;
    for (const listener of this.listeners) listener();
  }
  dispose() { this.listeners.clear(); }
}
globalThis.__ssPageGuideTest = {
  workspace: {
    onDidChangeTextDocument: subscribe,
    onDidSaveTextDocument: subscribe,
    onDidChangeConfiguration(listener) { onConfigurationChange = listener; return subscribe(); },
    getConfiguration(section) {
      assert.equal(section, "ss");
      return { get(key, fallback) { assert.equal(key, "pageGuide.palette"); return selectedPalette ?? fallback; } };
    },
  },
  window: {
    visibleTextEditors: [],
    onDidChangeActiveTextEditor: subscribe,
    onDidChangeVisibleTextEditors: subscribe,
    createTextEditorDecorationType(options) {
      const decoration = { options, dispose() { decorations.delete(decoration); } };
      decorations.add(decoration);
      return decoration;
    },
  },
  CancellationTokenSource,
  Uri: { parse: (value) => value },
  DecorationRangeBehavior: { ClosedClosed: 1 },
  OverviewRulerLane: { Left: 1 },
  onDidChangeProjectSettings: subscribe,
  projectSettings: async () => settingsAvailable ? ({ pageGuide: {
    enabled, bodyBackground: true, boundary: true,
    boundaryBackground: true, gutterIcon: true, overviewRuler: true,
  } }) : undefined,
};
const output = await esbuild.build({
  entryPoints: [`${root}editor/vscode/src/pageGuide.ts`],
  bundle: true, write: false, format: "esm", platform: "node",
  plugins: [{ name: "mock-page-guide-host", setup(build) {
    build.onResolve({ filter: /^(vscode|\.\/projectConfig)$/ }, ({ path }) => ({ path, namespace: "ss-test" }));
    build.onLoad({ filter: /.*/, namespace: "ss-test" }, () => ({
      contents: "export const { workspace, window, Uri, DecorationRangeBehavior, OverviewRulerLane, CancellationTokenSource, onDidChangeProjectSettings, projectSettings } = globalThis.__ssPageGuideTest;",
    }));
  } }],
});
const { PageGuideDecorations } = await import(`data:text/javascript;base64,${Buffer.from(output.outputFiles[0].text).toString("base64")}`);
const guide = new PageGuideDecorations((document, token) => provide(document, token), message => errors.push(message));
const editor = {
  document: undefined,
  setDecorations(decoration, ranges) {
    assert(decorations.has(decoration), "page guide used a disposed decoration");
    paints.set(decoration, ranges);
  },
};
let cases = 0;
try {
  // The document deliberately disagrees with the supplied boundaries. The
  // extension must render compiler results without inspecting source text.
  editor.document = document(20);
  await paint([[2, 4], [9, 13]]);
  expectPages([[2, 4], [9, 13]]);
  const many = Array.from({ length: 25 }, (_, index) => [index * 4, index * 4 + 2]);
  editor.document = document(100);
  await paint(many);
  expectPages(many);

  editor.document = document(8);
  const fourPages = [[0, 1], [2, 3], [4, 5], [6, 7]];
  const classicColors = [
    "rgba(86, 156, 214, 0.15)", "rgba(214, 90, 90, 0.14)",
    "rgba(76, 168, 106, 0.14)", "rgba(214, 168, 74, 0.15)",
  ];
  await paint(fourPages);
  assert.deepEqual(currentPageColors(), classicColors);
  for (const [name, colors] of [
    ["lilac-ember", ["rgba(177, 166, 220, 0.15)", "rgba(233, 161, 169, 0.15)"]],
    ["teal-peach", ["rgba(119, 198, 193, 0.15)", "rgba(238, 173, 145, 0.15)"]],
    ["sage-rose", ["rgba(167, 199, 165, 0.15)", "rgba(229, 162, 172, 0.15)"]],
    ["meadow", [
      "rgba(167, 197, 160, 0.15)", "rgba(137, 185, 197, 0.15)",
      "rgba(213, 175, 154, 0.15)", "rgba(193, 173, 208, 0.15)",
    ]],
  ]) {
    selectedPalette = name;
    await paint(fourPages);
    assert.deepEqual(currentPageColors(), Array.from({ length: 4 }, (_, index) => colors[index % colors.length]));
    assert.equal(decorations.size, colors.length * 3);
  }
  selectedPalette = "not-a-palette";
  await paint(fourPages);
  assert.deepEqual(currentPageColors(), classicColors);
  selectedPalette = "teal-peach";
  globalThis.__ssPageGuideTest.window.visibleTextEditors.push(editor);
  paints.clear();
  onConfigurationChange({ affectsConfiguration: key => key === "ss.pageGuide.palette" });
  await new Promise(setImmediate);
  assert.equal(currentPageColors().length, 4);
  assert.equal(decorations.size, 6);
  globalThis.__ssPageGuideTest.window.visibleTextEditors.length = 0;

  // Incomplete syntax, unavailable servers and stale responses do not clear
  // existing decorations; a valid empty page list does.
  for (const response of [undefined, null, { version: 1, pages: null }, { version: 0, pages: [] }]) {
    provide = async () => response;
    paints.clear();
    await guide.refreshEditor(editor);
    assert.equal(paints.size, 0, "unavailable or stale syntax cleared existing page colors");
  }
  provide = async () => { throw new Error("Server restarting"); };
  await guide.refreshEditor(editor);
  assert.equal(paints.size, 0, "a failed request cleared page colors");
  assert.equal(errors.length, 1);
  settingsAvailable = false;
  await guide.refreshEditor(editor);
  assert.equal(paints.size, 0, "temporarily unavailable settings cleared page colors");
  settingsAvailable = true;

  const pending = [];
  provide = (document, token) => new Promise(resolve => pending.push({ version: document.version, token, resolve }));
  const older = guide.refreshEditor(editor);
  await new Promise(setImmediate);
  editor.document.version++;
  const latest = guide.refreshEditor(editor);
  await new Promise(setImmediate);
  assert(pending[0].token.isCancellationRequested, "a new edit did not cancel the previous page request");
  pending[1].resolve({ version: 2, pages: [{ startLine: 3, endLine: 6 }] });
  await latest;
  expectPages([[3, 6]]);
  const currentPaints = [...paints];
  pending[0].resolve({ version: 1, pages: [] });
  await older;
  assert.deepEqual([...paints], currentPaints, "an old response replaced the latest page colors");

  paints.clear();
  const changedVersion = guide.refreshEditor(editor);
  await new Promise(setImmediate);
  editor.document.version++;
  pending[2].resolve({ version: 2, pages: [] });
  await changedVersion;
  assert.equal(paints.size, 0, "a response for an older document version was painted");
  await paint([]);
  assert([...paints.values()].every(ranges => ranges.length === 0), "deleting all pages kept their colors");
  await paint(fourPages);
  enabled = false;
  paints.clear();
  await guide.refreshEditor(editor);
  assert([...paints.values()].every(ranges => ranges.length === 0), "disabling page guides kept their colors");
  enabled = true;

  paints.clear();
  provide = (document, token) => new Promise(resolve => pending.push({ version: document.version, token, resolve }));
  const disposed = guide.refreshEditor(editor);
  await new Promise(setImmediate);
  guide.dispose();
  await disposed;
  assert(pending.at(-1).token.isCancellationRequested);
  pending.at(-1).resolve({ version: editor.document.version, pages: [] });
  assert.equal(paints.size, 0, "a response painted decorations after disposal");
} finally {
  guide.dispose();
  assert.equal(decorations.size, 0, "page guide leaked decorations");
  delete globalThis.__ssPageGuideTest;
}
console.log(`Page guides: ${cases} compiler-range cases, palettes, version races and failure preservation passed`);

function document(lineCount) {
  return {
    uri: { toString: () => "file:///page-guide/slide.ss" }, languageId: "ss-slide", version: 1, lineCount,
    getText() { throw new Error("Page guides must not parse source text"); },
    lineAt(line) {
      assert(line >= 0 && line < lineCount);
      return { get text() { throw new Error("Page guides must not parse source lines"); }, range: { start: { line }, end: { line } } };
    },
  };
}
async function paint(ranges) {
  provide = async document => ({ version: document.version, pages: ranges.map(([startLine, endLine]) => ({ startLine, endLine })) });
  paints.clear();
  await guide.refreshEditor(editor);
}
function expectPages(expected) {
  cases++;
  const pages = [];
  const ends = [];
  const colors = new Map();
  for (const [decoration, ranges] of paints) {
    const { backgroundColor, borderWidth } = decoration.options;
    if (borderWidth === "2px 0 0 0") pages.push(...ranges.map(range => ({ line: range.start.line, color: backgroundColor })));
    else if (borderWidth === "0 0 2px 0") ends.push(...ranges.map(range => range.start.line));
    else for (const range of ranges) {
      assert(!colors.has(range.start.line), "overlapping page decorations");
      colors.set(range.start.line, backgroundColor);
    }
  }
  pages.sort((a, b) => a.line - b.line);
  ends.sort((a, b) => a - b);
  assert.deepEqual(pages.map(page => page.line), expected.map(([start]) => start));
  assert.deepEqual(ends, expected.map(([, end]) => end));
  const expectedLines = [];
  expected.forEach(([start, end], index) => {
    for (let line = start; line <= end; line++) expectedLines.push(line);
    if (index > 0) assert.notEqual(pages[index].color, pages[index - 1].color);
    assert.equal(new Set(Array.from({ length: end - start + 1 }, (_, offset) => colors.get(start + offset))).size, 1);
  });
  assert.deepEqual([...colors.keys()].sort((a, b) => a - b), expectedLines);
}
function currentPageColors() {
  return [...paints].filter(([decoration]) => decoration.options.borderWidth === "2px 0 0 0")
    .flatMap(([decoration, ranges]) => ranges.map(range => ({ line: range.start.line, color: decoration.options.backgroundColor })))
    .sort((a, b) => a.line - b.line).map(({ color }) => color);
}
