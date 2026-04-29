const vscode = require("vscode");
const cp = require("child_process");
const path = require("path");

function activate(context) {
  const emitter = new vscode.EventEmitter();
  const output = vscode.window.createOutputChannel("ss-slide");
  const refreshTimers = new Map();
  const guideIconPath = vscode.Uri.file(path.join(__dirname, "media", "page-block-guide.svg"));
  const pageBlockDecoration = vscode.window.createTextEditorDecorationType({
    gutterIconPath: guideIconPath,
    gutterIconSize: "contain",
    overviewRulerColor: "rgba(86, 156, 214, 0.45)",
    overviewRulerLane: vscode.OverviewRulerLane.Left,
  });

  function extractJsonPayload(stdout, stderr) {
    const candidates = [stdout, stderr].filter((text) => typeof text === "string" && text.trim().length > 0);
    for (const text of candidates) {
      const trimmed = text.trim();
      try {
        return JSON.parse(trimmed);
      } catch {}

      const start = trimmed.indexOf("{");
      const end = trimmed.lastIndexOf("}");
      if (start >= 0 && end > start) {
        const slice = trimmed.slice(start, end + 1);
        try {
          return JSON.parse(slice);
        } catch {}
      }
    }
    return null;
  }

  function scheduleRefresh(document, delayMs) {
    if (!document || document.languageId !== "ss-slide") {
      return;
    }

    const key = document.uri.toString();
    const existing = refreshTimers.get(key);
    if (existing) {
      clearTimeout(existing);
    }

    const timer = setTimeout(() => {
      refreshTimers.delete(key);
      emitter.fire();
    }, delayMs);
    refreshTimers.set(key, timer);
  }

  function clearRefresh(document) {
    if (!document) {
      return;
    }
    const key = document.uri.toString();
    const existing = refreshTimers.get(key);
    if (existing) {
      clearTimeout(existing);
      refreshTimers.delete(key);
    }
  }

  function isBlockStart(lineText, keyword) {
    const trimmed = lineText.trimStart();
    return trimmed === keyword || trimmed.startsWith(`${keyword} `) || trimmed.startsWith(`${keyword}(`) || trimmed.startsWith(`${keyword}\t`) || trimmed.startsWith(`${keyword}"`);
  }

  function isBlockEnd(lineText) {
    return /^\s*end\s*(?:;;.*)?$/.test(lineText);
  }

  function computePageBlockRanges(document) {
    const stack = [];
    const ranges = [];

    for (let line = 0; line < document.lineCount; line += 1) {
      const text = document.lineAt(line).text;
      if (isBlockStart(text, "page")) {
        stack.push({ kind: "page", line });
        continue;
      }
      if (isBlockStart(text, "fn")) {
        stack.push({ kind: "fn", line });
        continue;
      }
      if (!isBlockEnd(text) || stack.length === 0) {
        continue;
      }

      const block = stack.pop();
      if (block.kind !== "page") {
        continue;
      }

      for (let blockLine = block.line; blockLine <= line; blockLine += 1) {
        const lineRange = document.lineAt(blockLine).range;
        ranges.push(lineRange);
      }
    }

    return ranges;
  }

  function refreshBlockDecorations(editor) {
    if (!editor || editor.document.languageId !== "ss-slide") {
      return;
    }
    const ranges = computePageBlockRanges(editor.document);
    editor.setDecorations(pageBlockDecoration, ranges);
  }

  function refreshVisibleBlockDecorations() {
    for (const editor of vscode.window.visibleTextEditors) {
      refreshBlockDecorations(editor);
    }
  }

  const provider = {
    onDidChangeInlayHints: emitter.event,
    provideInlayHints(document, range, token) {
      if (document.languageId !== "ss-slide") {
        return [];
      }

      const workspaceFolder = vscode.workspace.getWorkspaceFolder(document.uri);
      if (!workspaceFolder) {
        return [];
      }

      return new Promise((resolve) => {
        const cwd = workspaceFolder.uri.fsPath;
        const args = ["build", "run", "--", "editor-info-file", document.uri.fsPath];
        output.appendLine(`[hint] zig ${args.join(" ")}`);
        output.appendLine(`[hint] cwd: ${cwd}`);
        cp.execFile(
          "zig",
          args,
          { cwd, maxBuffer: 10 * 1024 * 1024 },
          (error, stdout, stderr) => {
            if (token.isCancellationRequested) {
              resolve([]);
              return;
            }

            if (stderr && stderr.trim().length > 0) {
              output.appendLine("[hint] stderr:");
              output.appendLine(stderr.trimEnd());
            }

            if (error) {
              output.appendLine(`[hint] failed: ${error.message}`);
              resolve([]);
              return;
            }

            try {
              const payload = extractJsonPayload(stdout, stderr);
              if (!payload) {
                output.appendLine("[hint] no JSON payload");
                if (!stdout || stdout.trim().length === 0) {
                  output.appendLine("[hint] empty stdout");
                }
                resolve([]);
                return;
              }
              const hints = [];
              for (const item of payload.hints || []) {
                const pos = new vscode.Position(
                  Math.max(0, Number(item.line || 1) - 1),
                  Math.max(0, Number(item.column || 1) - 1),
                );
                if (!range.contains(pos)) {
                  continue;
                }
                const hint = new vscode.InlayHint(pos, String(item.label || ""));
                hint.paddingLeft = true;
                hint.paddingRight = false;
                hint.kind =
                  item.kind === "parameter_names"
                    ? vscode.InlayHintKind.Parameter
                    : vscode.InlayHintKind.Type;
                hints.push(hint);
              }
              output.appendLine(`[hint] ok: ${hints.length} hints`);
              resolve(hints);
            } catch (parseError) {
              output.appendLine("[hint] invalid JSON:");
              if (stdout && stdout.trim().length > 0) {
                output.appendLine(stdout.trimEnd());
              }
              if (stderr && stderr.trim().length > 0) {
                output.appendLine(stderr.trimEnd());
              }
              output.appendLine(`[hint] parse error: ${parseError.message}`);
              resolve([]);
            }
          },
        );
      });
    },
  };

  context.subscriptions.push(
    vscode.languages.registerInlayHintsProvider({ language: "ss-slide" }, provider),
  );

  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument((document) => {
      if (document.languageId === "ss-slide") {
        clearRefresh(document);
        emitter.fire();
        refreshVisibleBlockDecorations();
      }
    }),
  );

  context.subscriptions.push(
    vscode.workspace.onDidChangeTextDocument((event) => {
      scheduleRefresh(event.document, 400);
      refreshVisibleBlockDecorations();
    }),
  );

  context.subscriptions.push(
    vscode.workspace.onDidCloseTextDocument((document) => {
      clearRefresh(document);
    }),
  );

  context.subscriptions.push(
    vscode.window.onDidChangeActiveTextEditor((editor) => {
      refreshBlockDecorations(editor);
    }),
  );

  context.subscriptions.push(
    vscode.window.onDidChangeVisibleTextEditors(() => {
      refreshVisibleBlockDecorations();
    }),
  );

  context.subscriptions.push(emitter);
  context.subscriptions.push(output);
  context.subscriptions.push(pageBlockDecoration);
  context.subscriptions.push({
    dispose() {
      for (const timer of refreshTimers.values()) {
        clearTimeout(timer);
      }
      refreshTimers.clear();
    },
  });

  refreshVisibleBlockDecorations();
}

function deactivate() {}

module.exports = {
  activate,
  deactivate,
};
