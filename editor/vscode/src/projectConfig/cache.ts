import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";
import type { ProjectSettings } from "../projectConfig";

export interface LoadedProject {
  readonly settings: ProjectSettings;
  readonly entry?: vscode.Uri;
}

type Lookup = {
  projectFile?: string;
  directories: string[];
  value: LoadedProject;
};

type DirectoryWatch = {
  references: number;
  disposables: vscode.Disposable[];
};

export class ProjectSettingsCache implements vscode.Disposable {
  private readonly lookups = new Map<string, Lookup>();
  private readonly projects = new Map<string, { references: number; value: LoadedProject }>();
  private readonly watches = new Map<string, DirectoryWatch>();
  private readonly listeners = new Set<() => void>();
  private workspaceSubscription?: vscode.Disposable;
  private readonly maxLookups = 128;
  private readonly maxWatches = 256;

  constructor(
    private readonly load: (projectFile: string) => LoadedProject,
    private readonly defaults: LoadedProject,
  ) {}

  start(): this {
    this.workspaceSubscription ??= vscode.workspace.onDidChangeWorkspaceFolders(() => {
      this.clear();
      this.notify();
    });
    return this;
  }

  onDidChange(listener: () => void): vscode.Disposable {
    this.start();
    this.listeners.add(listener);
    return { dispose: () => { this.listeners.delete(listener); } };
  }

  get(uri: vscode.Uri | undefined): LoadedProject {
    this.start();
    const directory = uri?.scheme === "file"
      ? path.dirname(uri.fsPath)
      : vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    if (!directory) return this.defaults;
    const key = path.resolve(directory);
    const cached = this.lookups.get(key);
    if (cached) {
      this.lookups.delete(key);
      this.lookups.set(key, cached);
      return cached.value;
    }

    const directories: string[] = [];
    let current = key;
    let projectFile: string | undefined;
    for (;;) {
      directories.push(current);
      const candidate = path.join(current, "ss.toml");
      if (fs.existsSync(candidate)) {
        projectFile = candidate;
        const parent = path.dirname(current);
        if (parent !== current) directories.push(parent);
        break;
      }
      const parent = path.dirname(current);
      if (parent === current) break;
      current = parent;
    }
    // An unusually deep path is resolved without retaining unobserved configuration.
    if (directories.length > this.maxWatches) return projectFile ? this.load(projectFile) : this.defaults;
    while (this.lookups.size >= this.maxLookups ||
      this.watches.size + directories.filter((item) => !this.watches.has(item)).length > this.maxWatches) {
      this.remove(this.lookups.keys().next().value!);
    }

    let value = this.defaults;
    if (projectFile) {
      let project = this.projects.get(projectFile);
      if (!project) {
        project = { references: 0, value: this.load(projectFile) };
        this.projects.set(projectFile, project);
      }
      project.references++;
      value = project.value;
    }
    const retainedDirectories: string[] = [];
    this.lookups.set(key, { projectFile, directories: retainedDirectories, value });
    try {
      for (const item of directories) {
        this.retainWatch(item);
        retainedDirectories.push(item);
      }
    } catch {
      // A lookup without complete observation is returned without being retained.
      this.remove(key);
    }
    return value;
  }

  private retainWatch(directory: string): void {
    const existing = this.watches.get(directory);
    if (existing) {
      existing.references++;
      return;
    }
    // Parent directory events cover coalesced folder removal and creation events.
    const watcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(vscode.Uri.file(directory), "*"),
    );
    const invalidate = (uri: vscode.Uri) => {
      const changedPath = path.resolve(uri.fsPath);
      const affectedDirectory = path.basename(changedPath).toLowerCase() === "ss.toml" ? directory : changedPath;
      if (affectedDirectory !== directory && !this.watches.has(affectedDirectory)) return;
      let changed = false;
      for (const [key, lookup] of [...this.lookups]) {
        if (!lookup.directories.includes(affectedDirectory)) continue;
        this.remove(key);
        changed = true;
      }
      if (changed) this.notify();
    };
    const disposables: vscode.Disposable[] = [watcher];
    try {
      disposables.push(watcher.onDidChange(invalidate));
      disposables.push(watcher.onDidCreate(invalidate));
      disposables.push(watcher.onDidDelete(invalidate));
    } catch (error) {
      for (const disposable of disposables) disposable.dispose();
      throw error;
    }
    this.watches.set(directory, { references: 1, disposables });
  }

  private remove(key: string): void {
    const lookup = this.lookups.get(key);
    if (!lookup) return;
    this.lookups.delete(key);
    if (lookup.projectFile) {
      const project = this.projects.get(lookup.projectFile)!;
      if (--project.references === 0) this.projects.delete(lookup.projectFile);
    }
    for (const directory of lookup.directories) {
      const watch = this.watches.get(directory)!;
      if (--watch.references !== 0) continue;
      this.watches.delete(directory);
      for (const disposable of watch.disposables) disposable.dispose();
    }
  }

  private clear(): void {
    for (const key of [...this.lookups.keys()]) this.remove(key);
  }

  private notify(): void {
    for (const listener of [...this.listeners]) listener();
  }

  dispose(): void {
    this.listeners.clear();
    this.clear();
    this.workspaceSubscription?.dispose();
    this.workspaceSubscription = undefined;
  }
}
