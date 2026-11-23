import type * as vscode from "vscode";

export async function provideCurrentCodeLenses(
  document: vscode.TextDocument,
  token: vscode.CancellationToken,
  next: (document: vscode.TextDocument, token: vscode.CancellationToken) => vscode.ProviderResult<vscode.CodeLens[]>,
): Promise<vscode.CodeLens[] | null | undefined> {
  while (!token.isCancellationRequested) {
    const version = document.version;
    const lenses = await next(document, token);
    if (token.isCancellationRequested) return null;
    // Keep the provider request pending while VS Code tracks the existing
    // ranges through edits. Only publish positions for the current document.
    if (document.version === version) return lenses;
  }
  return null;
}
