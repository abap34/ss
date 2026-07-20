#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
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

await testManualPositionEditRequestsReconciliation();
await testNewSourceEditReschedulesReconciliation();

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
      buildOnReady: false,
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
        if (method === "ss/layoutEdit") {
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
    onDidChangeTextDocument(listener) {
      changeListeners.push(listener);
      return disposable();
    },
    createFileSystemWatcher: watcher,
    getWorkspaceFolder: () => undefined,
  };
  return {
    workspace,
    window: {},
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
    change(document) {
      for (const listener of changeListeners) listener({ document });
    },
    reset() {
      workspace.textDocuments.length = 0;
      changeListeners.length = 0;
      disposables.length = 0;
    },
  };
}
