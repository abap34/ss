import * as vscode from "vscode";
import { LanguageClient, LanguageClientOptions, Middleware, ServerOptions, Trace } from "vscode-languageclient/node";
import { PageGuideDecorations } from "./pageGuide";
import { initializeProjectSettings, onDidChangeProjectSettings, projectSettings, ProjectSettingsResponse, setProjectSettingsProvider } from "./projectConfig";
import { EditorController } from "./editor/controller";

let client: LanguageClient | undefined;
let pageGuide: PageGuideDecorations | undefined;
let editorController: EditorController | undefined;
let outputChannel: vscode.OutputChannel | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  context.subscriptions.push(initializeProjectSettings());
  const output = vscode.window.createOutputChannel("ss");
  outputChannel = output;
  context.subscriptions.push(onDidChangeProjectSettings((files) => {
    if (files.length === 0 || !client?.isRunning()) return;
    void client.sendNotification("workspace/didChangeWatchedFiles", {
      changes: files.map((file) => ({ uri: vscode.Uri.file(file).toString(), type: 2 })),
    }).catch((error) => output.appendLine(`Project settings notification failed: ${String(error)}`));
  }));
  pageGuide = new PageGuideDecorations();
  editorController = new EditorController(context, output, () => client);

  context.subscriptions.push(output, pageGuide, editorController);
  context.subscriptions.push(vscode.commands.registerCommand("ss.editor.open", () =>
    editorController?.open(vscode.window.activeTextEditor?.document)
  ));
  context.subscriptions.push(vscode.commands.registerCommand("ss.editor.build", () =>
    editorController?.build(vscode.window.activeTextEditor?.document)
  ));
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
  editorController?.dispose();
  editorController = undefined;
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
  const ready = active.start();
  setProjectSettingsProvider(async (projectFile) => {
    await ready;
    return active.sendRequest<ProjectSettingsResponse>("ss/projectSettings", { projectFile });
  }, (message) => outputChannel?.appendLine(message));
  await ready;
}

async function stopLanguageClient(): Promise<void> {
  const active = client;
  client = undefined;
  setProjectSettingsProvider(undefined);
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

function createMiddleware(): Middleware {
  return {
    provideCompletionItem: async (document, position, context, token, next) =>
      (await featureEnabled(document, "completion", token)) ? next(document, position, context, token) : undefined,
    provideHover: async (document, position, token, next) =>
      (await featureEnabled(document, "hover", token)) ? next(document, position, token) : null,
    provideDefinition: async (document, position, token, next) =>
      (await featureEnabled(document, "definition", token)) ? next(document, position, token) : null,
    provideDocumentSymbols: async (document, token, next) =>
      (await featureEnabled(document, "documentSymbols", token)) ? next(document, token) : [],
    provideFoldingRanges: async (document, context, token, next) =>
      (await featureEnabled(document, "foldingRanges", token)) ? next(document, context, token) : [],
    provideDocumentSemanticTokens: async (document, token, next) =>
      (await featureEnabled(document, "semanticTokens", token)) ? next(document, token) : undefined,
    provideDocumentSemanticTokensEdits: async (document, previousResultId, token, next) =>
      (await featureEnabled(document, "semanticTokens", token)) ? next(document, previousResultId, token) : undefined,
    provideDocumentColors: async (document, token, next) =>
      (await featureEnabled(document, "colors", token)) ? next(document, token) : [],
    provideColorPresentations: async (color, context, token, next) =>
      (await featureEnabled(context.document, "colors", token)) ? next(color, context, token) : [],
  };
}

type LspFeatureName =
  "completion" |
  "hover" |
  "definition" |
  "documentSymbols" |
  "foldingRanges" |
  "semanticTokens" |
  "colors";

async function featureEnabled(document: vscode.TextDocument, feature: LspFeatureName, token: vscode.CancellationToken): Promise<boolean> {
  const settings = (await projectSettings(document.uri))?.lsp;
  return !token.isCancellationRequested && Boolean(settings?.enabled && settings[feature]);
}
