import * as path from "path";
import * as vscode from "vscode";
import { LanguageClient } from "vscode-languageclient/node";
import { projectSettings } from "../projectConfig";
import { EditorSnapshot, LayoutEditResult, WebviewMessage } from "./protocol";
import {
  documentVersions,
  revealSource,
  toWorkspaceEdit,
  workspaceEditTargetsAreCurrent,
} from "./source";
import { ViewResources } from "./view";

type ClientProvider = () => LanguageClient | undefined;

interface Session {
  document: vscode.TextDocument;
  panel: vscode.WebviewPanel;
  timer?: NodeJS.Timeout;
  serial: number;
  requestRunning: boolean;
  refreshPending: boolean;
  disposed: boolean;
  dependencyPaths: Set<string>;
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
      this.schedule(existing, 0);
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

  private async handleMessage(
    session: Session,
    message: WebviewMessage,
  ): Promise<void> {
    if (message.type === "ready") {
      this.schedule(session, 0);
      return;
    }
    if (message.type === "revealSource") {
      await revealSource(message.path, message.start, message.end);
      return;
    }
    if (message.type === "translate") {
      await this.applyTranslation(session, message);
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
          status: "stale",
          message: "The document changed before the edit was applied.",
        });
        this.schedule(session, 0);
        return;
      }
      if (result.status !== "ok" || !result.workspaceEdit) {
        await this.post(session, {
          type: "editResult",
          status: result.status,
          message: result.message ?? "The edit could not be applied.",
        });
        if (result.status === "stale") this.schedule(session, 0);
        return;
      }
      const edit = toWorkspaceEdit(result.workspaceEdit);
      const applied = await vscode.workspace.applyEdit(edit);
      if (!applied) {
        await this.post(session, {
          type: "editResult",
          status: "rejected",
          message: "VS Code rejected the source edit.",
        });
        return;
      }
      this.schedule(session, 0);
    } catch (error) {
      this.output.appendLine(`[editor] layout edit failed: ${String(error)}`);
      await this.post(session, {
        type: "editResult",
        status: "rejected",
        message: String(error),
      });
    }
  }

  private refreshAffected(uri: vscode.Uri, delayMs?: number): void {
    if (uri.scheme !== "file" || path.extname(uri.fsPath) !== ".ss") return;
    const changedPath = normalizePath(uri.fsPath);
    for (const session of this.sessions.values()) {
      const direct = session.document.uri.toString() === uri.toString();
      const dependency = session.dependencyPaths.has(changedPath) &&
        projectSettings(session.document.uri).wysiwyg.refreshOnDependencyChange;
      if (direct || dependency) {
        this.schedule(session, delayMs ?? this.debounceFor(session.document));
      }
    }
  }

  private refreshAll(delayMs: number): void {
    for (const session of this.sessions.values()) {
      this.schedule(session, delayMs);
    }
  }

  private schedule(session: Session, delayMs: number): void {
    if (session.disposed) return;
    // Invalidate an in-flight response as soon as an edit is observed, not
    // after the debounce timer expires.
    session.serial += 1;
    if (session.timer) clearTimeout(session.timer);
    const serial = session.serial;
    session.timer = setTimeout(() => {
      session.timer = undefined;
      void this.refresh(session, serial);
    }, delayMs);
  }

  private async refresh(session: Session, serial: number): Promise<void> {
    const client = this.clientProvider();
    if (!client || session.disposed || serial !== session.serial) return;
    if (session.requestRunning) {
      // The server handles requests serially. Coalescing here prevents obsolete
      // snapshot work from forming a queue during rapid edits.
      session.refreshPending = true;
      return;
    }
    session.requestRunning = true;
    const documentVersion = session.document.version;
    try {
      const snapshot = await client.sendRequest<EditorSnapshot>(
        "ss/editorSnapshot",
        {
          textDocument: { uri: session.document.uri.toString() },
        },
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
        snapshot: prepared,
      });
    } catch (error) {
      if (session.disposed || serial !== session.serial) return;
      this.output.appendLine(`[editor] snapshot failed: ${String(error)}`);
      await this.post(session, {
        type: "error",
        message: "WYSIWYG preview update failed.",
      });
    } finally {
      session.requestRunning = false;
      if (session.refreshPending && !session.disposed) {
        session.refreshPending = false;
        this.schedule(session, 0);
      }
    }
  }

  private debounceFor(document: vscode.TextDocument): number {
    return document.languageId === "ss-slide"
      ? projectSettings(document.uri).wysiwyg.debounceMs
      : 0;
  }

  private post(session: Session, message: unknown): Thenable<boolean> {
    if (session.disposed) return Promise.resolve(false);
    return session.panel.webview.postMessage(message);
  }
}

function normalizePath(filePath: string): string {
  return path.resolve(filePath);
}
