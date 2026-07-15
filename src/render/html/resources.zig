const std = @import("std");
const render = @import("render");
const font = @import("font.zig");

pub const Kind = render.ResourceKind;

pub const Asset = struct {
    kind: Kind,
    resource: render.ResourceId,
    font_index: ?u32,
    relative_path: []u8,
    bytes: []u8,

    fn deinit(self: *Asset, allocator: std.mem.Allocator) void {
        allocator.free(self.relative_path);
        allocator.free(self.bytes);
    }
};

pub const Set = struct {
    assets: []Asset,
    has_pdf: bool,

    pub fn deinit(self: *Set, allocator: std.mem.Allocator) void {
        for (self.assets) |*asset| asset.deinit(allocator);
        allocator.free(self.assets);
        self.* = .{ .assets = &.{}, .has_pdf = false };
    }

    pub fn path(self: *const Set, kind: Kind, resource: render.ResourceId) ?[]const u8 {
        for (self.assets) |asset| {
            if (asset.kind == kind and asset.font_index == null and std.mem.eql(u8, &asset.resource, &resource)) return asset.relative_path;
        }
        return null;
    }

    pub fn fontPath(self: *const Set, resource: render.ResourceId, face_index: u32) ?[]const u8 {
        for (self.assets) |asset| {
            if (asset.kind == .font and asset.font_index == face_index and std.mem.eql(u8, &asset.resource, &resource)) return asset.relative_path;
        }
        return null;
    }
};

pub fn collect(allocator: std.mem.Allocator, ir: *const render.Ir) !Set {
    var assets = std.ArrayList(Asset).empty;
    errdefer {
        for (assets.items) |*asset| asset.deinit(allocator);
        assets.deinit(allocator);
    }
    var has_pdf = false;
    for (ir.fonts.instances) |instance| {
        try addFont(allocator, &assets, &ir.resources, instance.resource, instance.face_index);
    }
    for (ir.pages) |page| {
        for (page.items.items) |item| switch (item) {
            .text => {},
            .raster => |value| try add(allocator, &assets, &ir.resources, .raster, value.resource),
            .svg => |value| try add(allocator, &assets, &ir.resources, .svg, value.resource),
            .pdf_page => |value| {
                has_pdf = true;
                try add(allocator, &assets, &ir.resources, .pdf, value.resource);
            },
            else => {},
        };
    }
    return .{ .assets = try assets.toOwnedSlice(allocator), .has_pdf = has_pdf };
}

fn add(
    allocator: std.mem.Allocator,
    assets: *std.ArrayList(Asset),
    graph: *const render.ResourceGraph,
    kind: Kind,
    id: render.ResourceId,
) !void {
    for (assets.items) |asset| {
        if (asset.kind == kind and asset.font_index == null and std.mem.eql(u8, &asset.resource, &id)) return;
    }
    const resource = graph.find(id) orelse return error.MissingRenderResource;
    if (resource.kind != kind) return error.RenderResourceKindConflict;
    const bytes = try allocator.dupe(u8, resource.bytes);
    errdefer allocator.free(bytes);
    const relative_path = try relativePath(allocator, bytes, resource.extension());
    errdefer allocator.free(relative_path);
    try assets.append(allocator, .{ .kind = kind, .resource = id, .font_index = null, .relative_path = relative_path, .bytes = bytes });
}

fn addFont(
    allocator: std.mem.Allocator,
    assets: *std.ArrayList(Asset),
    graph: *const render.ResourceGraph,
    id: render.ResourceId,
    face_index: u32,
) !void {
    for (assets.items) |asset| {
        if (asset.kind == .font and asset.font_index == face_index and std.mem.eql(u8, &asset.resource, &id)) return;
    }
    const resource = graph.find(id) orelse return error.MissingRenderResource;
    if (resource.kind != .font) return error.RenderResourceKindConflict;
    const face = try font.extractFace(allocator, resource.bytes, face_index);
    errdefer allocator.free(face.bytes);
    const relative_path = try relativePath(allocator, face.bytes, face.extension);
    errdefer allocator.free(relative_path);
    try assets.append(allocator, .{ .kind = .font, .resource = id, .font_index = face_index, .relative_path = relative_path, .bytes = face.bytes });
}

fn relativePath(allocator: std.mem.Allocator, bytes: []const u8, extension: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return try std.fmt.allocPrint(allocator, "assets/{s}.{s}", .{ hex, extension });
}
