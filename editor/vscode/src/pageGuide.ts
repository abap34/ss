import * as vscode from "vscode";
import { PageGuideSettings, projectSettings } from "./projectConfig";

type BlockKind = "page" | "other";

type BlockFrame = {
  kind: BlockKind;
  line: number;
};

type PageRange = {
  start: vscode.Range;
  body: vscode.Range[];
  end: vscode.Range;
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

type ScanState = {
  inChevronBlock: boolean;
  inTripleString: boolean;
  inDoubleString: boolean;
};

const pagePalette: PaletteEntry[] = [
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
];

export class PageGuideDecorations implements vscode.Disposable {
  private readonly disposables: vscode.Disposable[] = [];
  private bodyDecorations: vscode.TextEditorDecorationType[] = [];
  private startDecorations: vscode.TextEditorDecorationType[] = [];
  private endDecorations: vscode.TextEditorDecorationType[] = [];
  private decorationSignature = "";

  constructor() {
    this.rebuildDecorations(projectSettings(undefined).pageGuide);
    const projectWatcher = vscode.workspace.createFileSystemWatcher("**/ss.toml");

    this.disposables.push(
      projectWatcher,
      vscode.workspace.onDidChangeTextDocument((event) => this.refreshDocument(event.document)),
      vscode.workspace.onDidSaveTextDocument((document) => this.refreshDocument(document)),
      vscode.window.onDidChangeActiveTextEditor((editor) => this.refreshEditor(editor)),
      vscode.window.onDidChangeVisibleTextEditors(() => this.refreshVisibleEditors()),
      projectWatcher.onDidChange(() => this.refreshVisibleEditors()),
      projectWatcher.onDidCreate(() => this.refreshVisibleEditors()),
      projectWatcher.onDidDelete(() => this.refreshVisibleEditors()),
    );

    this.refreshVisibleEditors();
  }

  dispose(): void {
    this.disposeDecorations();
    for (const disposable of this.disposables) {
      disposable.dispose();
    }
    this.disposables.length = 0;
  }

  private rebuildDecorations(settings: PageGuideSettings): void {
    const signature = JSON.stringify(settings);
    if (signature === this.decorationSignature) {
      return;
    }
    this.decorationSignature = signature;
    this.disposeDecorations();
    this.bodyDecorations = pagePalette.map((entry) => {
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
    this.startDecorations = pagePalette.map((entry) => vscode.window.createTextEditorDecorationType({
      isWholeLine: true,
      backgroundColor: settings.boundaryBackground ? entry.boundaryBackground : undefined,
      borderColor: settings.boundary ? entry.boundary : undefined,
      borderStyle: settings.boundary ? "solid" : undefined,
      borderWidth: settings.boundary ? "2px 0 0 0" : undefined,
      rangeBehavior: vscode.DecorationRangeBehavior.ClosedClosed,
    }));
    this.endDecorations = pagePalette.map((entry) => vscode.window.createTextEditorDecorationType({
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

  private refreshEditor(editor: vscode.TextEditor | undefined): void {
    if (!editor) {
      return;
    }
    const settings = projectSettings(editor.document.uri).pageGuide;
    this.rebuildDecorations(settings);
    if (editor.document.languageId !== "ss-slide" || !settings.enabled) {
      this.clearEditor(editor);
      return;
    }

    const buckets = computePageDecorationBuckets(editor.document, pagePalette.length);
    for (let index = 0; index < pagePalette.length; index += 1) {
      editor.setDecorations(this.bodyDecorations[index], buckets.bodies[index]);
      editor.setDecorations(this.startDecorations[index], buckets.starts[index]);
      editor.setDecorations(this.endDecorations[index], buckets.ends[index]);
    }
  }

  private clearEditor(editor: vscode.TextEditor): void {
    for (let index = 0; index < pagePalette.length; index += 1) {
      editor.setDecorations(this.bodyDecorations[index], []);
      editor.setDecorations(this.startDecorations[index], []);
      editor.setDecorations(this.endDecorations[index], []);
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
    buckets.ends[bucket].push(page.end);
  });

  return buckets;
}

function computePageRanges(document: vscode.TextDocument): PageRange[] {
  const pages: PageRange[] = [];
  const stack: BlockFrame[] = [];
  const scan: ScanState = { inChevronBlock: false, inTripleString: false, inDoubleString: false };

  for (let line = 0; line < document.lineCount; line += 1) {
    const visibleText = codeTextForBlockScan(document.lineAt(line).text, scan);
    const blockStart = blockStartKind(visibleText);
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

  return pages;
}

function pageRange(document: vscode.TextDocument, startLine: number, endLine: number): PageRange {
  const body: vscode.Range[] = [];
  for (let line = startLine; line <= endLine; line += 1) {
    body.push(document.lineAt(line).range);
  }

  return {
    start: document.lineAt(startLine).range,
    body,
    end: document.lineAt(endLine).range,
  };
}

function codeTextForBlockScan(lineText: string, state: ScanState): string {
  if (state.inChevronBlock) {
    if (/^\s*>>\s*(?:(?:;;|\/\/|#).*)?$/.test(lineText)) {
      state.inChevronBlock = false;
    }
    return "";
  }

  let out = "";
  for (let index = 0; index < lineText.length;) {
    if (state.inDoubleString) {
      const closing = lineText.indexOf("\"", index);
      if (closing < 0) {
        return out;
      }
      state.inDoubleString = false;
      index = closing + 1;
      continue;
    }
    if (lineText.startsWith("\"\"\"", index)) {
      state.inTripleString = !state.inTripleString;
      index += 3;
      continue;
    }
    if (state.inTripleString) {
      index += 1;
      continue;
    }
    if (lineText.startsWith("<<", index)) {
      state.inChevronBlock = true;
      break;
    }
    if (lineText.startsWith(";;", index) || lineText.startsWith("//", index) || lineText[index] === "#") {
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
  if (startsBlockKeyword(trimmed, "if")) {
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
