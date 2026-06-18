import * as path from "path";
import * as vscode from "vscode";
import {
  LayoutEditResult,
  PreviewSnapshot,
  ProtocolRange,
  ProtocolWorkspaceEdit,
  WebviewMessage,
} from "./wysiwygProtocol";
import {
  ClientProvider,
  DependencySession,
  documentForSession,
  documentForUri,
  ignoreGeneratedPath,
  normalizePath,
  requestProjectInfo,
  resolveProjectInfo,
  sessionDependsOn,
  updateDependencySession,
} from "./previewShared";
import { projectSettings, resolveProjectEntry } from "./projectConfig";
import { localResourceRoots, localResourceRootsForSnapshot, prepareSnapshotForWebview } from "./wysiwygResources";
import { errorMessage, logWysiwyg, showWysiwygLog } from "./wysiwygLogging";

export class WysiwygPreview implements vscode.Disposable {
  private readonly panels = new Map<string, WysiwygPreviewPanel>();
  private readonly disposables: vscode.Disposable[] = [];

  constructor(
    private readonly context: vscode.ExtensionContext,
    private readonly output: vscode.OutputChannel,
    private readonly clientProvider: ClientProvider,
  ) {
    this.disposables.push(vscode.workspace.onDidChangeTextDocument((event) => {
      if (event.document.languageId === "ss-slide" && projectSettings(event.document.uri).preview.refreshOnEdit) {
        this.scheduleAffectedDocument(event.document);
      }
    }));
    this.disposables.push(vscode.workspace.onDidSaveTextDocument((document) => {
      if (document.languageId === "ss-slide" && projectSettings(document.uri).preview.refreshOnSave) {
        this.scheduleAffectedDocument(document, 0);
      }
    }));
    this.disposables.push(vscode.workspace.onDidCloseTextDocument((document) => {
      this.panels.get(document.uri.toString())?.dispose();
    }));
    const watcher = vscode.workspace.createFileSystemWatcher("**/*.ss");
    const projectWatcher = vscode.workspace.createFileSystemWatcher("**/ss.toml");
    this.disposables.push(
      watcher,
      projectWatcher,
      watcher.onDidChange((uri) => this.scheduleAffectedUri(uri, 0)),
      watcher.onDidCreate((uri) => this.scheduleAffectedUri(uri, 0)),
      watcher.onDidDelete((uri) => this.scheduleAffectedUri(uri, 0)),
      projectWatcher.onDidChange((uri) => this.scheduleProjectConfigChange(uri, 0)),
      projectWatcher.onDidCreate((uri) => this.scheduleProjectConfigChange(uri, 0)),
      projectWatcher.onDidDelete((uri) => this.scheduleProjectConfigChange(uri, 0)),
    );
  }

  dispose(): void {
    for (const panel of this.panels.values()) {
      panel.dispose();
    }
    this.panels.clear();
    while (this.disposables.length !== 0) {
      this.disposables.pop()?.dispose();
    }
  }

  open(document: vscode.TextDocument | undefined): void {
    void this.openAsync(document);
  }

  private async openAsync(document: vscode.TextDocument | undefined): Promise<void> {
    const resolved = await this.resolvePreviewDocument(document);
    if (!resolved.document) {
      logWysiwyg(this.output, "open failed", resolved.message ?? "WYSIWYG preview could not find an entry document.");
      void vscode.window.showErrorMessage(resolved.message ?? "WYSIWYG preview could not find an entry document.");
      return;
    }
    document = resolved.document;
    if (!projectSettings(document.uri).preview.enabled) {
      void vscode.window.showWarningMessage("ss preview is disabled by ss.toml [editor.preview].enabled.");
      return;
    }

    const key = document.uri.toString();
    const existing = this.panels.get(key);
    if (existing) {
      logWysiwyg(this.output, "reveal", `${document.uri.toString()} version=${document.version}`);
      existing.show();
      existing.refresh(document);
      return;
    }

    logWysiwyg(this.output, "open", `${document.uri.toString()} version=${document.version}${resolved.projectFile ? ` project=${resolved.projectFile}` : ""}`);
    const panel = WysiwygPreviewPanel.create(this.context, this.output, this.clientProvider, document, () => {
      this.panels.delete(key);
    });
    this.panels.set(key, panel);
    panel.refresh(document);
  }

