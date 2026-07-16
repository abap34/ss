const std = @import("std");
const render = @import("render");
const font_tools = @import("font.zig");

pub const Kind = render.ResourceKind;

pub const Asset = struct {
    kind: Kind,
    resource: render.ResourceId,
    font_index: ?u32,
    digest: [32]u8,
    media_type: []const u8,
    relative_path: []u8,
    bytes: []u8,

    fn deinit(self: *Asset, allocator: std.mem.Allocator) void {
        allocator.free(self.relative_path);
        allocator.free(self.bytes);
    }
};

pub const Set = struct {
    assets: []Asset,
    local_fonts: []LocalFont,
    has_pdf: bool,

    pub fn deinit(self: *Set, allocator: std.mem.Allocator) void {
        for (self.assets) |*asset| asset.deinit(allocator);
        allocator.free(self.assets);
        for (self.local_fonts) |font| allocator.free(font.family);
        allocator.free(self.local_fonts);
        self.* = .{ .assets = &.{}, .local_fonts = &.{}, .has_pdf = false };
    }

    pub fn path(self: *const Set, kind: Kind, resource: render.ResourceId) ?[]const u8 {
        for (self.assets) |asset| {
            if (asset.kind == kind and asset.font_index == null and std.mem.eql(u8, &asset.resource, &resource)) return asset.relative_path;
        }
        return null;
    }

    pub fn fontSource(self: *const Set, resource: render.ResourceId, face_index: u32) ?FontSource {
        for (self.assets) |asset| {
            if (asset.kind == .font and asset.font_index == face_index and std.mem.eql(u8, &asset.resource, &resource)) {
                return .{ .embedded = asset.relative_path };
            }
        }
        for (self.local_fonts) |local| if (local.face_index == face_index and std.mem.eql(u8, &local.resource, &resource)) return .local;
        return null;
    }
};

pub const LocalFont = struct {
    resource: render.ResourceId,
    face_index: u32,
    family: []u8,
};

pub const FontSource = union(enum) {
    embedded: []const u8,
    local,
};

pub fn collect(allocator: std.mem.Allocator, ir: *const render.Ir) !Set {
    var assets = std.ArrayList(Asset).empty;
    var local_fonts = std.ArrayList(LocalFont).empty;
    errdefer {
        for (assets.items) |*asset| asset.deinit(allocator);
        assets.deinit(allocator);
        for (local_fonts.items) |local| allocator.free(local.family);
        local_fonts.deinit(allocator);
    }
    var has_pdf = false;
    for (ir.fonts.instances) |instance| {
        try addFont(allocator, &assets, &local_fonts, &ir.resources, instance.resource, instance.face_index, instance.family);
    }
    for (ir.pages) |page| {
        for (page.items.items) |item| switch (item) {
            .text => {},
            .raster => |value| try add(allocator, &assets, &ir.resources, .raster, value.resource),
            .svg => |value| try add(allocator, &assets, &ir.resources, .svg, value.resource),
            .math => |value| switch (value.content) {
                .structured => {},
                .raw_pdf => |raw| {
                    has_pdf = true;
                    try add(allocator, &assets, &ir.resources, .math_pdf, raw.resource);
                },
            },
            .pdf_page => |value| {
                has_pdf = true;
                try add(allocator, &assets, &ir.resources, .pdf, value.resource);
            },
            else => {},
        };
    }
    const owned_assets = try assets.toOwnedSlice(allocator);
    errdefer {
        for (owned_assets) |*asset| asset.deinit(allocator);
        allocator.free(owned_assets);
    }
    return .{
        .assets = owned_assets,
        .local_fonts = try local_fonts.toOwnedSlice(allocator),
        .has_pdf = has_pdf,
    };
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
    const identity = try identify(allocator, bytes, resource.extension());
    errdefer allocator.free(identity.relative_path);
    try assets.append(allocator, .{
        .kind = kind,
        .resource = id,
        .font_index = null,
        .digest = identity.digest,
        .media_type = resource.mediaType(),
        .relative_path = identity.relative_path,
        .bytes = bytes,
    });
}

fn addFont(
    allocator: std.mem.Allocator,
    assets: *std.ArrayList(Asset),
    local_fonts: *std.ArrayList(LocalFont),
    graph: *const render.ResourceGraph,
    id: render.ResourceId,
    face_index: u32,
    family: []const u8,
) !void {
    for (assets.items) |asset| {
        if (asset.kind == .font and asset.font_index == face_index and std.mem.eql(u8, &asset.resource, &id)) return;
    }
    for (local_fonts.items) |local| if (local.face_index == face_index and std.mem.eql(u8, &local.resource, &id)) return;
    const resource = graph.find(id) orelse return error.MissingRenderResource;
    if (resource.kind != .font) return error.RenderResourceKindConflict;
    const face = font_tools.extractFace(allocator, resource.bytes, face_index) catch |err| switch (err) {
        error.FontEmbeddingRestricted => {
            const owned_family = try allocator.dupe(u8, family);
            errdefer allocator.free(owned_family);
            try local_fonts.append(allocator, .{ .resource = id, .face_index = face_index, .family = owned_family });
            return;
        },
        else => return err,
    };
    errdefer allocator.free(face.bytes);
    const identity = try identify(allocator, face.bytes, face.extension);
    errdefer allocator.free(identity.relative_path);
    try assets.append(allocator, .{
        .kind = .font,
        .resource = id,
        .font_index = face_index,
        .digest = identity.digest,
        .media_type = if (std.mem.eql(u8, face.extension, "otf")) "font/otf" else "font/ttf",
        .relative_path = identity.relative_path,
        .bytes = face.bytes,
    });
}

const Identity = struct {
    digest: [32]u8,
    relative_path: []u8,
};

fn identify(allocator: std.mem.Allocator, bytes: []const u8, extension: []const u8) !Identity {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return .{ .digest = digest, .relative_path = try std.fmt.allocPrint(allocator, "assets/{s}.{s}", .{ hex, extension }) };
}
