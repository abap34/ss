import * as vscode from "vscode";

export class RenderDiagnosticStore implements vscode.Disposable {
  private readonly collection = vscode.languages.createDiagnosticCollection("ss-render");
  private readonly diagnosticsByOwner = new Map<string, Map<string, vscode.Diagnostic[]>>();

  replace(owner: string, diagnosticsByPath: Map<string, vscode.Diagnostic[]>): void {
    const previous = this.diagnosticsByOwner.get(owner);
    const next = diagnosticsByUri(diagnosticsByPath);
    const affected = affectedUris(previous, next);

    if (next.size === 0) {
      this.diagnosticsByOwner.delete(owner);
    } else {
      this.diagnosticsByOwner.set(owner, next);
    }
    this.refresh(affected);
  }

  clear(owner: string): void {
    const previous = this.diagnosticsByOwner.get(owner);
    if (!previous) {
      return;
    }
    this.diagnosticsByOwner.delete(owner);
    this.refresh(new Set(previous.keys()));
  }

  dispose(): void {
    this.collection.dispose();
    this.diagnosticsByOwner.clear();
  }

  private refresh(uris: Set<string>): void {
    for (const uriText of uris) {
      const diagnostics: vscode.Diagnostic[] = [];
      const seen = new Set<string>();
      for (const ownerDiagnostics of this.diagnosticsByOwner.values()) {
        const current = ownerDiagnostics.get(uriText);
        if (current) {
          for (const diagnostic of current) {
            const key = diagnosticKey(diagnostic);
            if (!seen.has(key)) {
              seen.add(key);
              diagnostics.push(diagnostic);
            }
          }
        }
      }

      const uri = vscode.Uri.parse(uriText);
      if (diagnostics.length === 0) {
        this.collection.delete(uri);
      } else {
        this.collection.set(uri, diagnostics);
      }
    }
  }
}

function diagnosticKey(diagnostic: vscode.Diagnostic): string {
  return [
    diagnostic.range.start.line,
    diagnostic.range.start.character,
    diagnostic.range.end.line,
    diagnostic.range.end.character,
    diagnostic.severity,
    String(diagnostic.source ?? ""),
    diagnosticCodeKey(diagnostic.code),
    diagnostic.message,
  ].join("\u0000");
}

function diagnosticCodeKey(code: vscode.Diagnostic["code"]): string {
  if (code === undefined) {
    return "";
  }
  if (typeof code === "object") {
    return `${code.value}:${code.target?.toString() ?? ""}`;
  }
  return String(code);
}

function diagnosticsByUri(diagnosticsByPath: Map<string, vscode.Diagnostic[]>): Map<string, vscode.Diagnostic[]> {
  const grouped = new Map<string, vscode.Diagnostic[]>();
  for (const [filePath, diagnostics] of diagnosticsByPath) {
    grouped.set(vscode.Uri.file(filePath).toString(), diagnostics);
  }
  return grouped;
}

function affectedUris(
  previous: Map<string, vscode.Diagnostic[]> | undefined,
  next: Map<string, vscode.Diagnostic[]>,
): Set<string> {
  const affected = new Set<string>();
  for (const uri of previous?.keys() ?? []) {
    affected.add(uri);
  }
  for (const uri of next.keys()) {
    affected.add(uri);
  }
  return affected;
}
