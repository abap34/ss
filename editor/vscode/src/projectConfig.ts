import * as vscode from "vscode";
import { LoadedProject, ProjectSettingsCache } from "./projectConfig/cache";

export interface ProjectSettings {
  readonly lsp: Readonly<LspSettings>;
  readonly wysiwyg: Readonly<WysiwygSettings>;
  readonly pageGuide: Readonly<PageGuideSettings>;
}

export interface LspSettings {
  enabled: boolean;
  debounceMs: number;
  diagnostics: boolean;
  completion: boolean;
  hover: boolean;
  definition: boolean;
  documentSymbols: boolean;
  foldingRanges: boolean;
  semanticTokens: boolean;
  colors: boolean;
}

export interface WysiwygSettings {
  enabled: boolean;
  debounceMs: number;
  maxWaitMs: number;
  refreshAutomatically: boolean;
  refreshOnDependencyChange: boolean;
}

export interface PageGuideSettings {
  enabled: boolean;
  bodyBackground: boolean;
  boundary: boolean;
  boundaryBackground: boolean;
  gutterIcon: boolean;
  overviewRuler: boolean;
}

export interface ProjectSettingsResponse {
  readonly schema: 1;
  readonly entryPath: string | null;
  readonly settings: ProjectSettings;
  readonly error?: { readonly code: string; readonly message: string };
}

export type ProjectSettingsProvider = (projectFile: string | undefined) => Promise<ProjectSettingsResponse>;

let cache: ProjectSettingsCache | undefined;
let changeSubscription: vscode.Disposable | undefined;
let reportError: (message: string) => void = () => {};
const listeners = new Set<(files: readonly string[]) => void>();

export function initializeProjectSettings(): vscode.Disposable {
  return { dispose: () => {
    setProjectSettingsProvider(undefined);
    listeners.clear();
  } };
}

export function setProjectSettingsProvider(
  provider: ProjectSettingsProvider | undefined,
  log: (message: string) => void = () => {},
): void {
  changeSubscription?.dispose();
  cache?.dispose();
  reportError = log;
  cache = provider ? new ProjectSettingsCache(async (projectFile) => {
    const response = await provider(projectFile);
    if (response.schema !== 1) throw new Error("Unsupported project settings response");
    if (response.error) log(`${projectFile ?? "ss.toml"}: ${response.error.message}`);
    return {
      settings: freezeSettings(response.settings),
      entry: response.entryPath ? vscode.Uri.file(response.entryPath) : undefined,
    };
  }).start() : undefined;
  changeSubscription = cache?.onDidChange(notify);
  notify();
}

export function onDidChangeProjectSettings(listener: (files: readonly string[]) => void): vscode.Disposable {
  listeners.add(listener);
  return { dispose: () => { listeners.delete(listener); } };
}

export async function projectSettings(uri: vscode.Uri | undefined): Promise<ProjectSettings | undefined> {
  return (await loadProject(uri))?.settings;
}

export async function projectEntryUri(uri: vscode.Uri | undefined): Promise<vscode.Uri | undefined> {
  return (await loadProject(uri))?.entry;
}

async function loadProject(uri: vscode.Uri | undefined): Promise<LoadedProject | undefined> {
  for (;;) {
    const active = cache;
    if (!active) return undefined;
    try {
      const result = await active.get(uri);
      if (active === cache) return result;
    } catch (error) {
      if (active === cache) {
        reportError(`Project settings could not be loaded: ${String(error)}`);
        return undefined;
      }
    }
  }
}

function notify(files: readonly string[] = []): void {
  for (const listener of [...listeners]) listener(files);
}

function freezeSettings(settings: ProjectSettings): ProjectSettings {
  Object.freeze(settings.lsp);
  Object.freeze(settings.wysiwyg);
  Object.freeze(settings.pageGuide);
  return Object.freeze(settings);
}
