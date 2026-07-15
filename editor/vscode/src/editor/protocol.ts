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
  schema: 1;
  pages: DisplayPage[];
}

export interface DisplayPage {
  page_id: number;
  index: number;
  width: number;
  height: number;
  items: DisplayItem[];
}

export type DisplayItem = FillRect | StrokeLine | RoundedRect | TextItem | ResourceItem | MathItem | PdfPageItem;

interface NodeItem {
  node_id?: number | null;
}

export interface FillRect extends NodeItem, Rect {
  type: "fill_rect";
  color: Color;
}

export interface StrokeLine extends NodeItem {
  type: "stroke_line";
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  line_width: number;
  dash_on: number;
  dash_off: number;
  color: Color;
}

export interface RoundedRect extends NodeItem, Rect {
  type: "rounded_rect";
  radius: number;
  line_width: number;
  fill: Color | null;
  stroke: Color | null;
}

export interface TextItem extends NodeItem {
  type: "text";
  x: number;
  baseline_y: number;
  width: number;
  text: string;
  font_family: string;
  font_weight: number;
  font_style: string;
  font_stretch: string;
  font_size: number;
  wrap: boolean;
  preserve_color_glyphs: boolean;
  color: Color;
}

export interface ResourceItem extends NodeItem, Rect {
  type: "raster" | "svg";
  resource_id: string;
  path: string;
  uri?: string;
  tint?: Color | null;
}

export interface PdfPageItem extends NodeItem, Rect {
  type: "pdf_page";
  resource_id: string;
  path: string;
  uri?: string;
  page_index: number;
  box: string;
  copy_annotations: boolean;
}

export interface MathItem extends NodeItem, Rect {
  type: "math";
  math_tree_id: number;
  resource_id: string;
  path: string;
  uri?: string;
  page_index: number;
  box: string;
}

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export type Color = [number, number, number];

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

export type WebviewMessage =
  | { type: "ready" }
  | { type: "revealSource"; path: string; start: number; end: number }
  | { type: "translate"; snapshotId: string; nodeId: number; pageId: number; mode: "absolute" | "relative"; fromBounds: Rect; toBounds: Rect };
