import * as path from "path";
import * as vscode from "vscode";
import { LanguageClient } from "vscode-languageclient/node";
import { projectSettings } from "../projectConfig";
import {
  EditorSnapshot,
  HostMessage,
  LayoutEditResult,
  ShapeEditResult,
  WebviewMessage,
} from "./protocol";
import { isRetryableSnapshotError } from "./request";
import {
  documentVersions,
  revealSource,
  toWorkspaceEdit,
  workspaceEditTargetsAreCurrent,
} from "./source";
import { refreshTiming, shouldStartPendingRefresh } from "./timing";
import { ViewResources } from "./view";

type ClientProvider = () => LanguageClient | undefined;

interface Session {
  document: vscode.TextDocument;
  panel: vscode.WebviewPanel;
  ready: boolean;
  buildOnReady: boolean;
  timer?: NodeJS.Timeout;
  serial: number;
  requestRunning: boolean;
  requestCancellation?: vscode.CancellationTokenSource;
  refreshPending: boolean;
  pendingRefreshSinceMs?: number;
  disposed: boolean;
  dependencyPaths: Set<string>;
  snapshotId?: string;
}

export class EditorController implements vscode.Disposable {
  private readonly sessions = new Map<string, Session>();
  private readonly disposables: vscode.Disposable[] = [];
  private readonly view: ViewResources;

  constructor(
    context: vscode.ExtensionContext,
    private readonly output: vscode.OutputChannel,
    private readonly clientProvider: ClientProvider,
  ) {
    this.view = new ViewResources(context.extensionUri);
    this.disposables.push(vscode.workspace.onDidChangeTextDocument((event) => {
      this.refreshAffected(event.document.uri);
    }));
    const sourceWatcher = vscode.workspace.createFileSystemWatcher("**/*.ss");
    const projectWatcher = vscode.workspace.createFileSystemWatcher(
      "**/ss.toml",
    );
    this.disposables.push(
      sourceWatcher,
      projectWatcher,
      sourceWatcher.onDidChange((uri) => this.refreshAffected(uri, 0)),
      sourceWatcher.onDidCreate(() => this.refreshAll(0)),
      sourceWatcher.onDidDelete((uri) => this.refreshAffected(uri, 0)),
      projectWatcher.onDidChange(() => this.refreshAll(0)),
      projectWatcher.onDidCreate(() => this.refreshAll(0)),
      projectWatcher.onDidDelete(() => this.refreshAll(0)),
    );
  }

  dispose(): void {
    for (const session of [...this.sessions.values()]) {
      session.panel.dispose();
    }
    this.sessions.clear();
    for (const disposable of this.disposables) disposable.dispose();
  }

  open(document: vscode.TextDocument | undefined): void {
    if (
      !document || document.languageId !== "ss-slide" ||
      document.uri.scheme !== "file"
    ) {
      void vscode.window.showWarningMessage(
        "Open an .ss file to start the WYSIWYG editor.",
      );
      return;
    }
    if (!projectSettings(document.uri).wysiwyg.enabled) {
      void vscode.window.showWarningMessage(
        "The WYSIWYG editor is disabled by ss.toml [editor.wysiwyg].enabled.",
      );
      return;
    }
    const key = document.uri.toString();
    const existing = this.sessions.get(key);
    if (existing) {
      existing.panel.reveal(vscode.ViewColumn.Beside, true);
      return;
    }

    const panel = vscode.window.createWebviewPanel(
      "ss.wysiwyg",
      `ss · ${path.basename(document.uri.fsPath)}`,
      { viewColumn: vscode.ViewColumn.Beside, preserveFocus: false },
      {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: this.view.roots(document),
      },
    );
    const session: Session = {
      document,
      panel,
      ready: false,
      buildOnReady: false,
      serial: 0,
      requestRunning: false,
      refreshPending: false,
      disposed: false,
      dependencyPaths: new Set([normalizePath(document.uri.fsPath)]),
    };
    this.sessions.set(key, session);
    panel.webview.html = this.view.html(panel.webview);
    panel.onDidDispose(() => {
      session.disposed = true;
      if (session.timer) clearTimeout(session.timer);
      session.requestCancellation?.cancel();
      this.sessions.delete(key);
      this.clientProvider()?.sendNotification("ss/editorClose", {
        textDocument: { uri: document.uri.toString() },
      });
    });
    panel.webview.onDidReceiveMessage((message: WebviewMessage) =>
      void this.handleMessage(session, message)
    );
  }

