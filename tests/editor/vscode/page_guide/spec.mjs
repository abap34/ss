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
  Uri: { parse: (value) => value },
  DecorationRangeBehavior: { ClosedClosed: 1 },
  OverviewRulerLane: { Left: 1 },
  onDidChangeProjectSettings: subscribe,
  projectSettings: async () => ({ pageGuide: {
    enabled: true, bodyBackground: true, boundary: true,
    boundaryBackground: true, gutterIcon: true, overviewRuler: true,
  } }),
};
const output = await esbuild.build({
  entryPoints: [`${root}editor/vscode/src/pageGuide.ts`],
  bundle: true, write: false, format: "esm", platform: "node",
  plugins: [{ name: "mock-page-guide-host", setup(build) {
    build.onResolve({ filter: /^(vscode|\.\/projectConfig)$/ }, ({ path }) => ({ path, namespace: "ss-test" }));
    build.onLoad({ filter: /.*/, namespace: "ss-test" }, () => ({
      contents: "export const { workspace, window, Uri, DecorationRangeBehavior, OverviewRulerLane, onDidChangeProjectSettings, projectSettings } = globalThis.__ssPageGuideTest;",
    }));
  } }],
});
const { PageGuideDecorations } = await import(`data:text/javascript;base64,${Buffer.from(output.outputFiles[0].text).toString("base64")}`);
const guide = new PageGuideDecorations();
const editor = {
  document: undefined,
  setDecorations(decoration, ranges) {
    assert(decorations.has(decoration), "page guide used a disposed decoration");
    paints.set(decoration, ranges);
  },
};
let cases = 0;
try {
  const nested = [
    "page _", "stages s { first second third }", "show s >= s.first",
    "  if true", "    show s >= s.second", '      text! "Body"',
    "    end", "  else", '    text! "Alternative"', "  end", "end", "end ;; page",
    "", "page _", "end",
  ];
  expectPages(await paint(nested), [[0, 11], [13, 14]]);

  for (const suffix of ["", ")", ") |=| text(\"Other\")", " || text! \"Other\"", "//other", "/=/ other", " # text", " ;; comment"]) {
    const lines = ["page _", "show true", "let item = text(<< ;; content", "page fake", "show false", "end", `  >>${suffix}`, "end", "end", "page _", "end"];
    expectPages(await paint(lines), [[0, 8], [9, 10]]);
  }

  const composed = [
    "page _", "show true", "text! <<", "page fake", "end",
    ">> || text! << ;; second block", "page another_fake", "show false", "end", ">>)",
    "end", "end", "page _", "end",
  ];
  expectPages(await paint(composed), [[0, 11], [12, 13]]);
  expectPages(await paint(composed.join("\r\n")), [[0, 11], [12, 13]]);

  const quoted = [
    "page _", 'text! "Multiline', "page fake", "show false", "end", '<< >> ;; quoted"',
    'text! "A literal backslash\\"', "end", ";; page fake", "page _", "end",
  ];
  expectPages(await paint(quoted), [[0, 7], [9, 10]]);

  for (const marker of [";;", "#", "//"]) {
    const lines = ["page _", `end ${marker} trailing text`, "page _", "end"];
    expectPages(await paint(lines), [[0, marker === ";;" ? 1 : null, 1], [2, 3]]);
  }

  const unfinished = ["page _", "show true", 'text! "First"', "end", "page _", "end", "page _", "show true"];
  const before = await paint(unfinished);
  expectPages(before, [[0, null, 3], [4, 5], [6, null, 7]]);
  const repaired = [...unfinished.slice(0, 4), "end", ...unfinished.slice(4), "end", "end"];
  expectPages(await paint(repaired), [[0, 4], [5, 6], [7, 10]]);

  // Color follows source page order, including repeated names and unfinished pages.
  const many = [];
  const expected = [];
  for (let index = 0; index < 25; index++) {
    const start = many.length;
    many.push("page _", 'text! "Body"');
    if (index % 3 === 0) expected.push([start, null, start + 1]);
    else { many.push("end"); expected.push([start, start + 2]); }
    many.push(";; page fake");
    if (index % 3 === 0) expected.at(-1)[2] += 1;
  }
  const first = await paint(many);
  expectPages(first, expected);
  assert.deepEqual((await paint(many)).pages, first.pages, "unchanged pages changed colors");

  // Each selected palette cycles through its own colors; classic remains the default.
  const fourPages = ["page _", "end", "page _", "end", "page _", "end", "page _", "end"];
  const classicColors = [
    "rgba(86, 156, 214, 0.15)", "rgba(214, 90, 90, 0.14)",
    "rgba(76, 168, 106, 0.14)", "rgba(214, 168, 74, 0.15)",
  ];
  assert.deepEqual((await paint(fourPages)).pages.map(({ color }) => color), classicColors);
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
    const painted = await paint(fourPages);
    assert.deepEqual(painted.pages.map(({ color }) => color),
      Array.from({ length: 4 }, (_, index) => colors[index % colors.length]), `${name} colors differ`);
    assert.equal(decorations.size, colors.length * 3, `${name} created the wrong number of decorations`);
  }
  selectedPalette = "not-a-palette";
  assert.deepEqual((await paint(fourPages)).pages.map(({ color }) => color), classicColors);

  selectedPalette = "teal-peach";
  globalThis.__ssPageGuideTest.window.visibleTextEditors.push(editor);
  paints.clear();
  onConfigurationChange({ affectsConfiguration: (key) => key === "ss.pageGuide.palette" });
  await new Promise(setImmediate);
  assert.deepEqual(currentPageColors(), [
    "rgba(119, 198, 193, 0.15)", "rgba(238, 173, 145, 0.15)",
    "rgba(119, 198, 193, 0.15)", "rgba(238, 173, 145, 0.15)",
  ]);
  globalThis.__ssPageGuideTest.window.visibleTextEditors.length = 0;

  // Incomplete literals keep fake page headers inside their current page.
  expectPages(await paint(["page _", "text! <<", "page fake", "end"]), [[0, null, 3]]);
  expectPages(await paint(["page _", 'text! "', "page fake", "end"]), [[0, null, 3]]);
} finally {
  guide.dispose();
  assert.equal(decorations.size, 0, "page guide leaked decorations");
  delete globalThis.__ssPageGuideTest;
}
console.log(`Page guides: ${cases} boundary and adjacent-color cases passed`);

