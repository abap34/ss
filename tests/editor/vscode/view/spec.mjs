#!/usr/bin/env node
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../..");
const require = createRequire(import.meta.url);
const esbuild = require(path.join(root, "editor/vscode/node_modules/esbuild"));
const output = await esbuild.build({
  entryPoints: [path.join(root, "editor/vscode/src/editor/view.ts")],
  bundle: true,
  write: false,
  format: "esm",
  platform: "node",
  plugins: [{
    name: "mock-vscode",
    setup(build) {
      build.onResolve({ filter: /^vscode$/ }, () => ({ path: "vscode", namespace: "test" }));
      build.onLoad({ filter: /.*/, namespace: "test" }, () => ({
        contents: "export const Uri = { file: (fsPath) => ({ fsPath }) }; export const workspace = { getWorkspaceFolder: () => undefined };",
      }));
    },
  }],
});
const { ViewResources } = await import(`data:text/javascript;base64,${Buffer.from(output.outputFiles[0].text).toString("base64")}`);
const view = new ViewResources({});
const resolved = [];
const webview = {
  asWebviewUri(uri) {
    resolved.push(uri.fsPath);
    return { toString: () => `webview:${uri.fsPath}` };
  },
};

const image = "assets/a.[1]$&.png";
const pdf = "assets/a.pdf";
const font = "assets/a.woff2";
const snapshot = freeze({
  snapshot_id: "first",
  layout: { objects: [{ id: 1, x: 10 }] },
  outline: [{ name: "A" }],
  editing: [{ node_id: 1 }],
  source_paths: ["/project/slide.ss"],
  display: {
    schema: 2,
    html: `<img src="${image}"><div data-pdf-src="${pdf}" style="background:url('${image}')"></div><img src="unrelated.png">`,
    css: `@font-face{src:url('${font}')} .image{background:url('${image}')} .other{background:url('unrelated.png')}`,
    assets: [
      { relative_path: image, path: "/cache/image.png" },
      { relative_path: pdf, path: "/cache/document.pdf" },
      { relative_path: font, path: "/cache/font.woff2" },
    ],
    translations: [{ node_id: 1, x: 0, y: 0 }],
  },
});
const prepared = view.prepareSnapshot(webview, snapshot);
assert.notEqual(prepared, snapshot);
assert.notEqual(prepared.display, snapshot.display);
for (const field of ["layout", "outline", "editing", "source_paths"]) {
  assert.equal(prepared[field], snapshot[field], `unchanged ${field} was cloned`);
}
assert.equal(prepared.display.assets, snapshot.display.assets);
assert.equal(prepared.display.translations, snapshot.display.translations);
assert.equal(prepared.display.html, '<img src="webview:/cache/image.png"><div data-pdf-src="webview:/cache/document.pdf" style="background:url(\'webview:/cache/image.png\')"></div><img src="unrelated.png">');
assert.equal(prepared.display.css, "@font-face{src:url('webview:/cache/font.woff2')} .image{background:url('webview:/cache/image.png')} .other{background:url('unrelated.png')}");
assert.deepEqual(resolved, ["/cache/image.png", "/cache/document.pdf", "/cache/font.woff2"]);
assert.ok(snapshot.display.html.includes(image));

const patch = freeze({ ...snapshot, display: { schema: 3, kind: "translation_patch", translations: [] } });
assert.equal(view.prepareSnapshot(webview, patch), patch);
const empty = freeze({ ...snapshot, display: { ...snapshot.display, assets: [] } });
assert.equal(view.prepareSnapshot(webview, empty), empty);

const chained = freeze({
  ...snapshot,
  display: {
    schema: 2,
    html: '<img src="first"><img src="webview:second">',
    css: "a{background:url('first')}",
    assets: [
      { relative_path: "first", path: "second" },
      { relative_path: "webview:second", path: "third" },
    ],
  },
});
const translated = view.prepareSnapshot(webview, chained);
assert.equal(translated.display.html, '<img src="webview:second"><img src="webview:third">');
assert.equal(translated.display.css, "a{background:url('webview:second')}");

for (const count of [1, 128, 2048]) {
  const assets = Array.from({ length: count }, (_, index) => ({
    relative_path: `assets/${index}.png`, path: `/cache/${index}.png`,
  }));
  const large = freeze({
    ...snapshot,
    display: {
      schema: 2,
      html: assets.map((asset) => `<img src="${asset.relative_path}">`).join(""),
      css: assets.map((asset) => `a{background:url('${asset.relative_path}')}`).join(""),
      assets,
    },
  });
  const result = view.prepareSnapshot(webview, large);
  assert.equal(result.layout, large.layout);
  assert.equal(result.display.html, assets.map((asset) => `<img src="webview:${asset.path}">`).join(""));
  assert.equal(result.display.css, assets.map((asset) => `a{background:url('webview:${asset.path}')}`).join(""));
}

function freeze(value) {
  if (value && typeof value === "object" && !Object.isFrozen(value)) {
    for (const child of Object.values(value)) freeze(child);
    Object.freeze(value);
  }
  return value;
}

console.log("Editor view resource tests passed");
