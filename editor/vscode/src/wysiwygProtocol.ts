export type ClientProvider = () => import("vscode-languageclient/node").LanguageClient | undefined;

export interface PreviewSnapshot {
  schemaVersion: 1;
  snapshotId: string;
  entryUri: string;
  documentVersion: number | null;
  coordinateSpace: CoordinateSpace;
  pages: PreviewPage[];
  objects: PreviewObject[];
  relations: PreviewRelation[];
  display: HtmlDisplay;
  diagnostics: unknown[];
}

export interface CoordinateSpace {
  unit: "pt";
  origin: "page-top-left";
  xAxis: "right";
  yAxis: "down";
}

export interface HtmlDisplay {
  schemaVersion: 1;
  coordinateSpace: CoordinateSpace;
  resources: HtmlResource[];
  pages: HtmlPage[];
}

export interface HtmlResource {
  id: number;
  kind: string;
  path: string;
  uri?: string;
  intrinsicWidth: number;
  intrinsicHeight: number;
  tintable: boolean;
}

export interface HtmlPage {
  pageId: number;
  index: number;
  frame: PreviewFrame;
  items: HtmlItem[];
}

export type HtmlItem = HtmlShapeItem | HtmlTextItem | HtmlResourceItem;

export interface HtmlShapeItem {
  type: "shape";
  nodeId: number;
  frame: PreviewFrame;
  fill: ColorTuple | null;
  stroke: ColorTuple | null;
  lineWidth: number;
  radius: number;
  dash: number[] | null;
}

export interface HtmlTextItem {
  type: "text";
  nodeId: number;
  frame: PreviewFrame;
  lines: HtmlTextLine[];
}

export interface HtmlTextLine {
  baselineY: number;
  lineHeight: number;
  spans: HtmlTextSpan[];
}

export type HtmlTextSpan = HtmlGlyphSpan | HtmlInlineResourceSpan;

export interface HtmlGlyphSpan {
  kind: "glyphs";
  x: number;
  text: string;
  fontFamily: string;
  fontWeight: number;
  fontStyle: string;
  fontSize: number;
  color: ColorTuple | null;
  linkUrl: string | null;
  strikethrough: boolean;
}

export interface HtmlInlineResourceSpan {
  kind: "resource";
  x: number;
  y: number;
  width: number;
  height: number;
  resourceId: number;
  tint: ColorTuple | null;
  linkUrl: string | null;
}

export interface HtmlResourceItem {
  type: "resource";
  nodeId: number;
  resourceId: number;
  frame: PreviewFrame;
  clip: boolean;
}

export type ColorTuple = [number, number, number];

export interface PreviewPage {
  id: number;
  index: number;
  label: string;
  frame: PreviewFrame;
}

export interface PreviewObject {
  id: number;
  pageId: number;
  kind: string;
  label: string;
  role?: string;
  frame: PreviewFrame;
  source?: PreviewSource | null;
  interaction: {
    selectable: boolean;
    movable: boolean;
    message?: string | null;
  };
}

export interface PreviewRelation {
  kind: "explicit" | "fallback" | string;
  pageId: number;
  axis: "horizontal" | "vertical" | string;
  targetNode: number;
  targetAnchor: PreviewAnchor;
  sourceKind: "page" | "node" | string;
  sourceNode: number | null;
  sourceAnchor: PreviewAnchor;
  offset: number;
}

export type PreviewAnchor = "left" | "right" | "top" | "bottom" | "center_x" | "center_y" | string;

export interface PreviewSource {
  uri: string;
  range: ProtocolRange;
}

export interface PreviewFrame {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ProtocolRange {
  start: ProtocolPosition;
  end: ProtocolPosition;
}

export interface ProtocolPosition {
  line: number;
  character: number;
}

export interface LayoutEditResult {
  schemaVersion: 1;
  status: "ok" | "stale" | "unsupported" | "rejected";
  message?: string;
  workspaceEdit?: ProtocolWorkspaceEdit;
}

export interface ProtocolWorkspaceEdit {
  changes?: Record<string, ProtocolTextEdit[]>;
}

export interface ProtocolTextEdit {
  range: ProtocolRange;
  newText: string;
}

export type WebviewMessage =
  { type: "ready" } |
  { type: "refresh" } |
  { type: "show-log" } |
  { type: "gesture"; snapshotId: string; selection: unknown; gesture: unknown } |
  { type: "reveal-source"; uri: string; range: ProtocolRange } |
  { type: "log"; message?: string };
