import * as vscode from "vscode";
import { onDidChangeProjectSettings, PageGuideSettings, projectSettings } from "./projectConfig";
import { withRequestDeadline } from "./editor/request";

export interface PageRangesResponse {
  readonly version: number | null;
  readonly pages: readonly { readonly startLine: number; readonly endLine: number }[] | null;
}

type PageRangesProvider = (document: vscode.TextDocument, token: vscode.CancellationToken) =>
  Promise<PageRangesResponse | null | undefined>;

type DecorationBuckets = {
  bodies: vscode.Range[][];
  starts: vscode.Range[][];
  ends: vscode.Range[][];
};

type PaletteEntry = {
  icon: string;
  ruler: string;
  background: string;
  boundary: string;
  boundaryBackground: string;
};

type PagePaletteName = "classic" | "lilac-ember" | "teal-peach" | "sage-rose" | "meadow";

const pagePalettes: Record<PagePaletteName, PaletteEntry[]> = {
  classic: [
    {
      icon: "#569CD6",
      ruler: "rgba(86, 156, 214, 0.80)",
      background: "rgba(86, 156, 214, 0.075)",
      boundary: "rgba(86, 156, 214, 0.90)",
      boundaryBackground: "rgba(86, 156, 214, 0.15)",
    },
    {
      icon: "#D65A5A",
      ruler: "rgba(214, 90, 90, 0.78)",
      background: "rgba(214, 90, 90, 0.07)",
      boundary: "rgba(214, 90, 90, 0.88)",
      boundaryBackground: "rgba(214, 90, 90, 0.14)",
    },
    {
      icon: "#4CA86A",
      ruler: "rgba(76, 168, 106, 0.78)",
      background: "rgba(76, 168, 106, 0.07)",
      boundary: "rgba(76, 168, 106, 0.88)",
      boundaryBackground: "rgba(76, 168, 106, 0.14)",
    },
    {
      icon: "#D6A84A",
      ruler: "rgba(214, 168, 74, 0.80)",
      background: "rgba(214, 168, 74, 0.075)",
      boundary: "rgba(214, 168, 74, 0.90)",
      boundaryBackground: "rgba(214, 168, 74, 0.15)",
    },
  ],
  "lilac-ember": [softPaletteEntry("#B1A6DC"), softPaletteEntry("#E9A1A9")],
  "teal-peach": [softPaletteEntry("#77C6C1"), softPaletteEntry("#EEAD91")],
  "sage-rose": [softPaletteEntry("#A7C7A5"), softPaletteEntry("#E5A2AC")],
  meadow: [
    softPaletteEntry("#A7C5A0"), softPaletteEntry("#89B9C5"),
    softPaletteEntry("#D5AF9A"), softPaletteEntry("#C1ADD0"),
  ],
};

function softPaletteEntry(icon: string): PaletteEntry {
  const rgb = [1, 3, 5].map((start) => Number.parseInt(icon.slice(start, start + 2), 16)).join(", ");
  return {
    icon,
    ruler: `rgba(${rgb}, 0.82)`,
    background: `rgba(${rgb}, 0.09)`,
    boundary: `rgba(${rgb}, 0.92)`,
    boundaryBackground: `rgba(${rgb}, 0.15)`,
  };
}

function isPagePaletteName(value: unknown): value is PagePaletteName {
  return typeof value === "string" && Object.prototype.hasOwnProperty.call(pagePalettes, value);
}

export class PageGuideDecorations implements vscode.Disposable {
  private readonly disposables: vscode.Disposable[] = [];
  private bodyDecorations: vscode.TextEditorDecorationType[] = [];
  private startDecorations: vscode.TextEditorDecorationType[] = [];
  private endDecorations: vscode.TextEditorDecorationType[] = [];
  private decorationSignature = "";
  private disposed = false;
  private readonly refreshes = new WeakMap<vscode.TextEditor, number>();
  private readonly requests = new Map<vscode.TextEditor, vscode.CancellationTokenSource>();

  constructor(
    private readonly providePageRanges: PageRangesProvider,
    private readonly reportError: (message: string) => void = () => {},
  ) {
    this.disposables.push(
      vscode.workspace.onDidChangeTextDocument((event) => this.refreshDocument(event.document)),
      vscode.workspace.onDidSaveTextDocument((document) => this.refreshDocument(document)),
      vscode.window.onDidChangeActiveTextEditor((editor) => this.refreshEditor(editor)),
      vscode.window.onDidChangeVisibleTextEditors(() => this.refreshVisibleEditors()),
      onDidChangeProjectSettings(() => this.refreshVisibleEditors()),
      vscode.workspace.onDidChangeConfiguration((event) => {
        if (event.affectsConfiguration("ss.pageGuide.palette")) this.refreshVisibleEditors();
      }),
    );

    this.refreshVisibleEditors();
  }

  dispose(): void {
    this.disposed = true;
    for (const request of this.requests.values()) {
      request.cancel();
      request.dispose();
    }
    this.requests.clear();
    this.disposeDecorations();
    for (const disposable of this.disposables) {
      disposable.dispose();
    }
    this.disposables.length = 0;
  }