  refreshOpenDocuments(delayMs = 0): void {
    this.refreshAll(delayMs);
  }

  build(document: vscode.TextDocument | undefined): boolean {
    let session = [...this.sessions.values()].find((candidate) =>
      candidate.panel.active
    );
    if (!session && document) {
      session = this.sessions.get(document.uri.toString());
    }
    if (!session && !document) {
      session ??= this.sessions.size === 1
        ? this.sessions.values().next().value
        : undefined;
    }
    if (session) {
      if (!session.ready) {
        session.buildOnReady = true;
        return true;
      }
      this.requestBuild(session);
      return true;
    }
    this.open(document);
    if (!document) return false;
    session = this.sessions.get(document.uri.toString());
    if (!session) return false;
    session.buildOnReady = true;
    return true;
  }

  private async handleMessage(
    session: Session,
    message: WebviewMessage,
  ): Promise<void> {
    if (message.type === "ready") {
      session.ready = true;
      if (session.buildOnReady) {
        session.buildOnReady = false;
        this.schedule(session, 0);
      } else {
        this.scheduleAutomatic(session, 0);
      }
      return;
    }
    if (message.type === "refreshFull") {
      session.snapshotId = undefined;
      this.schedule(session, 0);
      return;
    }
    if (message.type === "revealSource") {
      await revealSource(message.path, message.start, message.end);
      return;
    }
    if (message.type === "translate") {
      await this.applyTranslation(session, message);
      return;
    }
    if (message.type === "insertShape" || message.type === "editShapeStyle") {
      await this.applyShapeEdit(session, message);
    }
  }

  private async applyShapeEdit(
    session: Session,
    message: Extract<WebviewMessage, { type: "insertShape" | "editShapeStyle" }>,
  ): Promise<void> {
    const client = this.clientProvider();
    const operation = message.type === "insertShape" ? "insert" : "style";
    if (!client) {
      await this.post(session, {
        type: "shapeEditResult",
        requestId: message.requestId,
        operation,
        status: "unsupported",
        message: "Language server is not running.",
      });
      return;
    }
    const versions = documentVersions();
    try {
      const method = message.type === "insertShape"
        ? "ss/insertShape"
        : "ss/shapeStyleEdit";
      const result = await client.sendRequest<ShapeEditResult>(method, {
        textDocument: { uri: session.document.uri.toString() },
        snapshotId: message.snapshotId,
        pageId: message.pageId,
        ...(message.type === "insertShape"
          ? {
            kind: message.kind,
            bounds: message.bounds,
            fill: message.fill,
            stroke: message.stroke,
          }
          : {
            nodeId: message.nodeId,
            fill: message.fill,
            stroke: message.stroke,
          }),
      });
      if (session.disposed) return;
      if (!workspaceEditTargetsAreCurrent(result.workspaceEdit, versions)) {
        await this.post(session, {
          type: "shapeEditResult",
          requestId: message.requestId,
          operation,
          status: "stale",
          message: "The document changed before the edit was applied.",
        });
        this.scheduleAutomatic(session, 0);
        return;
      }
      if (result.status !== "ok") {
        await this.post(session, {
          type: "shapeEditResult",
          requestId: message.requestId,
          operation,
          status: result.status,
          message: result.message ?? "The shape edit could not be applied.",
        });
        if (result.status === "stale") this.scheduleAutomatic(session, 0);
        return;
      }
      if (!result.workspaceEdit) {
        await this.post(session, {
          type: "shapeEditResult",
          requestId: message.requestId,
          operation,
          status: "rejected",
          message: result.message ?? "The language server returned no source edit.",
        });
        return;
      }
      const applied = await vscode.workspace.applyEdit(
        toWorkspaceEdit(result.workspaceEdit),
      );
      if (!applied) {
        await this.post(session, {
          type: "shapeEditResult",
          requestId: message.requestId,
          operation,
          status: "rejected",
          message: "VS Code rejected the source edit.",
        });
        return;
      }
      await this.post(session, {
        type: "shapeEditResult",
        requestId: message.requestId,
        operation,
        status: "applied",
        documentVersion: session.document.version,
        selection: result.selection,
      });
      this.scheduleAutomatic(session, 0);
    } catch (error) {
      this.output.appendLine(`[editor] shape edit failed: ${String(error)}`);
      await this.post(session, {
        type: "shapeEditResult",
        requestId: message.requestId,
        operation,
        status: "rejected",
        message: String(error),
      });
    }
  }

