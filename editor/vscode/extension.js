const vscode = require("vscode");
const cp = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

function activate(context) {
  const emitter = new vscode.EventEmitter();
  const output = vscode.window.createOutputChannel("ss-slide");
  const refreshTimers = new Map();
  const diagnosticTimers = new Map();
  const previewTimers = new Map();
  const lastEditTimes = new Map();
  const inlayHintIdleMs = () =>
    Math.max(0, Number(vscode.workspace.getConfiguration("ss").get("inlayHints.idleMs", 300)));
  const previewSessions = new Map();
  const activeCommands = new Map();
  const diagnosticCollection = vscode.languages.createDiagnosticCollection("ss");
  const editorInfoCache = new Map();
  const editorInfoRequests = new Map();
  const editorInfoGenerations = new Map();
  const pageBlockPalette = [
    { ruler: "rgba(86, 156, 214, 0.52)", icon: "#569CD6" },
    { ruler: "rgba(220, 90, 90, 0.50)", icon: "#DC5A5A" },
    { ruler: "rgba(90, 184, 110, 0.50)", icon: "#5AB86E" },
    { ruler: "rgba(214, 168, 74, 0.52)", icon: "#D6A84A" },
  ];
  const pageBlockDecorations = pageBlockPalette.map(({ ruler, icon }) =>
    vscode.window.createTextEditorDecorationType({
      gutterIconPath: pageBlockGuideIconUri(icon),
      gutterIconSize: "contain",
      overviewRulerColor: ruler,
      overviewRulerLane: vscode.OverviewRulerLane.Left,
    }),
  );

  function pageBlockGuideIconUri(fill) {
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="8" height="20" viewBox="0 0 8 20"><rect x="2" y="0" width="3" height="20" rx="1.5" fill="${fill}"/></svg>`;
    return vscode.Uri.parse(`data:image/svg+xml;utf8,${encodeURIComponent(svg)}`);
  }

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

  function stripAnsi(text) {
    return String(text || "").replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
  }

  function clearEditorInfoCache(document) {
    if (!document) {
      return;
    }
    editorInfoCache.delete(documentKey(document));
  }

  function currentEditorInfoGeneration(document) {
    if (!document) {
      return 0;
    }
    return editorInfoGenerations.get(documentKey(document)) || 0;
  }

  function bumpEditorInfoGeneration(document) {
    if (!document) {
      return 0;
    }
    const next = currentEditorInfoGeneration(document) + 1;
    editorInfoGenerations.set(documentKey(document), next);
    return next;
  }

  function clearEditorInfoGeneration(document) {
    if (!document) {
      return;
    }
    editorInfoGenerations.delete(documentKey(document));
  }

  function clearEditorInfoRequest(document) {
    if (!document) {
      return;
    }
    stopActiveCommand(document, "dump");
    editorInfoRequests.delete(documentKey(document));
  }

  function getWordAtPosition(document, position) {
    const range = document.getWordRangeAtPosition(position, /[A-Za-z_][A-Za-z0-9_]*/g);
    return range ? document.getText(range) : "";
  }

  function getPropertyCompletionContext(document, position) {
    const line = document.lineAt(position.line).text;
    const head = line.slice(0, position.character);
    const match = /([A-Za-z_][A-Za-z0-9_]*)\.\s*([A-Za-z_][A-Za-z0-9_]*)?$/.exec(head);
    if (!match) {
      return null;
    }
    return {
      objectName: match[1],
      prefix: match[2] || "",
    };
  }

  function documentKey(document) {
    return document.uri.toString();
  }

  function commandKey(document, kind) {
    return `${documentKey(document)}::${kind}`;
  }

  function cliPath() {
    return vscode.workspace.getConfiguration("ss").get("cli.path", "ss");
  }

  function commandCwd(document) {
    const workspaceFolder = vscode.workspace.getWorkspaceFolder(document.uri);
    if (workspaceFolder) {
      return workspaceFolder.uri.fsPath;
    }
    if (document && document.uri && document.uri.scheme === "file") {
      return path.dirname(document.uri.fsPath);
    }
    return null;
  }

  function queryEditorInfo(document) {
    if (!document || document.languageId !== "ss-slide" || document.uri.scheme !== "file") {
      return Promise.resolve(null);
    }

    const key = documentKey(document);
    const generation = currentEditorInfoGeneration(document);
    const cached = editorInfoCache.get(key);
    if (cached && cached.generation === generation) {
      return Promise.resolve(cached.payload);
    }

    const existing = editorInfoRequests.get(key);
    if (existing) {
      return cached ? Promise.resolve(cached.payload) : existing;
    }

    const runRequest = new Promise((resolve) => {
      const cwd = commandCwd(document);
      if (!cwd) {
        resolve(cached ? cached.payload : null);
        return;
      }
      const command = cliPath();
      const args = ["dump", document.uri.fsPath, "--asset-base-dir", assetBaseDir(document)];
      output.appendLine(`[info] ${command} ${args.join(" ")}`);
      output.appendLine(`[info] cwd: ${cwd}`);
      stopActiveCommand(document, "dump");
      const child = cp.execFile(
        command,
        args,
        { cwd, maxBuffer: 10 * 1024 * 1024 },
        (error, stdout, stderr) => {
          const activeKey = commandKey(document, "dump");
          if (activeCommands.get(activeKey) === child) {
            activeCommands.delete(activeKey);
          }
          if (stderr && stderr.trim().length > 0) {
            output.appendLine("[info] stderr:");
            output.appendLine(stderr.trimEnd());
          }

          if (error) {
            output.appendLine(`[info] failed: ${error.message}`);
            resolve(cached ? cached.payload : null);
            return;
          }

          const payload = extractJsonPayload(stdout, stderr);
          if (!payload) {
            output.appendLine("[info] no JSON payload");
            if (!stdout || stdout.trim().length === 0) {
              output.appendLine("[info] empty stdout");
            }
            resolve(cached ? cached.payload : null);
            return;
          }

          editorInfoCache.set(key, { generation, payload });
          emitter.fire();
          resolve(payload);
        },
      );
      activeCommands.set(commandKey(document, "dump"), child);
    });

    const finalize = runRequest.finally(() => {
      editorInfoRequests.delete(key);
    });
    editorInfoRequests.set(key, finalize);
    if (cached) {
      return Promise.resolve(cached.payload);
    }
    return finalize;
  }

  function diagnosticsEnabled() {
    return vscode.workspace.getConfiguration("ss").get("diagnostics.enabled", true);
  }

  function livePreviewDebounceMs() {
    return Math.max(80, Number(vscode.workspace.getConfiguration("ss").get("livePreview.debounceMs", 350)));
  }

  function livePreviewOpenMode() {
    return vscode.workspace.getConfiguration("ss").get("livePreview.openMode", "vscode");
  }

  function stableHash(text) {
    return crypto.createHash("sha1").update(text).digest("hex").slice(0, 12);
  }

  function assetBaseDir(document) {
    return path.dirname(document.uri.fsPath);
  }

  function snapshotOutputPath(document) {
    const cwd = commandCwd(document);
    const root = cwd || os.tmpdir();
    const outDir = path.join(root, ".ss-cache", "vscode-snapshots");
    const base = path.basename(document.uri.fsPath, path.extname(document.uri.fsPath)).replace(/[^A-Za-z0-9_-]/g, "_") || "untitled";
    return {
      dir: outDir,
      path: path.join(outDir, `${base}-${stableHash(document.uri.toString())}.ss`),
    };
  }

  async function writeSnapshot(document) {
    if (!document || document.uri.scheme !== "file") {
      return null;
    }

    const { dir, path: snapshotPath } = snapshotOutputPath(document);
    await fs.promises.mkdir(dir, { recursive: true });
    await fs.promises.writeFile(snapshotPath, document.getText(), "utf8");
    return snapshotPath;
  }

  async function removeFileIfExists(filePath) {
    if (!filePath) {
      return;
    }
    try {
      await fs.promises.unlink(filePath);
    } catch (error) {
      if (error && error.code !== "ENOENT") {
        output.appendLine(`[cleanup] ${error.message}`);
      }
    }
  }

  async function cleanupLegacySnapshots(document) {
    if (!document || document.uri.scheme !== "file") {
      return;
    }
    const dir = path.dirname(document.uri.fsPath);
    const currentSnapshot = snapshotOutputPath(document).path;
    try {
      const entries = await fs.promises.readdir(dir);
      await Promise.all(entries.map(async (entry) => {
        if (!entry.startsWith(".ss-vscode-") || !entry.endsWith(".ss")) {
          return;
        }
        const filePath = path.join(dir, entry);
        if (filePath === currentSnapshot) {
          return;
        }
        await removeFileIfExists(filePath);
      }));
    } catch (error) {
      if (error && error.code !== "ENOENT") {
        output.appendLine(`[snapshot cleanup] ${error.message}`);
      }
    }
  }

  function stopActiveCommand(document, kind) {
    if (!document) {
      return;
    }
    const key = commandKey(document, kind);
    const child = activeCommands.get(key);
    if (!child) {
      return;
    }
    activeCommands.delete(key);
    try {
      child.kill();
    } catch {}
  }

  function runSs(document, args, label, kind) {
    const cwd = commandCwd(document);
    if (!cwd) {
      return Promise.resolve({
        error: new Error("ss files must be opened from a local directory"),
        stdout: "",
        stderr: "",
      });
    }

    const command = cliPath();
    output.appendLine(`[${label}] ${command} ${args.join(" ")}`);
    output.appendLine(`[${label}] cwd: ${cwd}`);
    stopActiveCommand(document, kind);
    return new Promise((resolve) => {
      const child = cp.execFile(command, args, { cwd, maxBuffer: 20 * 1024 * 1024 }, (error, stdout, stderr) => {
        const key = commandKey(document, kind);
        if (activeCommands.get(key) === child) {
          activeCommands.delete(key);
        }
        resolve({ error, stdout: stdout || "", stderr: stderr || "" });
      });
      activeCommands.set(commandKey(document, kind), child);
    });
  }

  function parseCliDiagnostics(document, stdout, stderr) {
    const diagnostics = [];
    const seen = new Set();
    const text = stripAnsi(`${stderr || ""}\n${stdout || ""}`);
    const lines = text.split(/\r?\n/);

    for (const line of lines) {
      let match = /^(ERROR|WARNING):\s+(.*):(\d+):(\d+):\s+(.*)$/.exec(line);
      let severityText;
      let lineNumber;
      let columnNumber;
      let message;

      if (match) {
        severityText = match[1];
        lineNumber = Number(match[3]);
        columnNumber = Number(match[4]);
        message = match[5];
      } else {
        match = /^(.*):(\d+):(\d+):\s+(error|warning):\s+(.*)$/i.exec(line);
        if (!match) {
          continue;
        }
        severityText = match[4].toUpperCase();
        lineNumber = Number(match[2]);
        columnNumber = Number(match[3]);
        message = match[5];
      }

      const zeroLine = Math.max(0, Math.min(document.lineCount - 1, lineNumber - 1));
      const lineText = zeroLine < document.lineCount ? document.lineAt(zeroLine).text : "";
      const zeroColumn = Math.max(0, Math.min(lineText.length, columnNumber - 1));
      const endColumn = lineText.length > zeroColumn ? lineText.length : zeroColumn;
      const range = new vscode.Range(
        new vscode.Position(zeroLine, zeroColumn),
        new vscode.Position(zeroLine, endColumn),
      );
      const diagnostic = new vscode.Diagnostic(
        range,
        message,
        severityText === "WARNING" ? vscode.DiagnosticSeverity.Warning : vscode.DiagnosticSeverity.Error,
      );
      const key = `${severityText}:${zeroLine}:${zeroColumn}:${message}`;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      diagnostic.source = "ss";
      diagnostics.push(diagnostic);
    }

    return diagnostics;
  }

  async function refreshDiagnostics(document) {
    if (!document || document.languageId !== "ss-slide" || document.uri.scheme !== "file") {
      return;
    }

    const snapshotPath = await writeSnapshot(document);
    if (!snapshotPath) {
      return;
    }

    try {
      const result = await runSs(document, ["check", snapshotPath, "--asset-base-dir", assetBaseDir(document)], "diagnostics", "diagnostics");
      const diagnostics = parseCliDiagnostics(document, result.stdout, result.stderr);
      diagnosticCollection.set(document.uri, diagnostics);
      if (result.error && diagnostics.length === 0) {
        output.appendLine(`[diagnostics] failed: ${result.error.message}`);
        if (result.stderr.trim().length > 0) output.appendLine(result.stderr.trimEnd());
        if (result.stdout.trim().length > 0) output.appendLine(result.stdout.trimEnd());
      } else {
        output.appendLine(`[diagnostics] ${diagnostics.length} diagnostics`);
      }
    } finally {}
  }

  function scheduleDiagnostics(document, delayMs) {
    if (!document || document.languageId !== "ss-slide") {
      return;
    }
    if (!diagnosticsEnabled()) {
      diagnosticCollection.delete(document.uri);
      return;
    }
    const key = documentKey(document);
    const existing = diagnosticTimers.get(key);
    if (existing) {
      clearTimeout(existing);
    }
    const timer = setTimeout(() => {
      diagnosticTimers.delete(key);
      refreshDiagnostics(document);
    }, delayMs);
    diagnosticTimers.set(key, timer);
  }

  function clearDiagnosticsTimer(document) {
    if (!document) {
      return;
    }
    const key = documentKey(document);
    const existing = diagnosticTimers.get(key);
    if (existing) {
      clearTimeout(existing);
      diagnosticTimers.delete(key);
    }
    stopActiveCommand(document, "diagnostics");
  }

  function clearPreviewSession(document) {
    if (!document) {
      return;
    }
    const key = documentKey(document);
    const existing = previewTimers.get(key);
    if (existing) {
      clearTimeout(existing);
      previewTimers.delete(key);
    }
    stopActiveCommand(document, "preview");
    previewSessions.delete(key);
  }

  function previewOutputPath(document, renderId) {
    const cwd = commandCwd(document);
    const root = cwd || os.tmpdir();
    const outDir = path.join(root, ".ss-cache", "vscode-preview");
    const base = path.basename(document.uri.fsPath, path.extname(document.uri.fsPath)).replace(/[^A-Za-z0-9_-]/g, "_") || "preview";
    const stem = `${base}-${stableHash(document.uri.toString())}`;
    return {
      dir: outDir,
      pdf: path.join(outDir, `${stem}.pdf`),
      tempPdf: path.join(outDir, `${stem}.tmp-${process.pid}-${renderId}.pdf`),
      legacyFixedPdf: path.join(outDir, `${base}-fixed.pdf`),
      stalePrefix: `${stem}-`,
      tempPrefix: `${stem}.tmp-`,
    };
  }

  async function cleanupPreviewCache(document, keepPdf) {
    const { dir, pdf, legacyFixedPdf, stalePrefix, tempPrefix } = previewOutputPath(document, 0);
    try {
      const entries = await fs.promises.readdir(dir);
      await Promise.all(entries.map(async (entry) => {
        const filePath = path.join(dir, entry);
        if (filePath === keepPdf || filePath === pdf) {
          return;
        }
        if (filePath === legacyFixedPdf) {
          await removeFileIfExists(filePath);
          return;
        }
        if ((entry.startsWith(stalePrefix) || entry.startsWith(tempPrefix)) && entry.endsWith(".pdf")) {
          await removeFileIfExists(filePath);
        }
      }));
    } catch (error) {
      if (error && error.code !== "ENOENT") {
        output.appendLine(`[preview cleanup] ${error.message}`);
      }
    }
  }

  async function revealPreviewPdf(document, pdfPath, force) {
    const key = documentKey(document);
    const session = previewSessions.get(key) || {};
    if (!force && session.opened) {
      return;
    }

    const uri = vscode.Uri.file(pdfPath);
    if (livePreviewOpenMode() === "external") {
      await vscode.env.openExternal(uri);
    } else {
      await vscode.commands.executeCommand("vscode.open", uri, {
        viewColumn: vscode.ViewColumn.Beside,
        preserveFocus: true,
        preview: false,
      });
    }
    previewSessions.set(key, { ...session, opened: true, pdfPath });
  }

  async function renderPreview(document) {
    if (!document || document.languageId !== "ss-slide" || document.uri.scheme !== "file") {
      return;
    }

    const key = documentKey(document);
    if (!previewSessions.has(key)) {
      return;
    }

    const session = previewSessions.get(key) || {};
    const renderId = (session.renderId || 0) + 1;
    previewSessions.set(key, { ...session, renderId });

    const snapshotPath = await writeSnapshot(document);
    if (!snapshotPath) {
      return;
    }

    const { dir, pdf, tempPdf } = previewOutputPath(document, renderId);
    await fs.promises.mkdir(dir, { recursive: true });

    try {
      const result = await runSs(document, ["render", snapshotPath, tempPdf, "--asset-base-dir", assetBaseDir(document)], "preview", "preview");
      const latestSession = previewSessions.get(key);
      if (!latestSession || latestSession.renderId !== renderId) {
        await removeFileIfExists(tempPdf);
        return;
      }

      const diagnostics = parseCliDiagnostics(document, result.stdout, result.stderr);
      diagnosticCollection.set(document.uri, diagnostics);
      if (result.error) {
        output.appendLine("[preview] failed:");
        if (result.stderr.trim().length > 0) output.appendLine(result.stderr.trimEnd());
        if (result.stdout.trim().length > 0) output.appendLine(result.stdout.trimEnd());
        vscode.window.showErrorMessage("ss preview failed. See the ss-slide output for details.");
        return;
      }
      await fs.promises.copyFile(tempPdf, pdf);
      await removeFileIfExists(tempPdf);
      previewSessions.set(key, { ...latestSession, pdfPath: pdf });
      await cleanupPreviewCache(document, pdf);
      await revealPreviewPdf(document, pdf, false);
    } finally {
      await removeFileIfExists(tempPdf);
    }
  }

  function schedulePreview(document, delayMs) {
    if (!document || document.languageId !== "ss-slide") {
      return;
    }
    const key = documentKey(document);
    if (!previewSessions.has(key)) {
      return;
    }
    const existing = previewTimers.get(key);
    if (existing) {
      clearTimeout(existing);
    }
    const timer = setTimeout(() => {
      previewTimers.delete(key);
      renderPreview(document);
    }, delayMs);
    previewTimers.set(key, timer);
  }

  function openLivePreview(document) {
    if (!document || document.languageId !== "ss-slide" || document.uri.scheme !== "file") {
      vscode.window.showWarningMessage("Open an .ss file to start live preview.");
      return;
    }

    const key = documentKey(document);
    const existing = previewSessions.get(key);
    if (existing) {
      if (existing.pdfPath) {
        revealPreviewPdf(document, existing.pdfPath, true);
      }
      renderPreview(document);
      return;
    }

    previewSessions.set(key, { opened: false, pdfPath: null, renderId: 0 });
    void cleanupPreviewCache(document, null);
    renderPreview(document);
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
    const ranges = pageBlockDecorations.map(() => []);
    let pageIndex = 0;

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

      const bucket = ranges[pageIndex % ranges.length];
      for (let blockLine = block.line; blockLine <= line; blockLine += 1) {
        const lineRange = document.lineAt(blockLine).range;
        bucket.push(lineRange);
      }
      pageIndex += 1;
    }

    return ranges;
  }

  function refreshBlockDecorations(editor) {
    if (!editor || editor.document.languageId !== "ss-slide") {
      return;
    }
    const rangeBuckets = computePageBlockRanges(editor.document);
    for (const decoration of pageBlockDecorations) {
      editor.setDecorations(decoration, []);
    }
    rangeBuckets.forEach((ranges, index) => {
      editor.setDecorations(pageBlockDecorations[index], ranges);
    });
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
      if (document.isDirty) {
        // Withdraw hints while the buffer differs from disk — positions
        // would drift against the source the cached dump was computed for.
        return [];
      }
      const idleMs = inlayHintIdleMs();
      const lastEdit = lastEditTimes.get(documentKey(document)) || 0;
      const sinceEdit = Date.now() - lastEdit;
      if (lastEdit && sinceEdit < idleMs) {
        // Wait until the user has been idle for a while before letting hints
        // pop back in, so a quick save-then-type doesn't flash them.
        scheduleRefresh(document, idleMs - sinceEdit);
        return [];
      }
      const generation = currentEditorInfoGeneration(document);
      const cached = editorInfoCache.get(documentKey(document));
      if (!cached || cached.generation !== generation) {
        // Kick off a fresh dump but don't render stale-generation hints.
        queryEditorInfo(document);
        return [];
      }

      return queryEditorInfo(document).then((payload) => {
        if (!payload || !payload.hints || token.isCancellationRequested) {
          return [];
        }

        const hints = [];
        for (const item of payload.hints) {
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
        return hints;
      });
    },
    provideCompletionItems(document, position, _context, token) {
      if (document.languageId !== "ss-slide" || token.isCancellationRequested) {
        return [];
      }

      const propertyContext = getPropertyCompletionContext(document, position);
      const prefix = getWordAtPosition(document, position);
      return queryEditorInfo(document).then((payload) => {
        if (!payload || token.isCancellationRequested) {
          return [];
        }

        if (propertyContext) {
          const variable = (payload.variables || []).find((item) => String(item && item.name ? item.name : "") === propertyContext.objectName);
          if (!variable || String(variable.type || "") !== "object") {
            return [];
          }
          const objectShape = String(variable.objectShape || "unknown");
          const items = [];
          for (const schema of payload.property_schemas || []) {
            const key = String(schema && schema.key ? schema.key : "");
            if (!key) {
              continue;
            }
            const allowedShapes = Array.isArray(schema.allowedShapes) ? schema.allowedShapes.map((item) => String(item)) : [];
            const shapeAllowed =
              objectShape === "unknown" ||
              objectShape === "generic" ||
              allowedShapes.length === 0 ||
              allowedShapes.includes(objectShape);
            if (!shapeAllowed) {
              continue;
            }
            if (propertyContext.prefix && !key.startsWith(propertyContext.prefix)) {
              continue;
            }
            const completion = new vscode.CompletionItem(key, vscode.CompletionItemKind.Property);
            completion.insertText = key;
            completion.filterText = key;
            const valueType = schema && schema.valueType ? String(schema.valueType) : "";
            completion.detail = valueType ? `property: ${valueType}` : "property";
            if (allowedShapes.length > 0) {
              completion.documentation = new vscode.MarkdownString(`allowed on: ${allowedShapes.join(", ")}`);
            }
            items.push(completion);
          }
          return items;
        }

        const items = [];
        for (const item of payload.functions || []) {
          const label = String(item.name || "");
          if (!label) {
            continue;
          }
          if (prefix && !label.startsWith(prefix)) {
            continue;
          }

          const completion = new vscode.CompletionItem(label, vscode.CompletionItemKind.Function);
          completion.insertText = label;
          completion.filterText = label;
          if (item.signature) {
            completion.detail = String(item.signature);
          }
          if (item.summary) {
            completion.documentation = new vscode.MarkdownString(String(item.summary));
          }
          if (item.source) {
            completion.detail = `${completion.detail ? `${completion.detail}\n` : ""}[${String(item.source)}]`;
          }
          items.push(completion);
        }

        for (const item of payload.variables || []) {
          const label = String(item && item.name ? item.name : "");
          if (!label) {
            continue;
          }
          if (label && payload.functions) {
            const sameNameAsFunction = (payload.functions || []).some((func) => String(func && func.name ? func.name : "") === label);
            if (sameNameAsFunction) {
              continue;
            }
          }
          if (prefix && !label.startsWith(prefix)) {
            continue;
          }

          const completion = new vscode.CompletionItem(label, vscode.CompletionItemKind.Variable);
          completion.insertText = label;
          completion.filterText = label;
          if (item.type) {
            completion.detail = `type: ${String(item.type)}`;
          }
          items.push(completion);
        }
        return items;
      });
    },
    provideDefinition(document, position, token) {
      if (document.languageId !== "ss-slide" || token.isCancellationRequested) {
        return null;
      }

      const target = getWordAtPosition(document, position);
      if (!target) {
        return null;
      }

      return queryEditorInfo(document).then((payload) => {
        if (!payload || !payload.definitions || token.isCancellationRequested) {
          return null;
        }

        const workspaceFolder = vscode.workspace.getWorkspaceFolder(document.uri);
        for (const item of payload.definitions) {
          if (String(item && item.name ? item.name : "") !== target) {
            continue;
          }
          const line = Math.max(0, Number(item.line || 1) - 1);
          const column = Math.max(0, Number(item.column || 1) - 1);
          const length = Math.max(1, Number(item.length || target.length || 1));
          let definitionPath = null;
          if (item.file) {
            definitionPath = String(item.file);
            if (!path.isAbsolute(definitionPath) && workspaceFolder && workspaceFolder.uri && workspaceFolder.uri.fsPath) {
              definitionPath = path.join(workspaceFolder.uri.fsPath, definitionPath);
            }
          }
          const definitionUri = definitionPath ? vscode.Uri.file(definitionPath) : document.uri;
          return new vscode.Location(
            definitionUri,
            new vscode.Range(
              new vscode.Position(line, column),
              new vscode.Position(line, column + length),
            ),
          );
        }
        return null;
      });
    },
    provideHover(document, position, token) {
      if (document.languageId !== "ss-slide" || token.isCancellationRequested) {
        return null;
      }

      const target = getWordAtPosition(document, position);
      if (!target) {
        return null;
      }

      return queryEditorInfo(document).then((payload) => {
        if (!payload || (!payload.functions && !payload.variables) || token.isCancellationRequested) {
          return null;
        }

        for (const item of payload.functions || []) {
          if (String(item.name || "") !== target) {
            continue;
          }
          const markdown = new vscode.MarkdownString();
          if (item.signature) {
            markdown.appendCodeblock(String(item.signature), "ss");
          }
          if (item.summary) {
            markdown.appendText("\n\n");
            markdown.appendText(String(item.summary));
          }
          if (item.source) {
            markdown.appendText(`\n\nsource: ${String(item.source)}`);
          }
          if (item.resultSort) {
            markdown.appendText(`\nresult: ${String(item.resultSort)}`);
          }
          return new vscode.Hover(markdown);
        }

        for (const item of payload.variables || []) {
          if (String(item && item.name ? item.name : "") !== target) {
            continue;
          }
          const markdown = new vscode.MarkdownString();
          markdown.appendCodeblock(`(${target}: ${String(item.type || "unknown")})`, "ss");
          if (item.type) {
            markdown.appendText(`\ntype: ${String(item.type)}`);
          }
          return new vscode.Hover(markdown);
        }
        return null;
      });
    },
  };

  context.subscriptions.push(
    vscode.languages.registerInlayHintsProvider({ language: "ss-slide" }, provider),
  );
  context.subscriptions.push(
    vscode.languages.registerCompletionItemProvider({ language: "ss-slide" }, provider, "."),
  );
  context.subscriptions.push(
    vscode.languages.registerHoverProvider({ language: "ss-slide" }, provider),
  );
  context.subscriptions.push(
    vscode.languages.registerDefinitionProvider({ language: "ss-slide" }, provider),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("ss.preview.live", () => {
      openLivePreview(vscode.window.activeTextEditor && vscode.window.activeTextEditor.document);
    }),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("ss.checkCurrentFile", () => {
      const document = vscode.window.activeTextEditor && vscode.window.activeTextEditor.document;
      if (document && document.languageId === "ss-slide") {
        refreshDiagnostics(document);
      }
    }),
  );

  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument((document) => {
      if (document.languageId === "ss-slide") {
        void cleanupLegacySnapshots(document);
        bumpEditorInfoGeneration(document);
        clearEditorInfoRequest(document);
        clearRefresh(document);
        clearDiagnosticsTimer(document);
        emitter.fire();
        refreshDiagnostics(document);
        schedulePreview(document, 0);
        refreshVisibleBlockDecorations();
      }
    }),
  );

  context.subscriptions.push(
    vscode.workspace.onDidChangeTextDocument((event) => {
      void cleanupLegacySnapshots(event.document);
      clearEditorInfoRequest(event.document);
      lastEditTimes.set(documentKey(event.document), Date.now());
      // Immediately ask VS Code to re-query inlay hints so the dirty buffer
      // hides them right away instead of leaving the previous frame on screen.
      emitter.fire();
      scheduleRefresh(event.document, inlayHintIdleMs());
      scheduleDiagnostics(event.document, 250);
      schedulePreview(event.document, livePreviewDebounceMs());
      refreshVisibleBlockDecorations();
    }),
  );

  context.subscriptions.push(
    vscode.workspace.onDidCloseTextDocument((document) => {
      void cleanupLegacySnapshots(document);
      clearEditorInfoCache(document);
      clearEditorInfoGeneration(document);
      clearEditorInfoRequest(document);
      clearRefresh(document);
      clearDiagnosticsTimer(document);
      clearPreviewSession(document);
      lastEditTimes.delete(documentKey(document));
      void removeFileIfExists(snapshotOutputPath(document).path);
      diagnosticCollection.delete(document.uri);
    }),
  );

  context.subscriptions.push(
    vscode.window.onDidChangeActiveTextEditor((editor) => {
      refreshBlockDecorations(editor);
      if (editor && editor.document.languageId === "ss-slide") {
        scheduleDiagnostics(editor.document, 50);
      }
    }),
  );

  context.subscriptions.push(
    vscode.window.onDidChangeVisibleTextEditors(() => {
      refreshVisibleBlockDecorations();
    }),
  );

  context.subscriptions.push(emitter);
  context.subscriptions.push(output);
  context.subscriptions.push(diagnosticCollection);
  for (const decoration of pageBlockDecorations) {
    context.subscriptions.push(decoration);
  }
  context.subscriptions.push({
    dispose() {
      for (const timer of refreshTimers.values()) {
        clearTimeout(timer);
      }
      refreshTimers.clear();
      for (const timer of diagnosticTimers.values()) {
        clearTimeout(timer);
      }
      diagnosticTimers.clear();
      for (const timer of previewTimers.values()) {
        clearTimeout(timer);
      }
      previewTimers.clear();
      for (const child of activeCommands.values()) {
        try {
          child.kill();
        } catch {}
      }
      activeCommands.clear();
      previewSessions.clear();
    },
  });

  refreshVisibleBlockDecorations();
  for (const document of vscode.workspace.textDocuments) {
    if (document.languageId === "ss-slide") {
      void cleanupLegacySnapshots(document);
      scheduleDiagnostics(document, 100);
    }
  }
}

function deactivate() {}

module.exports = {
  activate,
  deactivate,
};
