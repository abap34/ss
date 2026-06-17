import * as path from "path";
import * as vscode from "vscode";
import { PreviewSnapshot } from "./wysiwygProtocol";

export function localResourceRoots(context: vscode.ExtensionContext, document: vscode.TextDocument): vscode.Uri[] {
  return localResourceRootsForUri(context, document.uri);
}

export function localResourceRootsForUri(context: vscode.ExtensionContext, uri: vscode.Uri): vscode.Uri[] {
  const workspaceRoot = vscode.workspace.getWorkspaceFolder(uri)?.uri.fsPath ?? path.dirname(uri.fsPath);
  return uniqueUris([
    context.extensionUri,
    vscode.Uri.file(workspaceRoot),
    vscode.Uri.file(path.dirname(uri.fsPath)),
    vscode.Uri.file(path.join(workspaceRoot, ".ss-cache")),
    vscode.Uri.file(path.join(path.dirname(uri.fsPath), ".ss-cache")),
  ]);
}

export function localResourceRootsForSnapshot(
  context: vscode.ExtensionContext,
  uri: vscode.Uri,
  snapshot: PreviewSnapshot,
): vscode.Uri[] {
  const roots = localResourceRootsForUri(context, uri);
  for (const resource of snapshot.display?.resources ?? []) {
    if (!path.isAbsolute(resource.path)) {
      continue;
    }
    roots.push(vscode.Uri.file(path.dirname(resource.path)));
  }
  return uniqueUris(roots);
}

export function prepareSnapshotForWebview(
  webview: vscode.Webview,
  snapshot: PreviewSnapshot,
  allowedRoots: vscode.Uri[],
): PreviewSnapshot {
  const allowedFileRoots = allowedRoots
    .filter((root) => root.scheme === "file")
    .map((root) => path.resolve(root.fsPath));
  return {
    ...snapshot,
    display: {
      ...snapshot.display,
      resources: (snapshot.display?.resources ?? []).map((resource) => {
        const uri = vscode.Uri.file(resource.path);
        if (!isAllowedResource(uri.fsPath, allowedFileRoots)) {
          return { ...resource };
        }
        return {
          ...resource,
          uri: webview.asWebviewUri(uri).toString(),
        };
      }),
    },
  };
}

function isAllowedResource(resourcePath: string, allowedFileRoots: string[]): boolean {
  const normalized = path.resolve(resourcePath);
  return allowedFileRoots.some((base) => {
    return normalized === base || normalized.startsWith(base + path.sep);
  });
}

function uniqueUris(uris: vscode.Uri[]): vscode.Uri[] {
  const seen = new Set<string>();
  const result: vscode.Uri[] = [];
  for (const uri of uris) {
    const key = uri.toString();
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    result.push(uri);
  }
  return result;
}
