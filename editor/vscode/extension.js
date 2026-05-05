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

  function formatFunctionSource(item) {
    const source = item && item.source ? String(item.source) : "";
    const moduleSpec = item && item.moduleSpec ? String(item.moduleSpec) : "";
    if (source && moduleSpec) {
      return `${source}: ${moduleSpec}`;
    }
    return moduleSpec || source;
  }

  function getPropertyCompletionContext(document, position) {
    const line = document.lineAt(position.line).text;
    const head = line.slice(0, position.character);
    const memberMatch = /([A-Za-z_][A-Za-z0-9_]*)\.\s*([A-Za-z_][A-Za-z0-9_]*)?$/.exec(head);
    if (memberMatch) {
      return {
        kind: "member",
        objectName: memberMatch[1],
        prefix: memberMatch[2] || "",
      };
    }
    const setPropMatch = /\bset_prop\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*"([^"]*)$/.exec(head);
    if (setPropMatch) {
      return {
        kind: "set_prop",
        objectName: setPropMatch[1],
        prefix: setPropMatch[2] || "",
      };
    }
    return null;
  }

  function declarations(payload) {
    return payload && payload.declarations && typeof payload.declarations === "object"
      ? payload.declarations
      : {};
  }

  function asArray(value) {
    return Array.isArray(value) ? value : [];
  }

  function classBaseMap(payload) {
    const result = new Map();
    for (const item of asArray(declarations(payload).classes)) {
      const name = String(item && item.name ? item.name : "");
      if (!name) {
        continue;
      }
      result.set(name, item.base ? String(item.base) : null);
    }
    return result;
  }

  function variableClassName(variable) {
    if (!variable) {
      return null;
    }
    const explicitClass = String(variable.objectClass || "");
    if (explicitClass) {
      return explicitClass;
    }
    const type = String(variable.type || variable.runtimeSort || "");
    if (type === "document") {
      return "DocumentObject";
    }
    if (type === "page") {
      return "PageObject";
    }
    return null;
  }

  function inheritedFields(payload, className) {
    const fields = asArray(declarations(payload).fields);
    if (!className) {
      return uniqueFields(fields);
    }

    const bases = classBaseMap(payload);
    const chain = [];
    const seen = new Set();
    let current = className;
    while (current && !seen.has(current)) {
      seen.add(current);
      chain.push(current);
      current = bases.get(current);
    }
    chain.reverse();

    const byName = new Map();
    for (const classItem of chain) {
      for (const field of fields) {
        if (String(field && field.class ? field.class : "") !== classItem) {
          continue;
        }
        const name = String(field && field.name ? field.name : "");
        if (name) {
          byName.set(name, field);
        }
      }
    }
    return Array.from(byName.values()).sort((a, b) => String(a.name || "").localeCompare(String(b.name || "")));
  }

  function uniqueFields(fields) {
    const byName = new Map();
    for (const field of fields) {
      const name = String(field && field.name ? field.name : "");
      if (name) {
        byName.set(name, field);
      }
    }
    return Array.from(byName.values()).sort((a, b) => String(a.name || "").localeCompare(String(b.name || "")));
  }

  function fieldCompletionItems(payload, objectName, prefix) {
    const variable = asArray(payload.variables).find((item) => String(item && item.name ? item.name : "") === objectName);
    const runtimeSort = String(variable && (variable.runtimeSort || variable.type) ? variable.runtimeSort || variable.type : "");
    const staticType = String(variable && variable.type ? variable.type : "");
    const isSelectionObject = runtimeSort === "selection" && staticType.startsWith("selection<object");
    if (!variable || (!["document", "page", "object"].includes(runtimeSort) && !isSelectionObject)) {
      return [];
    }

    const className = variableClassName(variable);
    const fields = inheritedFields(payload, className);
    return fields
      .filter((field) => {
        const name = String(field && field.name ? field.name : "");
        return name && (!prefix || name.startsWith(prefix));
      })
      .map((field) => {
        const name = String(field.name);
        const completion = new vscode.CompletionItem(name, vscode.CompletionItemKind.Property);
        completion.insertText = name;
        completion.filterText = name;
        const type = field.type ? String(field.type) : "";
        const owner = field.class ? String(field.class) : "";
        completion.detail = type ? `${type}${owner ? ` (${owner})` : ""}` : owner || "field";
        const documentation = new vscode.MarkdownString();
        if (type) {
          documentation.appendMarkdown(`type: \`${type}\``);
        }
        if (field.default !== undefined && field.default !== null) {
          if (documentation.value) {
            documentation.appendText("\n\n");
          }
          documentation.appendMarkdown(`default: \`${String(field.default)}\``);
        }
        if (owner) {
          if (documentation.value) {
            documentation.appendText("\n\n");
          }
          documentation.appendMarkdown(`declared on: \`${owner}\``);
        }
        if (documentation.value) {
          completion.documentation = documentation;
        }
        return completion;
      });
  }

  function declarationCompletionItems(payload, prefix) {
    const items = [];
    const decl = declarations(payload);
    const staticKeywords = ["import", "const", "document", "page", "fn", "let", "bind", "return", "end", "constrain", "type", "extend"];
    const builtinTypes = ["document", "page", "object", "selection", "anchor", "style", "string", "number", "constraints", "fragment", "code", "list"];
    const annotations = ["@render", "@phase", "@host", "@op", "@measure", "@layout", "@refine"];

    for (const keyword of staticKeywords) {
      if (prefix && !keyword.startsWith(prefix)) {
        continue;
      }
      const completion = new vscode.CompletionItem(keyword, vscode.CompletionItemKind.Keyword);
      completion.insertText = keyword;
      completion.detail = "keyword";
      items.push(completion);
    }

    for (const typeName of builtinTypes) {
      if (prefix && !typeName.startsWith(prefix)) {
        continue;
      }
      const completion = new vscode.CompletionItem(typeName, vscode.CompletionItemKind.TypeParameter);
      completion.insertText = typeName;
      completion.detail = "kernel type";
      items.push(completion);
    }

    for (const annotation of annotations) {
      const name = annotation.slice(1);
      if (prefix && !name.startsWith(prefix) && !annotation.startsWith(prefix)) {
        continue;
      }
      const completion = new vscode.CompletionItem(annotation, vscode.CompletionItemKind.Event);
      completion.insertText = annotation;
      completion.filterText = annotation;
      completion.detail = "function annotation";
      items.push(completion);
    }

    for (const item of asArray(decl.valueDomains)) {
      const label = String(item && item.name ? item.name : "");
      if (!label || (prefix && !label.startsWith(prefix))) {
        continue;
      }
      const completion = new vscode.CompletionItem(label, vscode.CompletionItemKind.TypeParameter);
      completion.insertText = label;
      completion.detail = item.body ? `type = ${String(item.body)}` : "type";
      if (item.refinement) {
        completion.documentation = new vscode.MarkdownString(`refinement: \`${String(item.refinement)}\``);
      }
      items.push(completion);
    }

    for (const item of asArray(decl.classes)) {
      const label = String(item && item.name ? item.name : "");
      if (!label || (prefix && !label.startsWith(prefix))) {
        continue;
      }
      const completion = new vscode.CompletionItem(label, vscode.CompletionItemKind.Class);
      completion.insertText = label;
      completion.detail = item.base ? `object class, base ${String(item.base)}` : "object class";
      items.push(completion);
    }

    for (const item of asArray(decl.roles)) {
      const label = String(item && item.name ? item.name : "");
      if (!label || (prefix && !label.startsWith(prefix))) {
        continue;
      }
      const completion = new vscode.CompletionItem(label, vscode.CompletionItemKind.EnumMember);
      completion.insertText = label;
      completion.detail = item.class ? `role: ${String(item.class)}` : "role";
      items.push(completion);
    }

    return items;
  }

  function declarationHover(payload, target) {
    const decl = declarations(payload);
    const markdown = new vscode.MarkdownString();

    for (const item of asArray(decl.classes)) {
      if (String(item && item.name ? item.name : "") !== target) {
        continue;
      }
      markdown.appendCodeblock(`type ${target} = object { ... }`, "ss");
      if (item.base) {
        markdown.appendMarkdown(`base: \`${String(item.base)}\``);
      } else {
        markdown.appendMarkdown("object class");
      }
      return new vscode.Hover(markdown);
    }

    for (const item of asArray(decl.valueDomains)) {
      if (String(item && item.name ? item.name : "") !== target) {
        continue;
      }
      markdown.appendCodeblock(`type ${target} = ${String(item.body || "unknown")}`, "ss");
      if (item.refinement) {
        markdown.appendMarkdown(`refinement: \`${String(item.refinement)}\``);
      }
      return new vscode.Hover(markdown);
    }

    for (const item of asArray(decl.roles)) {
      if (String(item && item.name ? item.name : "") !== target) {
        continue;
      }
      markdown.appendCodeblock(target, "ss");
      markdown.appendMarkdown(item.class ? `role of \`${String(item.class)}\`` : "role");
      return new vscode.Hover(markdown);
    }

    const field = uniqueFields(asArray(decl.fields)).find((item) => String(item && item.name ? item.name : "") === target);
    if (field) {
      const type = field.type ? String(field.type) : "unknown";
      markdown.appendCodeblock(`${target}: ${type}`, "ss");
      if (field.class) {
        markdown.appendMarkdown(`declared on: \`${String(field.class)}\``);
      }
      if (field.default !== undefined && field.default !== null) {
        if (markdown.value) {
          markdown.appendText("\n\n");
        }
        markdown.appendMarkdown(`default: \`${String(field.default)}\``);
      }
      return new vscode.Hover(markdown);
    }

    return null;
  }

  const cssNamedColors = new Map([
    ["black", [0, 0, 0]],
    ["white", [1, 1, 1]],
    ["red", [1, 0, 0]],
    ["green", [0, 128 / 255, 0]],
    ["lime", [0, 1, 0]],
    ["blue", [0, 0, 1]],
    ["yellow", [1, 1, 0]],
    ["cyan", [0, 1, 1]],
    ["aqua", [0, 1, 1]],
    ["magenta", [1, 0, 1]],
    ["fuchsia", [1, 0, 1]],
    ["gray", [128 / 255, 128 / 255, 128 / 255]],
    ["grey", [128 / 255, 128 / 255, 128 / 255]],
    ["silver", [192 / 255, 192 / 255, 192 / 255]],
    ["maroon", [128 / 255, 0, 0]],
    ["olive", [128 / 255, 128 / 255, 0]],
    ["purple", [128 / 255, 0, 128 / 255]],
    ["teal", [0, 128 / 255, 128 / 255]],
    ["navy", [0, 0, 128 / 255]],
    ["orange", [1, 165 / 255, 0]],
  ]);

  function parseSsColorLiteral(raw) {
    const match = /^c"((?:\\.|[^"\\])*)"$/.exec(raw.trim());
    if (!match) {
      return null;
    }
    let inner;
    try {
      inner = JSON.parse(`"${match[1]}"`);
    } catch {
      inner = match[1];
    }
    return parseSsColor(inner);
  }

  function parseSsColor(raw) {
    const text = String(raw || "").trim();
    if (!text) {
      return null;
    }
    if (text.startsWith("#")) {
      return parseHexColor(text.slice(1));
    }
    if (text.includes(",")) {
      const parts = text.split(",").map((part) => Number(part.trim()));
      if (parts.length !== 3 || parts.some((value) => !Number.isFinite(value) || value < 0 || value > 1)) {
        return null;
      }
      return parts;
    }
    return cssNamedColors.get(text.toLowerCase()) || null;
  }

  function parseHexColor(hex) {
    if (![3, 4, 6, 8].includes(hex.length) || /[^0-9a-fA-F]/.test(hex)) {
      return null;
    }
    if (hex.length === 3 || hex.length === 4) {
      return [
        parseInt(hex[0] + hex[0], 16) / 255,
        parseInt(hex[1] + hex[1], 16) / 255,
        parseInt(hex[2] + hex[2], 16) / 255,
      ];
    }
    return [
      parseInt(hex.slice(0, 2), 16) / 255,
      parseInt(hex.slice(2, 4), 16) / 255,
      parseInt(hex.slice(4, 6), 16) / 255,
    ];
  }

  function colorToHex(color) {
    const toByte = (value) => Math.max(0, Math.min(255, Math.round(value * 255)));
    const toHex = (value) => toByte(value).toString(16).padStart(2, "0");
    return `#${toHex(color.red)}${toHex(color.green)}${toHex(color.blue)}`;
  }

  const colorProvider = {
    provideDocumentColors(document, token) {
      if (document.languageId !== "ss-slide" || token.isCancellationRequested) {
        return [];
      }
      const text = document.getText();
      const colors = [];
      const pattern = /c"(?:\\.|[^"\\])*"/g;
      let match;
      while ((match = pattern.exec(text)) !== null) {
        const rgb = parseSsColorLiteral(match[0]);
        if (!rgb) {
          continue;
        }
        const range = new vscode.Range(document.positionAt(match.index), document.positionAt(match.index + match[0].length));
        colors.push(new vscode.ColorInformation(range, new vscode.Color(rgb[0], rgb[1], rgb[2], 1)));
      }
      return colors;
    },
    provideColorPresentations(color) {
      const hex = colorToHex(color);
      return [
        new vscode.ColorPresentation(`c"${hex}"`),
        new vscode.ColorPresentation(`c"${Number(color.red.toFixed(4))},${Number(color.green.toFixed(4))},${Number(color.blue.toFixed(4))}"`),
      ];
    },
  };

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

  function projectRootMarkerIn(text) {
    return String(text || "")
      .split(/\r?\n/, 12)
      .some((line) => /^\s*;;\s*!root\b/.test(line));
  }

  async function fileHasProjectRootMarker(filePath) {
    try {
      const handle = await fs.promises.open(filePath, "r");
      try {
        const buffer = Buffer.alloc(2048);
        const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
        return projectRootMarkerIn(buffer.slice(0, bytesRead).toString("utf8"));
      } finally {
        await handle.close();
      }
    } catch {
      return false;
    }
  }

  async function findProjectRootPath(document) {
    if (!document || document.uri.scheme !== "file") {
      return null;
    }
    if (projectRootMarkerIn(document.getText())) {
      return document.uri.fsPath;
    }

    const workspaceFolder = vscode.workspace.getWorkspaceFolder(document.uri);
    const stopDir = workspaceFolder && workspaceFolder.uri ? workspaceFolder.uri.fsPath : path.parse(document.uri.fsPath).root;
    let dir = path.dirname(document.uri.fsPath);
    while (true) {
      let entries = [];
      try {
        entries = await fs.promises.readdir(dir, { withFileTypes: true });
      } catch {}
      const candidates = entries
        .filter((entry) => entry.isFile() && entry.name.endsWith(".ss"))
        .map((entry) => path.join(dir, entry.name))
        .sort((a, b) => {
          if (a === document.uri.fsPath) return -1;
          if (b === document.uri.fsPath) return 1;
          return path.basename(a).localeCompare(path.basename(b));
        });
      for (const candidate of candidates) {
        if (await fileHasProjectRootMarker(candidate)) {
          return candidate;
        }
      }

      if (path.resolve(dir) === path.resolve(stopDir)) {
        break;
      }
      const parent = path.dirname(dir);
      if (parent === dir) {
        break;
      }
      dir = parent;
    }
    return null;
  }

  async function projectContext(document) {
    const rootPath = await findProjectRootPath(document);
    const entryPath = rootPath || (document && document.uri && document.uri.scheme === "file" ? document.uri.fsPath : null);
    const projectDir = entryPath ? path.dirname(entryPath) : commandCwd(document);
    return { entryPath, projectDir, hasProjectRoot: Boolean(rootPath) };
  }

  function uniquePaths(paths) {
    const result = [];
    const seen = new Set();
    for (const item of paths) {
      if (!item) {
        continue;
      }
      const normalized = path.resolve(String(item));
      if (seen.has(normalized)) {
        continue;
      }
      seen.add(normalized);
      result.push(normalized);
    }
    return result;
  }

  function definitionSearchRoots(document) {
    const workspaceFolder = vscode.workspace.getWorkspaceFolder(document.uri);
    return uniquePaths([
      workspaceFolder && workspaceFolder.uri && workspaceFolder.uri.fsPath ? workspaceFolder.uri.fsPath : null,
      commandCwd(document),
      context.extensionUri && context.extensionUri.fsPath ? context.extensionUri.fsPath : null,
      context.extensionUri && context.extensionUri.fsPath ? path.resolve(context.extensionUri.fsPath, "..") : null,
      context.extensionUri && context.extensionUri.fsPath ? path.resolve(context.extensionUri.fsPath, "..", "..") : null,
    ]);
  }

  async function fileExists(filePath) {
    try {
      await fs.promises.access(filePath, fs.constants.R_OK);
      return true;
    } catch {
      return false;
    }
  }

  function moduleForDefinition(payload, item) {
    const modules = Array.isArray(payload && payload.modules) ? payload.modules : [];
    const moduleId = item && item.moduleId !== undefined && item.moduleId !== null ? Number(item.moduleId) : null;
    if (moduleId !== null && Number.isFinite(moduleId)) {
      const found = modules.find((module) => Number(module && module.id) === moduleId);
      if (found) {
        return found;
      }
    }

    const moduleSpec = item && item.moduleSpec ? String(item.moduleSpec) : "";
    if (!moduleSpec) {
      return null;
    }
    return modules.find((module) => String(module && module.spec ? module.spec : "") === moduleSpec) || null;
  }

  function stdlibPathFromSpec(moduleSpec) {
    const spec = String(moduleSpec || "");
    if (!spec.startsWith("std:")) {
      return null;
    }
    const name = spec.slice("std:".length);
    if (!name || !/^[A-Za-z0-9_./-]+$/.test(name) || name.split("/").includes("..")) {
      return null;
    }
    return path.join("stdlib", ...name.split("/")) + ".ss";
  }

  async function resolveFileDefinitionUri(document, filePath) {
    const raw = String(filePath || "");
    if (!raw) {
      return null;
    }
    if (path.isAbsolute(raw)) {
      return vscode.Uri.file(raw);
    }

    for (const root of definitionSearchRoots(document)) {
      const candidate = path.join(root, raw);
      if (await fileExists(candidate)) {
        return vscode.Uri.file(candidate);
      }
    }

    const cwd = commandCwd(document);
    return cwd ? vscode.Uri.file(path.join(cwd, raw)) : vscode.Uri.file(raw);
  }

  async function resolveStdlibDefinitionUri(document, moduleSpec) {
    const relativePath = stdlibPathFromSpec(moduleSpec);
    if (!relativePath) {
      return null;
    }
    for (const root of definitionSearchRoots(document)) {
      const candidate = path.join(root, relativePath);
      if (await fileExists(candidate)) {
        return vscode.Uri.file(candidate);
      }
    }
    return null;
  }

  async function cachedModuleDefinitionUri(document, module) {
    const source = module && module.source ? String(module.source) : "";
    if (!source) {
      return null;
    }
    const root = commandCwd(document) || os.tmpdir();
    const cacheDir = path.join(root, ".ss-cache", "vscode-modules");
    const spec = String((module && module.spec) || `module-${module && module.id !== undefined ? module.id : "unknown"}`);
    const safeName = spec.replace(/[^A-Za-z0-9_.-]/g, "_") || "module";
    const filePath = path.join(cacheDir, `${safeName}.ss`);
    await fs.promises.mkdir(cacheDir, { recursive: true });
    await fs.promises.writeFile(filePath, source, "utf8");
    return vscode.Uri.file(filePath);
  }

  async function resolveDefinitionUri(document, payload, item) {
    if (item && item.file) {
      return resolveFileDefinitionUri(document, item.file);
    }

    const module = moduleForDefinition(payload, item);
    if (module && module.path) {
      return resolveFileDefinitionUri(document, module.path);
    }

    const moduleSpec = String((item && item.moduleSpec) || (module && module.spec) || "");
    const stdlibUri = await resolveStdlibDefinitionUri(document, moduleSpec);
    if (stdlibUri) {
      return stdlibUri;
    }

    if (module) {
      return cachedModuleDefinitionUri(document, module);
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
      void (async () => {
        const contextInfo = await projectContext(document);
        const cwd = contextInfo.projectDir || commandCwd(document);
        if (!cwd) {
          resolve(cached ? cached.payload : null);
          return;
        }
        const entryPath = contextInfo.entryPath || document.uri.fsPath;
        const command = cliPath();
        const args = ["dump", entryPath, "--asset-base-dir", contextInfo.projectDir || assetBaseDir(document)];
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
      })().catch((error) => {
        output.appendLine(`[info] failed: ${error.message}`);
        resolve(cached ? cached.payload : null);
      });
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

  function openTextForPath(filePath) {
    const resolved = path.resolve(filePath);
    return vscode.workspace.textDocuments.find(
      (doc) => doc.uri && doc.uri.scheme === "file" && path.resolve(doc.uri.fsPath) === resolved,
    );
  }

  async function sourceTextForPath(filePath) {
    const open = openTextForPath(filePath);
    if (open) {
      return open.getText();
    }
    return fs.promises.readFile(filePath, "utf8");
  }

  function importSpecsFromSource(source) {
    const specs = [];
    const pattern = /^\s*import\s+([^\s;]+)/gm;
    let match;
    while ((match = pattern.exec(source)) !== null) {
      const raw = String(match[1] || "").trim().replace(/^"|"$/g, "");
      if (raw && !raw.startsWith("std:")) {
        specs.push(raw);
      }
    }
    return specs;
  }

  function resolveLocalImport(fromFile, spec) {
    if (path.isAbsolute(spec)) {
      return spec;
    }
    return path.resolve(path.dirname(fromFile), spec);
  }

  async function writeProjectSnapshot(document, contextInfo) {
    if (!contextInfo.entryPath) {
      return null;
    }
    const projectDir = contextInfo.projectDir || path.dirname(contextInfo.entryPath);
    const root = commandCwd(document) || projectDir || os.tmpdir();
    const snapshotDir = path.join(root, ".ss-cache", "vscode-projects", stableHash(contextInfo.entryPath));
    const pathMap = new Map();
    const seen = new Set();

    async function copyModule(filePath) {
      const original = path.resolve(filePath);
      if (seen.has(original)) {
        return;
      }
      seen.add(original);

      const source = await sourceTextForPath(original);
      const relative = path.relative(projectDir, original);
      const safeRelative = relative && !relative.startsWith("..") && !path.isAbsolute(relative)
        ? relative
        : path.join("__external", stableHash(original), path.basename(original));
      const snapshotPath = path.join(snapshotDir, safeRelative);
      await fs.promises.mkdir(path.dirname(snapshotPath), { recursive: true });
      await fs.promises.writeFile(snapshotPath, source, "utf8");
      pathMap.set(path.resolve(snapshotPath), original);

      for (const spec of importSpecsFromSource(source)) {
        await copyModule(resolveLocalImport(original, spec));
      }
    }

    await copyModule(contextInfo.entryPath);
    const relativeEntry = path.relative(projectDir, path.resolve(contextInfo.entryPath));
    const snapshotEntry = path.join(snapshotDir, relativeEntry && !relativeEntry.startsWith("..") ? relativeEntry : path.basename(contextInfo.entryPath));
    return { entryPath: snapshotEntry, dir: snapshotDir, pathMap };
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

  function diagnosticOriginalPath(rawPath, pathMap) {
    const resolved = path.resolve(String(rawPath || ""));
    return (pathMap && pathMap.get(resolved)) || resolved;
  }

  function diagnosticRange(filePath, lineNumber, columnNumber) {
    const open = openTextForPath(filePath);
    const zeroLine = Math.max(0, lineNumber - 1);
    const zeroColumn = Math.max(0, columnNumber - 1);
    if (!open || zeroLine >= open.lineCount) {
      return new vscode.Range(
        new vscode.Position(zeroLine, zeroColumn),
        new vscode.Position(zeroLine, zeroColumn + 1),
      );
    }
    const lineText = open.lineAt(zeroLine).text;
    const column = Math.min(lineText.length, zeroColumn);
    const endColumn = lineText.length > column ? lineText.length : column + 1;
    return new vscode.Range(
      new vscode.Position(zeroLine, column),
      new vscode.Position(zeroLine, endColumn),
    );
  }

  function parseCliDiagnosticsByFile(fallbackDocument, stdout, stderr, pathMap) {
    const diagnosticsByUri = new Map();
    const seen = new Set();
    const text = stripAnsi(`${stderr || ""}\n${stdout || ""}`);
    const lines = text.split(/\r?\n/);

    for (const line of lines) {
      let match = /^(ERROR|WARNING):\s+(.*):(\d+):(\d+):\s+(.*)$/.exec(line);
      let severityText;
      let filePath;
      let lineNumber;
      let columnNumber;
      let message;

      if (match) {
        severityText = match[1];
        filePath = match[2];
        lineNumber = Number(match[3]);
        columnNumber = Number(match[4]);
        message = match[5];
      } else {
        match = /^(.*):(\d+):(\d+):\s+(error|warning):\s+(.*)$/i.exec(line);
        if (!match) {
          continue;
        }
        severityText = match[4].toUpperCase();
        filePath = match[1];
        lineNumber = Number(match[2]);
        columnNumber = Number(match[3]);
        message = match[5];
      }

      const originalPath = path.isAbsolute(filePath)
        ? diagnosticOriginalPath(filePath, pathMap)
        : (fallbackDocument && fallbackDocument.uri.scheme === "file" ? fallbackDocument.uri.fsPath : filePath);
      const range = diagnosticRange(originalPath, lineNumber, columnNumber);
      const diagnostic = new vscode.Diagnostic(
        range,
        message,
        severityText === "WARNING" ? vscode.DiagnosticSeverity.Warning : vscode.DiagnosticSeverity.Error,
      );
      const uri = vscode.Uri.file(originalPath);
      const key = `${uri.toString()}:${severityText}:${lineNumber}:${columnNumber}:${message}`;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      diagnostic.source = "ss";
      const uriKey = uri.toString();
      const diagnostics = diagnosticsByUri.get(uriKey) || [];
      diagnostics.push(diagnostic);
      diagnosticsByUri.set(uriKey, diagnostics);
    }

    return diagnosticsByUri;
  }

  function publishDiagnostics(fallbackDocument, diagnosticsByUri) {
    diagnosticCollection.clear();
    if (diagnosticsByUri.size === 0 && fallbackDocument) {
      diagnosticCollection.set(fallbackDocument.uri, []);
      return 0;
    }
    let count = 0;
    for (const [uriText, diagnostics] of diagnosticsByUri.entries()) {
      diagnosticCollection.set(vscode.Uri.parse(uriText), diagnostics);
      count += diagnostics.length;
    }
    return count;
  }

  async function refreshDiagnostics(document) {
    if (!document || document.languageId !== "ss-slide" || document.uri.scheme !== "file") {
      return;
    }

    const contextInfo = await projectContext(document);
    const snapshot = await writeProjectSnapshot(document, contextInfo);
    const entryPath = snapshot ? snapshot.entryPath : contextInfo.entryPath || document.uri.fsPath;
    const baseDir = contextInfo.projectDir || assetBaseDir(document);
    if (!entryPath) {
      return;
    }

    try {
      const result = await runSs(document, ["check", entryPath, "--asset-base-dir", baseDir], "diagnostics", "diagnostics");
      const diagnosticsByUri = parseCliDiagnosticsByFile(document, result.stdout, result.stderr, snapshot && snapshot.pathMap);
      const diagnosticCount = publishDiagnostics(document, diagnosticsByUri);
      if (result.error && diagnosticCount === 0) {
        output.appendLine(`[diagnostics] failed: ${result.error.message}`);
        if (result.stderr.trim().length > 0) output.appendLine(result.stderr.trimEnd());
        if (result.stdout.trim().length > 0) output.appendLine(result.stdout.trimEnd());
      } else {
        output.appendLine(`[diagnostics] ${diagnosticCount} diagnostics`);
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

    const contextInfo = await projectContext(document);
    const snapshot = await writeProjectSnapshot(document, contextInfo);
    const entryPath = snapshot ? snapshot.entryPath : contextInfo.entryPath || document.uri.fsPath;
    const baseDir = contextInfo.projectDir || assetBaseDir(document);
    if (!entryPath) {
      return;
    }

    const { dir, pdf, tempPdf } = previewOutputPath(document, renderId);
    await fs.promises.mkdir(dir, { recursive: true });

    try {
      const result = await runSs(document, ["render", entryPath, tempPdf, "--asset-base-dir", baseDir], "preview", "preview");
      const latestSession = previewSessions.get(key);
      if (!latestSession || latestSession.renderId !== renderId) {
        await removeFileIfExists(tempPdf);
        return;
      }

      const diagnosticsByUri = parseCliDiagnosticsByFile(document, result.stdout, result.stderr, snapshot && snapshot.pathMap);
      publishDiagnostics(document, diagnosticsByUri);
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
          return fieldCompletionItems(payload, propertyContext.objectName, propertyContext.prefix);
        }

        const items = declarationCompletionItems(payload, prefix);
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
          const sourceLabel = formatFunctionSource(item);
          if (sourceLabel) {
            completion.detail = `${completion.detail ? `${completion.detail}\n` : ""}[${sourceLabel}]`;
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

      return queryEditorInfo(document).then(async (payload) => {
        if (!payload || !payload.definitions || token.isCancellationRequested) {
          return null;
        }

        for (const item of payload.definitions) {
          if (String(item && item.name ? item.name : "") !== target) {
            continue;
          }
          const line = Math.max(0, Number(item.line || 1) - 1);
          const column = Math.max(0, Number(item.column || 1) - 1);
          const length = Math.max(1, Number(item.length || target.length || 1));
          const definitionUri = (await resolveDefinitionUri(document, payload, item)) || document.uri;
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
        if (!payload || token.isCancellationRequested) {
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
          if (item.moduleSpec) {
            markdown.appendText(`\nmodule: ${String(item.moduleSpec)}`);
          }
          if (item.file) {
            markdown.appendText(`\nfile: ${String(item.file)}`);
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
        return declarationHover(payload, target);
      });
    },
  };

  context.subscriptions.push(
    vscode.languages.registerInlayHintsProvider({ language: "ss-slide" }, provider),
  );
  context.subscriptions.push(
    vscode.languages.registerCompletionItemProvider({ language: "ss-slide" }, provider, ".", "\"", "@"),
  );
  context.subscriptions.push(
    vscode.languages.registerHoverProvider({ language: "ss-slide" }, provider),
  );
  context.subscriptions.push(
    vscode.languages.registerDefinitionProvider({ language: "ss-slide" }, provider),
  );
  context.subscriptions.push(
    vscode.languages.registerColorProvider({ language: "ss-slide" }, colorProvider),
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
