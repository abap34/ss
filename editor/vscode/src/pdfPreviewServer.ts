import * as crypto from "crypto";
import * as fs from "fs";
import * as http from "http";
import * as path from "path";
import type * as vscode from "vscode";

interface PreviewServerSession {
  pdfPath: string;
  version: number;
}

export interface PdfPreviewRefreshPayload {
  type: "refresh";
  pdfUri: string;
  version: number;
  fileName: string;
}

export class PdfPreviewServer implements vscode.Disposable {
  private readonly token = crypto.randomBytes(24).toString("hex");
  private readonly sessions = new Map<string, PreviewServerSession>();
  private server: http.Server | undefined;
  private startPromise: Promise<void> | undefined;
  private listenPort: number | undefined;

  constructor(
    private readonly extensionPath: string,
    private readonly output: vscode.OutputChannel,
  ) {}

  get port(): number {
    if (this.listenPort === undefined) {
      throw new Error("PDF preview server has not started.");
    }
    return this.listenPort;
  }

  get origin(): string {
    return `http://127.0.0.1:${this.port}`;
  }

  async register(pdfPath: string, version: number): Promise<string> {
    await this.ensureStarted();
    const id = crypto.randomUUID();
    this.sessions.set(id, { pdfPath, version });
    return id;
  }

  update(id: string, pdfPath: string, version: number): void {
    if (!this.sessions.has(id)) {
      return;
    }
    this.sessions.set(id, { pdfPath, version });
  }

  unregister(id: string): void {
    this.sessions.delete(id);
  }

  viewerUrl(id: string): string {
    const session = this.sessions.get(id);
    const version = session?.version ?? 0;
    return `${this.origin}/${this.token}/viewer/${encodeURIComponent(id)}?v=${version}`;
  }

  refreshPayload(id: string): PdfPreviewRefreshPayload | undefined {
    const session = this.sessions.get(id);
    if (!session) {
      return undefined;
    }
    return {
      type: "refresh",
      pdfUri: this.pdfUrl(id, session.version),
      version: session.version,
      fileName: path.basename(session.pdfPath),
    };
  }

  dispose(): void {
    this.sessions.clear();
    this.server?.close();
    this.server = undefined;
    this.startPromise = undefined;
    this.listenPort = undefined;
  }

  private async ensureStarted(): Promise<void> {
    if (this.server && this.listenPort !== undefined) {
      return;
    }
    if (this.startPromise) {
      return this.startPromise;
    }

    this.startPromise = new Promise<void>((resolve, reject) => {
      const server = http.createServer((request, response) => {
        void this.handle(request, response);
      });
      const fail = (error: Error): void => {
        this.output.appendLine(`[preview] PDF preview server failed: ${error.message}`);
        reject(error);
      };
      server.once("error", fail);
      server.listen(0, "127.0.0.1", () => {
        server.off("error", fail);
        server.on("error", (error) => {
          this.output.appendLine(`[preview] PDF preview server error: ${error.message}`);
        });
        const address = server.address();
        if (!address || typeof address === "string") {
          reject(new Error("PDF preview server did not receive a TCP port."));
          return;
        }
        this.server = server;
        this.listenPort = address.port;
        this.output.appendLine(`[preview] PDF preview server listening on ${this.origin}`);
        resolve();
      });
    }).finally(() => {
      this.startPromise = undefined;
    });

    return this.startPromise;
  }

  private async handle(request: http.IncomingMessage, response: http.ServerResponse): Promise<void> {
    try {
      if (request.method !== "GET" && request.method !== "HEAD") {
        sendText(response, 405, "Method not allowed");
        return;
      }

      const url = new URL(request.url ?? "/", "http://127.0.0.1");
      const segments = url.pathname.split("/").filter(Boolean).map((segment) => decodeURIComponent(segment));
      if (segments[0] !== this.token) {
        sendText(response, 404, "Not found");
        return;
      }

      if (segments[1] === "viewer" && segments[2]) {
        this.serveViewer(response, segments[2], request.method === "HEAD");
        return;
      }
      if (segments[1] === "pdf" && segments[2]) {
        await this.servePdf(response, segments[2], request.method === "HEAD");
        return;
      }
      if (segments[1] === "media") {
        await this.serveStatic(response, path.join(this.extensionPath, "media"), segments.slice(2), request.method === "HEAD");
        return;
      }
      if (segments[1] === "pdfjs") {
        await this.serveStatic(response, path.join(this.extensionPath, "out", "pdfjs"), segments.slice(2), request.method === "HEAD");
        return;
      }

      sendText(response, 404, "Not found");
    } catch (error) {
      this.output.appendLine(`[preview] PDF preview server request failed: ${String(error)}`);
      if (!response.headersSent) {
        sendText(response, 500, "Internal server error");
      } else {
        response.end();
      }
    }
  }

  private serveViewer(response: http.ServerResponse, id: string, headOnly: boolean): void {
    const session = this.sessions.get(id);
    if (!session) {
      sendText(response, 404, "Preview session not found");
      return;
    }
    const body = this.viewerHtml(id, session);
    sendBuffer(response, 200, "text/html; charset=utf-8", Buffer.from(body, "utf8"), {
      "Cache-Control": "no-store",
    }, headOnly);
  }

