import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";

export interface ProjectSettings {
  lsp: LspSettings;
  preview: PreviewSettings;
  pageGuide: PageGuideSettings;
}

export interface LspSettings {
  enabled: boolean;
  changeDebounceMs: number;
  diagnostics: boolean;
  completion: boolean;
  hover: boolean;
  definition: boolean;
  inlayHints: boolean;
  inlayHintArguments: boolean;
  inlayHintPositions: boolean;
  documentSymbols: boolean;
  foldingRanges: boolean;
  semanticTokens: boolean;
  colors: boolean;
}

export interface PreviewSettings {
  enabled: boolean;
  debounceMs: number;
  refreshOnEdit: boolean;
  refreshOnSave: boolean;
  refreshOnDependencyChange: boolean;
  openMode: "vscode" | "external";
  revealAfterRender: boolean;
  renderTimeoutMs: number;
  outputDirectory: string;
  snapshotDirectory: string;
  deleteSnapshotsAfterRender: boolean;
  extraRenderArgs: string[];
}

export interface PageGuideSettings {
  enabled: boolean;
  bodyBackground: boolean;
  boundary: boolean;
  boundaryBackground: boolean;
  gutterIcon: boolean;
  overviewRuler: boolean;
}

const defaultSettings: ProjectSettings = {
  lsp: {
    enabled: true,
    changeDebounceMs: 120,
    diagnostics: true,
    completion: true,
    hover: true,
    definition: true,
    inlayHints: true,
    inlayHintArguments: true,
    inlayHintPositions: true,
    documentSymbols: true,
    foldingRanges: true,
    semanticTokens: true,
    colors: true,
  },
  preview: {
    enabled: true,
    debounceMs: 350,
    refreshOnEdit: true,
    refreshOnSave: true,
    refreshOnDependencyChange: true,
    openMode: "vscode",
    revealAfterRender: true,
    renderTimeoutMs: 30000,
    outputDirectory: ".ss-cache/vscode-preview",
    snapshotDirectory: ".ss-cache/vscode-projects",
    deleteSnapshotsAfterRender: true,
    extraRenderArgs: [],
  },
  pageGuide: {
    enabled: true,
    bodyBackground: true,
    boundary: true,
    boundaryBackground: true,
    gutterIcon: true,
    overviewRuler: true,
  },
};

export function projectSettings(uri: vscode.Uri | undefined): ProjectSettings {
  const projectFile = findProjectFile(uri);
  if (!projectFile) {
    return cloneDefaults();
  }
  const source = readProjectFile(projectFile);
  if (source === undefined) {
    return cloneDefaults();
  }
  const table = parseTomlSubset(source);
  const inlayHints = boolValue(table, "editor.lsp", "inlay_hints", defaultSettings.lsp.inlayHints);
  return {
    lsp: {
      enabled: boolValue(table, "editor.lsp", "enabled", defaultSettings.lsp.enabled),
      changeDebounceMs: numberValue(table, "editor.lsp", "debounce", defaultSettings.lsp.changeDebounceMs, 0),
      diagnostics: boolValue(table, "editor.lsp", "diagnostics", defaultSettings.lsp.diagnostics),
      completion: boolValue(table, "editor.lsp", "completion", defaultSettings.lsp.completion),
      hover: boolValue(table, "editor.lsp", "hover", defaultSettings.lsp.hover),
      definition: boolValue(table, "editor.lsp", "definition", defaultSettings.lsp.definition),
      inlayHints,
      inlayHintArguments: boolValue(table, "editor.lsp.inlay_hints", "arguments", inlayHints),
      inlayHintPositions: boolValue(table, "editor.lsp.inlay_hints", "positions", inlayHints),
      documentSymbols: boolValue(table, "editor.lsp", "document_symbols", defaultSettings.lsp.documentSymbols),
      foldingRanges: boolValue(table, "editor.lsp", "folding_ranges", defaultSettings.lsp.foldingRanges),
      semanticTokens: boolValue(table, "editor.lsp", "semantic_tokens", defaultSettings.lsp.semanticTokens),
      colors: boolValue(table, "editor.lsp", "colors", defaultSettings.lsp.colors),
    },
    preview: {
      enabled: boolValue(table, "editor.preview", "enabled", defaultSettings.preview.enabled),
      debounceMs: numberValue(table, "editor.preview", "debounce", defaultSettings.preview.debounceMs, 0),
      refreshOnEdit: boolValue(table, "editor.preview.refresh", "edit", defaultSettings.preview.refreshOnEdit),
      refreshOnSave: boolValue(table, "editor.preview.refresh", "save", defaultSettings.preview.refreshOnSave),
      refreshOnDependencyChange: boolValue(table, "editor.preview.refresh", "dependency", defaultSettings.preview.refreshOnDependencyChange),
      openMode: stringValue(table, "editor.preview", "open", defaultSettings.preview.openMode) === "external" ? "external" : "vscode",
      revealAfterRender: boolValue(table, "editor.preview", "reveal", defaultSettings.preview.revealAfterRender),
      renderTimeoutMs: numberValue(table, "editor.preview.render", "timeout", defaultSettings.preview.renderTimeoutMs, 0),
      outputDirectory: stringValue(table, "editor.preview.path", "output", defaultSettings.preview.outputDirectory),
      snapshotDirectory: stringValue(table, "editor.preview.path", "snapshot", defaultSettings.preview.snapshotDirectory),
      deleteSnapshotsAfterRender: boolValue(table, "editor.preview.render", "delete_snapshots", defaultSettings.preview.deleteSnapshotsAfterRender),
      extraRenderArgs: stringArrayValue(table, "editor.preview.render", "extra_args"),
    },
    pageGuide: {
      enabled: boolValue(table, "editor.page_guide", "enabled", defaultSettings.pageGuide.enabled),
      bodyBackground: boolValue(table, "editor.page_guide", "body_background", defaultSettings.pageGuide.bodyBackground),
      boundary: boolValue(table, "editor.page_guide", "boundary", defaultSettings.pageGuide.boundary),
      boundaryBackground: boolValue(table, "editor.page_guide", "boundary_background", defaultSettings.pageGuide.boundaryBackground),
      gutterIcon: boolValue(table, "editor.page_guide", "gutter_icon", defaultSettings.pageGuide.gutterIcon),
      overviewRuler: boolValue(table, "editor.page_guide", "overview_ruler", defaultSettings.pageGuide.overviewRuler),
    },
  };
}

