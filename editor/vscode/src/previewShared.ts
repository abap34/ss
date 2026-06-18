import * as path from "path";
import * as vscode from "vscode";
import type { LanguageClient } from "vscode-languageclient/node";

export type ClientProvider = () => LanguageClient | undefined;

export interface ProjectInfo {
  entryPath?: string;
  assetBaseDir?: string;
  localModules?: string[];
}

export interface DependencySession {
  entryPath?: string;
  dependencyPaths?: Set<string>;
}

export interface ResolvedProjectInfo {
  entryPath: string;
  assetBaseDir: string;
  localModules: string[];
}

export async function requestProjectInfo(
  clientProvider: ClientProvider,
  document: vscode.TextDocument,
  onError?: (message: string) => void,
): Promise<ProjectInfo> {
  const client = clientProvider();
  if (!client) {
    return {};
  }
  try {
    return await client.sendRequest<ProjectInfo>("ss/projectInfo", {
      textDocument: { uri: document.uri.toString() },
    });
  } catch (error) {
    onError?.(String(error));
    return {};
  }
}

export function resolveProjectInfo(document: vscode.TextDocument, projectInfo: ProjectInfo): ResolvedProjectInfo {
  const entryPath = projectInfo.entryPath ?? document.uri.fsPath;
  return {
    entryPath,
    assetBaseDir: projectInfo.assetBaseDir ?? path.dirname(entryPath),
    localModules: projectInfo.localModules ?? [],
  };
}

export function updateDependencySession(session: DependencySession, entryPath: string, localModules: string[]): void {
  session.entryPath = normalizePath(entryPath);
  session.dependencyPaths = new Set(uniquePaths([entryPath, ...localModules]).map(normalizePath));
}

export function sessionDependsOn(session: DependencySession, changedPath: string): boolean {
  if (session.entryPath === changedPath) {
    return true;
  }
  return session.dependencyPaths?.has(changedPath) ?? false;
}

export function ignoreGeneratedPath(filePath: string): boolean {
  return path.resolve(filePath).split(path.sep).some((part) =>
    part === ".ss-cache" ||
    part === ".git" ||
    part === ".zig-cache" ||
    part === "node_modules" ||
    part === "zig-out"
  );
}

export function documentForUri(uri: vscode.Uri): vscode.TextDocument | undefined {
  return vscode.workspace.textDocuments.find((document) => document.uri.toString() === uri.toString());
}

export function documentForSession(key: string): vscode.TextDocument | undefined {
  return vscode.workspace.textDocuments.find((document) => document.uri.toString() === key);
}

export function normalizePath(filePath: string): string {
  return path.resolve(filePath);
}

export function uniquePaths(paths: string[]): string[] {
  return [...new Set(paths.map((item) => path.resolve(item)))];
}