  private async resolvePreviewDocument(document: vscode.TextDocument | undefined): Promise<{ document?: vscode.TextDocument; projectFile?: string; message?: string }> {
    const project = resolveProjectEntry(document?.uri);
    const fallbackProject = project.ok ? project : (document ? resolveProjectEntry(undefined) : project);
    if (fallbackProject.ok) {
      try {
        const entryDocument = await vscode.workspace.openTextDocument(fallbackProject.entry.entryUri);
        if (entryDocument.languageId !== "ss-slide" || entryDocument.uri.scheme !== "file") {
          return { message: `[project].entry is not an .ss document: ${fallbackProject.entry.entryUri.fsPath}` };
        }
        return { document: entryDocument, projectFile: fallbackProject.entry.projectFile };
      } catch (error) {
        return { message: `Failed to open [project].entry: ${errorMessage(error)}` };
      }
    }

    if (document?.languageId === "ss-slide" && document.uri.scheme === "file") {
      return { document };
    }
    return { message: fallbackProject.message };
  }

  private scheduleAffectedDocument(document: vscode.TextDocument, delayMs?: number): void {
    this.scheduleAffectedPath(document.uri.fsPath, delayMs, document);
  }

  private scheduleAffectedUri(uri: vscode.Uri, delayMs?: number): void {
    if (uri.scheme !== "file" || ignoreGeneratedPath(uri.fsPath)) {
      return;
    }
    this.scheduleAffectedPath(uri.fsPath, delayMs);
  }

  private scheduleProjectConfigChange(uri: vscode.Uri, delayMs?: number): void {
    if (uri.scheme !== "file" || ignoreGeneratedPath(uri.fsPath)) {
      return;
    }
    for (const key of this.panels.keys()) {
      const document = documentForSession(key);
      if (document) {
        this.panels.get(key)?.scheduleRefresh(document, delayMs);
      }
    }
  }

  private scheduleAffectedPath(changedPath: string, delayMs?: number, changedDocument?: vscode.TextDocument): void {
    const normalized = normalizePath(changedPath);
    const scheduled = new Set<string>();
    if (changedDocument) {
      const directKey = changedDocument.uri.toString();
      const direct = this.panels.get(directKey);
      if (direct) {
        direct.scheduleRefresh(changedDocument, delayMs);
        scheduled.add(directKey);
      }
    }

    for (const [key, panel] of this.panels) {
      if (scheduled.has(key) || !sessionDependsOn(panel, normalized)) {
        continue;
      }
      const document = documentForSession(key);
      if (!document || !projectSettings(document.uri).preview.refreshOnDependencyChange) {
        continue;
      }
      panel.scheduleRefresh(document, delayMs);
      scheduled.add(key);
    }
  }
}

class WysiwygPreviewPanel implements vscode.Disposable, DependencySession {
  private disposed = false;
  private snapshot?: PreviewSnapshot;
  private refreshTimer?: NodeJS.Timeout;
  private refreshSerial = 0;
  private readonly disposables: vscode.Disposable[] = [];
  entryPath?: string;
  dependencyPaths?: Set<string>;

  private constructor(
    private readonly context: vscode.ExtensionContext,
    private readonly output: vscode.OutputChannel,
    private readonly clientProvider: ClientProvider,
    private readonly sourceUri: vscode.Uri,
    private readonly panel: vscode.WebviewPanel,
    onDispose: () => void,
  ) {
    this.disposables.push(this.panel.webview.onDidReceiveMessage((message: WebviewMessage) => {
      void this.handleMessage(message);
    }));
    this.disposables.push(this.panel.onDidDispose(() => {
      this.disposeResources();
      onDispose();
    }));
    this.panel.webview.html = this.html();
  }

