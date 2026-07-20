import * as vscode from "vscode";
import { WorkspaceEditValue } from "./protocol";

export function documentVersions(): ReadonlyMap<string, number> {
  return new Map(
    vscode.workspace.textDocuments.map((document) => [
      document.uri.toString(),
      document.version,
    ]),
  );
}

export function workspaceEditTargetsAreCurrent(
  value: WorkspaceEditValue | undefined,
  versions: ReadonlyMap<string, number>,
): boolean {
  for (const uri of Object.keys(value?.changes ?? {})) {
    const expected = versions.get(uri);
    if (expected == null) continue;
    const current = vscode.workspace.textDocuments.find((document) =>
      document.uri.toString() === uri
    );
    if (!current || current.version !== expected) return false;
  }
  return true;
}

export function toWorkspaceEdit(
  value: WorkspaceEditValue,
): vscode.WorkspaceEdit {
  const result = new vscode.WorkspaceEdit();
  for (const [uri, edits] of Object.entries(value.changes ?? {})) {
    const target = vscode.Uri.parse(uri);
    result.set(
      target,
      edits.map((edit) =>
        vscode.TextEdit.replace(
          new vscode.Range(
            edit.range.start.line,
            edit.range.start.character,
            edit.range.end.line,
            edit.range.end.character,
          ),
          edit.newText,
        )
      ),
    );
  }
  return result;
}

export async function revealSource(
  filePath: string,
  start: number,
  end: number,
): Promise<void> {
  const document = await vscode.workspace.openTextDocument(
    vscode.Uri.file(filePath),
  );
  const source = document.getText();
  const startOffset = utf16OffsetAtUtf8Byte(source, start);
  const endOffset = utf16OffsetAtUtf8Byte(source, Math.max(start, end));
  const range = new vscode.Range(
    document.positionAt(startOffset),
    document.positionAt(endOffset),
  );
  const viewColumn = existingViewColumn(document.uri);
  const editor = await vscode.window.showTextDocument(document, {
    preview: false,
    preserveFocus: false,
    viewColumn,
  });
  editor.selection = new vscode.Selection(range.start, range.end);
  editor.revealRange(
    range,
    vscode.TextEditorRevealType.InCenterIfOutsideViewport,
  );
}

function existingViewColumn(uri: vscode.Uri): vscode.ViewColumn | undefined {
  const visible = vscode.window.visibleTextEditors.find((editor) =>
    editor.document.uri.toString() === uri.toString()
  );
  if (visible?.viewColumn != null) return visible.viewColumn;

  for (const group of vscode.window.tabGroups.all) {
    for (const tab of group.tabs) {
      if (tabContainsUri(tab.input, uri)) return group.viewColumn;
    }
  }
  return undefined;
}

function tabContainsUri(input: unknown, uri: vscode.Uri): boolean {
  const target = uri.toString();
  if (input instanceof vscode.TabInputText) {
    return input.uri.toString() === target;
  }
  if (input instanceof vscode.TabInputTextDiff) {
    return input.original.toString() === target ||
      input.modified.toString() === target;
  }
  return false;
}

function utf16OffsetAtUtf8Byte(source: string, byteOffset: number): number {
  const bytes = Buffer.from(source, "utf8");
  const end = Math.min(bytes.length, Math.max(0, Math.trunc(byteOffset)));
  return bytes.subarray(0, end).toString("utf8").length;
}
