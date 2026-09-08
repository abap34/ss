import type {
  EditorSnapshot, HostMessage, WebviewMessage, ShapeEditingCapability,
  ShapeFill, ShapeStroke, Point, Rect, IconCatalogResult, IconCategory, IconStyle,
} from "../../src/editor/protocol";

export type Snapshot = EditorSnapshot;
export type Selection = { pageId: number; binding: string };
export type Failure = { status: "failed"; message: string };
export type Applied = { status: "applied" };
export type ShapeRequest = Extract<WebviewMessage, {
  type: "insertShape" | "editShapeStyle" | "editLineGeometry" | "editShapeBounds";
}>;
export type IconRequest = Extract<WebviewMessage, { type: "insertIcon" }>;
export type EditRequest = ShapeRequest | IconRequest;
export type EditResult = Extract<HostMessage, { type: "shapeEditResult" | "iconEditResult" }>;
export interface EditIntent {
  message: EditRequest;
  selection: Selection | null;
  phase?: "queued" | "requested" | "applied";
  documentVersion?: number;
}
export interface QueuePolicy<Intent extends EditIntent, Outcome extends Applied> {
  snapshot(): Snapshot | null;
  post(message: Intent["message"]): void;
  render(): void;
  nextRequestId(): number;
  sameSlot?(left: Intent, right: Intent): boolean;
  rebase(snapshot: Snapshot, intent: Intent): Failure | null;
  applied(snapshot: Snapshot, intent: Intent, version?: number): Outcome | Failure | null;
  discard(intent: Intent): void;
  failureMessage: string;
}

type Preview<Message> = Message extends unknown
  ? Omit<Message, "requestId" | "snapshotId" | "type"> : never;
export type ShapePreview = Preview<Extract<ShapeRequest, { type: "insertShape" }>>;
export type ShapeOperation = Extract<HostMessage, { type: "shapeEditResult" }>["operation"];
export type ShapeApplied = Applied & { operation: ShapeOperation };
export type ShapeIntent = EditIntent & (
  | { operation: "insert"; message: Extract<ShapeRequest, { type: "insertShape" }>; preview: ShapePreview }
  | { operation: "style"; message: Extract<ShapeRequest, { type: "editShapeStyle" }> }
  | {
    operation: "geometry";
    message: Extract<ShapeRequest, { type: "editLineGeometry" }>;
    geometry: { nodeId: number; pageId: number; start: Point; end: Point };
  }
  | {
    operation: "resize";
    message: Extract<ShapeRequest, { type: "editShapeBounds" }>;
    bounds: { nodeId: number; pageId: number; kind: ShapeKind; bounds: Rect; fill: ShapeFill; stroke: ShapeStroke };
  }
);
export type IconIntent = EditIntent & {
  message: IconRequest;
  preview: { pageId: number; kind: "icon"; bounds: Rect; svg: string | null; color: string };
};

export type ShapeKind = ShapeEditingCapability["kind"];
export type ShapeTool = ShapeKind | "elbow_line" | "select" | "icon";
export interface ShapeDraft {
  fill: ShapeFill;
  stroke: ShapeStroke;
  arrowStart: boolean;
  arrowEnd: boolean;
}
export type ShapeStyleInput = { stroke: ShapeStroke } & Partial<Omit<ShapeDraft, "stroke">>;
export interface EditState {
  snapshot: Snapshot | null;
  currentPageId: number | null;
  pointerMode: string;
  shapeTool: ShapeTool;
}
export interface ShapeState extends EditState {
  shapeStyle: ShapeDraft;
}
export interface IconDraft {
  source: string | null;
  name: string | null;
  style: Exclude<IconStyle, "all"> | null;
  svg: string | null;
  color: string;
}
export interface IconState extends EditState {
  iconDraft: IconDraft;
  iconPickerOpen: boolean;
  iconQuery: string;
  iconStyle: IconStyle;
  iconCategory: string;
  iconCatalog: IconCatalogResult | null;
  iconCatalogPending: boolean;
  iconCatalogError: string | null;
  iconCategories: IconCategory[];
}
export interface EditActions {
  post(message: WebviewMessage): void;
  render(): void;
  selectObject(nodeId: number, pageId: number, reveal: boolean): void;
  reportError?(message: string): void;
}
