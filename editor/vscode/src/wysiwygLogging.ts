import * as vscode from "vscode";

export function logWysiwyg(output: vscode.OutputChannel, event: string, detail = ""): void {
  output.appendLine(`[wysiwyg] ${event}${detail ? ` ${detail}` : ""}`);
}

export function showWysiwygLog(output: vscode.OutputChannel): void {
  output.show(true);
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
