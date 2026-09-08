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
    const display = snapshot.display;
    if (display.schema !== 2 || display.assets.length === 0) return snapshot;
    const references = new Map<string, string>();
    for (const asset of display.assets) {
      if (!references.has(asset.relative_path)) {
        references.set(
          asset.relative_path,
          webview.asWebviewUri(vscode.Uri.file(asset.path)).toString(),
        );
      }
    }
    return {
      ...snapshot,
      display: {
        ...display,
        html: replaceHtmlAssets(display.html, references),
        css: replaceCssAssets(display.css, references),
      },
    };
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

function replaceHtmlAssets(html: string, references: ReadonlyMap<string, string>): string {
  return html.replace(
    /\b(src|data-pdf-src)="([^"]*)"|url\('([^']*)'\)/g,
    (match: string, attribute: string | undefined, attributePath: string | undefined, cssPath: string | undefined) => {
      const uri = references.get(attributePath ?? cssPath ?? "");
      if (uri === undefined) return match;
      return attribute === undefined ? `url('${uri}')` : `${attribute}="${uri}"`;
    },
  );
}

function replaceCssAssets(css: string, references: ReadonlyMap<string, string>): string {
  return css.replace(/url\('([^']*)'\)/g, (match: string, assetPath: string) => {
    const uri = references.get(assetPath);
    return uri === undefined ? match : `url('${uri}')`;
  });
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
