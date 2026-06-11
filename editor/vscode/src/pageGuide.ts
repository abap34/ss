import * as vscode from "vscode";

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
  private readonly bodyDecorations: vscode.TextEditorDecorationType[];
  private readonly startDecorations: vscode.TextEditorDecorationType[];
  private readonly endDecorations: vscode.TextEditorDecorationType[];

  constructor() {
    this.bodyDecorations = pagePalette.map((entry) => vscode.window.createTextEditorDecorationType({
      isWholeLine: true,
      backgroundColor: entry.background,
      gutterIconPath: pageGuideIconUri(entry.icon),
      gutterIconSize: "contain",
      overviewRulerColor: entry.ruler,
      overviewRulerLane: vscode.OverviewRulerLane.Left,
      rangeBehavior: vscode.DecorationRangeBehavior.ClosedClosed,
    }));
    this.startDecorations = pagePalette.map((entry) => vscode.window.createTextEditorDecorationType({
      isWholeLine: true,
      backgroundColor: entry.boundaryBackground,
      borderColor: entry.boundary,
      borderStyle: "solid",
      borderWidth: "2px 0 0 0",
      rangeBehavior: vscode.DecorationRangeBehavior.ClosedClosed,
    }));
    this.endDecorations = pagePalette.map((entry) => vscode.window.createTextEditorDecorationType({
      isWholeLine: true,
      backgroundColor: entry.boundaryBackground,
      borderColor: entry.boundary,
      borderStyle: "solid",
      borderWidth: "0 0 2px 0",
      rangeBehavior: vscode.DecorationRangeBehavior.ClosedClosed,
    }));

    this.disposables.push(
      ...this.bodyDecorations,
      ...this.startDecorations,
      ...this.endDecorations,
      vscode.workspace.onDidChangeTextDocument((event) => this.refreshDocument(event.document)),
      vscode.workspace.onDidSaveTextDocument((document) => this.refreshDocument(document)),
      vscode.window.onDidChangeActiveTextEditor((editor) => this.refreshEditor(editor)),
      vscode.window.onDidChangeVisibleTextEditors(() => this.refreshVisibleEditors()),
    );

    this.refreshVisibleEditors();
  }

  dispose(): void {
    for (const disposable of this.disposables) {
      disposable.dispose();
    }
    this.disposables.length = 0;
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
    if (editor.document.languageId !== "ss-slide") {
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
  const scan: ScanState = { inChevronBlock: false, inTripleString: false };

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
      index = skipDoubleQuotedString(lineText, index + 1);
      continue;
    }

    out += lineText[index];
    index += 1;
  }

  return out;
}

function skipDoubleQuotedString(lineText: string, index: number): number {
  for (let pos = index; pos < lineText.length; pos += 1) {
    if (lineText[pos] === "\\") {
      pos += 1;
      continue;
    }
    if (lineText[pos] === "\"") {
      return pos + 1;
    }
  }
  return lineText.length;
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
