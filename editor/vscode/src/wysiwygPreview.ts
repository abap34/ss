import * as path from "path";
import * as vscode from "vscode";
import {
  ClientProvider,
  LayoutEditResult,
  PreviewSnapshot,
  ProtocolRange,
  ProtocolWorkspaceEdit,
  WebviewMessage,
} from "./wysiwygProtocol";
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
      const key = event.document.uri.toString();
      const panel = this.panels.get(key);
      if (event.document.languageId === "ss-slide" && panel) {
        panel.scheduleRefresh(event.document);
      }
    }));
    this.disposables.push(vscode.workspace.onDidCloseTextDocument((document) => {
      this.panels.get(document.uri.toString())?.dispose();
    }));
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
    if (!document || document.languageId !== "ss-slide" || document.uri.scheme !== "file") {
      void vscode.window.showWarningMessage("Open an .ss file to start WYSIWYG preview.");
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

    logWysiwyg(this.output, "open", `${document.uri.toString()} version=${document.version}`);
    const panel = WysiwygPreviewPanel.create(this.context, this.output, this.clientProvider, document, () => {
      this.panels.delete(key);
    });
    this.panels.set(key, panel);
    panel.refresh(document);
  }
}

class WysiwygPreviewPanel implements vscode.Disposable {
  private disposed = false;
  private snapshot?: PreviewSnapshot;
  private refreshTimer?: NodeJS.Timeout;
  private refreshSerial = 0;
  private readonly disposables: vscode.Disposable[] = [];

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

  scheduleRefresh(document: vscode.TextDocument): void {
    if (this.refreshTimer) {
      clearTimeout(this.refreshTimer);
    }
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = undefined;
      this.refresh(document);
    }, 120);
  }

  refresh(document = documentForUri(this.sourceUri)): void {
    if (this.disposed || !document) {
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
      this.log("previewSnapshot request", `serial=${serial} version=${document.version}`);
      const snapshot = await client.sendRequest<PreviewSnapshot>("ss/previewSnapshot", {
        schemaVersion: 1,
        textDocument: { uri: document.uri.toString(), version: document.version },
      });
      if (this.disposed || serial !== this.refreshSerial) {
        this.log("previewSnapshot ignored", `serial=${serial}`);
        return;
      }
      this.snapshot = snapshot;
      this.panel.title = previewTitle(document.uri);
      const displayItems = snapshot.display?.pages?.reduce((sum, page) => sum + (page.items?.length ?? 0), 0) ?? 0;
      const resources = snapshot.display?.resources?.length ?? 0;
      this.log("previewSnapshot result", `serial=${serial} snapshot=${snapshot.snapshotId} pages=${snapshot.pages.length} objects=${snapshot.objects.length} displayItems=${displayItems} resources=${resources} diagnostics=${snapshot.diagnostics.length} elapsed=${Date.now() - started}ms`);
      const prepared = this.prepareSnapshot(snapshot);
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
      return;
    }
    if (this.snapshot.documentVersion !== null && document.version !== this.snapshot.documentVersion) {
      this.log("layoutEdit skipped", `document version changed since snapshot snapshotVersion=${this.snapshot.documentVersion} currentVersion=${document.version}`);
      this.postStatus("Refreshing before layout edit");
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
        if (result.status === "stale") {
          this.scheduleRefresh(document);
        }
        return;
      }
      if (!result.workspaceEdit) {
        this.postStatus("Language server returned no edit.");
        return;
      }
      const applied = await vscode.workspace.applyEdit(toWorkspaceEdit(result.workspaceEdit));
      this.log("workspaceEdit applied", `applied=${applied}`);
      if (!applied) {
        this.postStatus("VS Code did not apply the edit.");
        return;
      }
      const nextDocument = documentForUri(this.sourceUri);
      if (nextDocument) {
        this.scheduleRefresh(nextDocument);
      }
    } catch (error) {
      this.log("layoutEdit failed", errorMessage(error));
      this.postStatus(errorMessage(error));
    }
  }

  private postStatus(message: string): void {
    void this.panel.webview.postMessage({ type: "status", message });
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

function documentForUri(uri: vscode.Uri): vscode.TextDocument | undefined {
  return vscode.workspace.textDocuments.find((document) => document.uri.toString() === uri.toString());
}

function previewTitle(uri: vscode.Uri): string {
  return `ss WYSIWYG: ${path.basename(uri.fsPath)}`;
}

function randomNonce(): string {
  return Array.from({ length: 32 }, () => Math.floor(Math.random() * 16).toString(16)).join("");
}
