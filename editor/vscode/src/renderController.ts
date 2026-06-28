import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";
import { LanguageClient } from "vscode-languageclient/node";
import { PdfPreviewPanel } from "./pdfPreviewPanel";
import { PdfPreviewServer } from "./pdfPreviewServer";
import { projectSettings } from "./projectConfig";
import { RenderDiagnosticStore } from "./renderDiagnosticStore";
import { parseSsDiagnosticsJson } from "./renderDiagnostics";

type ClientProvider = () => LanguageClient | undefined;

interface ProjectInfo {
  entryPath?: string;
  assetBaseDir?: string;
  localModules?: string[];
}

interface RenderSession {
  wantsPreview: boolean;
  externalOpened: boolean;
  rendering: boolean;
  queuedDocument?: vscode.TextDocument;
  pdfPath?: string;
  renderId: number;
  timer?: NodeJS.Timeout;
  entryPath?: string;
  dependencyPaths?: Set<string>;
  panel?: PdfPreviewPanel;
}

export class RenderController implements vscode.Disposable {
  private readonly sessions = new Map<string, RenderSession>();
  private readonly disposables: vscode.Disposable[] = [];
  private readonly previewServer: PdfPreviewServer;
  private readonly renderDiagnostics: RenderDiagnosticStore;

  constructor(
    private readonly context: vscode.ExtensionContext,
    private readonly output: vscode.OutputChannel,
    private readonly clientProvider: ClientProvider,
  ) {
    this.previewServer = new PdfPreviewServer(context.extensionPath, output);
    this.renderDiagnostics = new RenderDiagnosticStore();
    this.disposables.push(this.renderDiagnostics);
    this.disposables.push(vscode.workspace.onDidOpenTextDocument((document) => {
      this.scheduleDocumentRender(document, 0);
    }));
    this.disposables.push(vscode.workspace.onDidSaveTextDocument((document) => {
      if (document.languageId === "ss-slide" && projectSettings(document.uri).preview.refreshOnSave) {
        this.scheduleAffectedDocument(document, 0);
      }
    }));
    this.disposables.push(vscode.workspace.onDidCloseTextDocument((document) => {
      this.stopSession(document.uri.toString(), true);
    }));
    const watcher = vscode.workspace.createFileSystemWatcher("**/*.ss");
    const projectWatcher = vscode.workspace.createFileSystemWatcher("**/ss.toml");
    this.disposables.push(
      watcher,
      projectWatcher,
      watcher.onDidChange((uri) => this.scheduleAffectedUri(uri, 0)),
      watcher.onDidCreate((uri) => this.scheduleAffectedUri(uri, 0)),
      watcher.onDidDelete((uri) => this.scheduleAffectedUri(uri, 0)),
      projectWatcher.onDidChange((uri) => this.scheduleProjectConfigChange(uri, 0)),
      projectWatcher.onDidCreate((uri) => this.scheduleProjectConfigChange(uri, 0)),
      projectWatcher.onDidDelete((uri) => this.scheduleProjectConfigChange(uri, 0)),
    );
  }

  dispose(): void {
    for (const key of [...this.sessions.keys()]) {
      this.stopSession(key, true);
    }
    for (const disposable of this.disposables) {
      disposable.dispose();
    }
    this.previewServer.dispose();
  }

  openPreview(document: vscode.TextDocument | undefined): void {
    if (!document || document.languageId !== "ss-slide" || document.uri.scheme !== "file") {
      void vscode.window.showWarningMessage("Open an .ss file to start live preview.");
      return;
    }
    if (!projectSettings(document.uri).preview.enabled) {
      void vscode.window.showWarningMessage("ss live preview is disabled by ss.toml [editor.preview].enabled.");
      return;
    }
    const key = document.uri.toString();
    const session = this.ensureSession(key);
    session.wantsPreview = true;
    if (session.pdfPath) {
      void this.present(document, session, session.pdfPath, true);
    }
    this.schedule(document, 0);
  }

