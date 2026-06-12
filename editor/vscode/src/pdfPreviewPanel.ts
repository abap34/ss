import * as path from "path";
import * as vscode from "vscode";
import { PdfPreviewServer } from "./pdfPreviewServer";
import type { PdfPreviewRefreshPayload } from "./pdfPreviewServer";

type WebviewMessage =
  { type: "ready" } |
  { type: "log"; message?: string } |
  { type: "error"; message?: string };

interface PanelRefreshMessage {
  type: "refresh";
  payload: PdfPreviewRefreshPayload;
}

export class PdfPreviewPanel implements vscode.Disposable {
  private disposed = false;
  private readonly disposables: vscode.Disposable[] = [];

  private constructor(
    private readonly previewServer: PdfPreviewServer,
    private readonly sourceUri: vscode.Uri,
    private readonly panel: vscode.WebviewPanel,
    private readonly output: vscode.OutputChannel,
    private readonly serverSessionId: string,
    onDispose: () => void,
  ) {
    this.disposables.push(this.panel.webview.onDidReceiveMessage((message: WebviewMessage) => {
      if (!message || typeof message !== "object") {
        return;
      }
      if (message.type === "ready") {
        this.output.appendLine("[preview] PDF viewer ready");
      } else if (message.type === "log") {
        this.output.appendLine(`[preview] PDF viewer: ${message.message ?? ""}`);
      } else if (message.type === "error") {
        this.output.appendLine(`[preview] PDF viewer error: ${message.message ?? "unknown error"}`);
      }
    }));
    this.disposables.push(this.panel.onDidDispose(() => {
      this.disposeResources();
      onDispose();
    }));
    this.panel.webview.html = this.html();
  }

  static async create(
    context: vscode.ExtensionContext,
    previewServer: PdfPreviewServer,
    document: vscode.TextDocument,
    pdfPath: string,
    version: number,
    output: vscode.OutputChannel,
    onDispose: () => void,
  ): Promise<PdfPreviewPanel> {
    const serverSessionId = await previewServer.register(pdfPath, version);
    const panel = vscode.window.createWebviewPanel(
      "ssPdfPreview",
      previewTitle(document.uri),
      vscode.ViewColumn.Beside,
      {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: [],
        portMapping: [
          {
            webviewPort: previewServer.port,
            extensionHostPort: previewServer.port,
          },
        ],
      },
    );
    return new PdfPreviewPanel(previewServer, document.uri, panel, output, serverSessionId, onDispose);
  }

  show(): void {
    this.panel.reveal(vscode.ViewColumn.Beside, true);
  }

  reveal(pdfPath: string, version: number): void {
    this.refresh(pdfPath, version);
    this.panel.reveal(vscode.ViewColumn.Beside, true);
  }

  refresh(pdfPath: string, version: number): void {
    if (this.disposed) {
      return;
    }
    this.previewServer.update(this.serverSessionId, pdfPath, version);
    this.panel.title = previewTitle(this.sourceUri);
    const payload = this.previewServer.refreshPayload(this.serverSessionId);
    if (!payload) {
      return;
    }
    const message: PanelRefreshMessage = { type: "refresh", payload };
    void this.panel.webview.postMessage(message).then((delivered) => {
      if (!delivered && !this.disposed) {
        this.panel.webview.html = this.html();
      }
    });
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.panel.dispose();
    this.disposeResources();
  }

  private html(): string {
    const nonce = randomNonce();
    const frameUri = this.previewServer.viewerUrl(this.serverSessionId);
    const csp = [
      "default-src 'none'",
      `frame-src ${this.previewServer.origin}`,
      `script-src 'nonce-${nonce}'`,
      "style-src 'unsafe-inline'",
    ].join("; ");

    return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="Content-Security-Policy" content="${csp}">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ss PDF Preview</title>
  <style>
    html,
    body {
      width: 100%;
      height: 100%;
      margin: 0;
      overflow: hidden;
      background: var(--vscode-editor-background);
    }

    iframe {
      width: 100%;
      height: 100%;
      border: 0;
      display: block;
      background: var(--vscode-editor-background);
    }
  </style>
</head>
<body>
  <iframe title="ss PDF Preview" src="${escapeAttribute(frameUri)}"></iframe>
  <script nonce="${nonce}">
    const vscode = acquireVsCodeApi();
    const frameOrigin = "${this.previewServer.origin}";
    const frame = document.querySelector("iframe");
    let frameReady = false;
    let pendingRefresh = undefined;

    function sendRefresh(payload) {
      if (frameReady && frame && frame.contentWindow) {
        frame.contentWindow.postMessage(payload, frameOrigin);
      } else {
        pendingRefresh = payload;
      }
    }

    window.addEventListener("message", (event) => {
      const payload = event.data;
      if (payload && payload.type === "refresh" && payload.payload) {
        sendRefresh(payload.payload);
        return;
      }
      if (event.origin !== frameOrigin) {
        return;
      }
      if (payload && payload.source === "ss-pdf-viewer" && payload.message) {
        if (payload.message.type === "ready") {
          frameReady = true;
          if (pendingRefresh) {
            const next = pendingRefresh;
            pendingRefresh = undefined;
            sendRefresh(next);
          }
        }
        vscode.postMessage(payload.message);
      }
    });
  </script>
</body>
</html>`;
  }

  private disposeResources(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.previewServer.unregister(this.serverSessionId);
    while (this.disposables.length !== 0) {
      this.disposables.pop()?.dispose();
    }
  }
}

function previewTitle(uri: vscode.Uri): string {
  return `ss Preview: ${path.basename(uri.fsPath)}`;
}

function randomNonce(): string {
  return Array.from({ length: 32 }, () => Math.floor(Math.random() * 16).toString(16)).join("");
}

function escapeAttribute(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