function readProjectFile(projectFile: string): string | undefined {
  try {
    return fs.readFileSync(projectFile, "utf8");
  } catch {
    return undefined;
  }
}

function cloneDefaults(): ProjectSettings {
  return {
    lsp: { ...defaultSettings.lsp },
    preview: { ...defaultSettings.preview, extraRenderArgs: [...defaultSettings.preview.extraRenderArgs] },
    pageGuide: { ...defaultSettings.pageGuide },
  };
}

function findProjectFile(uri: vscode.Uri | undefined): string | undefined {
  let current = uri?.scheme === "file" ? path.dirname(uri.fsPath) : vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
  while (current) {
    const candidate = path.join(current, "ss.toml");
    if (fs.existsSync(candidate)) {
      return candidate;
    }
    const parent = path.dirname(current);
    if (parent === current) {
      return undefined;
    }
    current = parent;
  }
  return undefined;
}

type TomlSubset = Map<string, Map<string, string>>;

function parseTomlSubset(source: string): TomlSubset {
  const table: TomlSubset = new Map();
  let section = "";
  for (const rawLine of source.split(/\r?\n/)) {
    const line = stripComment(rawLine).trim();
    if (!line) {
      continue;
    }
    const sectionMatch = /^\[([A-Za-z0-9_.-]+)\]$/.exec(line);
    if (sectionMatch) {
      section = sectionMatch[1];
      continue;
    }
    const eq = line.indexOf("=");
    if (eq < 0 || !section) {
      continue;
    }
    const key = line.slice(0, eq).trim();
    const value = line.slice(eq + 1).trim();
    const fields = table.get(section) ?? new Map<string, string>();
    fields.set(key, value);
    table.set(section, fields);
  }
  return table;
}

function stripComment(line: string): string {
  let inString = false;
  let escaped = false;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char === "\\") {
        escaped = true;
      } else if (char === "\"") {
        inString = false;
      }
      continue;
    }
    if (char === "\"") {
      inString = true;
    } else if (char === "#") {
      return line.slice(0, index);
    }
  }
  return line;
}

function rawValue(table: TomlSubset, section: string, key: string): string | undefined {
  return table.get(section)?.get(key);
}

function boolValue(table: TomlSubset, section: string, key: string, fallback: boolean): boolean {
  const value = rawValue(table, section, key);
  return value === "true" ? true : value === "false" ? false : fallback;
}

function numberValue(table: TomlSubset, section: string, key: string, fallback: number, minimum: number): number {
  const parsed = Number(rawValue(table, section, key));
  return Number.isFinite(parsed) ? Math.max(minimum, parsed) : fallback;
}

function stringValue(table: TomlSubset, section: string, key: string, fallback: string): string {
  const value = rawValue(table, section, key);
  if (!value || value.length < 2 || !value.startsWith("\"") || !value.endsWith("\"")) {
    return fallback;
  }
  return value.slice(1, -1);
}

function stringArrayValue(table: TomlSubset, section: string, key: string): string[] {
  const value = rawValue(table, section, key);
  if (!value?.startsWith("[") || !value.endsWith("]")) {
    return [];
  }
  return value.slice(1, -1).split(",").map((item) => item.trim()).filter(Boolean).map((item) => {
    if (item.startsWith("\"") && item.endsWith("\"")) {
      return item.slice(1, -1);
    }
    return item;
  });
}