  refreshOpenDocuments(delayMs?: number): void {
    for (const document of vscode.workspace.textDocuments) {
      this.scheduleDocumentRender(document, delayMs);
    }
  }

  private schedule(document: vscode.TextDocument, delayMs?: number): void {
    const key = document.uri.toString();
    const session = this.sessions.get(key);
    if (!session) {
      return;
    }
    if (session.timer) {
      clearTimeout(session.timer);
      session.timer = undefined;
    }
    const settings = projectSettings(document.uri).preview;
    if (!settings.enabled) {
      session.renderId += 1;
      session.queuedDocument = undefined;
      this.renderDiagnostics.clear(key);
      return;
    }
    const configuredDelay = settings.debounceMs;
    session.timer = setTimeout(() => {
      session.timer = undefined;
      void this.requestRender(document);
    }, delayMs ?? configuredDelay);
  }

  private scheduleAffectedDocument(document: vscode.TextDocument, delayMs?: number): void {
    if (document.uri.scheme !== "file" || ignoreGeneratedPath(document.uri.fsPath)) {
      return;
    }
    this.scheduleAffectedPath(document.uri.fsPath, delayMs, document);
  }

  private scheduleDocumentRender(document: vscode.TextDocument, delayMs?: number): void {
    if (document.languageId !== "ss-slide" || document.uri.scheme !== "file" || ignoreGeneratedPath(document.uri.fsPath)) {
      return;
    }
    this.ensureSession(document.uri.toString());
    this.schedule(document, delayMs);
  }

  private scheduleAffectedUri(uri: vscode.Uri, delayMs?: number): void {
    if (uri.scheme !== "file" || ignoreGeneratedPath(uri.fsPath)) {
      return;
    }
    this.scheduleAffectedPath(uri.fsPath, delayMs);
  }

  private scheduleProjectConfigChange(uri: vscode.Uri, delayMs?: number): void {
    if (uri.scheme !== "file" || ignoreGeneratedPath(uri.fsPath)) {
      return;
    }
    this.scheduleAll(delayMs);
  }

  private scheduleAll(delayMs?: number): void {
    for (const key of this.sessions.keys()) {
      const document = documentForSession(key);
      if (document) {
        this.schedule(document, delayMs);
      }
    }
  }

  private scheduleAffectedPath(changedPath: string, delayMs?: number, changedDocument?: vscode.TextDocument): void {
    const normalized = normalizePath(changedPath);
    const scheduled = new Set<string>();
    if (changedDocument) {
      const directKey = changedDocument.uri.toString();
      this.ensureSession(directKey);
      this.schedule(changedDocument, delayMs);
      scheduled.add(directKey);
    }

    for (const [key, session] of this.sessions) {
      if (scheduled.has(key) || !sessionDependsOn(session, normalized)) {
        continue;
      }
      const document = documentForSession(key);
      if (!document) {
        continue;
      }
      if (!projectSettings(document.uri).preview.refreshOnDependencyChange) {
        continue;
      }
      this.schedule(document, delayMs);
      scheduled.add(key);
    }
  }

  private async requestRender(document: vscode.TextDocument): Promise<void> {
    const key = document.uri.toString();
    const session = this.sessions.get(key);
    if (!session) {
      return;
    }
    if (session.rendering) {
      session.renderId += 1;
      session.queuedDocument = document;
      return;
    }

    session.rendering = true;
    session.queuedDocument = undefined;
    try {
      let nextDocument: vscode.TextDocument | undefined = document;
      while (nextDocument && this.sessions.get(key) === session) {
        const currentDocument = nextDocument;
        nextDocument = undefined;
        session.queuedDocument = undefined;
        await this.render(currentDocument);
        nextDocument = session.queuedDocument;
      }
    } finally {
      if (this.sessions.get(key) === session) {
        const queued = session.queuedDocument;
        session.rendering = false;
        session.queuedDocument = undefined;
        if (queued) {
          void this.requestRender(queued);
        }
      }
    }
  }

