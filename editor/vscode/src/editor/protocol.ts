export interface EditorSnapshot {
  schema: 1;
  kind: "ss-editor-snapshot";
  snapshot_id: string;
  generation: number;
  entry_path: string;
  source_paths: string[];
  coordinate_space: CoordinateSpace;
  layout: LayoutData;
  display: DisplaySnapshot;
  outline: OutlineItem[];
  editing: EditingTarget[];
  stale?: boolean;
  build_diagnostics?: BuildDiagnostic[];
}

export interface BuildDiagnostic {
  uri: string;
  range: {
    start: { line: number; character: number };
    end: { line: number; character: number };
  };
  code: string;
  message: string;
}

export interface CoordinateSpace {
  unit: "pt";
  origin: "page-top-left";
  x_axis: "right";
  y_axis: "down";
}

export interface LayoutData {
  pages: LayoutPage[];
  objects: LayoutObject[];
  anchors: LayoutAnchor[];
  relations: LayoutRelation[];
  failures: unknown[];
}

export interface LayoutPage {
  id: number;
  index: number;
  name: string;
  width: number;
  height: number;
}

export interface LayoutObject {
  id: number;
  page_id: number;
  name: string;
  role?: string | null;
  object_kind?: string | null;
  x: number;
  y: number;
  width: number;
  height: number;
  group: boolean;
  location?: SourceLocation | null;
}

export interface LayoutAnchor {
  page_id: number;
  node_id: number;
  anchor: Anchor;
  value: number;
}

export interface LayoutRelation {
  index: number;
  kind: "explicit" | "fallback";
  axis: "horizontal" | "vertical";
  offset: number;
  expression: string;
  location?: SourceLocation | null;
  target: RelationEndpoint;
  source: RelationEndpoint;
}

export interface RelationEndpoint {
  type: "page" | "node";
  node_id?: number;
  label: string;
  anchor: Anchor;
}

export type Anchor = "left" | "right" | "top" | "bottom" | "center_x" | "center_y";

export interface SourceLocation {
  path: string;
  line: number;
  column: number;
  start: number;
  end: number;
}

export interface DisplaySnapshot {
  schema: 2;
  html: string;
  css: string;
  has_pdf: boolean;
  assets: DisplayAsset[];
}

export interface DisplayAsset {
  kind: "font" | "raster" | "svg" | "pdf" | "math_pdf";
  resource_id: string;
  digest: string;
  media_type: string;
  relative_path: string;
  path: string;
}

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface OutlineItem {
  id: number;
  parent_id: number | null;
  page_id: number;
  kind: "page" | "group" | "object";
  label: string;
  role?: string | null;
}

export interface EditingTarget {
  node_id: number;
  page_id: number;
  page_index: number;
  page_name: string;
  binding: string;
  binding_required: boolean;
  statement_start: number;
  statement_end: number;
  path: string;
  page_start: number;
  page_end: number;
}

export interface LayoutEditResult {
  schema: 1;
  status: "ok" | "stale" | "unsupported" | "rejected";
  message?: string;
  workspaceEdit?: {
    changes?: Record<string, Array<{
      range: {
        start: { line: number; character: number };
        end: { line: number; character: number };
      };
      newText: string;
    }>>;
  };
}

export type HostMessage =
  | {
    type: "snapshot";
    revision: number;
    documentVersion: number;
    snapshot: EditorSnapshot;
  }
  | { type: "error"; revision: number; message: string }
  | {
    type: "editResult";
    requestId: number;
    status: "applied";
    documentVersion: number;
  }
  | {
    type: "editResult";
    requestId: number;
    status: Exclude<LayoutEditResult["status"], "ok">;
    message?: string;
  };

export type WebviewMessage =
  | { type: "ready" }
  | { type: "revealSource"; path: string; start: number; end: number }
  | {
    type: "translate";
    requestId: number;
    snapshotId: string;
    nodeId: number;
    pageId: number;
    mode: "absolute" | "relative";
    fromBounds: Rect;
    toBounds: Rect;
  };
