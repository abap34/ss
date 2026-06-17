const std = @import("std");
const core = @import("core");

pub const NodeId = core.NodeId;
pub const ResourceId = u32;
pub const Frame = core.Frame;
pub const Color = core.render_policy.Color;
pub const Dash = core.render_policy.Dash;
pub const FontFace = core.font.Face;
pub const FontStyle = core.font.Style;

pub const ResourceKind = enum {
    svg,
    png,

    pub fn fromExtension(path: []const u8) ?ResourceKind {
        const ext = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ext, ".svg")) return .svg;
        if (std.ascii.eqlIgnoreCase(ext, ".png")) return .png;
        return null;
    }

    pub fn name(self: ResourceKind) []const u8 {
        return @tagName(self);
    }
};

pub const Resource = struct {
    id: ResourceId,
    kind: ResourceKind,
    path: []u8,
    logical_key: []u8,
    intrinsic_width: f32,
    intrinsic_height: f32,
    tintable: bool = false,

    pub fn deinit(self: *Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.logical_key);
    }
};

pub const Document = struct {
    resources: std.ArrayList(Resource) = .empty,
    pages: std.ArrayList(Page) = .empty,

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.resources.items) |*resource| resource.deinit(allocator);
        self.resources.deinit(allocator);
        for (self.pages.items) |*page| page.deinit(allocator);
        self.pages.deinit(allocator);
    }

    pub fn resourceById(self: *const Document, id: ResourceId) ?*const Resource {
        for (self.resources.items) |*resource| {
            if (resource.id == id) return resource;
        }
        return null;
    }
};

pub const Page = struct {
    page_id: NodeId,
    index: usize,
    label: []const u8,
    frame: Frame,
    items: std.ArrayList(Item) = .empty,

    pub fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit(allocator);
    }
};

pub const Item = union(enum) {
    shape: ShapeItem,
    text: TextItem,
    resource: ResourceItem,

    pub fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .shape, .resource => {},
            .text => |*item| item.deinit(allocator),
        }
    }

    pub fn nodeId(self: Item) ?NodeId {
        return switch (self) {
            .shape => |item| item.node_id,
            .text => |item| item.node_id,
            .resource => |item| item.node_id,
        };
    }
};

pub const ShapeItem = struct {
    node_id: ?NodeId,
    frame: Frame,
    fill: ?Color = null,
    stroke: ?Color = null,
    line_width: f32 = 0,
    radius: f32 = 0,
    dash: ?Dash = null,
    clip: bool = false,
};

pub const ResourceItem = struct {
    node_id: NodeId,
    resource_id: ResourceId,
    frame: Frame,
    tint: ?Color = null,
    clip: bool = true,
    link_id: ?[]const u8 = null,
};

pub const TextItem = struct {
    node_id: NodeId,
    frame: Frame,
    clip: bool = true,
    lines: std.ArrayList(TextLine) = .empty,

    pub fn deinit(self: *TextItem, allocator: std.mem.Allocator) void {
        for (self.lines.items) |*line| line.deinit(allocator);
        self.lines.deinit(allocator);
    }
};

pub const TextLine = struct {
    baseline_y: f32,
    line_height: f32,
    spans: std.ArrayList(TextSpan) = .empty,

    pub fn deinit(self: *TextLine, allocator: std.mem.Allocator) void {
        for (self.spans.items) |*span| span.deinit(allocator);
        self.spans.deinit(allocator);
    }
};

pub const TextSpan = union(enum) {
    glyphs: GlyphSpan,
    resource: InlineResourceSpan,

    pub fn deinit(self: *TextSpan, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .glyphs => |*span| span.deinit(allocator),
            .resource => {},
        }
    }
};

pub const GlyphSpan = struct {
    x: f32,
    text: []u8,
    font: FontFace,
    font_size: f32,
    color: Color,
    link_url: ?[]u8 = null,
    strikethrough: bool = false,

    pub fn deinit(self: *GlyphSpan, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.link_url) |url| allocator.free(url);
    }
};

pub const InlineResourceSpan = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    resource_id: ResourceId,
    tint: ?Color = null,
    link_url: ?[]const u8 = null,
};

pub fn cloneFrame(frame: core.Frame) Frame {
    return .{
        .x = frame.x,
        .y = frame.y,
        .width = frame.width,
        .height = frame.height,
        .x_set = frame.x_set,
        .y_set = frame.y_set,
    };
}