  private async applyTranslation(
    session: Session,
    message: Extract<WebviewMessage, { type: "translate" }>,
  ): Promise<void> {
    const client = this.clientProvider();
    if (!client) {
      await this.post(session, {
        type: "editResult",
        requestId: message.requestId,
        status: "unsupported",
        message: "Language server is not running.",
      });
      return;
    }
    const versions = documentVersions();
    try {
      const result = await client.sendRequest<LayoutEditResult>(
        "ss/layoutEdit",
        {
          textDocument: { uri: session.document.uri.toString() },
          snapshotId: message.snapshotId,
          nodeId: message.nodeId,
          pageId: message.pageId,
          mode: message.mode,
          fromBounds: message.fromBounds,
          toBounds: message.toBounds,
        },
      );
      if (session.disposed) return;
      if (
        !workspaceEditTargetsAreCurrent(result.workspaceEdit, versions)
      ) {
        await this.post(session, {
          type: "editResult",
          requestId: message.requestId,
          status: "stale",
          message: "The document changed before the edit was applied.",
        });
        this.scheduleAutomatic(session, 0);
        return;
      }
      if (result.status !== "ok") {
        await this.post(session, {
          type: "editResult",
          requestId: message.requestId,
          status: result.status,
          message: result.message ?? "The edit could not be applied.",
        });
        if (result.status === "stale") this.scheduleAutomatic(session, 0);
        return;
      }
      if (!result.workspaceEdit) {
        await this.post(session, {
          type: "editResult",
          requestId: message.requestId,
          status: "rejected",
          message: result.message ?? "The language server returned no source edit.",
        });
        return;
      }
      const edit = toWorkspaceEdit(result.workspaceEdit);
      const applied = await vscode.workspace.applyEdit(edit);
      if (!applied) {
        await this.post(session, {
          type: "editResult",
          requestId: message.requestId,
          status: "rejected",
          message: "VS Code rejected the source edit.",
        });
        return;
      }
      await this.post(session, {
        type: "editResult",
        requestId: message.requestId,
        status: "applied",
        documentVersion: session.document.version,
      });
    } catch (error) {
      this.output.appendLine(`[editor] layout edit failed: ${String(error)}`);
      await this.post(session, {
        type: "editResult",
        requestId: message.requestId,
        status: "rejected",
        message: String(error),
      });
    }
  }

  private refreshAffected(uri: vscode.Uri, delayMs?: number): void {
    if (uri.scheme !== "file" || path.extname(uri.fsPath) !== ".ss") return;
    const changedPath = normalizePath(uri.fsPath);
    for (const session of this.sessions.values()) {
      const settings = projectSettings(session.document.uri).wysiwyg;
      const direct = session.document.uri.toString() === uri.toString();
      const dependency = session.dependencyPaths.has(changedPath) &&
        settings.refreshOnDependencyChange;
      if (direct || dependency) {
        this.scheduleAutomatic(
          session,
          delayMs ?? settings.debounceMs,
          delayMs ?? settings.maxWaitMs,
        );
      }
    }
  }

  private refreshAll(delayMs: number): void {
    for (const session of this.sessions.values()) {
      this.scheduleAutomatic(session, delayMs);
    }
  }

  private scheduleAutomatic(
    session: Session,
    delayMs: number,
    maxWaitMs = delayMs,
  ): void {
    if (
      projectSettings(session.document.uri).wysiwyg.refreshAutomatically
    ) {
      this.schedule(session, delayMs, maxWaitMs);
      return;
    }
    this.markBuildRequired(session);
  }

  private markBuildRequired(session: Session): void {
    if (session.disposed) return;
    if (session.timer) clearTimeout(session.timer);
    session.timer = undefined;
    session.pendingRefreshSinceMs = undefined;
    session.refreshPending = false;
    session.serial += 1;
    session.requestCancellation?.cancel();
    void this.post(session, {
      type: "buildStatus",
      revision: session.serial,
      status: "manual",
    });
  }