  static create(
    context: vscode.ExtensionContext,
    output: vscode.OutputChannel,
    clientProvider: ClientProvider,
    document: vscode.TextDocument,
    onDispose: () => void,
  ): WysiwygPreviewPanel {
    const panel = vscode.window.createWebviewPanel(
      "ssWysiwygPreview",
      previewTitle(document.uri),
      vscode.ViewColumn.Beside,
      {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: localResourceRoots(context, document),
      },
    );
    return new WysiwygPreviewPanel(context, output, clientProvider, document.uri, panel, onDispose);
  }

  show(): void {
    this.panel.reveal(vscode.ViewColumn.Beside, true);
  }

  scheduleRefresh(document: vscode.TextDocument, delayMs?: number): void {
    const settings = projectSettings(document.uri).preview;
    if (!settings.enabled) {
      return;
    }
    if (this.refreshTimer) {
      clearTimeout(this.refreshTimer);
    }
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = undefined;
      this.refresh(document);
    }, delayMs ?? settings.debounceMs);
  }

  refresh(document = documentForUri(this.sourceUri)): void {
    if (this.disposed || !document) {
      return;
    }
    if (!projectSettings(document.uri).preview.enabled) {
      return;
    }
    const serial = this.refreshSerial + 1;
    this.refreshSerial = serial;
    this.log("refresh start", `serial=${serial} version=${document.version}`);
    void this.requestSnapshot(document, serial);
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.panel.dispose();
    this.disposeResources();
  }

  private async handleMessage(message: WebviewMessage): Promise<void> {
    if (!message || typeof message !== "object") {
      return;
    }
    if (message.type === "ready" || message.type === "refresh") {
      this.refresh();
      return;
    }
    if (message.type === "show-log") {
      showWysiwygLog(this.output);
      return;
    }
    if (message.type === "gesture") {
      await this.applyLayoutEdit(message);
      return;
    }
    if (message.type === "reveal-source") {
      await revealSource(message.uri, message.range);
      return;
    }
    if (message.type === "log") {
      logWysiwyg(this.output, message.message ?? "");
    }
  }

  private async requestSnapshot(document: vscode.TextDocument, serial: number): Promise<void> {
    const client = this.clientProvider();
    if (!client) {
      this.postStatus("Language server is not running.");
      return;
    }
    const started = Date.now();
    try {
      const projectInfo = resolveProjectInfo(document, await requestProjectInfo(this.clientProvider, document, (message) => {
        this.log("projectInfo failed", message);
      }));
      updateDependencySession(this, projectInfo.entryPath, projectInfo.localModules);
      if (this.disposed || serial !== this.refreshSerial) {
        this.log("previewSnapshot ignored", `serial=${serial}`);
        return;
      }
      this.log("previewSnapshot request", `serial=${serial} version=${document.version}`);
      const snapshot = await client.sendRequest<PreviewSnapshot>("ss/previewSnapshot", {
        schemaVersion: 1,
        textDocument: { uri: document.uri.toString(), version: document.version },
      });
      if (this.disposed || serial !== this.refreshSerial) {
        this.log("previewSnapshot ignored", `serial=${serial}`);
        return;
      }
      this.panel.title = previewTitle(document.uri);
      const displayItems = snapshot.display?.pages?.reduce((sum, page) => sum + (page.items?.length ?? 0), 0) ?? 0;
      const resources = snapshot.display?.resources?.length ?? 0;
      this.log("previewSnapshot result", `serial=${serial} snapshot=${snapshot.snapshotId} pages=${snapshot.pages.length} objects=${snapshot.objects.length} displayItems=${displayItems} resources=${resources} diagnostics=${snapshot.diagnostics.length} elapsed=${Date.now() - started}ms`);
      if (!isRenderableSnapshot(snapshot)) {
        const reason = snapshot.diagnostics.length > 0 ? `${snapshot.diagnostics.length} diagnostics` : "empty preview";
        this.log("previewSnapshot retained previous", `serial=${serial} reason=${reason}`);
        this.postStatus(this.snapshot ? `Preview not updated: ${reason}` : `Preview unavailable: ${reason}`);
        return;
      }
      const prepared = this.prepareSnapshot(snapshot);
      this.snapshot = snapshot;
      const resourceUris = prepared.display?.resources?.filter((resource) => resource.uri).length ?? 0;
      const relativeResources = prepared.display?.resources?.filter((resource) => !path.isAbsolute(resource.path)).length ?? 0;
      this.log("previewSnapshot resources", `resources=${resources} webviewUris=${resourceUris} missingUris=${resources - resourceUris} relativePaths=${relativeResources}`);
      void this.panel.webview.postMessage({ type: "snapshot", snapshot: prepared });
    } catch (error) {
      this.log("previewSnapshot failed", errorMessage(error));
      this.postStatus(errorMessage(error));
    }
  }

  private async applyLayoutEdit(message: Extract<WebviewMessage, { type: "gesture" }>): Promise<void> {
    const client = this.clientProvider();
    const document = documentForUri(this.sourceUri);
    if (!client || !document || !this.snapshot) {
      this.postStatus("Preview is not ready.");
      this.postLayoutEditResult(message, "rejected", "Preview is not ready.");
      return;
    }
    if (this.snapshot.documentVersion !== null && document.version !== this.snapshot.documentVersion) {
      this.log("layoutEdit skipped", `document version changed since snapshot snapshotVersion=${this.snapshot.documentVersion} currentVersion=${document.version}`);
      this.postStatus("Refreshing before layout edit");
      this.postLayoutEditResult(message, "stale", "Refreshing before layout edit");
      this.scheduleRefresh(document);
      return;
    }

    try {
      const requestVersion = this.snapshot.documentVersion ?? document.version;
      this.log("layoutEdit request", `snapshot=${message.snapshotId} version=${requestVersion} currentVersion=${document.version}`);
      const result = await client.sendRequest<LayoutEditResult>("ss/layoutEdit", {
        schemaVersion: 1,
        textDocument: { uri: document.uri.toString(), version: requestVersion },
        snapshotId: message.snapshotId,
        selection: message.selection,
        gesture: message.gesture,
      });
      this.log("layoutEdit result", `status=${result.status}${result.message ? ` message=${result.message}` : ""}`);
      if (result.status !== "ok") {
        this.postStatus(result.message ?? result.status);
        this.postLayoutEditResult(message, result.status, result.message);
        if (result.status === "stale") {
          this.scheduleRefresh(document);
        }
        return;
      }
      if (!result.workspaceEdit) {
        this.postStatus("Language server returned no edit.");
        this.postLayoutEditResult(message, "rejected", "Language server returned no edit.");
        return;
      }
      const applied = await vscode.workspace.applyEdit(toWorkspaceEdit(result.workspaceEdit));
      this.log("workspaceEdit applied", `applied=${applied}`);
      if (!applied) {
        this.postStatus("VS Code did not apply the edit.");
        this.postLayoutEditResult(message, "rejected", "VS Code did not apply the edit.");
        return;
      }
      this.postLayoutEditResult(message, "ok", undefined);
      const nextDocument = documentForUri(this.sourceUri);
      if (nextDocument) {
        this.scheduleRefresh(nextDocument);
      }
    } catch (error) {
      this.log("layoutEdit failed", errorMessage(error));
      this.postStatus(errorMessage(error));
      this.postLayoutEditResult(message, "rejected", errorMessage(error));
    }
  }

  private postStatus(message: string): void {
    void this.panel.webview.postMessage({ type: "status", message });
  }

  private postLayoutEditResult(message: Extract<WebviewMessage, { type: "gesture" }>, status: LayoutEditResult["status"], detail: string | undefined): void {
    if (message.requestId === undefined) {
      return;
    }
    void this.panel.webview.postMessage({
      type: "layout-edit-result",
      requestId: message.requestId,
      status,
      message: detail,
    });
  }

  private log(event: string, detail = ""): void {
    logWysiwyg(this.output, event, detail);
  }

  private prepareSnapshot(snapshot: PreviewSnapshot): PreviewSnapshot {
    const roots = localResourceRootsForSnapshot(this.context, this.sourceUri, snapshot);
    this.panel.webview.options = {
      ...this.panel.webview.options,
      localResourceRoots: roots,
    };
    return prepareSnapshotForWebview(this.panel.webview, snapshot, roots);
  }

  private html(): string {
    const nonce = randomNonce();
    const scriptUri = this.panel.webview.asWebviewUri(vscode.Uri.joinPath(this.context.extensionUri, "media", "wysiwygPreview.js"));
    const styleUri = this.panel.webview.asWebviewUri(vscode.Uri.joinPath(this.context.extensionUri, "media", "wysiwygPreview.css"));
    const csp = [
      "default-src 'none'",
      `script-src 'nonce-${nonce}' ${this.panel.webview.cspSource}`,
      `style-src ${this.panel.webview.cspSource}`,
      `img-src ${this.panel.webview.cspSource} data: blob:`,
      `font-src ${this.panel.webview.cspSource}`,
    ].join("; ");

    return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="Content-Security-Policy" content="${csp}">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <link rel="stylesheet" href="${styleUri}">
  <title>ss WYSIWYG Preview</title>
</head>
<body>
  <div class="toolbar">
    <button id="refresh" type="button" title="Refresh">Refresh</button>
    <button id="showLog" type="button" title="Show log">Log</button>
    <button id="zoomOut" type="button" title="Zoom out" aria-label="Zoom out">-</button>
    <button id="fitWidth" type="button" title="Fit width">Fit</button>
    <button id="zoomIn" type="button" title="Zoom in" aria-label="Zoom in">+</button>
    <span id="zoomValue">100%</span>
    <span id="editMode" class="modeBadge" aria-live="polite">Absolute</span>
    <span id="status"></span>
  </div>
  <main id="pages" class="pages"></main>
  <script nonce="${nonce}" src="${scriptUri}"></script>
</body>
</html>`;
  }

  private disposeResources(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    if (this.refreshTimer) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = undefined;
    }
    while (this.disposables.length !== 0) {
      this.disposables.pop()?.dispose();
    }
  }
}

function toWorkspaceEdit(protocolEdit: ProtocolWorkspaceEdit): vscode.WorkspaceEdit {
  const workspaceEdit = new vscode.WorkspaceEdit();
  for (const [uriText, edits] of Object.entries(protocolEdit.changes ?? {})) {
    const uri = vscode.Uri.parse(uriText);
    for (const edit of edits) {
      workspaceEdit.replace(uri, toRange(edit.range), edit.newText);
    }
  }
  return workspaceEdit;
}

function toRange(range: ProtocolRange): vscode.Range {
  return new vscode.Range(
    new vscode.Position(range.start.line, range.start.character),
    new vscode.Position(range.end.line, range.end.character),
  );
}

async function revealSource(uriText: string, range: ProtocolRange): Promise<void> {
  const uri = vscode.Uri.parse(uriText);
  const document = await vscode.workspace.openTextDocument(uri);
  const editor = await vscode.window.showTextDocument(document, vscode.ViewColumn.One);
  const selection = new vscode.Selection(toRange(range).start, toRange(range).end);
  editor.selection = selection;
  editor.revealRange(selection, vscode.TextEditorRevealType.InCenterIfOutsideViewport);
}

function isRenderableSnapshot(snapshot: PreviewSnapshot): boolean {
  return snapshot.pages.length > 0 && (snapshot.display?.pages?.length ?? 0) > 0;
}

function previewTitle(uri: vscode.Uri): string {
  return `ss WYSIWYG: ${path.basename(uri.fsPath)}`;
}

function randomNonce(): string {
  return Array.from({ length: 32 }, () => Math.floor(Math.random() * 16).toString(16)).join("");
}
