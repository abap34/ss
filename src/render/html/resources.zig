const std = @import("std");
const render = @import("render");
const font_tools = @import("font.zig");

pub const Kind = render.ResourceKind;

const AssetKey = struct {
    kind: Kind,
    resource: render.ResourceId,
    font_index: ?u32,
};

const LocalFontKey = struct {
    resource: render.ResourceId,
    face_index: u32,
};

const EmbeddedKey = struct {
    kind: Kind,
    digest: [32]u8,
};

pub const Asset = struct {
    kind: Kind,
    resource: render.ResourceId,
    font_index: ?u32,
    digest: [32]u8,
    media_type: []const u8,
    relative_path: []u8,
    bytes: []u8,
    owns_bytes: bool = true,
    shared_bytes: ?*SharedBytes = null,
    embedded_reference: ?[]u8 = null,
    emit_embedded_data: bool = false,

    fn deinit(self: *Asset, allocator: std.mem.Allocator) void {
        allocator.free(self.relative_path);
        if (self.shared_bytes) |owner| {
            owner.release();
        } else if (self.owns_bytes) {
            allocator.free(self.bytes);
        }
        if (self.embedded_reference) |reference| allocator.free(reference);
    }
};

const SharedBytes = struct {
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),
    bytes: []u8,

    fn create(allocator: std.mem.Allocator, bytes: []u8) !*SharedBytes {
        const owner = try allocator.create(SharedBytes);
        owner.* = .{ .allocator = allocator, .bytes = bytes };
        return owner;
    }

    fn retain(self: *SharedBytes) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    fn release(self: *SharedBytes) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        self.allocator.free(self.bytes);
        self.allocator.destroy(self);
    }
};

const FontCacheKey = struct {
    resource: render.ResourceId,
    face_index: u32,
};

const CachedFont = union(enum) {
    local,
    resource: struct {
        digest: [32]u8,
        extension: []const u8,
        bytes: *SharedBytes,
    },
};

const CachedFontEntry = struct {
    value: CachedFont,
    last_used: u64,

    fn byteSize(self: *const CachedFontEntry) usize {
        return switch (self.value) {
            .local => 0,
            .resource => |resource| resource.bytes.bytes.len,
        };
    }

    fn deinit(self: *CachedFontEntry) void {
        switch (self.value) {
            .local => {},
            .resource => |resource| resource.bytes.release(),
        }
    }
};

const max_cached_font_bytes = 256 * 1024 * 1024;

pub const Cache = struct {
    allocator: std.mem.Allocator,
    fonts: std.AutoHashMap(FontCacheKey, CachedFontEntry),
    resource_digests: std.AutoHashMap(render.ResourceId, [32]u8),
    font_bytes: usize = 0,
    access_clock: u64 = 0,

    const max_font_entries = 32;
    const max_resource_digests = 4096;

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{
            .allocator = allocator,
            .fonts = std.AutoHashMap(FontCacheKey, CachedFontEntry).init(allocator),
            .resource_digests = std.AutoHashMap(render.ResourceId, [32]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Cache) void {
        var values = self.fonts.valueIterator();
        while (values.next()) |cached_font| cached_font.deinit();
        self.fonts.deinit();
        self.resource_digests.deinit();
        self.* = undefined;
    }

    fn resourceDigest(self: *Cache, resource: *const render.Resource) ![32]u8 {
        if (self.resource_digests.get(resource.id)) |digest| return digest;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(resource.bytes, &digest, .{});
        if (self.resource_digests.count() >= max_resource_digests) self.resource_digests.clearRetainingCapacity();
        try self.resource_digests.putNoClobber(resource.id, digest);
        return digest;
    }

    fn font(self: *Cache, graph: *const render.ResourceGraph, id: render.ResourceId, face_index: u32) !*const CachedFont {
        const key = FontCacheKey{ .resource = id, .face_index = face_index };
        if (self.fonts.getPtr(key)) |cached| {
            cached.last_used = self.nextAccess();
            return &cached.value;
        }
        const source = graph.find(id) orelse return error.MissingRenderResource;
        if (source.kind != .font) return error.RenderResourceKindConflict;
        const cached: CachedFont = blk: {
            const face = font_tools.extractFace(self.allocator, source.bytes, face_index) catch |err| switch (err) {
                error.FontEmbeddingRestricted => break :blk .local,
                else => return err,
            };
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(face.bytes, &digest, .{});
            const owned_bytes = SharedBytes.create(self.allocator, face.bytes) catch |err| {
                self.allocator.free(face.bytes);
                return err;
            };
            break :blk .{ .resource = .{
                .digest = digest,
                .extension = face.extension,
                .bytes = owned_bytes,
            } };
        };
        errdefer switch (cached) {
            .local => {},
            .resource => |value| value.bytes.release(),
        };
        const byte_size = switch (cached) {
            .local => 0,
            .resource => |value| value.bytes.bytes.len,
        };
        if (byte_size > max_cached_font_bytes) return error.FontCacheEntryTooLarge;
        while (self.fonts.count() > 0 and
            (self.fonts.count() >= max_font_entries or
                byte_size > max_cached_font_bytes or self.font_bytes > max_cached_font_bytes - byte_size))
        {
            self.evictLeastRecentlyUsedFont();
        }
        try self.fonts.putNoClobber(key, .{ .value = cached, .last_used = self.nextAccess() });
        self.font_bytes += byte_size;
        return &self.fonts.getPtr(key).?.value;
    }

    fn nextAccess(self: *Cache) u64 {
        self.access_clock +%= 1;
        if (self.access_clock == 0) self.access_clock = 1;
        return self.access_clock;
    }

    fn evictLeastRecentlyUsedFont(self: *Cache) void {
        var oldest_key: ?FontCacheKey = null;
        var oldest_access: u64 = std.math.maxInt(u64);
        var iterator = self.fonts.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.last_used >= oldest_access) continue;
            oldest_key = entry.key_ptr.*;
            oldest_access = entry.value_ptr.last_used;
        }
        const removed = self.fonts.fetchRemove(oldest_key orelse return) orelse return;
        self.font_bytes -= removed.value.byteSize();
        var entry = removed.value;
        entry.deinit();
    }
};