  private requestBuild(session: Session): void {
    if (session.requestRunning) {
      if (session.requestCancellation?.token.isCancellationRequested) {
        if (session.timer) clearTimeout(session.timer);
        session.timer = undefined;
        session.pendingRefreshSinceMs = undefined;
        session.refreshPending = true;
      }
      return;
    }
    this.schedule(session, 0);
  }

  private schedule(
    session: Session,
    delayMs: number,
    maxWaitMs = delayMs,
  ): void {
    if (session.disposed) return;
    if (session.requestRunning) {
      session.refreshPending = true;
      session.requestCancellation?.cancel();
    }
    // Invalidate an in-flight response as soon as an edit is observed, not
    // after the debounce timer expires.
    session.serial += 1;
    void this.post(session, {
      type: "buildStatus",
      revision: session.serial,
      status: "building",
    });
    if (session.timer) clearTimeout(session.timer);
    const timing = refreshTiming(
      Date.now(),
      session.pendingRefreshSinceMs,
      delayMs,
      maxWaitMs,
    );
    session.pendingRefreshSinceMs = timing.pendingSinceMs;
    const serial = session.serial;
    session.timer = setTimeout(() => {
      session.timer = undefined;
      session.pendingRefreshSinceMs = undefined;
      void this.refresh(session, serial);
    }, timing.delayMs);
  }

  private async refresh(session: Session, serial: number): Promise<void> {
    if (session.disposed || serial !== session.serial) return;
    const client = this.clientProvider();
    if (!client) {
      await this.post(session, {
        type: "buildStatus",
        revision: serial,
        status: "unavailable",
      });
      return;
    }
    if (session.requestRunning) {
      // The server handles requests serially. Coalescing here prevents obsolete
      // snapshot work from forming a queue during rapid edits.
      session.refreshPending = true;
      return;
    }
    session.requestRunning = true;
    const requestCancellation = new vscode.CancellationTokenSource();
    session.requestCancellation = requestCancellation;
    const documentVersion = session.document.version;
    const buildStartedAt = performance.now();
    try {
      const snapshot = await client.sendRequest<EditorSnapshot>(
        "ss/editorSnapshot",
        {
          textDocument: { uri: session.document.uri.toString() },
          baseSnapshotId: session.snapshotId ?? "",
        },
        requestCancellation.token,
      );
      if (
        session.disposed || serial !== session.serial ||
        documentVersion !== session.document.version
      ) return;
      session.dependencyPaths = new Set(
        snapshot.source_paths.map(normalizePath),
      );
      this.view.updateRoots(session.panel.webview, session.document, snapshot);
      const prepared = this.view.prepareSnapshot(
        session.panel.webview,
        snapshot,
      );
      await this.post(session, {
        type: "snapshot",
        revision: serial,
        documentVersion,
        buildDurationMs: performance.now() - buildStartedAt,
        snapshot: prepared,
      });
      session.snapshotId = snapshot.snapshot_id;
    } catch (error) {
      if (session.disposed || serial !== session.serial) return;
      if (isRetryableSnapshotError(error)) {
        session.refreshPending = true;
        return;
      }
      this.output.appendLine(`[editor] snapshot failed: ${String(error)}`);
      await this.post(session, {
        type: "error",
        revision: serial,
        buildDurationMs: performance.now() - buildStartedAt,
        message: snapshotFailureMessage(error),
      });
    } finally {
      requestCancellation.dispose();
      if (session.requestCancellation === requestCancellation) {
        session.requestCancellation = undefined;
      }
      session.requestRunning = false;
      const refreshImmediately = shouldStartPendingRefresh(
        session.refreshPending,
        session.timer !== undefined,
      );
      session.refreshPending = false;
      if (refreshImmediately && !session.disposed) {
        this.schedule(session, 0);
      }
    }
  }

  private post(session: Session, message: HostMessage): Thenable<boolean> {
    if (session.disposed) return Promise.resolve(false);
    return session.panel.webview.postMessage(message);
  }
}

function normalizePath(filePath: string): string {
  return path.resolve(filePath);
}

function snapshotFailureMessage(error: unknown): string {
  const detail = error instanceof Error ? error.message : String(error);
  const normalized = detail.trim();
  return normalized.length > 0
    ? `WYSIWYG build failed: ${normalized}`
    : "WYSIWYG build failed.";
}
