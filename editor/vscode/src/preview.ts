import * as crypto from "crypto";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as vscode from "vscode";
import { LanguageClient } from "vscode-languageclient/node";

type ClientProvider = () => LanguageClient | undefined;

interface ProjectInfo {
  entryPath?: string;
  assetBaseDir?: string;
  localModules?: string[];
}

interface PreviewSession {
  opened: boolean;
  pdfPath?: string;
  renderId: number;
  timer?: NodeJS.Timeout;
  entryPath?: string;
  dependencyPaths?: Set<string>;
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

  constructor(
    private readonly context: vscode.ExtensionContext,
    private readonly output: vscode.OutputChannel,
    private readonly clientProvider: ClientProvider,
  ) {
    this.disposables.push(vscode.workspace.onDidChangeTextDocument((event) => {
      if (event.document.languageId === "ss-slide") {
        this.scheduleAffectedDocument(event.document);
      }
    }));
    this.disposables.push(vscode.workspace.onDidSaveTextDocument((document) => {
      if (document.languageId === "ss-slide") {
        this.scheduleAffectedDocument(document, 0);
      }
    }));
    this.disposables.push(vscode.workspace.onDidCloseTextDocument((document) => {
      const session = this.sessions.get(document.uri.toString());
      if (session?.timer) {
        clearTimeout(session.timer);
      }
      this.sessions.delete(document.uri.toString());
    }));
    const watcher = vscode.workspace.createFileSystemWatcher("**/*.ss");
    this.disposables.push(
      watcher,
      watcher.onDidChange((uri) => this.scheduleAffectedUri(uri, 0)),
      watcher.onDidCreate((uri) => this.scheduleAffectedUri(uri, 0)),
      watcher.onDidDelete((uri) => this.scheduleAffectedUri(uri, 0)),
    );
  }

  dispose(): void {
    for (const session of this.sessions.values()) {
      if (session.timer) {
        clearTimeout(session.timer);
      }
    }
    this.sessions.clear();
    for (const disposable of this.disposables) {
      disposable.dispose();
    }
  }

  open(document: vscode.TextDocument | undefined): void {
    if (!document || document.languageId !== "ss-slide" || document.uri.scheme !== "file") {
      void vscode.window.showWarningMessage("Open an .ss file to start live preview.");
      return;
    }
    const key = document.uri.toString();
    const current = this.sessions.get(key);
    if (current) {
      if (current.pdfPath) {
        void this.reveal(document, current.pdfPath, true);
      }
      this.schedule(document, 0);
      return;
    }
    this.sessions.set(key, { opened: false, renderId: 0 });
    this.schedule(document, 0);
  }

  private schedule(document: vscode.TextDocument, delayMs?: number): void {
    const key = document.uri.toString();
    const session = this.sessions.get(key);
    if (!session) {
      return;
    }
    if (session.timer) {
      clearTimeout(session.timer);
    }
    const configuredDelay = Math.max(80, vscode.workspace.getConfiguration("ss").get<number>("livePreview.debounceMs", 350));
    session.timer = setTimeout(() => {
      session.timer = undefined;
      void this.render(document);
    }, delayMs ?? configuredDelay);
  }

  private scheduleAffectedDocument(document: vscode.TextDocument, delayMs?: number): void {
    this.scheduleAffectedPath(document.uri.fsPath, delayMs, document);
  }

  private scheduleAffectedUri(uri: vscode.Uri, delayMs?: number): void {
    if (uri.scheme !== "file") {
      return;
    }
    this.scheduleAffectedPath(uri.fsPath, delayMs);
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
      this.schedule(document, delayMs);
      scheduled.add(key);
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
    const snapshot = await this.writeSnapshot(entryPath, assetBaseDir, localModules, renderId);
    const paths = this.previewPaths(document, renderId);
    await fs.promises.mkdir(paths.dir, { recursive: true });

    const command = vscode.workspace.getConfiguration("ss").get<string>("cli.path", "ss");
    const args = ["render", snapshot.entryPath, paths.tempPdf, "--asset-base-dir", snapshot.assetBaseDir];
    this.output.appendLine(`[preview] ${command} ${args.join(" ")}`);
    const result = await run(command, args, snapshot.cwd);
    await fs.promises.rm(snapshot.snapshotDir, { recursive: true, force: true }).catch(() => undefined);
    if (this.sessions.get(key)?.renderId !== renderId) {
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
    session.pdfPath = paths.pdf;
    await this.cleanupPreviewCache(paths.dir, paths.pdf, paths.stem);
    await this.reveal(document, paths.pdf, false);
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
      this.output.appendLine(`[preview] projectInfo failed: ${String(error)}`);
      return {};
    }
  }

