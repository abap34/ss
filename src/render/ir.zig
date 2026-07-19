const std = @import("std");
const core = @import("core");
const fonts = @import("ir/fonts.zig");
const geometry = @import("ir/geometry.zig");
const ir_fingerprint = @import("ir/fingerprint.zig");
const math = @import("ir/math.zig");
const resources = @import("ir/resources.zig");
const semantics = @import("ir/semantics.zig");
const text_ir = @import("ir/text.zig");
const validation = @import("ir/validation.zig");

pub const CoordinateSpace = geometry.CoordinateSpace;
pub const Rect = geometry.Rect;
pub const Point = geometry.Point;
pub const Transform = geometry.Transform;
pub const Clip = geometry.Clip;
pub const ValidationError = validation.Error;
pub const Fingerprint = ir_fingerprint.Digest;
pub const TextLayout = text_ir.Layout;
pub const TextLine = text_ir.Line;
pub const TextRun = text_ir.Run;
pub const TextCluster = text_ir.Cluster;
pub const TextDirection = text_ir.Direction;
pub const Glyph = text_ir.Glyph;
pub const FontInstanceId = fonts.Id;
pub const FontVariation = fonts.Variation;
pub const FontFeature = fonts.Feature;
pub const MathConstants = fonts.MathConstants;
pub const FontInstance = fonts.Instance;
pub const FontCatalog = fonts.Catalog;
pub const FontBuilder = fonts.Builder;
pub const ResourceId = resources.Id;
pub const ResourceKind = resources.Kind;
pub const Resource = resources.Resource;
pub const ResourceGraph = resources.Graph;
pub const identifyResource = resources.identify;
pub const ResourceMetadata = resources.Metadata;
pub const RasterMetadata = resources.RasterMetadata;
pub const RasterOrientation = resources.RasterOrientation;
pub const RasterColorSpace = resources.RasterColorSpace;
pub const RasterInterpolation = resources.RasterInterpolation;
pub const SvgMetadata = resources.SvgMetadata;
pub const SvgViewBox = resources.SvgViewBox;
pub const SvgAlign = resources.SvgAlign;
pub const SvgScale = resources.SvgScale;
pub const PdfResourceMetadata = resources.PdfMetadata;
pub const PdfPageMetadata = resources.PdfPageMetadata;
pub const PdfBox = resources.PdfBox;
pub const SemanticId = semantics.Id;
pub const SemanticRole = semantics.Role;
pub const SemanticLinkKind = semantics.LinkKind;
pub const SemanticNode = semantics.Node;
pub const SemanticTree = semantics.Tree;
pub const MathTreeId = math.TreeId;
pub const MathNodeId = math.NodeId;
pub const MathInputKind = math.InputKind;
pub const MathNodeKind = math.Kind;
pub const MathNode = math.Node;
pub const MathTree = math.Tree;
pub const MathCatalog = math.Catalog;
pub const MathBuilder = math.Builder;
pub const MathLayout = math.Layout;
pub const MathElement = math.Element;
pub const MathTextElement = math.TextElement;
pub const MathRuleElement = math.RuleElement;

pub const ItemId = u64;

pub const SourceRange = struct {
    module_id: core.SourceModuleId,
    start: usize,
    end: usize,
};

pub const BlendMode = enum {
    normal,
    multiply,
    screen,
    overlay,
    darken,
    lighten,
};

pub const ItemHeader = struct {
    item_id: ItemId,
    node_id: ?core.NodeId,
    source: ?SourceRange = null,
    semantic_id: ?SemanticId = null,
    bounds: Rect,
    ink_bounds: Rect,
    transform: Transform = .{},
    clip: ?Clip = null,
    opacity: f64 = 1,
    blend_mode: BlendMode = .normal,
    paint_index: u32,
};

pub const StrokeLine = struct {
    header: ItemHeader,
    start: Point,
    end: Point,
    line_width: f64,
    color: core.render_policy.Color,
    dash_on: f64 = 0,
    dash_off: f64 = 0,
};

pub const FillRect = struct {
    header: ItemHeader,
    rect: Rect,
    color: core.render_policy.Color,
};

