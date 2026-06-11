import * as vscode from "vscode";
import { LanguageClient, LanguageClientOptions, ServerOptions, Trace } from "vscode-languageclient/node";
import { PageGuideDecorations } from "./pageGuide";
import { LivePreview } from "./preview";

let client: LanguageClient | undefined;
let pageGuide: PageGuideDecorations | undefined;
let preview: LivePreview | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  const output = vscode.window.createOutputChannel("ss");
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
    synchronize: {
      fileEvents: [
        vscode.workspace.createFileSystemWatcher("**/*.ss"),
        vscode.workspace.createFileSystemWatcher("**/ss.toml"),
      ],
    },
  };

  client = new LanguageClient("ss", "ss Language Server", serverOptions, clientOptions);
  applyTraceSetting(client);
  pageGuide = new PageGuideDecorations();
  preview = new LivePreview(context, output, () => client);

  context.subscriptions.push(output, client, pageGuide, preview);
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
  }));

  await client.start();
}

export async function deactivate(): Promise<void> {
  pageGuide?.dispose();
  pageGuide = undefined;
  preview?.dispose();
  preview = undefined;
  const active = client;
  client = undefined;
  if (active) {
    await active.stop();
  }
}

function applyTraceSetting(active: LanguageClient): void {
  const setting = vscode.workspace.getConfiguration("ss").get<string>("lsp.trace.server", "off");
  const trace = setting === "verbose" ? Trace.Verbose : setting === "messages" ? Trace.Messages : Trace.Off;
  active.setTrace(trace);
}
