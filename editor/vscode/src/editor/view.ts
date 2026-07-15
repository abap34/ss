import * as path from "path";
import * as vscode from "vscode";
import { EditorSnapshot } from "./protocol";

export class ViewResources {
  constructor(private readonly extensionUri: vscode.Uri) {}

  roots(document: vscode.TextDocument): vscode.Uri[] {
    const roots = [
      this.extensionUri,
      vscode.Uri.file(path.dirname(document.uri.fsPath)),
    ];
    const workspace = vscode.workspace.getWorkspaceFolder(document.uri);
    if (workspace) roots.push(workspace.uri);
    return roots;
  }

  updateRoots(
    webview: vscode.Webview,
    document: vscode.TextDocument,
    snapshot: EditorSnapshot,
  ): void {
    const roots = this.roots(document);
    for (const page of snapshot.display.pages) {
      for (const item of page.items) {
        if (!isResource(item)) continue;
        roots.push(vscode.Uri.file(path.dirname(item.path)));
      }
    }
    const unique = new Map(roots.map((root) => [root.toString(), root]));
    webview.options = {
      enableScripts: true,
      localResourceRoots: [...unique.values()],
    };
  }

  prepareSnapshot(
    webview: vscode.Webview,
    snapshot: EditorSnapshot,
  ): EditorSnapshot {
    const copy = structuredClone(snapshot);
    for (const page of copy.display.pages) {
      for (const item of page.items) {
        if (!isResource(item)) continue;
        item.uri = webview.asWebviewUri(vscode.Uri.file(item.path)).toString();
      }
    }
    return copy;
  }

  html(webview: vscode.Webview): string {
    const nonce = randomNonce();
    const script = webview.asWebviewUri(
      vscode.Uri.joinPath(this.extensionUri, "media", "editor", "main.js"),
    );
    const style = webview.asWebviewUri(
      vscode.Uri.joinPath(this.extensionUri, "media", "editor", "main.css"),
    );
    return `<!doctype html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src ${webview.cspSource} data: blob:; object-src ${webview.cspSource} data: blob:; style-src ${webview.cspSource}; script-src 'nonce-${nonce}' ${webview.cspSource}; font-src ${webview.cspSource} data:;">
  <link rel="stylesheet" href="${style}">
</head>
<body><div id="app"></div><script type="module" nonce="${nonce}" src="${script}"></script></body>
</html>`;
  }
}

function isResource(
  item: EditorSnapshot["display"]["pages"][number]["items"][number],
): item is Extract<typeof item, { type: "raster" | "svg" | "math" | "pdf_page" }> {
  return item.type === "raster" || item.type === "svg" ||
    item.type === "math" || item.type === "pdf_page";
}

function randomNonce(): string {
  const alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  let result = "";
  for (let index = 0; index < 32; index += 1) {
    result += alphabet[Math.floor(Math.random() * alphabet.length)];
  }
  return result;
}