  private async writeSnapshot(entryPath: string, assetBaseDir: string, modules: string[], renderId: number): Promise<Snapshot> {
    const workspaceRoot = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath ?? path.dirname(entryPath);
    const snapshotRoot = path.join(workspaceRoot, ".ss-cache", "vscode-projects", stableHash(entryPath));
    const snapshotDir = path.join(snapshotRoot, `${process.pid}-${renderId}`);
    await fs.promises.rm(snapshotDir, { recursive: true, force: true });
    await copyDirectory(assetBaseDir, snapshotDir);
    const paths = unique([entryPath, ...modules, ...vscode.workspace.textDocuments.filter((doc) => doc.languageId === "ss-slide" && doc.uri.scheme === "file").map((doc) => doc.uri.fsPath)]);
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
    const dir = path.join(workspaceRoot, ".ss-cache", "vscode-preview");
    const base = path.basename(document.uri.fsPath, path.extname(document.uri.fsPath)).replace(/[^A-Za-z0-9_-]/g, "_") || "preview";
    const stem = `${base}-${stableHash(document.uri.toString())}`;
    return {
      dir,
      stem,
      pdf: path.join(dir, `${stem}.pdf`),
      tempPdf: path.join(dir, `${stem}.tmp-${process.pid}-${renderId}.pdf`),
    };
  }

  private async reveal(document: vscode.TextDocument, pdfPath: string, force: boolean): Promise<void> {
    const key = document.uri.toString();
    const session = this.sessions.get(key);
    if (!session || (!force && session.opened)) {
      return;
    }
    const uri = vscode.Uri.file(pdfPath);
    if (vscode.workspace.getConfiguration("ss").get<string>("livePreview.openMode", "vscode") === "external") {
      await vscode.env.openExternal(uri);
    } else {
      await vscode.commands.executeCommand("vscode.open", uri, {
        viewColumn: vscode.ViewColumn.Beside,
        preserveFocus: true,
        preview: false,
      });
    }
    session.opened = true;
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

function sessionDependsOn(session: PreviewSession, changedPath: string): boolean {
  if (session.entryPath === changedPath) {
    return true;
  }
  return session.dependencyPaths?.has(changedPath) ?? false;
}

function documentForSession(key: string): vscode.TextDocument | undefined {
  return vscode.workspace.textDocuments.find((document) => document.uri.toString() === key);
}

function unique(paths: string[]): string[] {
  return [...new Set(paths.map((item) => path.resolve(item)))];
}

function safeRelative(root: string, filePath: string): string {
  const relative = path.relative(root, filePath);
  if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
    return path.join("__external", stableHash(filePath), path.basename(filePath));
  }
  return relative;
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
  return name === ".ss-cache" ||
    name === ".git" ||
    name === ".zig-cache" ||
    name === "zig-out" ||
    name === "node_modules" ||
    name === "dist" ||
    name === "build" ||
    name === "coverage";
}

function run(command: string, args: string[], cwd: string): Promise<{ code: number | null; stdout: string; stderr: string }> {
  const childProcess = require("child_process") as typeof import("child_process");
  return new Promise((resolve) => {
    const child = childProcess.spawn(command, args, { cwd });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => { stdout += chunk; });
    child.stderr.on("data", (chunk: string) => { stderr += chunk; });
    child.on("error", (error: Error) => resolve({ code: -1, stdout, stderr: error.message }));
    child.on("close", (code: number | null) => resolve({ code, stdout, stderr }));
  });
}

async function removeIfExists(filePath: string): Promise<void> {
  await fs.promises.unlink(filePath).catch((error: NodeJS.ErrnoException) => {
    if (error.code !== "ENOENT") {
      throw error;
    }
  });
}