  private async servePdf(response: http.ServerResponse, id: string, headOnly: boolean): Promise<void> {
    const session = this.sessions.get(id);
    if (!session) {
      sendText(response, 404, "Preview session not found");
      return;
    }
    const stat = await fs.promises.stat(session.pdfPath).catch(() => undefined);
    if (!stat?.isFile()) {
      sendText(response, 404, "PDF not found");
      return;
    }
    response.writeHead(200, {
      "Content-Type": "application/pdf",
      "Content-Length": stat.size,
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    });
    if (headOnly) {
      response.end();
      return;
    }
    fs.createReadStream(session.pdfPath)
      .on("error", (error) => {
        this.output.appendLine(`[preview] PDF stream failed: ${error.message}`);
        response.destroy(error);
      })
      .pipe(response);
  }

  private async serveStatic(response: http.ServerResponse, root: string, segments: string[], headOnly: boolean): Promise<void> {
    const filePath = safeJoin(root, segments);
    if (!filePath) {
      sendText(response, 404, "Not found");
      return;
    }
    const stat = await fs.promises.stat(filePath).catch(() => undefined);
    if (!stat?.isFile()) {
      sendText(response, 404, "Not found");
      return;
    }
    sendBuffer(response, 200, mimeType(filePath), await fs.promises.readFile(filePath), {
      "Cache-Control": "public, max-age=31536000, immutable",
    }, headOnly);
  }

  private viewerHtml(id: string, session: PreviewServerSession): string {
    const base = `${this.origin}/${this.token}`;
    const fileName = path.basename(session.pdfPath);
    const csp = [
      "default-src 'none'",
      "script-src 'self'",
      "worker-src 'self' blob:",
      "style-src 'self'",
      "img-src 'self' data: blob:",
      "font-src 'self'",
      "connect-src 'self'",
    ].join("; ");

    return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="Content-Security-Policy" content="${csp}">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <link rel="stylesheet" href="${base}/media/pdfPreview.css">
  <title>ss PDF Preview</title>
</head>
<body data-pdfjs-uri="${base}/pdfjs/build/pdf.min.mjs" data-worker-uri="${base}/pdfjs/build/pdf.worker.min.mjs" data-cmap-uri="${base}/pdfjs/cmaps/" data-standard-font-uri="${base}/pdfjs/standard_fonts/" data-initial-pdf-uri="${escapeAttribute(this.pdfUrl(id, session.version))}" data-initial-file-name="${escapeAttribute(fileName)}" data-initial-version="${escapeAttribute(String(session.version))}">
  <header class="toolbar">
    <input id="pageNumber" type="number" min="1" value="1" aria-label="Page number">
    <span id="pageCount">/ 0</span>
    <span class="separator"></span>
    <button id="zoomOut" type="button" title="Zoom out" aria-label="Zoom out">-</button>
    <button id="fitWidth" type="button" title="Fit width">Fit</button>
    <button id="zoomIn" type="button" title="Zoom in" aria-label="Zoom in">+</button>
    <span id="zoomValue">100%</span>
  </header>
  <main id="scroll" class="scroll">
    <div id="pages" class="pages"></div>
  </main>
  <script src="${base}/media/pdfPreview.js"></script>
</body>
</html>`;
  }

  private pdfUrl(id: string, version: number): string {
    return `${this.origin}/${this.token}/pdf/${encodeURIComponent(id)}?v=${encodeURIComponent(String(version))}`;
  }
}

function sendText(response: http.ServerResponse, statusCode: number, text: string): void {
  sendBuffer(response, statusCode, "text/plain; charset=utf-8", Buffer.from(text, "utf8"), {
    "Cache-Control": "no-store",
  }, false);
}

function sendBuffer(
  response: http.ServerResponse,
  statusCode: number,
  contentType: string,
  body: Buffer,
  headers: Record<string, string>,
  headOnly: boolean,
): void {
  response.writeHead(statusCode, {
    ...headers,
    "Content-Type": contentType,
    "Content-Length": body.length,
    "X-Content-Type-Options": "nosniff",
  });
  response.end(headOnly ? undefined : body);
}

function safeJoin(root: string, segments: string[]): string | undefined {
  if (segments.length === 0 || segments.some((segment) => segment === "" || segment === "." || segment === ".." || path.isAbsolute(segment))) {
    return undefined;
  }
  const resolvedRoot = path.resolve(root);
  const resolvedPath = path.resolve(resolvedRoot, ...segments);
  const relative = path.relative(resolvedRoot, resolvedPath);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    return undefined;
  }
  return resolvedPath;
}

function mimeType(filePath: string): string {
  switch (path.extname(filePath).toLowerCase()) {
    case ".css":
      return "text/css; charset=utf-8";
    case ".js":
    case ".mjs":
      return "text/javascript; charset=utf-8";
    case ".svg":
      return "image/svg+xml";
    case ".png":
      return "image/png";
    case ".wasm":
      return "application/wasm";
    case ".ttf":
      return "font/ttf";
    case ".otf":
      return "font/otf";
    default:
      return "application/octet-stream";
  }
}

function escapeAttribute(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
