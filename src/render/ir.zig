const std = @import("std");
const core = @import("core");
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
pub const Glyph = text_ir.Glyph;
pub const ResourceId = resources.Id;
pub const ResourceKind = resources.Kind;
pub const Resource = resources.Resource;
pub const ResourceGraph = resources.Graph;
pub const ResourceBuilder = resources.Builder;
pub const SemanticId = semantics.Id;
pub const SemanticRole = semantics.Role;
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

pub const ItemId = u64;

pub const ItemHeader = struct {
    item_id: ItemId,
    node_id: ?core.NodeId,
    semantic_id: ?SemanticId = null,
    bounds: Rect,
    ink_bounds: Rect,
    transform: Transform = .{},
    clip: ?Clip = null,
    opacity: f64 = 1,
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
    font_weight: u16,
    font_style: core.font.Style,
    font_stretch: core.font.Stretch,
    font_size: f64,
    color: core.render_policy.Color,
    wrap: bool,
    preserve_color_glyphs: bool,

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

pub const Math = struct {
    header: ItemHeader,
    rect: Rect,
    tree: MathTreeId,
    pdf_resource: ResourceId,
    page_index: usize,
    box: core.render_policy.PdfPageBox,
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
            .fill_rect, .stroke_line, .rounded_rect, .raster, .svg, .math, .pdf_page => {},
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
    width: f64,
    height: f64,
    items: std.ArrayList(Item) = .empty,
    links: std.ArrayList(Link) = .empty,
    destinations: std.ArrayList(Destination) = .empty,
    reading_order: []SemanticId = &.{},

    pub fn deinit(self: *Page, allocator: std.mem.Allocator) void {
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
            if (item == .pdf_page or item == .math) return true;
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
        const bounds = Rect{
            .x = @min(start.x, end.x),
            .y = @min(start.y, end.y),
            .width = @abs(end.x - start.x),
            .height = @abs(end.y - start.y),
        };
        const ink_bounds = Rect{
            .x = bounds.x - half_width,
            .y = bounds.y - half_width,
            .width = bounds.width + line_width,
            .height = bounds.height + line_width,
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

    pub fn appendText(
        self: *Page,
        allocator: std.mem.Allocator,
        node_id: ?core.NodeId,
        x: f64,
        baseline_y: f64,
        width: f64,
        text: []const u8,
        font: core.font.Face,
        font_size: f64,
        color: core.render_policy.Color,
        wrap: bool,
        preserve_color_glyphs: bool,
    ) !void {
        const layout = try TextLayout.simple(allocator, text, font.family, font_size, width);
        try self.appendTextLayout(allocator, node_id, x, baseline_y, width, layout, font, font_size, color, wrap, preserve_color_glyphs);
    }

    pub fn appendTextLayout(
        self: *Page,
        allocator: std.mem.Allocator,
        node_id: ?core.NodeId,
        x: f64,
        baseline_y: f64,
        width: f64,
        layout: TextLayout,
        font: core.font.Face,
        font_size: f64,
        color: core.render_policy.Color,
        wrap: bool,
        preserve_color_glyphs: bool,
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
            .font_weight = font.weight,
            .font_style = font.style,
            .font_stretch = font.stretch,
            .font_size = font_size,
            .color = color,
            .wrap = wrap,
            .preserve_color_glyphs = preserve_color_glyphs,
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

    pub fn appendMath(
        self: *Page,
        allocator: std.mem.Allocator,
        node_id: ?core.NodeId,
        rect: Rect,
        tree: MathTreeId,
        pdf_resource: ResourceId,
        page_index: usize,
        box: core.render_policy.PdfPageBox,
    ) !void {
        try self.items.append(allocator, .{ .math = .{
            .header = self.itemHeader(node_id, rect, rect),
            .rect = rect,
            .tree = tree,
            .pdf_resource = pdf_resource,
            .page_index = page_index,
            .box = box,
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
    schema_version: u32 = 3,
    resources: ResourceGraph = .{},
    semantics: SemanticTree = .{},
    math: MathCatalog = .{},
    pages: []Page,

    pub fn deinit(self: *Ir, allocator: std.mem.Allocator) void {
        for (self.pages) |*page| page.deinit(allocator);
        allocator.free(self.pages);
        self.resources.deinit(allocator);
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