  private async render(document: vscode.TextDocument): Promise<void> {
    const key = document.uri.toString();
    const session = this.sessions.get(key);
    if (!session) {
      return;
    }
    const renderId = session.renderId + 1;
    session.renderId = renderId;

    const projectInfo = await this.projectInfo(document);
    const entryPath = projectInfo.entryPath ?? document.uri.fsPath;
    const assetBaseDir = projectInfo.assetBaseDir ?? path.dirname(entryPath);
    const localModules = projectInfo.localModules ?? [];
    session.entryPath = normalizePath(entryPath);
    session.dependencyPaths = new Set(unique([entryPath, ...localModules]).map(normalizePath));
    if (!this.renderIsCurrent(key, renderId)) {
      return;
    }
    const paths = this.previewPaths(document, renderId);
    await fs.promises.mkdir(paths.dir, { recursive: true });

    const settings = projectSettings(document.uri).preview;
    const command = vscode.workspace.getConfiguration("ss").get<string>("cli.path", "ss");
    const entryUri = vscode.Uri.file(entryPath);
    const workspaceRoot = vscode.workspace.getWorkspaceFolder(entryUri)?.uri.fsPath ?? path.dirname(entryPath);
    const args = [
      "render",
      entryPath,
      paths.tempPdf,
      "--asset-base-dir",
      assetBaseDir,
      "--cache-id",
      entryPath,
      "--diagnostics-json",
      paths.diagnosticsJson,
      ...settings.extraRenderArgs,
    ];
    this.output.appendLine(`[render] ${command} ${args.join(" ")}`);
    const result = await run(command, args, workspaceRoot, settings.renderTimeoutMs);
    const current = this.sessions.get(key);
    if (!current || current.renderId !== renderId) {
      await removeIfExists(paths.tempPdf);
      await removeIfExists(paths.diagnosticsJson);
      return;
    }
    const diagnostics = await this.readRenderDiagnostics(paths.diagnosticsJson);
    if (result.code !== 0) {
      const output = renderOutput(result);
      this.output.appendLine(output || `[render] failed with exit code ${result.code}`);
      if (diagnostics.size === 0) {
        this.clearRenderDiagnostics(key);
      } else {
        this.renderDiagnostics.replace(key, diagnostics);
      }
      await removeIfExists(paths.tempPdf);
      await removeIfExists(paths.diagnosticsJson);
      return;
    }
    if (diagnostics.size === 0) {
      this.clearRenderDiagnostics(key);
    } else {
      this.renderDiagnostics.replace(key, diagnostics);
    }
    if (!sessionHasPreviewConsumer(current)) {
      current.pdfPath = undefined;
      await removeIfExists(paths.tempPdf);
      await removeIfExists(paths.diagnosticsJson);
      return;
    }
    await fs.promises.copyFile(paths.tempPdf, paths.pdf);
    await removeIfExists(paths.tempPdf);
    await removeIfExists(paths.diagnosticsJson);
    current.pdfPath = paths.pdf;
    await this.cleanupPreviewCache(paths.dir, paths.pdf, paths.stem);
    await this.present(document, current, paths.pdf, false);
  }

  private renderIsCurrent(key: string, renderId: number): boolean {
    const current = this.sessions.get(key);
    return Boolean(current && current.renderId === renderId);
  }

  private async projectInfo(document: vscode.TextDocument): Promise<ProjectInfo> {
    const client = this.clientProvider();
    if (!client) {
      return {};
    }
    try {
      return await client.sendRequest<ProjectInfo>("ss/projectInfo", {
        textDocument: { uri: document.uri.toString() },
      });
    } catch (error) {
      this.output.appendLine(`[render] projectInfo failed: ${String(error)}`);
      return {};
    }
  }

  private async readRenderDiagnostics(diagnosticsJsonPath: string): Promise<Map<string, vscode.Diagnostic[]>> {
    const source = await fs.promises.readFile(diagnosticsJsonPath, "utf8").catch(() => undefined);
    if (source === undefined) {
      return new Map();
    }
    try {
      return structuredRenderDiagnostics(source, {});
    } catch (error) {
      this.output.appendLine(`[render] failed to read diagnostics JSON: ${String(error)}`);
      return new Map();
    }
  }

