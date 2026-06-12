import * as vscode from "vscode";
import { LanguageClient, LanguageClientOptions, Middleware, ServerOptions, Trace } from "vscode-languageclient/node";
import { PageGuideDecorations } from "./pageGuide";
import { LivePreview } from "./preview";
import { projectSettings } from "./projectConfig";

let client: LanguageClient | undefined;
let pageGuide: PageGuideDecorations | undefined;
let preview: LivePreview | undefined;
let outputChannel: vscode.OutputChannel | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  const output = vscode.window.createOutputChannel("ss");
  outputChannel = output;
  pageGuide = new PageGuideDecorations();
  preview = new LivePreview(context, output, () => client);

  context.subscriptions.push(output, pageGuide, preview);
  context.subscriptions.push(vscode.commands.registerCommand("ss.preview.live", () => {
    preview?.open(vscode.window.activeTextEditor?.document);
  }));
  context.subscriptions.push(vscode.commands.registerCommand("ss.checkCurrentFile", async () => {
    const document = vscode.window.activeTextEditor?.document;
    if (document?.languageId !== "ss-slide") {
      return;
    }
    await document.save();
  }));
  context.subscriptions.push(vscode.workspace.onDidChangeConfiguration((event) => {
    if (event.affectsConfiguration("ss.lsp.trace.server") && client) {
      applyTraceSetting(client);
    }
    if (event.affectsConfiguration("ss.cli.path")) {
      void restartLanguageClient(context);
    }
  }));

  await restartLanguageClient(context);
}

export async function deactivate(): Promise<void> {
  pageGuide?.dispose();
  pageGuide = undefined;
  preview?.dispose();
  preview = undefined;
  await stopLanguageClient();
  outputChannel = undefined;
}

async function restartLanguageClient(context: vscode.ExtensionContext): Promise<void> {
  await stopLanguageClient();
  if (!outputChannel) {
    return;
  }
  const active = createLanguageClient(outputChannel);
  client = active;
  context.subscriptions.push(active);
  await active.start();
}

async function stopLanguageClient(): Promise<void> {
  const active = client;
  client = undefined;
  if (active) {
    await active.stop();
  }
}

function createLanguageClient(output: vscode.OutputChannel): LanguageClient {
  const command = vscode.workspace.getConfiguration("ss").get<string>("cli.path", "ss");
  const serverOptions: ServerOptions = {
    command,
    args: ["lsp"],
    options: {
      cwd: vscode.workspace.workspaceFolders?.[0]?.uri.fsPath,
    },
  };
  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "ss-slide" }],
    outputChannel: output,
    middleware: createMiddleware(),
    synchronize: {
      fileEvents: [
        vscode.workspace.createFileSystemWatcher("**/*.ss"),
        vscode.workspace.createFileSystemWatcher("**/ss.toml"),
      ],
    },
  };

  const active = new LanguageClient("ss", "ss Language Server", serverOptions, clientOptions);
  applyTraceSetting(active);
  return active;
}

function applyTraceSetting(active: LanguageClient): void {
  const setting = vscode.workspace.getConfiguration("ss").get<string>("lsp.trace.server", "off");
  const trace = setting === "verbose" ? Trace.Verbose : setting === "messages" ? Trace.Messages : Trace.Off;
  active.setTrace(trace);
}

type ChangeNext = (event: vscode.TextDocumentChangeEvent) => Promise<void>;

type PendingChange = {
  event: vscode.TextDocumentChangeEvent;
  next: ChangeNext;
};

type PendingChangeQueue = {
  items: PendingChange[];
  timer?: NodeJS.Timeout;
  flushing: boolean;
};