pub const Set = struct {
    assets: []Asset,
    local_fonts: []LocalFont,
    has_pdf: bool,
    asset_index: std.AutoHashMap(AssetKey, usize),
    local_font_index: std.AutoHashMap(LocalFontKey, usize),

    pub fn deinit(self: *Set, allocator: std.mem.Allocator) void {
        for (self.assets) |*asset| asset.deinit(allocator);
        allocator.free(self.assets);
        for (self.local_fonts) |font| allocator.free(font.family);
        allocator.free(self.local_fonts);
        self.asset_index.deinit();
        self.local_font_index.deinit();
        self.* = undefined;
    }

    pub fn prepareEmbeddedResources(self: *Set, allocator: std.mem.Allocator) !void {
        var seen = std.AutoHashMap(EmbeddedKey, void).init(allocator);
        defer seen.deinit();
        for (self.assets) |*asset| {
            if (asset.embedded_reference != null) continue;
            const digest_hex = std.fmt.bytesToHex(asset.digest, .lower);
            asset.embedded_reference = try std.fmt.allocPrint(allocator, "ss-resource:{s}:{s}", .{ @tagName(asset.kind), digest_hex });
            const entry = try seen.getOrPut(.{ .kind = asset.kind, .digest = asset.digest });
            asset.emit_embedded_data = !entry.found_existing;
        }
    }

    fn findAsset(self: *const Set, kind: Kind, resource: render.ResourceId, font_index: ?u32) ?*const Asset {
        const index = self.asset_index.get(.{ .kind = kind, .resource = resource, .font_index = font_index }) orelse return null;
        return &self.assets[index];
    }

    fn hasLocalFont(self: *const Set, resource: render.ResourceId, face_index: u32) bool {
        return self.local_font_index.contains(.{ .resource = resource, .face_index = face_index });
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

pub fn collect(allocator: std.mem.Allocator, ir: *const render.Ir, cache: ?*Cache) !Set {
    var assets = std.ArrayList(Asset).empty;
    var local_fonts = std.ArrayList(LocalFont).empty;
    var asset_index = std.AutoHashMap(AssetKey, usize).init(allocator);
    var local_font_index = std.AutoHashMap(LocalFontKey, usize).init(allocator);
    errdefer {
        for (assets.items) |*asset| asset.deinit(allocator);
        assets.deinit(allocator);
        for (local_fonts.items) |local| allocator.free(local.family);
        local_fonts.deinit(allocator);
        asset_index.deinit();
        local_font_index.deinit();
    }
    var has_pdf = false;
    for (ir.fonts.instances) |instance| {
        try addFont(allocator, &assets, &local_fonts, &asset_index, &local_font_index, &ir.resources, instance.resource, instance.face_index, instance.family, cache);
    }
    for (ir.pages) |page| {
        for (page.items.items) |item| switch (item) {
            .text => {},
            .raster => |value| try add(allocator, &assets, &asset_index, &ir.resources, .raster, value.resource, cache),
            .svg => |value| try add(allocator, &assets, &asset_index, &ir.resources, .svg, value.resource, cache),
            .latex => |value| {
                has_pdf = true;
                try add(allocator, &assets, &asset_index, &ir.resources, .latex_pdf, value.resource, cache);
            },
            .pdf_page => |value| {
                has_pdf = true;
                try add(allocator, &assets, &asset_index, &ir.resources, .pdf, value.resource, cache);
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
        .asset_index = asset_index,
        .local_font_index = local_font_index,
    };
}

fn add(
    allocator: std.mem.Allocator,
    assets: *std.ArrayList(Asset),
    asset_index: *std.AutoHashMap(AssetKey, usize),
    graph: *const render.ResourceGraph,
    kind: Kind,
    id: render.ResourceId,
    cache: ?*Cache,
) !void {
    const key = AssetKey{ .kind = kind, .resource = id, .font_index = null };
    if (asset_index.contains(key)) return;
    const resource = graph.find(id) orelse return error.MissingRenderResource;
    if (resource.kind != kind) return error.RenderResourceKindConflict;
    const digest = if (cache) |resource_cache| try resource_cache.resourceDigest(resource) else blk: {
        var value: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(resource.bytes, &value, .{});
        break :blk value;
    };
    try assets.ensureUnusedCapacity(allocator, 1);
    try asset_index.ensureUnusedCapacity(1);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const relative_path = try std.fmt.allocPrint(allocator, "assets/{s}.{s}", .{ hex, resource.extension() });
    assets.appendAssumeCapacity(.{
        .kind = kind,
        .resource = id,
        .font_index = null,
        .digest = digest,
        .media_type = resource.mediaType(),
        .relative_path = relative_path,
        .bytes = resource.bytes,
        .owns_bytes = false,
    });
    asset_index.putAssumeCapacityNoClobber(key, assets.items.len - 1);
}

fn addFont(
    allocator: std.mem.Allocator,
    assets: *std.ArrayList(Asset),
    local_fonts: *std.ArrayList(LocalFont),
    asset_index: *std.AutoHashMap(AssetKey, usize),
    local_font_index: *std.AutoHashMap(LocalFontKey, usize),
    graph: *const render.ResourceGraph,
    id: render.ResourceId,
    face_index: u32,
    family: []const u8,
    cache: ?*Cache,
) !void {
    const asset_key = AssetKey{ .kind = .font, .resource = id, .font_index = face_index };
    const local_key = LocalFontKey{ .resource = id, .face_index = face_index };
    if (asset_index.contains(asset_key) or local_font_index.contains(local_key)) return;
    const resource = graph.find(id) orelse return error.MissingRenderResource;
    if (resource.kind != .font) return error.RenderResourceKindConflict;
    if (resource.bytes.len <= max_cached_font_bytes) if (cache) |font_cache| {
        const cached = font_cache.font(graph, id, face_index) catch |err| switch (err) {
            error.FontCacheEntryTooLarge => null,
            else => return err,
        };
        if (cached) |cached_font| switch (cached_font.*) {
            .local => {
                try local_fonts.ensureUnusedCapacity(allocator, 1);
                try local_font_index.ensureUnusedCapacity(1);
                const owned_family = try allocator.dupe(u8, family);
                local_fonts.appendAssumeCapacity(.{ .resource = id, .face_index = face_index, .family = owned_family });
                local_font_index.putAssumeCapacityNoClobber(local_key, local_fonts.items.len - 1);
                return;
            },
            .resource => |face| {
                try assets.ensureUnusedCapacity(allocator, 1);
                try asset_index.ensureUnusedCapacity(1);
                const hex = std.fmt.bytesToHex(face.digest, .lower);
                const relative_path = try std.fmt.allocPrint(allocator, "assets/{s}.{s}", .{ hex, face.extension });
                face.bytes.retain();
                assets.appendAssumeCapacity(.{
                    .kind = .font,
                    .resource = id,
                    .font_index = face_index,
                    .digest = face.digest,
                    .media_type = if (std.mem.eql(u8, face.extension, "otf")) "font/otf" else "font/ttf",
                    .relative_path = relative_path,
                    .bytes = face.bytes.bytes,
                    .owns_bytes = false,
                    .shared_bytes = face.bytes,
                });
                asset_index.putAssumeCapacityNoClobber(asset_key, assets.items.len - 1);
                return;
            },
        };
    };
    const face = font_tools.extractFace(allocator, resource.bytes, face_index) catch |err| switch (err) {
        error.FontEmbeddingRestricted => {
            try local_fonts.ensureUnusedCapacity(allocator, 1);
            try local_font_index.ensureUnusedCapacity(1);
            const owned_family = try allocator.dupe(u8, family);
            local_fonts.appendAssumeCapacity(.{ .resource = id, .face_index = face_index, .family = owned_family });
            local_font_index.putAssumeCapacityNoClobber(local_key, local_fonts.items.len - 1);
            return;
        },
        else => return err,
    };
    errdefer allocator.free(face.bytes);
    const identity = try identify(allocator, face.bytes, face.extension);
    errdefer allocator.free(identity.relative_path);
    try assets.ensureUnusedCapacity(allocator, 1);
    try asset_index.ensureUnusedCapacity(1);
    assets.appendAssumeCapacity(.{
        .kind = .font,
        .resource = id,
        .font_index = face_index,
        .digest = identity.digest,
        .media_type = if (std.mem.eql(u8, face.extension, "otf")) "font/otf" else "font/ttf",
        .relative_path = identity.relative_path,
        .bytes = face.bytes,
    });
    asset_index.putAssumeCapacityNoClobber(asset_key, assets.items.len - 1);
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