  private clearRenderDiagnostics(owner: string): void {
    this.renderDiagnostics.clear(owner);
  }

  private previewPaths(document: vscode.TextDocument, renderId: number): { dir: string; stem: string; pdf: string; tempPdf: string; diagnosticsJson: string } {
    const workspaceRoot = vscode.workspace.getWorkspaceFolder(document.uri)?.uri.fsPath ?? path.dirname(document.uri.fsPath);
    const dir = resolveWorkspacePath(workspaceRoot, projectSettings(document.uri).preview.outputDirectory);
    const base = path.basename(document.uri.fsPath, path.extname(document.uri.fsPath)).replace(/[^A-Za-z0-9_-]/g, "_") || "preview";
    const stem = `${base}-${stableHash(document.uri.toString())}`;
    return {
      dir,
      stem,
      pdf: path.join(dir, `${stem}.pdf`),
      tempPdf: path.join(dir, `${stem}.tmp-${process.pid}-${renderId}.pdf`),
      diagnosticsJson: path.join(dir, `${stem}.tmp-${process.pid}-${renderId}.diagnostics.json`),
    };
  }

  private async present(document: vscode.TextDocument, session: RenderSession, pdfPath: string, forceReveal: boolean): Promise<void> {
    const key = document.uri.toString();
    if (this.sessions.get(key) !== session) {
      return;
    }
    const settings = projectSettings(document.uri).preview;
    if (settings.openMode === "external") {
      this.disposePanel(session);
      if (forceReveal || (!session.externalOpened && (session.wantsPreview || settings.revealAfterRender))) {
        await vscode.env.openExternal(vscode.Uri.file(pdfPath));
        session.externalOpened = true;
      }
      return;
    }

    session.externalOpened = false;
    if (!session.panel) {
      if (!forceReveal && !session.wantsPreview && !settings.revealAfterRender) {
        return;
      }
      let panel: PdfPreviewPanel;
      panel = await PdfPreviewPanel.create(this.context, this.previewServer, document, pdfPath, session.renderId, this.output, () => {
        this.detachPreviewPanel(key, panel);
      });
      if (this.sessions.get(key) !== session) {
        panel.dispose();
        return;
      }
      session.panel = panel;
      session.panel.show();
      return;
    }

    if (forceReveal) {
      session.panel.reveal(pdfPath, session.renderId);
    } else {
      session.panel.refresh(pdfPath, session.renderId);
    }
  }

  private ensureSession(key: string): RenderSession {
    const current = this.sessions.get(key);
    if (current) {
      return current;
    }
    const session: RenderSession = {
      wantsPreview: false,
      externalOpened: false,
      rendering: false,
      renderId: 0,
    };
    this.sessions.set(key, session);
    return session;
  }

  private stopSession(key: string, disposePanel: boolean): void {
    const session = this.sessions.get(key);
    if (!session) {
      return;
    }
    if (session.timer) {
      clearTimeout(session.timer);
      session.timer = undefined;
    }
    if (disposePanel) {
      this.disposePanel(session);
    } else {
      session.panel = undefined;
    }
    this.clearRenderDiagnostics(key);
    this.sessions.delete(key);
  }

  private detachPreviewPanel(key: string, panel: PdfPreviewPanel): void {
    const session = this.sessions.get(key);
    if (!session || session.panel !== panel) {
      return;
    }
    session.panel = undefined;
    session.wantsPreview = false;
    session.pdfPath = undefined;
  }

  private disposePanel(session: RenderSession): void {
    const panel = session.panel;
    if (!panel) {
      return;
    }
    session.panel = undefined;
    panel.dispose();
  }