function createMiddleware(): Middleware {
  const pendingChanges = new Map<string, PendingChangeQueue>();

  const flushChanges = async (key: string): Promise<void> => {
    const queue = pendingChanges.get(key);
    if (!queue || queue.flushing) {
      return;
    }
    if (queue.timer) {
      clearTimeout(queue.timer);
      queue.timer = undefined;
    }
    queue.flushing = true;
    try {
      while (queue.items.length !== 0) {
        const item = queue.items.shift();
        if (item) {
          await item.next(item.event);
        }
      }
    } finally {
      queue.flushing = false;
      if (queue.items.length === 0) {
        pendingChanges.delete(key);
      }
    }
  };

  return {
    didChange: (event, next) => {
      const settings = projectSettings(event.document.uri).lsp;
      if (!settings.enabled) {
        return Promise.resolve();
      }
      const delay = settings.changeDebounceMs;
      if (delay === 0) {
        return next(event);
      }
      const key = event.document.uri.toString();
      const queue = pendingChanges.get(key) ?? { items: [], flushing: false };
      queue.items.push({ event, next });
      if (queue.timer) {
        clearTimeout(queue.timer);
      }
      queue.timer = setTimeout(() => {
        void flushChanges(key);
      }, delay);
      pendingChanges.set(key, queue);
      return Promise.resolve();
    },
    didSave: async (document, next) => {
      await flushChanges(document.uri.toString());
      await next(document);
    },
    didClose: async (document, next) => {
      await flushChanges(document.uri.toString());
      await next(document);
      pendingChanges.delete(document.uri.toString());
    },
    handleDiagnostics: (uri, diagnostics, next) => {
      const settings = projectSettings(uri).lsp;
      next(uri, settings.enabled && settings.diagnostics ? diagnostics : []);
    },
    provideCompletionItem: (document, position, context, token, next) =>
      featureEnabled(document, "completion") ? next(document, position, context, token) : undefined,
    provideHover: (document, position, token, next) =>
      featureEnabled(document, "hover") ? next(document, position, token) : null,
    provideDefinition: (document, position, token, next) =>
      featureEnabled(document, "definition") ? next(document, position, token) : null,
    provideInlayHints: (document, viewPort, token, next) =>
      inlayHintsEnabled(document) ? filterInlayHints(document, next(document, viewPort, token)) : [],
    provideDocumentSymbols: (document, token, next) =>
      featureEnabled(document, "documentSymbols") ? next(document, token) : [],
    provideFoldingRanges: (document, context, token, next) =>
      featureEnabled(document, "foldingRanges") ? next(document, context, token) : [],
    provideDocumentSemanticTokens: (document, token, next) =>
      featureEnabled(document, "semanticTokens") ? next(document, token) : undefined,
    provideDocumentSemanticTokensEdits: (document, previousResultId, token, next) =>
      featureEnabled(document, "semanticTokens") ? next(document, previousResultId, token) : undefined,
    provideDocumentColors: (document, token, next) =>
      featureEnabled(document, "colors") ? next(document, token) : [],
    provideColorPresentations: (color, context, token, next) =>
      featureEnabled(context.document, "colors") ? next(color, context, token) : [],
  };
}

type LspFeatureName =
  "completion" |
  "hover" |
  "definition" |
  "inlayHints" |
  "documentSymbols" |
  "foldingRanges" |
  "semanticTokens" |
  "colors";

function featureEnabled(document: vscode.TextDocument, feature: LspFeatureName): boolean {
  const settings = projectSettings(document.uri).lsp;
  return settings.enabled && settings[feature];
}

function inlayHintsEnabled(document: vscode.TextDocument): boolean {
  const settings = projectSettings(document.uri).lsp;
  return settings.enabled && settings.inlayHints && (settings.inlayHintArguments || settings.inlayHintPositions);
}

async function filterInlayHints(
  document: vscode.TextDocument,
  value: vscode.ProviderResult<vscode.InlayHint[]>,
): Promise<vscode.InlayHint[]> {
  const hints = await Promise.resolve(value);
  if (!hints) {
    return [];
  }
  const settings = projectSettings(document.uri).lsp;
  return hints.filter((hint) => {
    if (hint.kind === vscode.InlayHintKind.Parameter) {
      return settings.inlayHintArguments;
    }
    if (hint.kind === vscode.InlayHintKind.Type) {
      return settings.inlayHintPositions;
    }
    return true;
  });
}
