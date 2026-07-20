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
    if (snapshot.display.schema !== 2) return;
    for (const asset of snapshot.display.assets) {
      roots.push(vscode.Uri.file(path.dirname(asset.path)));
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
    if (copy.display.schema !== 2) return copy;
    for (const asset of copy.display.assets) {
      const uri = webview.asWebviewUri(vscode.Uri.file(asset.path)).toString();
      copy.display.html = replaceHtmlAsset(copy.display.html, asset.relative_path, uri);
      copy.display.css = replaceAll(copy.display.css, `url('${asset.relative_path}')`, `url('${uri}')`);
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
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src ${webview.cspSource} data: blob:; style-src ${webview.cspSource} 'unsafe-inline'; script-src 'nonce-${nonce}' ${webview.cspSource}; worker-src ${webview.cspSource} blob:; connect-src ${webview.cspSource}; font-src ${webview.cspSource} data:;">
  <link rel="stylesheet" href="${style}">
</head>
<body><div id="app"></div><script type="module" nonce="${nonce}" src="${script}"></script></body>
</html>`;
  }
}

function replaceHtmlAsset(html: string, path: string, uri: string): string {
  let result = replaceAll(html, `src="${path}"`, `src="${uri}"`);
  result = replaceAll(result, `data-pdf-src="${path}"`, `data-pdf-src="${uri}"`);
  return replaceAll(result, `url('${path}')`, `url('${uri}')`);
}

function replaceAll(value: string, source: string, replacement: string): string {
  return value.split(source).join(replacement);
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