  private async cleanupPreviewCache(dir: string, keepPdf: string, stem: string): Promise<void> {
    const entries = await fs.promises.readdir(dir).catch(() => []);
    await Promise.all(entries.map(async (entry) => {
      const file = path.join(dir, entry);
      if (file === keepPdf) {
        return;
      }
      if ((entry.startsWith(`${stem}.tmp-`) || entry.startsWith(`${stem}-`)) && entry.endsWith(".pdf")) {
        await removeIfExists(file);
      }
    }));
  }
}

function stableHash(text: string): string {
  return crypto.createHash("sha1").update(text).digest("hex").slice(0, 12);
}

function normalizePath(filePath: string): string {
  return path.resolve(filePath);
}

function renderOutput(result: { stdout: string; stderr: string }): string {
  return [result.stderr.trimEnd(), result.stdout.trimEnd()].filter((part) => part.length > 0).join("\n");
}

function structuredRenderDiagnostics(source: string, pathMap: Record<string, string>): Map<string, vscode.Diagnostic[]> {
  const grouped = new Map<string, vscode.Diagnostic[]>();
  for (const parsed of parseSsDiagnosticsJson(source, pathMap)) {
    const diagnostic = new vscode.Diagnostic(
      new vscode.Range(parsed.line, parsed.character, parsed.endLine, parsed.endCharacter),
      parsed.message,
      parsed.severity === "warning" ? vscode.DiagnosticSeverity.Warning : vscode.DiagnosticSeverity.Error,
    );
    diagnostic.source = "ss render";
    diagnostic.code = parsed.code;
    const items = grouped.get(parsed.filePath) ?? [];
    items.push(diagnostic);
    grouped.set(parsed.filePath, items);
  }
  return grouped;
}

function sessionHasPreviewConsumer(session: RenderSession): boolean {
  return session.wantsPreview || session.panel !== undefined || session.externalOpened;
}

function sessionDependsOn(session: RenderSession, changedPath: string): boolean {
  if (session.entryPath === changedPath) {
    return true;
  }
  return session.dependencyPaths?.has(changedPath) ?? false;
}

function ignoreGeneratedPath(filePath: string): boolean {
  return path.resolve(filePath).split(path.sep).some((part) =>
    part === ".ss-cache" ||
    part === ".git" ||
    part === ".zig-cache" ||
    part === "node_modules" ||
    part === "zig-out"
  );
}

function documentForSession(key: string): vscode.TextDocument | undefined {
  return vscode.workspace.textDocuments.find((document) => document.uri.toString() === key);
}

function unique(paths: string[]): string[] {
  return [...new Set(paths.map((item) => path.resolve(item)))];
}

function resolveWorkspacePath(workspaceRoot: string, configuredPath: string): string {
  return path.isAbsolute(configuredPath) ? configuredPath : path.join(workspaceRoot, configuredPath);
}

function run(command: string, args: string[], cwd: string, timeoutMs: number): Promise<{ code: number | null; stdout: string; stderr: string }> {
  const childProcess = require("child_process") as typeof import("child_process");
  return new Promise((resolve) => {
    const child = childProcess.spawn(command, args, { cwd });
    let stdout = "";
    let stderr = "";
    let finished = false;
    let timedOut = false;
    const timer = timeoutMs > 0 ? setTimeout(() => {
      timedOut = true;
      child.kill();
    }, timeoutMs) : undefined;
    const finish = (code: number | null, nextStderr: string): void => {
      if (finished) {
        return;
      }
      finished = true;
      if (timer) {
        clearTimeout(timer);
      }
      resolve({ code, stdout, stderr: nextStderr });
    };
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => { stdout += chunk; });
    child.stderr.on("data", (chunk: string) => { stderr += chunk; });
    child.on("error", (error: Error) => finish(-1, error.message));
    child.on("close", (code: number | null) => finish(timedOut ? -1 : code, timedOut ? `[render] timed out after ${timeoutMs}ms` : stderr));
  });
}

async function removeIfExists(filePath: string): Promise<void> {
  await fs.promises.unlink(filePath).catch((error: NodeJS.ErrnoException) => {
    if (error.code !== "ENOENT") {
      throw error;
    }
  });
}