  private rebuildDecorations(settings: PageGuideSettings, palette: PaletteEntry[], paletteName: PagePaletteName): void {
    const signature = JSON.stringify({ settings, paletteName });
    if (signature === this.decorationSignature) {
      return;
    }
    this.decorationSignature = signature;
    this.disposeDecorations();
    this.bodyDecorations = palette.map((entry) => {
      const options: vscode.DecorationRenderOptions = {
        isWholeLine: true,
        rangeBehavior: vscode.DecorationRangeBehavior.ClosedClosed,
      };
      if (settings.bodyBackground) {
        options.backgroundColor = entry.background;
      }
      if (settings.gutterIcon) {
        options.gutterIconPath = pageGuideIconUri(entry.icon);
        options.gutterIconSize = "contain";
      }
      if (settings.overviewRuler) {
        options.overviewRulerColor = entry.ruler;
        options.overviewRulerLane = vscode.OverviewRulerLane.Left;
      }
      return vscode.window.createTextEditorDecorationType(options);
    });
    this.startDecorations = palette.map((entry) => vscode.window.createTextEditorDecorationType({
      isWholeLine: true,
      backgroundColor: settings.boundaryBackground ? entry.boundaryBackground : undefined,
      borderColor: settings.boundary ? entry.boundary : undefined,
      borderStyle: settings.boundary ? "solid" : undefined,
      borderWidth: settings.boundary ? "2px 0 0 0" : undefined,
      rangeBehavior: vscode.DecorationRangeBehavior.ClosedClosed,
    }));
    this.endDecorations = palette.map((entry) => vscode.window.createTextEditorDecorationType({
      isWholeLine: true,
      backgroundColor: settings.boundaryBackground ? entry.boundaryBackground : undefined,
      borderColor: settings.boundary ? entry.boundary : undefined,
      borderStyle: settings.boundary ? "solid" : undefined,
      borderWidth: settings.boundary ? "0 0 2px 0" : undefined,
      rangeBehavior: vscode.DecorationRangeBehavior.ClosedClosed,
    }));
  }

  private disposeDecorations(): void {
    for (const decoration of [...this.bodyDecorations, ...this.startDecorations, ...this.endDecorations]) {
      decoration.dispose();
    }
    this.bodyDecorations = [];
    this.startDecorations = [];
    this.endDecorations = [];
  }

  private refreshDocument(document: vscode.TextDocument): void {
    for (const editor of vscode.window.visibleTextEditors) {
      if (editor.document.uri.toString() === document.uri.toString()) {
        this.refreshEditor(editor);
      }
    }
  }

  private refreshVisibleEditors(): void {
    for (const editor of vscode.window.visibleTextEditors) {
      this.refreshEditor(editor);
    }
  }

  private async refreshEditor(editor: vscode.TextEditor | undefined): Promise<void> {
    if (!editor || this.disposed) return;
    const revision = (this.refreshes.get(editor) ?? 0) + 1;
    this.refreshes.set(editor, revision);
    this.requests.get(editor)?.cancel();
    if (editor.document.languageId !== "ss-slide") {
      this.clearEditor(editor);
      return;
    }
    const document = editor.document;
    const version = document.version;
    const settings = (await projectSettings(document.uri))?.pageGuide;
    if (this.disposed || this.refreshes.get(editor) !== revision) return;
    if (!settings) return;
    if (!settings.enabled) {
      this.clearEditor(editor);
      return;
    }
    const cancellation = new vscode.CancellationTokenSource();
    this.requests.set(editor, cancellation);
    let response: PageRangesResponse | null | undefined;
    try {
      response = await withRequestDeadline(() => this.providePageRanges(document, cancellation.token), cancellation);
    } catch (error) {
      if (!cancellation.token.isCancellationRequested) this.reportError(`Page guides could not be updated: ${String(error)}`);
      return;
    } finally {
      if (this.requests.get(editor) === cancellation) this.requests.delete(editor);
      cancellation.dispose();
    }
    // VS Code tracks the existing decoration ranges through edits. Keep those
    // ranges while parsing is incomplete or the server is unavailable.
    if (this.disposed || this.refreshes.get(editor) !== revision || editor.document !== document ||
      document.version !== version || response?.version !== version || response.pages === null) return;
    const configuredPalette = vscode.workspace.getConfiguration("ss").get<string>("pageGuide.palette", "classic");
    const paletteName = isPagePaletteName(configuredPalette) ? configuredPalette : "classic";
    const palette = pagePalettes[paletteName];
    this.rebuildDecorations(settings, palette, paletteName);
    const buckets = computePageDecorationBuckets(document, response.pages, palette.length);
    for (let index = 0; index < palette.length; index += 1) {
      editor.setDecorations(this.bodyDecorations[index], buckets.bodies[index]);
      editor.setDecorations(this.startDecorations[index], buckets.starts[index]);
      editor.setDecorations(this.endDecorations[index], buckets.ends[index]);
    }
  }

  private clearEditor(editor: vscode.TextEditor): void {
    for (const decoration of [...this.bodyDecorations, ...this.startDecorations, ...this.endDecorations]) {
      editor.setDecorations(decoration, []);
    }
  }
}

function pageGuideIconUri(fill: string): vscode.Uri {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="24" viewBox="0 0 10 24"><rect x="1" y="0" width="7" height="24" rx="2" fill="${fill}"/></svg>`;
  return vscode.Uri.parse(`data:image/svg+xml;utf8,${encodeURIComponent(svg)}`);
}

function computePageDecorationBuckets(document: vscode.TextDocument, pages: NonNullable<PageRangesResponse["pages"]>, colorCount: number): DecorationBuckets {
  const buckets: DecorationBuckets = {
    bodies: Array.from({ length: colorCount }, () => []),
    starts: Array.from({ length: colorCount }, () => []),
    ends: Array.from({ length: colorCount }, () => []),
  };

  pages.forEach((page, index) => {
    const bucket = index % colorCount;
    buckets.starts[bucket].push(document.lineAt(page.startLine).range);
    for (let line = page.startLine; line <= page.endLine; line++) buckets.bodies[bucket].push(document.lineAt(line).range);
    buckets.ends[bucket].push(document.lineAt(page.endLine).range);
  });

  return buckets;
}