pub const RoundedRect = struct {
    header: ItemHeader,
    rect: Rect,
    radius: f64,
    fill: ?core.render_policy.Color,
    stroke: ?core.render_policy.Color,
    line_width: f64,
};

pub const Text = struct {
    header: ItemHeader,
    x: f64,
    y: f64,
    width: f64,
    layout: TextLayout,
    font_size: f64,
    color: core.render_policy.Color,

    fn deinit(self: *Text, allocator: std.mem.Allocator) void {
        self.layout.deinit(allocator);
    }

    pub fn baselineY(self: *const Text) f64 {
        return self.y + self.layout.firstBaseline();
    }
};

pub const Raster = struct {
    header: ItemHeader,
    rect: Rect,
    resource: ResourceId,
};

pub const Svg = struct {
    header: ItemHeader,
    rect: Rect,
    resource: ResourceId,
    tint: ?core.render_policy.Color,
};

pub const PdfPage = struct {
    header: ItemHeader,
    rect: Rect,
    resource: ResourceId,
    page_index: usize,
    box: core.render_policy.PdfPageBox,
    copy_annotations: bool,
};

pub const StructuredMath = struct {
    layout: MathLayout,
    color: core.render_policy.Color,
};

pub const RawMathPdf = struct {
    resource: ResourceId,
    page_index: usize,
    box: core.render_policy.PdfPageBox,
};

pub const MathContent = union(enum) {
    structured: StructuredMath,
    raw_pdf: RawMathPdf,

    fn deinit(self: *MathContent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .structured => |*value| value.layout.deinit(allocator),
            .raw_pdf => {},
        }
    }
};

pub const Math = struct {
    header: ItemHeader,
    rect: Rect,
    tree: MathTreeId,
    content: MathContent,
};

pub const Item = union(enum) {
    fill_rect: FillRect,
    stroke_line: StrokeLine,
    rounded_rect: RoundedRect,
    text: Text,
    raster: Raster,
    svg: Svg,
    math: Math,
    pdf_page: PdfPage,

    pub fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |*item| item.deinit(allocator),
            .math => |*item| item.content.deinit(allocator),
            .fill_rect, .stroke_line, .rounded_rect, .raster, .svg, .pdf_page => {},
        }
    }

    pub fn nodeId(self: Item) ?core.NodeId {
        return switch (self) {
            inline else => |item| item.header.node_id,
        };
    }

    pub fn header(self: Item) ItemHeader {
        return switch (self) {
            inline else => |item| item.header,
        };
    }

    pub fn setSemanticId(self: *Item, semantic_id: ?SemanticId) void {
        switch (self.*) {
            inline else => |*item| item.header.semantic_id = semantic_id,
        }
    }

    pub fn setSource(self: *Item, source: ?SourceRange) void {
        switch (self.*) {
            inline else => |*item| item.header.source = source,
        }
    }
};

pub const LinkKind = enum {
    uri,
    destination,
};

pub const Link = struct {
    kind: LinkKind,
    target: [:0]u8,
    rect: Rect,

    fn deinit(self: *Link, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
    }
};

