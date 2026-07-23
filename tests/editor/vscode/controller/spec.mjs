#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../..",
);
const require = createRequire(import.meta.url);
const esbuild = require(
  path.join(root, "editor", "vscode", "node_modules", "esbuild"),
);
const mock = vscodeMock();
globalThis.__ssVscodeMock = mock;
const output = await esbuild.build({
  entryPoints: [
    path.join(root, "editor", "vscode", "src", "editor", "controller.ts"),
  ],
  bundle: true,
  write: false,
  format: "esm",
  platform: "node",
  target: "node20",
  plugins: [{
    name: "mock-vscode",
    setup(build) {
      build.onResolve({ filter: /^vscode$/ }, () => ({
        path: "vscode",
        namespace: "ss-test",
      }));
      build.onLoad({ filter: /.*/, namespace: "ss-test" }, () => ({
        loader: "js",
        contents: `
          const mock = globalThis.__ssVscodeMock;
          export const workspace = mock.workspace;
          export const window = mock.window;
          export const Uri = mock.Uri;
          export const WorkspaceEdit = mock.WorkspaceEdit;
          export const TextEdit = mock.TextEdit;
          export const Range = mock.Range;
          export const Selection = mock.Selection;
          export const CancellationTokenSource = mock.CancellationTokenSource;
          export const ViewColumn = mock.ViewColumn;
          export const TextEditorRevealType = mock.TextEditorRevealType;
          export const TabInputText = mock.TabInputText;
          export const TabInputTextDiff = mock.TabInputTextDiff;
        `,
      }));
    },
  }],
});
const source = output.outputFiles[0].text;
const { EditorController } = await import(
  `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`
);

await testOpenResolvesConfiguredEntryWithoutSsDocument();
await testOpeningManualPreviewBuildsInitialSnapshot();
await testManualPositionEditRequestsReconciliation();
await testNewSourceEditReschedulesReconciliation();
await testLineGeometryEditForwardsOrderedPagePoints();
await testShapeBoundsEditForwardsPageBounds();
await testComponentWidthEditReachesTheWebview();
await testComponentDeletionReachesTheWebview();
await testIconCatalogAndInsertionReachTheWebview();

