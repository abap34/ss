const std = @import("std");
const core = @import("core");
const geometry = @import("ir/geometry.zig");

pub const CoordinateSpace = geometry.CoordinateSpace;
pub const Rect = geometry.Rect;
pub const Point = geometry.Point;
pub const Transform = geometry.Transform;
pub const Clip = geometry.Clip;

pub const ItemId = u64;

pub const ItemHeader = struct {
    item_id: ItemId,
    node_id: ?core.NodeId,
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
    baseline_y: f64,
    width: f64,
    text: [:0]u8,
    font_family: [:0]u8,
    font_weight: u16,
    font_style: core.font.Style,
    font_stretch: core.font.Stretch,
    font_size: f64,
    color: core.render_policy.Color,
    wrap: bool,
    preserve_color_glyphs: bool,

    fn deinit(self: *Text, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.font_family);
    }
};

pub const Raster = struct {
    header: ItemHeader,
    rect: Rect,
    path: [:0]u8,

    fn deinit(self: *Raster, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const Svg = struct {
    header: ItemHeader,
    rect: Rect,
    path: [:0]u8,
    tint: ?core.render_policy.Color,

    fn deinit(self: *Svg, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const PdfPage = struct {
    header: ItemHeader,
    rect: Rect,
    path: [:0]u8,
    page_index: usize,
    box: core.render_policy.PdfPageBox,
    copy_annotations: bool,

    fn deinit(self: *PdfPage, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const Item = union(enum) {
    fill_rect: FillRect,
    stroke_line: StrokeLine,
    rounded_rect: RoundedRect,
    text: Text,
    raster: Raster,
    svg: Svg,
    pdf_page: PdfPage,

    pub fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |*item| item.deinit(allocator),
            .raster => |*item| item.deinit(allocator),
            .svg => |*item| item.deinit(allocator),
            .pdf_page => |*item| item.deinit(allocator),
            .fill_rect, .stroke_line, .rounded_rect => {},
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

    pub fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit(allocator);
        for (self.links.items) |*link| link.deinit(allocator);
        self.links.deinit(allocator);
        for (self.destinations.items) |*destination| destination.deinit(allocator);
        self.destinations.deinit(allocator);
    }

    pub fn hasPdfPages(self: *const Page) bool {
        for (self.items.items) |item| {
            if (item == .pdf_page) return true;
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
        const owned_text = try allocator.dupeZ(u8, text);
        errdefer allocator.free(owned_text);
        const owned_family = try allocator.dupeZ(u8, font.family);
        errdefer allocator.free(owned_family);
        const bounds = Rect{
            .x = x,
            .y = baseline_y - font_size,
            .width = @max(width, 0),
            .height = @max(font_size, 0),
        };
        try self.items.append(allocator, .{ .text = .{
            .header = self.itemHeader(node_id, bounds, bounds),
            .x = x,
            .baseline_y = baseline_y,
            .width = width,
            .text = owned_text,
            .font_family = owned_family,
            .font_weight = font.weight,
            .font_style = font.style,
            .font_stretch = font.stretch,
            .font_size = font_size,
            .color = color,
            .wrap = wrap,
            .preserve_color_glyphs = preserve_color_glyphs,
        } });
    }

    pub fn appendRaster(self: *Page, allocator: std.mem.Allocator, node_id: ?core.NodeId, rect: Rect, path: []const u8) !void {
        const owned_path = try allocator.dupeZ(u8, path);
        errdefer allocator.free(owned_path);
        try self.items.append(allocator, .{ .raster = .{
            .header = self.itemHeader(node_id, rect, rect),
            .rect = rect,
            .path = owned_path,
        } });
    }

    pub fn appendSvg(
        self: *Page,
        allocator: std.mem.Allocator,
        node_id: ?core.NodeId,
        rect: Rect,
        path: []const u8,
        tint: ?core.render_policy.Color,
    ) !void {
        const owned_path = try allocator.dupeZ(u8, path);
        errdefer allocator.free(owned_path);
        try self.items.append(allocator, .{ .svg = .{
            .header = self.itemHeader(node_id, rect, rect),
            .rect = rect,
            .path = owned_path,
            .tint = tint,
        } });
    }

    pub fn appendPdfPage(
        self: *Page,
        allocator: std.mem.Allocator,
        node_id: ?core.NodeId,
        rect: Rect,
        path: []const u8,
        page_index: usize,
        box: core.render_policy.PdfPageBox,
        copy_annotations: bool,
    ) !void {
        const owned_path = try allocator.dupeZ(u8, path);
        errdefer allocator.free(owned_path);
        try self.items.append(allocator, .{ .pdf_page = .{
            .header = self.itemHeader(node_id, rect, rect),
            .rect = rect,
            .path = owned_path,
            .page_index = page_index,
            .box = box,
            .copy_annotations = copy_annotations,
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
    schema_version: u32 = 2,
    pages: []Page,

    pub fn deinit(self: *Ir, allocator: std.mem.Allocator) void {
        for (self.pages) |*page| page.deinit(allocator);
        allocator.free(self.pages);
        self.* = .{ .pages = &.{} };
    }
};
