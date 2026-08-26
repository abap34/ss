const std = @import("std");
const core = @import("core");
const fonts = @import("ir/fonts.zig");
const geometry = @import("ir/geometry.zig");
const ir_fingerprint = @import("ir/fingerprint.zig");
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
pub const FontSpec = fonts.Spec;
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

pub const PathCommand = union(enum) {
    move_to: Point,
    line_to: Point,
    cubic_to: struct {
        control1: Point,
        control2: Point,
        end: Point,
    },
    close: void,
};

pub const LineCap = enum { butt, round, square };
pub const LineJoin = enum { miter, round, bevel };
pub const FillRule = enum { nonzero, even_odd };
pub const GradientSpread = enum { pad, repeat, reflect };

pub const StrokePaint = struct {
    color: core.render_policy.Color,
    width: f64,
    cap: LineCap = .butt,
    join: LineJoin = .miter,
    miter_limit: f64 = 10,
    dash: []const f64 = &.{},
    dash_offset: f64 = 0,

    fn clone(self: StrokePaint, allocator: std.mem.Allocator) !StrokePaint {
        var result = self;
        result.dash = try allocator.dupe(f64, self.dash);
        return result;
    }

    fn deinit(self: *StrokePaint, allocator: std.mem.Allocator) void {
        allocator.free(self.dash);
        self.dash = &.{};
    }
};

pub const GradientStop = struct {
    offset: f64,
    color: core.render_policy.Color,
};

pub const LinearGradientPaint = struct {
    start: Point,
    end: Point,
    stops: []const GradientStop,
    spread: GradientSpread = .pad,
};

pub const RadialGradientPaint = struct {
    start_center: Point,
    start_radius: f64,
    end_center: Point,
    end_radius: f64,
    stops: []const GradientStop,
    spread: GradientSpread = .pad,
};

pub const BaseFillPaint = union(enum) {
    none: void,
    solid: core.render_policy.Color,
    linear: LinearGradientPaint,
    radial: RadialGradientPaint,
};

pub const TilePatternPaint = struct {
    commands: []const PathCommand,
    cell_width: f64,
    cell_height: f64,
    transform: Transform = .{},
    fill: ?core.render_policy.Color = null,
    stroke: ?StrokePaint = null,

    fn clone(self: TilePatternPaint, allocator: std.mem.Allocator) !TilePatternPaint {
        var result = self;
        result.commands = try allocator.dupe(PathCommand, self.commands);
        errdefer allocator.free(result.commands);
        if (self.stroke) |stroke| result.stroke = try stroke.clone(allocator);
        return result;
    }

    fn deinit(self: *TilePatternPaint, allocator: std.mem.Allocator) void {
        allocator.free(self.commands);
        if (self.stroke) |*stroke| stroke.deinit(allocator);
        self.commands = &.{};
    }
};

pub const FillPaint = struct {
    base: BaseFillPaint = .{ .none = {} },
    overlay: ?TilePatternPaint = null,
    rule: FillRule = .nonzero,
    opacity: f64 = 1,

    fn clone(self: FillPaint, allocator: std.mem.Allocator) !FillPaint {
        var result = self;
        switch (self.base) {
            .linear => |linear| {
                result.base.linear.stops = try allocator.dupe(GradientStop, linear.stops);
            },
            .radial => |radial| {
                result.base.radial.stops = try allocator.dupe(GradientStop, radial.stops);
            },
            .none, .solid => {},
        }
        errdefer switch (result.base) {
            .linear => |linear| allocator.free(linear.stops),
            .radial => |radial| allocator.free(radial.stops),
            .none, .solid => {},
        };
        if (self.overlay) |overlay| result.overlay = try overlay.clone(allocator);
        return result;
    }

    fn deinit(self: *FillPaint, allocator: std.mem.Allocator) void {
        switch (self.base) {
            .linear => |linear| allocator.free(linear.stops),
            .radial => |radial| allocator.free(radial.stops),
            .none, .solid => {},
        }
        if (self.overlay) |*overlay| overlay.deinit(allocator);
    }
};

