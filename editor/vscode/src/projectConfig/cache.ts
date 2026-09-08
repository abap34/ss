import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";
import type { ProjectSettings } from "../projectConfig";

export interface LoadedProject {
  readonly settings: ProjectSettings;
  readonly entry?: vscode.Uri;
}

type Lookup = {
  invalidated: boolean;
  projectFile?: string;
  directories: string[];
  value: Promise<LoadedProject>;
};

type DirectoryWatch = {
  references: number;
  disposables: vscode.Disposable[];
};

export class ProjectSettingsCache implements vscode.Disposable {
  private readonly lookups = new Map<string, Lookup>();
  private readonly projects = new Map<string, { references: number; value: Promise<LoadedProject> }>();
  private readonly watches = new Map<string, DirectoryWatch>();
  private readonly listeners = new Set<(files: readonly string[]) => void>();
  private workspaceSubscription?: vscode.Disposable;
  private readonly maxLookups = 128;
  private readonly maxWatches = 256;
  private defaults?: Promise<LoadedProject>;
  private disposed = false;

  constructor(
    private readonly load: (projectFile: string | undefined) => Promise<LoadedProject>,
  ) {}

  start(): this {
    this.workspaceSubscription ??= vscode.workspace.onDidChangeWorkspaceFolders(() => {
      this.clear();
      this.notify();
    });
    return this;
  }

  onDidChange(listener: (files: readonly string[]) => void): vscode.Disposable {
    this.start();
    this.listeners.add(listener);
    return { dispose: () => { this.listeners.delete(listener); } };
  }

  async get(uri: vscode.Uri | undefined): Promise<LoadedProject> {
    for (;;) {
      if (this.disposed) throw new Error("Project settings cache was disposed");
      const lookup = this.lookup(uri);
      try {
        const value = await lookup.value;
        if (this.disposed) throw new Error("Project settings cache was disposed");
        if (!lookup.invalidated) return value;
      } catch (error) {
        if (this.disposed || !lookup.invalidated) throw error;
      }
    }
  }

  private defaultValue(): Promise<LoadedProject> {
    return this.defaults ??= this.load(undefined);
  }

  private lookup(uri: vscode.Uri | undefined): Lookup {
    this.start();
    const directory = uri?.scheme === "file"
      ? path.dirname(uri.fsPath)
      : vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    if (!directory) return { invalidated: false, directories: [], value: this.defaultValue() };
    const key = path.resolve(directory);
    const cached = this.lookups.get(key);
    if (cached) {
      this.lookups.delete(key);
      this.lookups.set(key, cached);
      return cached;
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
    if (directories.length > this.maxWatches) {
      return { invalidated: false, directories: [], projectFile, value: projectFile ? this.load(projectFile) : this.defaultValue() };
    }
    while (this.lookups.size >= this.maxLookups ||
      this.watches.size + directories.filter((item) => !this.watches.has(item)).length > this.maxWatches) {
      this.remove(this.lookups.keys().next().value!);
    }

    let value: Promise<LoadedProject>;
    if (projectFile) {
      let project = this.projects.get(projectFile);
      if (!project) {
        project = { references: 0, value: this.load(projectFile) };
        this.projects.set(projectFile, project);
      }
      project.references++;
      value = project.value;
    } else {
      value = this.defaultValue();
    }
    const retainedDirectories: string[] = [];
    const lookup = { invalidated: false, projectFile, directories: retainedDirectories, value };
    this.lookups.set(key, lookup);
    try {
      for (const item of directories) {
        this.retainWatch(item);
        retainedDirectories.push(item);
      }
    } catch {
      // A lookup without complete observation is returned without being retained.
      this.remove(key);
    }
    return lookup;
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
      const files = new Set<string>([path.join(affectedDirectory, "ss.toml")]);
      for (const [key, lookup] of [...this.lookups]) {
        if (!lookup.directories.includes(affectedDirectory)) continue;
        if (lookup.projectFile) files.add(lookup.projectFile);
        this.remove(key, true);
        changed = true;
      }
      if (changed) this.notify([...files]);
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

  private remove(key: string, invalidate = false): void {
    const lookup = this.lookups.get(key);
    if (!lookup) return;
    if (invalidate) lookup.invalidated = true;
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
    for (const key of [...this.lookups.keys()]) this.remove(key, true);
  }

  private notify(files: readonly string[] = []): void {
    for (const listener of [...this.listeners]) listener(files);
  }

  dispose(): void {
    this.disposed = true;
    this.listeners.clear();
    this.clear();
    this.workspaceSubscription?.dispose();
    this.workspaceSubscription = undefined;
  }
}
