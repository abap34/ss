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
    embedded_reference: ?[]u8 = null,
    embedded_data: ?[]u8 = null,

    fn deinit(self: *Asset, allocator: std.mem.Allocator) void {
        allocator.free(self.relative_path);
        allocator.free(self.bytes);
        if (self.embedded_reference) |reference| allocator.free(reference);
        if (self.embedded_data) |data| allocator.free(data);
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

    pub fn prepareEmbeddedResources(self: *Set, allocator: std.mem.Allocator) !void {
        for (self.assets, 0..) |*asset, index| {
            if (asset.embedded_reference != null) continue;
            const digest_hex = std.fmt.bytesToHex(asset.digest, .lower);
            asset.embedded_reference = try std.fmt.allocPrint(allocator, "ss-resource:{s}:{s}", .{ @tagName(asset.kind), digest_hex });
            var duplicate = false;
            for (self.assets[0..index]) |previous| {
                if (std.mem.eql(u8, previous.embedded_reference.?, asset.embedded_reference.?)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) asset.embedded_data = try base64(allocator, asset.bytes);
        }
    }

    fn findAsset(self: *const Set, kind: Kind, resource: render.ResourceId, font_index: ?u32) ?*const Asset {
        for (self.assets) |*asset| {
            if (asset.kind == kind and asset.font_index == font_index and std.mem.eql(u8, &asset.resource, &resource)) return asset;
        }
        return null;
    }

    fn hasLocalFont(self: *const Set, resource: render.ResourceId, face_index: u32) bool {
        for (self.local_fonts) |local| {
            if (local.face_index == face_index and std.mem.eql(u8, &local.resource, &resource)) return true;
        }
        return false;
    }
};

pub const ReferenceMode = enum { external, embedded };

pub const References = struct {
    set: *const Set,
    mode: ReferenceMode,

    pub fn hasPdf(self: References) bool {
        return self.set.has_pdf;
    }

    pub fn isEmbedded(self: References) bool {
        return self.mode == .embedded;
    }

    pub fn reference(self: References, kind: Kind, resource: render.ResourceId) ?[]const u8 {
        const asset = self.set.findAsset(kind, resource, null) orelse return null;
        return switch (self.mode) {
            .external => asset.relative_path,
            .embedded => asset.embedded_reference,
        };
    }

    pub fn fontSource(self: References, resource: render.ResourceId, face_index: u32) ?FontSource {
        if (self.set.findAsset(.font, resource, face_index)) |asset| {
            const source = switch (self.mode) {
                .external => asset.relative_path,
                .embedded => asset.embedded_reference orelse return null,
            };
            return .{ .resource = source };
        }
        return if (self.set.hasLocalFont(resource, face_index)) .local else null;
    }
};

pub const LocalFont = struct {
    resource: render.ResourceId,
    face_index: u32,
    family: []u8,
};

pub const FontSource = union(enum) {
    resource: []const u8,
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

pub fn dataUrl(allocator: std.mem.Allocator, media_type: []const u8, bytes: []const u8) ![]u8 {
    const prefix = try std.fmt.allocPrint(allocator, "data:{s};base64,", .{media_type});
    defer allocator.free(prefix);
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const url = try allocator.alloc(u8, prefix.len + encoded_len);
    @memcpy(url[0..prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(url[prefix.len..], bytes);
    return url;
}

fn base64(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return encoded;
}
