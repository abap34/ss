import * as crypto from "crypto";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as vscode from "vscode";
import { PdfPreviewPanel } from "./pdfPreviewPanel";
import { PdfPreviewServer } from "./pdfPreviewServer";
import {
  ClientProvider,
  DependencySession,
  documentForSession,
  ignoreGeneratedPath,
  normalizePath,
  requestProjectInfo,
  resolveProjectInfo,
  sessionDependsOn,
  uniquePaths,
  updateDependencySession,
} from "./previewShared";
import { projectSettings } from "./projectConfig";

interface PreviewSession extends DependencySession {
  wantsPreview: boolean;
  externalOpened: boolean;
  rendering: boolean;
  queuedDocument?: vscode.TextDocument;
  pdfPath?: string;
  renderId: number;
  timer?: NodeJS.Timeout;
  panel?: PdfPreviewPanel;
}

interface Snapshot {
  entryPath: string;
  assetBaseDir: string;
  cwd: string;
  snapshotDir: string;
}

export class LivePreview implements vscode.Disposable {
  private readonly sessions = new Map<string, PreviewSession>();
  private readonly disposables: vscode.Disposable[] = [];
  private readonly previewServer: PdfPreviewServer;

  constructor(
    private readonly context: vscode.ExtensionContext,
    private readonly output: vscode.OutputChannel,
    private readonly clientProvider: ClientProvider,
  ) {
    this.previewServer = new PdfPreviewServer(context.extensionPath, output);
    this.disposables.push(vscode.workspace.onDidChangeTextDocument((event) => {
      if (event.document.languageId === "ss-slide" && projectSettings(event.document.uri).preview.refreshOnEdit) {
        this.scheduleAffectedDocument(event.document);
      }
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

  open(document: vscode.TextDocument | undefined): void {
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

  private schedule(document: vscode.TextDocument, delayMs?: number): void {
    const key = document.uri.toString();
    const session = this.sessions.get(key);
    if (!session) {
      return;
    }
    const settings = projectSettings(document.uri).preview;
    if (!settings.enabled) {
      return;
    }
    if (session.timer) {
      clearTimeout(session.timer);
    }
    const configuredDelay = settings.debounceMs;
    session.timer = setTimeout(() => {
      session.timer = undefined;
      void this.requestRender(document);
    }, delayMs ?? configuredDelay);
  }

  private scheduleAffectedDocument(document: vscode.TextDocument, delayMs?: number): void {
    this.scheduleAffectedPath(document.uri.fsPath, delayMs, document);
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
      if (this.sessions.has(directKey)) {
        this.schedule(changedDocument, delayMs);
        scheduled.add(directKey);
      }
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

    const projectInfo = resolveProjectInfo(document, await requestProjectInfo(this.clientProvider, document, (message) => {
      this.output.appendLine(`[preview] projectInfo failed: ${message}`);
    }));
    const { entryPath, assetBaseDir, localModules } = projectInfo;
    updateDependencySession(session, entryPath, localModules);
    if (!this.renderIsCurrent(key, renderId)) {
      return;
    }
    const snapshot = await this.writeSnapshot(entryPath, assetBaseDir, localModules, renderId);
    if (!this.renderIsCurrent(key, renderId)) {
      const settings = projectSettings(document.uri).preview;
      if (settings.deleteSnapshotsAfterRender) {
        await fs.promises.rm(snapshot.snapshotDir, { recursive: true, force: true }).catch(() => undefined);
      }
      return;
    }
    const paths = this.previewPaths(document, renderId);
    await fs.promises.mkdir(paths.dir, { recursive: true });

    const settings = projectSettings(document.uri).preview;
    const command = vscode.workspace.getConfiguration("ss").get<string>("cli.path", "ss");
    const args = [
      "render",
      snapshot.entryPath,
      paths.tempPdf,
      "--asset-base-dir",
      snapshot.assetBaseDir,
      "--cache-id",
      entryPath,
      ...settings.extraRenderArgs,
    ];
    this.output.appendLine(`[preview] ${command} ${args.join(" ")}`);
    const result = await run(command, args, snapshot.cwd, settings.renderTimeoutMs);
    if (settings.deleteSnapshotsAfterRender) {
      await fs.promises.rm(snapshot.snapshotDir, { recursive: true, force: true }).catch(() => undefined);
    }
    const current = this.sessions.get(key);
    if (!current || current.renderId !== renderId) {
      await removeIfExists(paths.tempPdf);
      return;
    }
    if (result.code !== 0) {
      this.output.appendLine(result.stderr.trimEnd() || result.stdout.trimEnd() || `[preview] failed with exit code ${result.code}`);
      await removeIfExists(paths.tempPdf);
      return;
    }
    await fs.promises.copyFile(paths.tempPdf, paths.pdf);
    await removeIfExists(paths.tempPdf);
    current.pdfPath = paths.pdf;
    await this.cleanupPreviewCache(paths.dir, paths.pdf, paths.stem);
    await this.present(document, current, paths.pdf, false);
  }

  private renderIsCurrent(key: string, renderId: number): boolean {
    const current = this.sessions.get(key);
    return Boolean(current && current.renderId === renderId);
  }

  private async writeSnapshot(entryPath: string, assetBaseDir: string, modules: string[], renderId: number): Promise<Snapshot> {
    const entryUri = vscode.Uri.file(entryPath);
    const workspaceRoot = vscode.workspace.getWorkspaceFolder(entryUri)?.uri.fsPath ?? path.dirname(entryPath);
    const settings = projectSettings(vscode.Uri.file(entryPath)).preview;
    const snapshotRoot = path.join(resolveWorkspacePath(workspaceRoot, settings.snapshotDirectory), stableHash(entryPath));
    const snapshotDir = path.join(snapshotRoot, `${process.pid}-${renderId}`);
    await fs.promises.rm(snapshotDir, { recursive: true, force: true });
    await copyDirectory(assetBaseDir, snapshotDir);
    const paths = uniquePaths([entryPath, ...modules, ...vscode.workspace.textDocuments.filter((doc) => doc.languageId === "ss-slide" && doc.uri.scheme === "file").map((doc) => doc.uri.fsPath)]);
    for (const sourcePath of paths) {
      const text = openDocumentText(sourcePath) ?? await fs.promises.readFile(sourcePath, "utf8").catch(() => undefined);
      if (text === undefined) {
        continue;
      }
      const relative = safeRelative(assetBaseDir, sourcePath);
      const target = path.join(snapshotDir, relative);
      await fs.promises.mkdir(path.dirname(target), { recursive: true });
      await fs.promises.writeFile(target, text, "utf8");
    }
    return {
      entryPath: path.join(snapshotDir, safeRelative(assetBaseDir, entryPath)),
      assetBaseDir: snapshotDir,
      cwd: workspaceRoot,
      snapshotDir,
    };
  }

  private previewPaths(document: vscode.TextDocument, renderId: number): { dir: string; stem: string; pdf: string; tempPdf: string } {
    const workspaceRoot = vscode.workspace.getWorkspaceFolder(document.uri)?.uri.fsPath ?? path.dirname(document.uri.fsPath);
    const dir = resolveWorkspacePath(workspaceRoot, projectSettings(document.uri).preview.outputDirectory);
    const base = path.basename(document.uri.fsPath, path.extname(document.uri.fsPath)).replace(/[^A-Za-z0-9_-]/g, "_") || "preview";
    const stem = `${base}-${stableHash(document.uri.toString())}`;
    return {
      dir,
      stem,
      pdf: path.join(dir, `${stem}.pdf`),
      tempPdf: path.join(dir, `${stem}.tmp-${process.pid}-${renderId}.pdf`),
    };
  }

  private async present(document: vscode.TextDocument, session: PreviewSession, pdfPath: string, forceReveal: boolean): Promise<void> {
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
        const current = this.sessions.get(key);
        if (current?.panel === panel) {
          this.stopSession(key, false);
        }
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

  private ensureSession(key: string): PreviewSession {
    const current = this.sessions.get(key);
    if (current) {
      return current;
    }
    const session: PreviewSession = {
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
    this.sessions.delete(key);
  }

  private disposePanel(session: PreviewSession): void {
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

function safeRelative(root: string, filePath: string): string {
  const relative = path.relative(root, filePath);
  if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
    return path.join("__external", stableHash(filePath), path.basename(filePath));
  }
  return relative;
}

function resolveWorkspacePath(workspaceRoot: string, configuredPath: string): string {
  return path.isAbsolute(configuredPath) ? configuredPath : path.join(workspaceRoot, configuredPath);
}

function openDocumentText(filePath: string): string | undefined {
  const resolved = path.resolve(filePath);
  return vscode.workspace.textDocuments.find((doc) => doc.uri.scheme === "file" && path.resolve(doc.uri.fsPath) === resolved)?.getText();
}

async function copyDirectory(source: string, target: string): Promise<void> {
  const entries = await fs.promises.readdir(source, { withFileTypes: true }).catch(() => []);
  await fs.promises.mkdir(target, { recursive: true });
  for (const entry of entries) {
    if (skipSnapshotEntry(entry.name)) {
      continue;
    }
    const sourcePath = path.join(source, entry.name);
    const targetPath = path.join(target, entry.name);
    if (entry.isDirectory()) {
      await copyDirectory(sourcePath, targetPath);
    } else if (entry.isFile()) {
      await fs.promises.mkdir(path.dirname(targetPath), { recursive: true });
      await fs.promises.copyFile(sourcePath, targetPath);
    }
  }
}

function skipSnapshotEntry(name: string): boolean {
  return name === "ss.toml" ||
    name === ".ss-cache" ||
    name === ".git" ||
    name === ".zig-cache" ||
    name === "zig-out" ||
    name === "node_modules" ||
    name === "dist" ||
    name === "build" ||
    name === "coverage";
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
    child.on("close", (code: number | null) => finish(timedOut ? -1 : code, timedOut ? `[preview] render timed out after ${timeoutMs}ms` : stderr));
  });
}

async function removeIfExists(filePath: string): Promise<void> {
  await fs.promises.unlink(filePath).catch((error: NodeJS.ErrnoException) => {
    if (error.code !== "ENOENT") {
      throw error;
    }
  });
}
