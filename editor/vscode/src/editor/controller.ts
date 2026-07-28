import * as path from "path";
import * as vscode from "vscode";
import { LanguageClient } from "vscode-languageclient/node";
import { projectEntryUri, projectSettings } from "../projectConfig";
import {
  ComponentDeleteResult,
  EditorSnapshot,
  HostMessage,
  IconCatalogResult,
  LayoutEditResult,
  Rect,
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
import {
  ShapeEditMessage,
  shapeEditOperation,
  shapeEditRequest,
} from "./shape-edit-request";
import {
  refreshTiming,
  shouldScheduleRefresh,
  shouldStartPendingRefresh,
} from "./timing";
import { ViewResources } from "./view";

type ClientProvider = () => LanguageClient | undefined;
type SourceEditMessage = Exclude<
  WebviewMessage,
  { type: "ready" | "refreshFull" | "revealSource" | "queryIcons" }
>;

const immediateRefreshDelayMs = 0;
const languageServerUnavailableMessage = "Language server is not running.";
const sourceDocumentChangedMessage =
  "The document changed before the edit was applied.";
const commonSourceEditMessages = Object.freeze({
  unavailable: languageServerUnavailableMessage,
  stale: sourceDocumentChangedMessage,
});

interface LayoutSourceEditMessage {
  requestId: number;
  snapshotId: string;
  nodeId: number;
  pageId: number;
  fromBounds: Rect;
  toBounds: Rect;
}

type SourceEditOutcome<Result extends LayoutEditResult = LayoutEditResult> =
  | {
    status: "applied";
    documentVersion: number;
    result: Result;
    refresh: true;
  }
  | {
    status: Exclude<LayoutEditResult["status"], "ok">;
    message?: string;
    refresh?: true;
  };

interface SourceEditMessages {
  unavailable: string;
  stale: string;
  failed: string;
  missingEdit: string;
  logLabel: string;
}

interface Session {
  document: vscode.TextDocument;
  panel: vscode.WebviewPanel;
  ready: boolean;
  sourceEditQueue: Promise<void>;
  sourceEditCancellation?: vscode.CancellationTokenSource;
  timer?: NodeJS.Timeout;
  serial: number;
  requestRunning: boolean;
  requestCancellation?: vscode.CancellationTokenSource;
  refreshPending: boolean;
  editorReconciliationPending: boolean;
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
      sourceWatcher.onDidCreate(() => this.refreshAll(immediateRefreshDelayMs)),
      sourceWatcher.onDidDelete((uri) => this.refreshAffected(uri, 0)),
      projectWatcher.onDidChange(() =>
        this.refreshAll(immediateRefreshDelayMs)
      ),
      projectWatcher.onDidCreate(() =>
        this.refreshAll(immediateRefreshDelayMs)
      ),
      projectWatcher.onDidDelete(() =>
        this.refreshAll(immediateRefreshDelayMs)
      ),
    );
  }

  dispose(): void {
    for (const session of [...this.sessions.values()]) {
      session.disposed = true;
      if (session.timer) clearTimeout(session.timer);
      session.requestCancellation?.cancel();
      session.sourceEditCancellation?.cancel();
      session.panel.dispose();
    }
    this.sessions.clear();
    for (const disposable of this.disposables) disposable.dispose();
  }

  open(document: vscode.TextDocument | undefined): void {
    if (!document || !isSsDocument(document)) {
      void this.openProjectEntry(document?.uri);
      return;
    }
    this.openDocument(document);
  }

  private async openProjectEntry(contextUri: vscode.Uri | undefined): Promise<void> {
    const entryUri = projectEntryUri(contextUri);
    if (!entryUri) {
      await vscode.window.showWarningMessage(
        "No ss.toml [project].entry was found for the current workspace.",
      );
      return;
    }
    let document: vscode.TextDocument;
    try {
      document = await vscode.workspace.openTextDocument(entryUri);
    } catch (error) {
      this.output.appendLine(`WYSIWYG project entry open failed: ${String(error)}`);
      await vscode.window.showWarningMessage(
        `Could not open the ss.toml project entry: ${entryUri.fsPath}`,
      );
      return;
    }
    if (!isSsDocument(document)) {
      await vscode.window.showWarningMessage(
        `The ss.toml project entry is not an .ss file: ${entryUri.fsPath}`,
      );
      return;
    }
    this.openDocument(document);
  }

  private openDocument(document: vscode.TextDocument): void {
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
      sourceEditQueue: Promise.resolve(),
      serial: 0,
      requestRunning: false,
      refreshPending: false,
      editorReconciliationPending: false,
      disposed: false,
      dependencyPaths: new Set([normalizePath(document.uri.fsPath)]),
    };
    this.sessions.set(key, session);
    panel.webview.html = this.view.html(panel.webview);
    panel.onDidDispose(() => {
      session.disposed = true;
      if (session.timer) clearTimeout(session.timer);
      session.requestCancellation?.cancel();
      session.sourceEditCancellation?.cancel();
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
      if (!session.ready) return true;
      this.requestBuild(session);
      return true;
    }
    this.open(document);
    if (!document) return false;
    session = this.sessions.get(document.uri.toString());
    if (!session) return false;
    return true;
  }

  private async handleMessage(
    session: Session,
    message: WebviewMessage,
  ): Promise<void> {
    if (message.type === "ready") {
      session.ready = true;
      this.schedule(session, immediateRefreshDelayMs);
      return;
    }
    if (message.type === "refreshFull") {
      session.snapshotId = undefined;
      this.schedule(session, immediateRefreshDelayMs);
      return;
    }
    if (message.type === "revealSource") {
      await revealSource(message.path, message.start, message.end);
      return;
    }
    if (message.type === "queryIcons") {
      await this.queryIcons(session, message);
      return;
    }
    await this.enqueueSourceEdit(session, () =>
      this.handleSourceEditMessage(session, message)
    );
  }

  private async handleSourceEditMessage(
    session: Session,
    message: SourceEditMessage,
  ): Promise<void> {
    if (message.type === "translate") {
      await this.applyTranslation(session, message);
      return;
    }
    if (message.type === "resizeComponentWidth") {
      await this.applyComponentWidth(session, message);
      return;
    }
    if (message.type === "deleteComponent") {
      await this.applyComponentDelete(session, message);
      return;
    }
    if (message.type === "insertIcon") {
      await this.applyIconInsert(session, message);
      return;
    }
    if (message.type === "insertShape" || message.type === "editShapeStyle" ||
        message.type === "editLineGeometry" || message.type === "editShapeBounds") {
      await this.applyShapeEdit(session, message);
    }
  }

  private enqueueSourceEdit(
    session: Session,
    operation: () => Promise<void>,
  ): Promise<void> {
    const run = session.sourceEditQueue.then(async () => {
      if (session.disposed) return;
      const cancellation = new vscode.CancellationTokenSource();
      session.sourceEditCancellation = cancellation;
      try {
        await operation();
      } finally {
        if (session.sourceEditCancellation === cancellation) {
          session.sourceEditCancellation = undefined;
        }
        cancellation.dispose();
      }
    });
    session.sourceEditQueue = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }

  private async queryIcons(
    session: Session,
    message: Extract<WebviewMessage, { type: "queryIcons" }>,
  ): Promise<void> {
    const client = this.clientProvider();
    if (!client) {
      await this.post(session, {
        type: "iconCatalogError",
        requestId: message.requestId,
        message: languageServerUnavailableMessage,
      });
      return;
    }
    try {
      const result = await client.sendRequest<IconCatalogResult>(
        "ss/iconCatalog",
        {
          query: message.query,
          style: message.style,
          category: message.category,
          offset: message.offset,
        },
      );
      if (session.disposed) return;
      if (!Array.isArray(result.icons) || !Array.isArray(result.categories)) {
        throw new Error("The language server returned an invalid icon catalog.");
      }
      await this.post(session, {
        type: "iconCatalog",
        requestId: message.requestId,
        result,
      });
    } catch (error) {
      this.output.appendLine(`[editor] icon catalog failed: ${String(error)}`);
      await this.post(session, {
        type: "iconCatalogError",
        requestId: message.requestId,
        message: String(error),
      });
    }
  }

  private async applyComponentDelete(
    session: Session,
    message: Extract<WebviewMessage, { type: "deleteComponent" }>,
  ): Promise<void> {
    const outcome = await this.applySourceEdit<ComponentDeleteResult>(
      session,
      (client, token) => client.sendRequest<ComponentDeleteResult>(
        "ss/deleteComponent",
        {
          textDocument: { uri: session.document.uri.toString() },
          snapshotId: message.snapshotId,
          nodeId: message.nodeId,
          pageId: message.pageId,
        },
        token,
      ),
      {
        ...commonSourceEditMessages,
        failed: "The component could not be deleted.",
        missingEdit: "The language server returned no component deletion edit.",
        logLabel: "component deletion",
      },
    );
    if (!outcome) return;
    await this.post(session, outcome.status === "applied"
      ? {
        type: "componentDeleteResult",
        requestId: message.requestId,
        status: "applied",
        documentVersion: outcome.documentVersion,
      }
      : {
        type: "componentDeleteResult",
        requestId: message.requestId,
        status: outcome.status,
        message: outcome.message,
      });
    if (outcome.refresh) this.scheduleEditorReconciliation(session);
  }

  private async applyIconInsert(
    session: Session,
    message: Extract<WebviewMessage, { type: "insertIcon" }>,
  ): Promise<void> {
    const outcome = await this.applySourceEdit<ShapeEditResult>(
      session,
      (client, token) => client.sendRequest<ShapeEditResult>(
        "ss/insertIcon",
        {
          textDocument: { uri: session.document.uri.toString() },
          snapshotId: message.snapshotId,
          pageId: message.pageId,
          source: message.source,
          bounds: message.bounds,
          color: message.color,
        },
        token,
      ),
      {
        ...commonSourceEditMessages,
        failed: "The icon could not be inserted.",
        missingEdit: "The language server returned no icon insertion edit.",
        logLabel: "icon insertion",
      },
    );
    if (!outcome) return;
    await this.post(session, outcome.status === "applied"
      ? {
        type: "iconEditResult",
        requestId: message.requestId,
        status: "applied",
        documentVersion: outcome.documentVersion,
        selection: outcome.result.selection,
      }
      : {
        type: "iconEditResult",
        requestId: message.requestId,
        status: outcome.status,
        message: outcome.message,
      });
    if (outcome.refresh) {
      this.scheduleAutomatic(session, immediateRefreshDelayMs);
    }
  }

  private async applyShapeEdit(
    session: Session,
    message: ShapeEditMessage,
  ): Promise<void> {
    const operation = shapeEditOperation(message);
    const request = shapeEditRequest(
      session.document.uri.toString(),
      message,
    );
    const outcome = await this.applySourceEdit<ShapeEditResult>(
      session,
      (client, token) => client.sendRequest<ShapeEditResult>(
        request.method,
        request.params,
        token,
      ),
      {
        ...commonSourceEditMessages,
        failed: "The shape edit could not be applied.",
        missingEdit: "The language server returned no shape source edit.",
        logLabel: "shape edit",
      },
    );
    if (!outcome) return;
    await this.post(session, outcome.status === "applied"
      ? {
        type: "shapeEditResult",
        requestId: message.requestId,
        operation,
        status: "applied",
        documentVersion: outcome.documentVersion,
        selection: outcome.result.selection,
      }
      : {
        type: "shapeEditResult",
        requestId: message.requestId,
        operation,
        status: outcome.status,
        message: outcome.message,
      });
    if (outcome.refresh) {
      this.scheduleAutomatic(session, immediateRefreshDelayMs);
    }
  }

  private async applyTranslation(
    session: Session,
    message: Extract<WebviewMessage, { type: "translate" }>,
  ): Promise<void> {
    const outcome = await this.applyLayoutSourceEdit(
      session,
      message,
      message.mode,
      {
        ...commonSourceEditMessages,
        failed: "The edit could not be applied.",
        missingEdit: "The language server returned no source edit.",
        logLabel: "layout edit",
      },
    );
    if (!outcome) return;
    await this.post(session, outcome.status === "applied"
      ? {
        type: "editResult",
        requestId: message.requestId,
        status: "applied",
        documentVersion: outcome.documentVersion,
      }
      : {
        type: "editResult",
        requestId: message.requestId,
        status: outcome.status,
        message: outcome.message,
      });
    if (outcome.refresh) this.scheduleEditorReconciliation(session);
  }

  private async applyComponentWidth(
    session: Session,
    message: Extract<WebviewMessage, { type: "resizeComponentWidth" }>,
  ): Promise<void> {
    const outcome = await this.applyLayoutSourceEdit(
      session,
      message,
      "width",
      {
        ...commonSourceEditMessages,
        stale: "The document changed before the width edit was applied.",
        failed: "The component width could not be applied.",
        missingEdit: "The language server returned no component width edit.",
        logLabel: "component width edit",
      },
    );
    if (!outcome) return;
    await this.post(session, outcome.status === "applied"
      ? {
        type: "componentWidthEditResult",
        requestId: message.requestId,
        status: "applied",
        documentVersion: outcome.documentVersion,
      }
      : {
        type: "componentWidthEditResult",
        requestId: message.requestId,
        status: outcome.status,
        message: outcome.message,
      });
    if (outcome.refresh) this.scheduleEditorReconciliation(session);
  }

  private applyLayoutSourceEdit(
    session: Session,
    message: LayoutSourceEditMessage,
    mode: "absolute" | "relative" | "width",
    messages: SourceEditMessages,
  ): Promise<SourceEditOutcome | undefined> {
    return this.applySourceEdit(
      session,
      (client, token) => client.sendRequest<LayoutEditResult>(
        "ss/layoutEdit",
        {
          textDocument: { uri: session.document.uri.toString() },
          snapshotId: message.snapshotId,
          nodeId: message.nodeId,
          pageId: message.pageId,
          mode,
          fromBounds: message.fromBounds,
          toBounds: message.toBounds,
        },
        token,
      ),
      messages,
    );
  }

  private async applySourceEdit<Result extends LayoutEditResult>(
    session: Session,
    request: (
      client: LanguageClient,
      token?: vscode.CancellationToken,
    ) => Promise<Result>,
    messages: SourceEditMessages,
  ): Promise<SourceEditOutcome<Result> | undefined> {
    const client = this.clientProvider();
    if (!client) {
      return {
        status: "unsupported",
        message: messages.unavailable,
      };
    }
    const versions = documentVersions();
    const token = session.sourceEditCancellation?.token;
    try {
      const result = await request(client, token);
      if (session.disposed || token?.isCancellationRequested) return undefined;
      if (!workspaceEditTargetsAreCurrent(result.workspaceEdit, versions)) {
        return {
          status: "stale",
          message: messages.stale,
          refresh: true,
        };
      }
      if (result.status !== "ok") {
        if (result.status === "stale") {
          return {
            status: "stale",
            message: result.message ?? messages.failed,
            refresh: true,
          };
        }
        return {
          status: result.status,
          message: result.message ?? messages.failed,
        };
      }
      if (!result.workspaceEdit) {
        return {
          status: "rejected",
          message: result.message ?? messages.missingEdit,
        };
      }
      const applied = await vscode.workspace.applyEdit(
        toWorkspaceEdit(result.workspaceEdit),
      );
      if (!applied) {
        return {
          status: "rejected",
          message: "VS Code rejected the source edit.",
        };
      }
      return {
        status: "applied",
        documentVersion: session.document.version,
        result,
        refresh: true,
      };
    } catch (error) {
      if (session.disposed || token?.isCancellationRequested) return undefined;
      this.output.appendLine(`[editor] ${messages.logLabel} failed: ${String(error)}`);
      return {
        status: "rejected",
        message: String(error),
      };
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
    if (shouldScheduleRefresh(
      projectSettings(session.document.uri).wysiwyg.refreshAutomatically,
      session.editorReconciliationPending,
    )) {
      this.schedule(session, delayMs, maxWaitMs);
      return;
    }
    this.markBuildRequired(session);
  }

  private scheduleEditorReconciliation(session: Session): void {
    // Direct manipulation must receive an authoritative editing model before
    // another source edit can be generated. The server reuses the current
    // display and returns a translation patch for position-only changes.
    session.editorReconciliationPending = true;
    this.schedule(session, immediateRefreshDelayMs);
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
    this.schedule(session, immediateRefreshDelayMs);
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
      if (
        session.disposed || serial !== session.serial ||
        documentVersion !== session.document.version
      ) return;
      session.editorReconciliationPending = false;
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
      if (!session.disposed && serial === session.serial) {
        session.editorReconciliationPending = false;
      }
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
        this.schedule(session, immediateRefreshDelayMs);
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

function isSsDocument(document: vscode.TextDocument): boolean {
  return document.languageId === "ss-slide" && document.uri.scheme === "file";
}

function snapshotFailureMessage(error: unknown): string {
  const detail = error instanceof Error ? error.message : String(error);
  const normalized = detail.trim();
  return normalized.length > 0
    ? `WYSIWYG build failed: ${normalized}`
    : "WYSIWYG build failed.";
}