async function testOpenResolvesConfiguredEntryWithoutSsDocument() {
  const fixture = await mkdtemp(path.join(os.tmpdir(), "ss-editor-open-entry-"));
  try {
    const deck = path.join(fixture, "deck");
    const slide = path.join(deck, "slides.ss");
    await mkdir(deck);
    await writeFile(path.join(fixture, "ss.toml"), `[project]
entry = "deck/slides.ss"
`, "utf8");
    await writeFile(slide, "page demo\nend\n", "utf8");

    mock.reset();
    mock.workspace.workspaceFolders.push({ uri: mock.Uri.file(fixture) });
    const controller = new EditorController(
      { extensionUri: mock.Uri.file(fixture) },
      { appendLine() {} },
      () => undefined,
    );

    controller.open(undefined);
    await waitFor(() => controller.sessions.size === 1);
    const session = controller.sessions.values().next().value;
    assert.equal(session.document.uri.fsPath, slide);
    assert.deepEqual(mock.openedDocuments, [slide]);
    assert.deepEqual(mock.warnings, []);
    assert.equal(mock.panels.length, 1);
    assert.match(mock.panels[0].title, /slides\.ss$/);
    controller.dispose();
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
}

async function testOpeningManualPreviewBuildsInitialSnapshot() {
  await withManualSession(async ({ controller, session, requests, messages, change }) => {
    session.ready = false;
    session.snapshotId = undefined;
    await controller.handleMessage(session, { type: "ready" });
    await waitFor(() => requests.some((request) =>
      request.method === "ss/editorSnapshot"
    ));
    await waitFor(() => messages.some((message) => message.type === "snapshot"));
    assert.equal(
      messages.some((message) =>
        message.type === "buildStatus" && message.status === "manual"
      ),
      false,
      "opening a manual-refresh preview waited for a separate build command",
    );

    const initialBuildCount = requests.filter((request) =>
      request.method === "ss/editorSnapshot"
    ).length;
    change();
    await waitFor(() => messages.some((message) =>
      message.type === "buildStatus" && message.status === "manual"
    ));
    assert.equal(
      requests.filter((request) => request.method === "ss/editorSnapshot").length,
      initialBuildCount,
      "a later source edit ignored the manual-refresh setting",
    );
  });
}

async function testManualPositionEditRequestsReconciliation() {
  await withManualSession(async ({ controller, session, requests, messages }) => {
    await controller.applyTranslation(session, translationMessage(1));
    await waitFor(() => requests.some((request) =>
      request.method === "ss/editorSnapshot"
    ));
    await waitFor(() => messages.some((message) => message.type === "snapshot"));
    assert.equal(
      requests.filter((request) => request.method === "ss/editorSnapshot").length,
      1,
      "a manual position edit did not request one authoritative snapshot",
    );
    assert.equal(
      session.editorReconciliationPending,
      false,
      "an accepted snapshot left position reconciliation pending",
    );
  });
}

async function testNewSourceEditReschedulesReconciliation() {
  let rejectFirstSnapshot;
  let snapshotCount = 0;
  await withManualSession(async ({ controller, session, requests, messages, change }) => {
    session.snapshotResponse = () => {
      snapshotCount += 1;
      if (snapshotCount === 1) {
        return new Promise((_resolve, reject) => {
          rejectFirstSnapshot = reject;
        });
      }
      return editorSnapshot(`snapshot-${snapshotCount}`);
    };

    await controller.applyTranslation(session, translationMessage(2));
    await waitFor(() => snapshotCount === 1);
    const manualCount = messages.filter((message) =>
      message.type === "buildStatus" && message.status === "manual"
    ).length;

    change();
    const firstSnapshotRequest = requests.find((request) =>
      request.method === "ss/editorSnapshot"
    );
    assert.equal(
      firstSnapshotRequest?.token?.isCancellationRequested,
      true,
      "a superseded position reconciliation was not canceled",
    );
    rejectFirstSnapshot({ code: -32800 });
    await waitFor(() => snapshotCount === 2);
    await waitFor(() => messages.some((message) =>
      message.type === "snapshot" && message.documentVersion === 3
    ));

    assert.equal(
      messages.filter((message) =>
        message.type === "buildStatus" && message.status === "manual"
      ).length,
      manualCount,
      "a newer source edit discarded an in-flight position reconciliation",
    );
    assert.equal(
      requests.filter((request) => request.method === "ss/editorSnapshot").length,
      2,
      "a canceled position reconciliation was not retried for the latest source",
    );
    assert.equal(session.editorReconciliationPending, false);
  });
}

async function testLineGeometryEditForwardsOrderedPagePoints() {
  await withManualSession(async ({ controller, session, requests, messages }) => {
    await controller.applyShapeEdit(session, {
      type: "editLineGeometry",
      requestId: 9,
      snapshotId: "initial",
      nodeId: 7,
      pageId: 1,
      start: { x: 410, y: 120 },
      end: { x: 90, y: 360 },
    });
    const request = requests.find((candidate) =>
      candidate.method === "ss/editLineGeometry"
    );
    assert.deepEqual(request?.params, {
      textDocument: { uri: session.document.uri.toString() },
      snapshotId: "initial",
      pageId: 1,
      nodeId: 7,
      start: { x: 410, y: 120 },
      end: { x: 90, y: 360 },
    });
    assert(messages.some((message) =>
      message.type === "shapeEditResult" &&
      message.operation === "geometry" &&
      message.status === "applied"
    ), "an applied line geometry edit did not reach the webview");
  });
}

async function testShapeBoundsEditForwardsPageBounds() {
  await withManualSession(async ({ controller, session, requests, messages }) => {
    await controller.applyShapeEdit(session, {
      type: "editShapeBounds",
      requestId: 10,
      snapshotId: "initial",
      nodeId: 8,
      pageId: 1,
      kind: "speech_bubble",
      bounds: { x: 60, y: 80, width: 220, height: 140 },
    });
    const request = requests.find((candidate) =>
      candidate.method === "ss/editShapeBounds"
    );
    assert.deepEqual(request?.params, {
      textDocument: { uri: session.document.uri.toString() },
      snapshotId: "initial",
      pageId: 1,
      nodeId: 8,
      bounds: { x: 60, y: 80, width: 220, height: 140 },
    });
    assert(messages.some((message) =>
      message.type === "shapeEditResult" &&
      message.operation === "resize" &&
      message.status === "applied"
    ), "an applied shape resize did not reach the webview");
  });
}

async function testComponentDeletionReachesTheWebview() {
  await withManualSession(async ({ controller, session, requests, messages }) => {
    await controller.applyComponentDelete(session, {
      type: "deleteComponent",
      requestId: 11,
      snapshotId: "initial",
      nodeId: 9,
      pageId: 1,
    });
    const request = requests.find((candidate) =>
      candidate.method === "ss/deleteComponent"
    );
    assert.deepEqual(request?.params, {
      textDocument: { uri: session.document.uri.toString() },
      snapshotId: "initial",
      nodeId: 9,
      pageId: 1,
    });
    assert(messages.some((message) =>
      message.type === "componentDeleteResult" &&
      message.requestId === 11 && message.status === "applied"
    ), "an applied component deletion did not reach the webview");
    await waitFor(() => requests.some((candidate) =>
      candidate.method === "ss/editorSnapshot"
    ));
    await waitFor(() => messages.some((message) =>
      message.type === "snapshot"
    ));
    assert.equal(
      requests.filter((candidate) =>
        candidate.method === "ss/editorSnapshot"
      ).length,
      1,
      "a component deletion did not request one authoritative snapshot",
    );
  });
}

async function testComponentWidthEditReachesTheWebview() {
  await withManualSession(async ({ controller, session, requests, messages }) => {
    await controller.applyComponentWidth(session, {
      type: "resizeComponentWidth",
      requestId: 12,
      snapshotId: "initial",
      nodeId: 9,
      pageId: 1,
      fromBounds: { x: 80, y: 90, width: 180, height: 60 },
      toBounds: { x: 80, y: 90, width: 260, height: 60 },
    });
    const request = requests.find((candidate) =>
      candidate.method === "ss/layoutEdit" && candidate.params.mode === "width"
    );
    assert.deepEqual(request?.params, {
      textDocument: { uri: session.document.uri.toString() },
      snapshotId: "initial",
      nodeId: 9,
      pageId: 1,
      mode: "width",
      fromBounds: { x: 80, y: 90, width: 180, height: 60 },
      toBounds: { x: 80, y: 90, width: 260, height: 60 },
    });
    assert(messages.some((message) =>
      message.type === "componentWidthEditResult" &&
      message.requestId === 12 && message.status === "applied"
    ), "an applied component width edit did not reach the webview");
    await waitFor(() => requests.some((candidate) =>
      candidate.method === "ss/editorSnapshot"
    ));
    await waitFor(() => messages.some((message) =>
      message.type === "snapshot"
    ));
    assert.equal(
      requests.filter((candidate) =>
        candidate.method === "ss/editorSnapshot"
      ).length,
      1,
      "a component width edit did not request one authoritative snapshot",
    );
    assert.equal(
      session.editorReconciliationPending,
      false,
      "an accepted snapshot left component width reconciliation pending",
    );
  });
}

async function testIconCatalogAndInsertionReachTheWebview() {
  await withManualSession(async ({ controller, session, requests, messages }) => {
    await controller.queryIcons(session, {
      type: "queryIcons",
      requestId: 20,
      query: "star",
      style: "solid",
      category: "all",
      offset: 0,
    });
    const catalogRequest = requests.find((candidate) =>
      candidate.method === "ss/iconCatalog"
    );
    assert.deepEqual(catalogRequest?.params, {
      query: "star",
      style: "solid",
      category: "all",
      offset: 0,
    });
    assert(messages.some((message) =>
      message.type === "iconCatalog" && message.requestId === 20
    ), "the icon catalog did not reach the webview");

    await controller.applyIconInsert(session, {
      type: "insertIcon",
      requestId: 21,
      snapshotId: "initial",
      pageId: 1,
      source: "fa-solid:star",
      bounds: { x: 120, y: 140, width: 72, height: 72 },
      color: "#2563eb",
    });
    const insertion = requests.find((candidate) =>
      candidate.method === "ss/insertIcon"
    );
    assert.deepEqual(insertion?.params, {
      textDocument: { uri: session.document.uri.toString() },
      snapshotId: "initial",
      pageId: 1,
      source: "fa-solid:star",
      bounds: { x: 120, y: 140, width: 72, height: 72 },
      color: "#2563eb",
    });
    assert(messages.some((message) =>
      message.type === "iconEditResult" &&
      message.requestId === 21 && message.status === "applied"
    ), "the applied icon insertion did not reach the webview");
  });
}

async function withManualSession(run) {
  const fixture = await mkdtemp(path.join(os.tmpdir(), "ss-editor-controller-"));
  try {
    const slide = path.join(fixture, "slide.ss");
    await writeFile(path.join(fixture, "ss.toml"), `[project]
entry = "slide.ss"

[editor.wysiwyg]
debounce = 0
max_wait = 0

[editor.wysiwyg.refresh]
automatic = false
`, "utf8");
    await writeFile(slide, "page demo\nend\n", "utf8");

    mock.reset();
    const uri = mock.Uri.file(slide);
    const document = { uri, languageId: "ss-slide", version: 1 };
    mock.workspace.textDocuments.push(document);
    const requests = [];
    const messages = [];
    const session = {
      document,
      panel: {
        active: true,
        webview: {
          options: {},
          asWebviewUri: (value) => value,
          postMessage: async (message) => {
            messages.push(structuredClone(message));
            return true;
          },
        },
        dispose() {},
      },
      ready: true,
      serial: 0,
      requestRunning: false,
      refreshPending: false,
      editorReconciliationPending: false,
      disposed: false,
      dependencyPaths: new Set([path.resolve(slide)]),
      snapshotId: "initial",
      snapshotResponse: () => editorSnapshot("reconciled"),
    };
    const client = {
      async sendRequest(method, params, token) {
        requests.push({ method, params, token });
        if (method === "ss/layoutEdit" || method === "ss/editLineGeometry" ||
            method === "ss/editShapeBounds" || method === "ss/deleteComponent") {
          return {
            schema: 1,
            status: "ok",
            workspaceEdit: {
              changes: {
                [uri.toString()]: [{
                  range: {
                    start: { line: 0, character: 0 },
                    end: { line: 0, character: 0 },
                  },
                  newText: "",
                }],
              },
            },
          };
        }
        if (method === "ss/iconCatalog") {
          return {
            schema: 1,
            collection: "fontawesome-free",
            version: "7.2.0",
            query: params.query,
            style: params.style,
            category: params.category,
            offset: params.offset,
            total_available: 2141,
            total_matches: 1,
            has_more: false,
            categories: [{ id: "shapes", label: "Shapes" }],
            icons: [{
              id: "fa-solid:star",
              name: "star",
              style: "solid",
              svg: "<svg></svg>",
            }],
          };
        }
        if (method === "ss/insertIcon") {
          return {
            schema: 1,
            status: "ok",
            workspaceEdit: {
              changes: {
                [uri.toString()]: [{
                  range: {
                    start: { line: 0, character: 0 },
                    end: { line: 0, character: 0 },
                  },
                  newText: "",
                }],
              },
            },
            selection: { path: slide, pageId: params.pageId, binding: "icon_item" },
          };
        }
        if (method === "ss/editorSnapshot") return session.snapshotResponse();
        throw new Error(`unexpected request ${method}`);
      },
      sendNotification() {},
    };
    const controller = new EditorController(
      { extensionUri: mock.Uri.file(fixture) },
      { appendLine() {} },
      () => client,
    );
    controller.sessions.set(uri.toString(), session);
    mock.workspace.applyEdit = async () => {
      document.version += 1;
      mock.change(document);
      return true;
    };

    await run({
      controller,
      session,
      requests,
      messages,
      change() {
        document.version += 1;
        mock.change(document);
      },
    });
    controller.dispose();
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
}

function translationMessage(requestId) {
  return {
    type: "translate",
    requestId,
    snapshotId: "initial",
    nodeId: 7,
    pageId: 1,
    mode: "absolute",
    fromBounds: { x: 10, y: 10, width: 20, height: 20 },
    toBounds: { x: 30, y: 40, width: 20, height: 20 },
  };
}

function editorSnapshot(snapshotId) {
  return {
    snapshot_id: snapshotId,
    source_paths: [],
    display: {
      schema: 3,
      kind: "translation_patch",
      base_snapshot_id: "initial",
      translations: [],
    },
  };
}

async function waitFor(predicate) {
  const deadline = Date.now() + 2_000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("timed out waiting for controller state");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

function vscodeMock() {
  const changeListeners = [];
  const disposables = [];
  const openedDocuments = [];
  const panels = [];
  const warnings = [];
  class Uri {
    constructor(value) {
      this.scheme = "file";
      this.fsPath = path.resolve(value);
    }
    static file(value) {
      return new Uri(value);
    }
    static parse(value) {
      return new Uri(fileURLToPath(value));
    }
    static joinPath(base, ...parts) {
      return new Uri(path.join(base.fsPath, ...parts));
    }
    toString() {
      return pathToFileURL(this.fsPath).toString();
    }
  }
  class WorkspaceEdit {
    set(uri, edits) {
      this.uri = uri;
      this.edits = edits;
    }
  }
  class Range {
    constructor(...values) {
      this.values = values;
    }
  }
  class CancellationTokenSource {
    constructor() {
      this.token = { isCancellationRequested: false };
    }
    cancel() {
      this.token.isCancellationRequested = true;
    }
    dispose() {}
  }
  class TabInputText {}
  class TabInputTextDiff {}
  const disposable = () => {
    const value = { dispose() {} };
    disposables.push(value);
    return value;
  };
  const watcher = () => ({
    dispose() {},
    onDidChange: () => disposable(),
    onDidCreate: () => disposable(),
    onDidDelete: () => disposable(),
  });
  const workspace = {
    textDocuments: [],
    workspaceFolders: [],
    applyEdit: async () => true,
    async openTextDocument(uri) {
      openedDocuments.push(uri.fsPath);
      const document = {
        uri,
        languageId: path.extname(uri.fsPath) === ".ss" ? "ss-slide" : "plaintext",
        version: 1,
      };
      this.textDocuments.push(document);
      return document;
    },
    onDidChangeTextDocument(listener) {
      changeListeners.push(listener);
      return disposable();
    },
    createFileSystemWatcher: watcher,
    getWorkspaceFolder: () => undefined,
  };
  const window = {
    async showWarningMessage(message) {
      warnings.push(message);
      return undefined;
    },
    createWebviewPanel(_viewType, title) {
      const panel = {
        title,
        active: true,
        webview: {
          options: {},
          cspSource: "test-webview",
          html: "",
          asWebviewUri: (value) => value,
          postMessage: async () => true,
          onDidReceiveMessage: () => disposable(),
        },
        onDidDispose: () => disposable(),
        reveal() {},
        dispose() {},
      };
      panels.push(panel);
      return panel;
    },
  };
  return {
    workspace,
    window,
    Uri,
    WorkspaceEdit,
    TextEdit: { replace: (range, newText) => ({ range, newText }) },
    Range,
    Selection: class {},
    CancellationTokenSource,
    ViewColumn: { Beside: 2 },
    TextEditorRevealType: { InCenterIfOutsideViewport: 0 },
    TabInputText,
    TabInputTextDiff,
    openedDocuments,
    panels,
    warnings,
    change(document) {
      for (const listener of changeListeners) listener({ document });
    },
    reset() {
      workspace.textDocuments.length = 0;
      workspace.workspaceFolders.length = 0;
      changeListeners.length = 0;
      disposables.length = 0;
      openedDocuments.length = 0;
      panels.length = 0;
      warnings.length = 0;
    },
  };
}