pub const VectorPath = struct {
    header: ItemHeader,
    commands: []const PathCommand,
    fill: FillPaint,
    stroke: ?StrokePaint,

    fn deinit(self: *VectorPath, allocator: std.mem.Allocator) void {
        allocator.free(self.commands);
        self.fill.deinit(allocator);
        if (self.stroke) |*stroke| stroke.deinit(allocator);
    }
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

pub const Latex = struct {
    header: ItemHeader,
    rect: Rect,
    resource: ResourceId,
    page_index: usize,
    box: core.render_policy.PdfPageBox,
};

pub const Item = union(enum) {
    fill_rect: FillRect,
    stroke_line: StrokeLine,
    vector_path: VectorPath,
    rounded_rect: RoundedRect,
    text: Text,
    raster: Raster,
    svg: Svg,
    latex: Latex,
    pdf_page: PdfPage,

    pub fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |*item| item.deinit(allocator),
            .vector_path => |*item| item.deinit(allocator),
            .fill_rect, .stroke_line, .rounded_rect, .raster, .svg, .latex, .pdf_page => {},
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

pub const PageContent = struct {
    owner_allocator: std.mem.Allocator,
    content_allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),
    items: std.ArrayList(Item),
    links: std.ArrayList(Link),
    destinations: std.ArrayList(Destination),

    fn retain(self: *PageContent) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *PageContent) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        for (self.items.items) |*item| item.deinit(self.content_allocator);
        self.items.deinit(self.content_allocator);
        for (self.links.items) |*link| link.deinit(self.content_allocator);
        self.links.deinit(self.content_allocator);
        for (self.destinations.items) |*destination| destination.deinit(self.content_allocator);
        self.destinations.deinit(self.content_allocator);
        self.owner_allocator.destroy(self);
    }

    pub fn materialize(
        self: *PageContent,
        allocator: std.mem.Allocator,
        page_id: core.NodeId,
        index: usize,
        width: f64,
        height: f64,
    ) !Page {
        const copied_items = try self.items.clone(allocator);
        self.retain();
        return .{
            .page_id = page_id,
            .index = index,
            .width = width,
            .height = height,
            .items = copied_items,
            .links = self.links,
            .destinations = self.destinations,
            .shared_content = self,
        };
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
    shared_content: ?*PageContent = null,

    pub fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.shared_content == null) for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit(allocator);
        if (self.shared_content) |content| {
            content.release();
        } else {
            for (self.links.items) |*link| link.deinit(allocator);
            self.links.deinit(allocator);
            for (self.destinations.items) |*destination| destination.deinit(allocator);
            self.destinations.deinit(allocator);
        }
        allocator.free(self.reading_order);
    }

    pub fn takeContent(
        self: *Page,
        owner_allocator: std.mem.Allocator,
        content_allocator: std.mem.Allocator,
    ) !*PageContent {
        std.debug.assert(self.shared_content == null);
        std.debug.assert(self.name.len == 0);
        std.debug.assert(self.reading_order.len == 0);
        const content = try owner_allocator.create(PageContent);
        content.* = .{
            .owner_allocator = owner_allocator,
            .content_allocator = content_allocator,
            .items = self.items,
            .links = self.links,
            .destinations = self.destinations,
        };
        self.items = .empty;
        self.links = .empty;
        self.destinations = .empty;
        return content;
    }

    pub fn ownedContentByteSize(self: *const Page) usize {
        var total = @sizeOf(PageContent) +|
            self.items.capacity *| @sizeOf(Item) +|
            self.links.capacity *| @sizeOf(Link) +|
            self.destinations.capacity *| @sizeOf(Destination);
        for (self.items.items) |item| switch (item) {
            .text => |value| total +|= value.layout.ownedByteSize(),
            .vector_path => |value| {
                total +|= value.commands.len *| @sizeOf(PathCommand);
                total +|= fillPaintOwnedByteSize(value.fill);
                if (value.stroke) |stroke| total +|= stroke.dash.len *| @sizeOf(f64);
            },
            .fill_rect, .stroke_line, .rounded_rect, .raster, .svg, .latex, .pdf_page => {},
        };
        for (self.links.items) |link| total +|= link.target.len +| 1;
        for (self.destinations.items) |destination| total +|= destination.name.len +| 1;
        return total;
    }

    pub fn hasPdfPages(self: *const Page) bool {
        for (self.items.items) |item| {
            if (item == .pdf_page) return true;
            if (item == .latex) return true;
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
        return self.appendStrokeLineWithOpacity(allocator, node_id, start, end, line_width, color, dash_on, dash_off, 1);
    }

    pub fn appendStrokeLineWithOpacity(
        self: *Page,
        allocator: std.mem.Allocator,
        node_id: ?core.NodeId,
        start: Point,
        end: Point,
        line_width: f64,
        color: core.render_policy.Color,
        dash_on: f64,
        dash_off: f64,
        opacity: f64,
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
        var header = self.itemHeader(node_id, bounds, ink_bounds);
        header.opacity = opacity;
        try self.items.append(allocator, .{ .stroke_line = .{
            .header = header,
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

    pub fn appendVectorPath(
        self: *Page,
        allocator: std.mem.Allocator,
        node_id: ?core.NodeId,
        commands: []const PathCommand,
        fill: FillPaint,
        stroke: ?StrokePaint,
    ) !void {
        const owned_commands = try allocator.dupe(PathCommand, commands);
        errdefer allocator.free(owned_commands);
        var owned_fill = try fill.clone(allocator);
        errdefer owned_fill.deinit(allocator);
        var owned_stroke: ?StrokePaint = if (stroke) |value| try value.clone(allocator) else null;
        errdefer if (owned_stroke) |*value| value.deinit(allocator);

        const bounds = pathBounds(commands) orelse Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
        const stroke_inset = if (stroke) |value| strokeBoundsInset(value) else 0;
        const ink_bounds = Rect{
            .x = bounds.x - stroke_inset,
            .y = bounds.y - stroke_inset,
            .width = bounds.width + stroke_inset * 2,
            .height = bounds.height + stroke_inset * 2,
        };
        try self.items.append(allocator, .{ .vector_path = .{
            .header = self.itemHeader(node_id, bounds, ink_bounds),
            .commands = owned_commands,
            .fill = owned_fill,
            .stroke = owned_stroke,
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

    pub fn appendLatexPdf(
        self: *Page,
        allocator: std.mem.Allocator,
        node_id: ?core.NodeId,
        rect: Rect,
        resource: ResourceId,
        page_index: usize,
        box: core.render_policy.PdfPageBox,
    ) !void {
        try self.items.append(allocator, .{ .latex = .{
            .header = self.itemHeader(node_id, rect, rect),
            .rect = rect,
            .resource = resource,
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

fn fillPaintOwnedByteSize(fill: FillPaint) usize {
    var total: usize = switch (fill.base) {
        .linear => |value| value.stops.len *| @sizeOf(GradientStop),
        .radial => |value| value.stops.len *| @sizeOf(GradientStop),
        .none, .solid => 0,
    };
    if (fill.overlay) |overlay| {
        total +|= overlay.commands.len *| @sizeOf(PathCommand);
        if (overlay.stroke) |stroke| total +|= stroke.dash.len *| @sizeOf(f64);
    }
    return total;
}

pub const Ir = struct {
    schema_version: u32 = 7,
    resources: ResourceGraph = .{},
    fonts: FontCatalog = .{},
    semantics: SemanticTree = .{},
    pages: []Page,

    pub fn deinit(self: *Ir, allocator: std.mem.Allocator) void {
        for (self.pages) |*page| page.deinit(allocator);
        allocator.free(self.pages);
        self.resources.deinit(allocator);
        self.fonts.deinit(allocator);
        self.semantics.deinit(allocator);
        self.* = .{ .pages = &.{} };
    }

    pub fn validate(self: *const Ir) ValidationError!void {
        try validation.document(self);
    }

    pub fn fingerprint(self: *const Ir) Fingerprint {
        return ir_fingerprint.document(self);
    }

    pub fn displayFingerprint(self: *const Ir) Fingerprint {
        return ir_fingerprint.displayDocument(self);
    }
};

fn strokeBoundsInset(stroke: StrokePaint) f64 {
    const half_width = @max(stroke.width / 2, 0);
    const cap_inset = if (stroke.cap == .square) half_width * std.math.sqrt2 else half_width;
    const join_inset = if (stroke.join == .miter) @max(stroke.width * stroke.miter_limit, half_width) else half_width;
    return @max(cap_inset, join_inset);
}

fn pathBounds(commands: []const PathCommand) ?Rect {
    var min_x = std.math.inf(f64);
    var min_y = std.math.inf(f64);
    var max_x = -std.math.inf(f64);
    var max_y = -std.math.inf(f64);
    var current: ?Point = null;
    var subpath_start: ?Point = null;
    for (commands) |command| switch (command) {
        .move_to => |point| {
            includePoint(point, &min_x, &min_y, &max_x, &max_y);
            current = point;
            subpath_start = point;
        },
        .line_to => |point| {
            includePoint(point, &min_x, &min_y, &max_x, &max_y);
            if (current) |value| includePoint(value, &min_x, &min_y, &max_x, &max_y);
            current = point;
        },
        .cubic_to => |cubic| {
            if (current) |start| includeCubicBounds(start, cubic.control1, cubic.control2, cubic.end, &min_x, &min_y, &max_x, &max_y);
            current = cubic.end;
        },
        .close => {
            if (subpath_start) |point| includePoint(point, &min_x, &min_y, &max_x, &max_y);
            current = subpath_start;
        },
    };
    if (!std.math.isFinite(min_x)) return null;
    return .{ .x = min_x, .y = min_y, .width = max_x - min_x, .height = max_y - min_y };
}

fn includeCubicBounds(p0: Point, p1: Point, p2: Point, p3: Point, min_x: *f64, min_y: *f64, max_x: *f64, max_y: *f64) void {
    includePoint(p0, min_x, min_y, max_x, max_y);
    includePoint(p3, min_x, min_y, max_x, max_y);
    includeCubicAxis(p0.x, p1.x, p2.x, p3.x, true, p0, p1, p2, p3, min_x, min_y, max_x, max_y);
    includeCubicAxis(p0.y, p1.y, p2.y, p3.y, false, p0, p1, p2, p3, min_x, min_y, max_x, max_y);
}

fn includeCubicAxis(a0: f64, a1: f64, a2: f64, a3: f64, x_axis: bool, p0: Point, p1: Point, p2: Point, p3: Point, min_x: *f64, min_y: *f64, max_x: *f64, max_y: *f64) void {
    const qa = -a0 + 3 * a1 - 3 * a2 + a3;
    const qb = 2 * (a0 - 2 * a1 + a2);
    const qc = a1 - a0;
    if (@abs(qa) < 1e-12) {
        if (@abs(qb) >= 1e-12) includeCubicAt(-qc / qb, p0, p1, p2, p3, min_x, min_y, max_x, max_y);
        return;
    }
    const discriminant = qb * qb - 4 * qa * qc;
    if (discriminant < 0) return;
    const root = @sqrt(discriminant);
    includeCubicAt((-qb + root) / (2 * qa), p0, p1, p2, p3, min_x, min_y, max_x, max_y);
    includeCubicAt((-qb - root) / (2 * qa), p0, p1, p2, p3, min_x, min_y, max_x, max_y);
    _ = x_axis;
}

fn includeCubicAt(t: f64, p0: Point, p1: Point, p2: Point, p3: Point, min_x: *f64, min_y: *f64, max_x: *f64, max_y: *f64) void {
    if (t <= 0 or t >= 1 or !std.math.isFinite(t)) return;
    const u = 1 - t;
    includePoint(.{
        .x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
        .y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y,
    }, min_x, min_y, max_x, max_y);
}

fn includePoint(point: Point, min_x: *f64, min_y: *f64, max_x: *f64, max_y: *f64) void {
    min_x.* = @min(min_x.*, point.x);
    min_y.* = @min(min_y.*, point.y);
    max_x.* = @max(max_x.*, point.x);
    max_y.* = @max(max_y.*, point.y);
}

pub fn pageFingerprint(page: *const Page) Fingerprint {
    return ir_fingerprint.page(page);
}

pub fn pageFingerprintUnbufferedForTesting(page: *const Page) Fingerprint {
    return ir_fingerprint.pageUnbufferedForTesting(page);
}