pub const Destination = struct {
    name: [:0]u8,
    point: Point,

    fn deinit(self: *Destination, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const Page = struct {
    page_id: core.NodeId,
    index: usize,
    name: []u8 = &.{},
    width: f64,
    height: f64,
    items: std.ArrayList(Item) = .empty,
    links: std.ArrayList(Link) = .empty,
    destinations: std.ArrayList(Destination) = .empty,
    reading_order: []SemanticId = &.{},

    pub fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit(allocator);
        for (self.links.items) |*link| link.deinit(allocator);
        self.links.deinit(allocator);
        for (self.destinations.items) |*destination| destination.deinit(allocator);
        self.destinations.deinit(allocator);
        allocator.free(self.reading_order);
    }

    pub fn hasPdfPages(self: *const Page) bool {
        for (self.items.items) |item| {
            if (item == .pdf_page) return true;
            if (item == .math and item.math.content == .raw_pdf) return true;
        }
        return false;
    }

    pub fn appendFillRect(self: *Page, allocator: std.mem.Allocator, node_id: ?core.NodeId, rect: Rect, color: core.render_policy.Color) !void {
        try self.items.append(allocator, .{ .fill_rect = .{
            .header = self.itemHeader(node_id, rect, rect),
            .rect = rect,
            .color = color,
        } });
    }

    pub fn appendStrokeLine(
        self: *Page,
        allocator: std.mem.Allocator,
        node_id: ?core.NodeId,
        start: Point,
        end: Point,
        line_width: f64,
        color: core.render_policy.Color,
        dash_on: f64,
        dash_off: f64,
    ) !void {
        const half_width = @max(line_width / 2, 0);
        const dx = end.x - start.x;
        const dy = end.y - start.y;
        const length = @sqrt(dx * dx + dy * dy);
        const x_padding = if (length > 0) half_width * @abs(dy) / length else 0;
        const y_padding = if (length > 0) half_width * @abs(dx) / length else 0;
        const bounds = Rect{
            .x = @min(start.x, end.x),
            .y = @min(start.y, end.y),
            .width = @abs(dx),
            .height = @abs(dy),
        };
        const ink_bounds = Rect{
            .x = bounds.x - x_padding,
            .y = bounds.y - y_padding,
            .width = bounds.width + x_padding * 2,
            .height = bounds.height + y_padding * 2,
        };
        try self.items.append(allocator, .{ .stroke_line = .{
            .header = self.itemHeader(node_id, bounds, ink_bounds),
            .start = start,
            .end = end,
            .line_width = line_width,
            .color = color,
            .dash_on = dash_on,
            .dash_off = dash_off,
        } });
    }

    pub fn appendRoundedRect(
        self: *Page,
        allocator: std.mem.Allocator,
        node_id: ?core.NodeId,
        rect: Rect,
        radius: f64,
        fill: ?core.render_policy.Color,
        stroke: ?core.render_policy.Color,
        line_width: f64,
    ) !void {
        const half_width = if (stroke != null) @max(line_width / 2, 0) else 0;
        const ink_bounds = Rect{
            .x = rect.x - half_width,
            .y = rect.y - half_width,
            .width = rect.width + half_width * 2,
            .height = rect.height + half_width * 2,
        };
        try self.items.append(allocator, .{ .rounded_rect = .{
            .header = self.itemHeader(node_id, rect, ink_bounds),
            .rect = rect,
            .radius = radius,
            .fill = fill,
            .stroke = stroke,
            .line_width = line_width,
        } });
    }

    pub fn appendTextLayout(
        self: *Page,
        allocator: std.mem.Allocator,
        node_id: ?core.NodeId,
        x: f64,
        baseline_y: f64,
        width: f64,
        layout: TextLayout,
        font_size: f64,
        color: core.render_policy.Color,
    ) !void {
        var owned_layout = layout;
        errdefer owned_layout.deinit(allocator);
        const y = baseline_y - owned_layout.firstBaseline();
        const logical = owned_layout.logical_bounds;
        const ink = owned_layout.ink_bounds;
        const bounds = Rect{ .x = x + logical.x, .y = y + logical.y, .width = logical.width, .height = logical.height };
        const ink_bounds = Rect{ .x = x + ink.x, .y = y + ink.y, .width = ink.width, .height = ink.height };
        try self.items.append(allocator, .{ .text = .{
            .header = self.itemHeader(node_id, bounds, ink_bounds),
            .x = x,
            .y = y,
            .width = width,
            .layout = owned_layout,
            .font_size = font_size,
            .color = color,
        } });
    }

    pub fn appendRaster(self: *Page, allocator: std.mem.Allocator, node_id: ?core.NodeId, rect: Rect, resource: ResourceId) !void {
        try self.items.append(allocator, .{ .raster = .{
            .header = self.itemHeader(node_id, rect, rect),
            .rect = rect,
            .resource = resource,
        } });
    }

    pub fn appendSvg(
        self: *Page,
        allocator: std.mem.Allocator,
        node_id: ?core.NodeId,
        rect: Rect,
        resource: ResourceId,
        tint: ?core.render_policy.Color,
    ) !void {
        try self.items.append(allocator, .{ .svg = .{
            .header = self.itemHeader(node_id, rect, rect),
            .rect = rect,
            .resource = resource,
            .tint = tint,
        } });
    }

    pub fn appendPdfPage(
        self: *Page,
        allocator: std.mem.Allocator,
        node_id: ?core.NodeId,
        rect: Rect,
        resource: ResourceId,
        page_index: usize,
        box: core.render_policy.PdfPageBox,
        copy_annotations: bool,
    ) !void {
        try self.items.append(allocator, .{ .pdf_page = .{
            .header = self.itemHeader(node_id, rect, rect),
            .rect = rect,
            .resource = resource,
            .page_index = page_index,
            .box = box,
            .copy_annotations = copy_annotations,
        } });
    }

    pub fn appendStructuredMath(
        self: *Page,
        allocator: std.mem.Allocator,
        node_id: ?core.NodeId,
        rect: Rect,
        tree: MathTreeId,
        layout: MathLayout,
        color: core.render_policy.Color,
    ) !void {
        var owned_layout = layout;
        errdefer owned_layout.deinit(allocator);
        try self.items.append(allocator, .{ .math = .{
            .header = self.itemHeader(node_id, rect, rect),
            .rect = rect,
            .tree = tree,
            .content = .{ .structured = .{ .layout = owned_layout, .color = color } },
        } });
    }

    pub fn appendRawMathPdf(
        self: *Page,
        allocator: std.mem.Allocator,
        node_id: ?core.NodeId,
        rect: Rect,
        tree: MathTreeId,
        resource: ResourceId,
        page_index: usize,
        box: core.render_policy.PdfPageBox,
    ) !void {
        try self.items.append(allocator, .{ .math = .{
            .header = self.itemHeader(node_id, rect, rect),
            .rect = rect,
            .tree = tree,
            .content = .{ .raw_pdf = .{ .resource = resource, .page_index = page_index, .box = box } },
        } });
    }

    pub fn appendLink(self: *Page, allocator: std.mem.Allocator, kind: LinkKind, target: []const u8, rect: Rect) !void {
        const owned_target = try allocator.dupeZ(u8, target);
        errdefer allocator.free(owned_target);
        try self.links.append(allocator, .{
            .kind = kind,
            .target = owned_target,
            .rect = rect,
        });
    }

    pub fn appendDestination(self: *Page, allocator: std.mem.Allocator, name: []const u8, point: Point) !void {
        const owned_name = try allocator.dupeZ(u8, name);
        errdefer allocator.free(owned_name);
        try self.destinations.append(allocator, .{
            .name = owned_name,
            .point = point,
        });
    }

    fn itemHeader(self: *const Page, node_id: ?core.NodeId, bounds: Rect, ink_bounds: Rect) ItemHeader {
        const paint_index: u32 = @intCast(self.items.items.len);
        return .{
            .item_id = (@as(u64, @intCast(self.index + 1)) << 32) | paint_index,
            .node_id = node_id,
            .bounds = bounds,
            .ink_bounds = ink_bounds,
            .paint_index = paint_index,
        };
    }
};

pub const Ir = struct {
    schema_version: u32 = 6,
    resources: ResourceGraph = .{},
    fonts: FontCatalog = .{},
    semantics: SemanticTree = .{},
    math: MathCatalog = .{},
    pages: []Page,

    pub fn deinit(self: *Ir, allocator: std.mem.Allocator) void {
        for (self.pages) |*page| page.deinit(allocator);
        allocator.free(self.pages);
        self.resources.deinit(allocator);
        self.fonts.deinit(allocator);
        self.semantics.deinit(allocator);
        self.math.deinit(allocator);
        self.* = .{ .pages = &.{} };
    }

    pub fn validate(self: *const Ir) ValidationError!void {
        try validation.document(self);
    }

    pub fn fingerprint(self: *const Ir) Fingerprint {
        return ir_fingerprint.document(self);
    }
};

pub fn pageFingerprint(page: *const Page) Fingerprint {
    return ir_fingerprint.page(page);
}
