import * as vscode from "vscode";
import { LayoutEditResult } from "./protocol";

export function documentVersions(): ReadonlyMap<string, number> {
  return new Map(
    vscode.workspace.textDocuments.map((document) => [
      document.uri.toString(),
      document.version,
    ]),
  );
}

export function workspaceEditTargetsAreCurrent(
  value: LayoutEditResult["workspaceEdit"],
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
  value: NonNullable<LayoutEditResult["workspaceEdit"]>,
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
  const editor = await vscode.window.showTextDocument(document, {
    preview: false,
    preserveFocus: false,
  });
  editor.selection = new vscode.Selection(range.start, range.end);
  editor.revealRange(
    range,
    vscode.TextEditorRevealType.InCenterIfOutsideViewport,
  );
}

function utf16OffsetAtUtf8Byte(source: string, byteOffset: number): number {
  const bytes = Buffer.from(source, "utf8");
  const end = Math.min(bytes.length, Math.max(0, Math.trunc(byteOffset)));
  return bytes.subarray(0, end).toString("utf8").length;
}