async function paint(source) {
  const lines = Array.isArray(source) ? source : source.split(/\r?\n/);
  editor.document = {
    uri: { toString: () => "file:///page-guide/slide.ss" }, languageId: "ss-slide", lineCount: lines.length,
    lineAt(line) { return { text: lines[line], range: { start: { line }, end: { line } } }; },
  };
  paints.clear();
  await guide.refreshEditor(editor);
  const pages = [];
  const ends = [];
  const colors = new Map();
  for (const [decoration, ranges] of paints) {
    const { backgroundColor, borderWidth } = decoration.options;
    if (borderWidth === "2px 0 0 0") {
      pages.push(...ranges.map((range) => ({ line: range.start.line, color: backgroundColor })));
    } else if (borderWidth === "0 0 2px 0") {
      ends.push(...ranges.map((range) => range.start.line));
    } else {
      for (const range of ranges) {
        const line = range.start.line;
        assert(!colors.has(line), `overlapping page decorations on line ${line}`);
        colors.set(line, backgroundColor);
      }
    }
  }
  pages.sort((a, b) => a.line - b.line);
  ends.sort((a, b) => a - b);
  return { pages, ends, colors, lines };
}

function expectPages(actual, expected) {
  cases += 1;
  assert.deepEqual(actual.pages.map((page) => page.line), expected.map(([start]) => start), "page starts differ");
  assert.deepEqual(actual.ends, expected.filter(([, end]) => end !== null).map(([, end]) => end), "page ends differ");
  const expectedLines = [];
  expected.forEach(([start, end, bodyEnd = end], index) => {
    for (let line = start; line <= bodyEnd; line++) expectedLines.push(line);
    if (index > 0) assert.notEqual(actual.pages[index].color, actual.pages[index - 1].color, "adjacent pages share a color");
    const bodyColors = new Set(Array.from({ length: bodyEnd - start + 1 }, (_, offset) => actual.colors.get(start + offset)));
    assert.equal(bodyColors.size, 1, "a page body changed colors inside a nested block");
  });
  assert.deepEqual([...actual.colors.keys()].sort((a, b) => a - b), expectedLines, "page body boundaries differ");
}

function currentPageColors() {
  return [...paints].filter(([decoration]) => decoration.options.borderWidth === "2px 0 0 0")
    .flatMap(([decoration, ranges]) => ranges.map((range) => ({ line: range.start.line, color: decoration.options.backgroundColor })))
    .sort((a, b) => a.line - b.line).map(({ color }) => color);
}
