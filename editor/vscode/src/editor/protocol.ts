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
  page_editing: PageEditingCapability[];
  shape_editing: ShapeEditingCapability[];
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
  location?: SourceLocation | null;
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

export type DisplaySnapshot = FullDisplaySnapshot | TranslationDisplayPatch;

export interface FullDisplaySnapshot {
  schema: 2;
  html: string;
  css: string;
  has_pdf: boolean;
  assets: DisplayAsset[];
  translations?: DisplayTranslation[];
}

export interface TranslationDisplayPatch {
  schema: 3;
  kind: "translation_patch";
  base_snapshot_id: string;
  translations: DisplayTranslation[];
}

export interface DisplayTranslation {
  node_id: number;
  x: number;
  y: number;
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

export interface PageEditingCapability {
  page_id: number;
  insert_shapes: boolean;
}

export interface ShapeStyle {
  fill: {
    enabled: boolean;
    color: string;
    opacity: number;
  };
  stroke: {
    enabled: boolean;
    color: string;
    width: number;
    style: "solid" | "dashed" | "dotted" | "dash_dot";
  };
}

export interface ShapeEditingCapability extends ShapeStyle {
  node_id: number;
  page_id: number;
  binding: string;
  kind: "rectangle" | "circle" | "arrow";
}

export interface WorkspaceEditValue {
  changes?: Record<string, Array<{
    range: {
      start: { line: number; character: number };
      end: { line: number; character: number };
    };
    newText: string;
  }>>;
}

export interface LayoutEditResult {
  schema: 1;
  status: "ok" | "stale" | "unsupported" | "rejected";
  message?: string;
  workspaceEdit?: WorkspaceEditValue;
}

export interface ShapeEditResult {
  schema: 1;
  status: LayoutEditResult["status"];
  message?: string;
  workspaceEdit?: WorkspaceEditValue;
  selection?: {
    path: string;
    pageId: number;
    binding: string;
  };
}

export type BuildStatus =
  "starting" |
  "building" |
  "complete" |
  "failed" |
  "unavailable";

export type HostMessage =
  | {
    type: "snapshot";
    revision: number;
    documentVersion: number;
    snapshot: EditorSnapshot;
  }
  | {
    type: "buildStatus";
    revision: number;
    status: BuildStatus;
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
  }
  | {
    type: "shapeEditResult";
    requestId: number;
    operation: "insert" | "style";
    status: "applied";
    documentVersion: number;
    selection?: ShapeEditResult["selection"];
  }
  | {
    type: "shapeEditResult";
    requestId: number;
    operation: "insert" | "style";
    status: Exclude<ShapeEditResult["status"], "ok">;
    message?: string;
  };

export type WebviewMessage =
  | { type: "ready" }
  | { type: "refreshFull" }
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
  }
  | {
    type: "insertShape";
    requestId: number;
    snapshotId: string;
    pageId: number;
    kind: "rectangle" | "circle" | "arrow";
    bounds: Rect;
    fill: ShapeStyle["fill"];
    stroke: ShapeStyle["stroke"];
  }
  | {
    type: "editShapeStyle";
    requestId: number;
    snapshotId: string;
    nodeId: number;
    pageId: number;
    fill: ShapeStyle["fill"];
    stroke: ShapeStyle["stroke"];
  };
