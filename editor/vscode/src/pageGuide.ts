import * as vscode from "vscode";
import { onDidChangeProjectSettings, PageGuideSettings, projectSettings } from "./projectConfig";

type BlockKind = "page" | "other";

type BlockFrame = {
  kind: BlockKind;
  line: number;
};

type PageRange = {
  start: vscode.Range;
  body: vscode.Range[];
  end?: vscode.Range;
};

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

type ScanState = {
  inChevronBlock: boolean;
  inDoubleString: boolean;
};

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

  constructor() {
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
    if (editor.document.languageId !== "ss-slide") {
      this.clearEditor(editor);
      return;
    }
    const settings = (await projectSettings(editor.document.uri))?.pageGuide;
    if (this.disposed || this.refreshes.get(editor) !== revision) return;
    if (!settings) {
      this.clearEditor(editor);
      return;
    }
    const configuredPalette = vscode.workspace.getConfiguration("ss").get<string>("pageGuide.palette", "classic");
    const paletteName = isPagePaletteName(configuredPalette) ? configuredPalette : "classic";
    const palette = pagePalettes[paletteName];
    this.rebuildDecorations(settings, palette, paletteName);
    if (!settings.enabled) {
      this.clearEditor(editor);
      return;
    }

    const buckets = computePageDecorationBuckets(editor.document, palette.length);
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

function computePageDecorationBuckets(document: vscode.TextDocument, colorCount: number): DecorationBuckets {
  const pages = computePageRanges(document);
  const buckets: DecorationBuckets = {
    bodies: Array.from({ length: colorCount }, () => []),
    starts: Array.from({ length: colorCount }, () => []),
    ends: Array.from({ length: colorCount }, () => []),
  };

  pages.forEach((page, index) => {
    const bucket = index % colorCount;
    buckets.bodies[bucket].push(...page.body);
    buckets.starts[bucket].push(page.start);
    if (page.end) buckets.ends[bucket].push(page.end);
  });

  return buckets;
}

function computePageRanges(document: vscode.TextDocument): PageRange[] {
  const pages: PageRange[] = [];
  const stack: BlockFrame[] = [];
  const scan: ScanState = { inChevronBlock: false, inDoubleString: false };

  for (let line = 0; line < document.lineCount; line += 1) {
    const visibleText = codeTextForBlockScan(document.lineAt(line).text, scan);
    const blockStart = blockStartKind(visibleText);
    if (blockStart === "page") {
      // Pages are top-level declarations. Recover at the next page while an
      // earlier block is incomplete, keeping every page in the color sequence.
      const previous = stack.find((block) => block.kind === "page");
      if (previous) pages.push(pageRange(document, previous.line, line - 1, false));
      stack.length = 0;
    }
    if (blockStart) {
      stack.push({ kind: blockStart, line });
      continue;
    }

    if (!isBlockEnd(visibleText) || stack.length === 0) {
      continue;
    }

    const block = stack.pop();
    if (block?.kind !== "page") {
      continue;
    }

    pages.push(pageRange(document, block.line, line));
  }

  const unfinished = stack.find((block) => block.kind === "page");
  if (unfinished) pages.push(pageRange(document, unfinished.line, document.lineCount - 1, false));
  return pages;
}

function pageRange(document: vscode.TextDocument, startLine: number, endLine: number, closed = true): PageRange {
  const body: vscode.Range[] = [];
  for (let line = startLine; line <= endLine; line += 1) {
    body.push(document.lineAt(line).range);
  }

  return {
    start: document.lineAt(startLine).range,
    body,
    end: closed ? document.lineAt(endLine).range : undefined,
  };
}

function codeTextForBlockScan(lineText: string, state: ScanState): string {
  let index = 0;
  if (state.inChevronBlock) {
    // The delimiter closes at the first non-space characters; its suffix is
    // ordinary source and can include another block string on the same line.
    const closing = /^[ \t\r]*>>/.exec(lineText);
    if (!closing) return "";
    state.inChevronBlock = false;
    index = closing[0].length;
  }

  let out = "";
  while (index < lineText.length) {
    if (state.inDoubleString) {
      const closing = lineText.indexOf("\"", index);
      if (closing < 0) {
        return out;
      }
      state.inDoubleString = false;
      index = closing + 1;
      continue;
    }
    if (lineText.startsWith("<<", index) && /^<<[ \t\r]*(?:;;.*)?$/.test(lineText.slice(index))) {
      state.inChevronBlock = true;
      break;
    }
    if (lineText.startsWith(";;", index)) {
      break;
    }
    if (lineText[index] === "\"") {
      state.inDoubleString = true;
      index += 1;
      continue;
    }

    out += lineText[index];
    index += 1;
  }

  return out;
}

function blockStartKind(lineText: string): BlockKind | undefined {
  const trimmed = lineText.trimStart();
  if (startsBlockKeyword(trimmed, "page")) {
    return "page";
  }
  if (startsBlockKeyword(trimmed, "document")) {
    return "other";
  }
  if (startsFunctionBlock(trimmed)) {
    return "other";
  }
  if (startsBlockKeyword(trimmed, "if") || startsBlockKeyword(trimmed, "show")) {
    return "other";
  }
  return undefined;
}

function startsFunctionBlock(trimmed: string): boolean {
  return /^fn(?:\/!?|!?)(?=\s|\(|$)/.test(trimmed);
}

function startsBlockKeyword(trimmed: string, keyword: string): boolean {
  if (!trimmed.startsWith(keyword)) {
    return false;
  }
  const next = trimmed[keyword.length];
  return next === undefined || /\s|\(|"/.test(next);
}

function isBlockEnd(lineText: string): boolean {
  return /^\s*end\s*$/.test(lineText);
}
