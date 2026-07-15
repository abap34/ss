const std = @import("std");

pub const Id = [32]u8;

pub const Kind = enum {
    font,
    raster,
    svg,
    pdf,
    math_pdf,
};

pub const Resource = struct {
    id: Id,
    kind: Kind,
    name: []u8,
    bytes: []u8,

    fn deinit(self: *Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.bytes);
    }

    pub fn extension(self: *const Resource) []const u8 {
        return extensionFor(self.kind, self.bytes);
    }

    pub fn mediaType(self: *const Resource) []const u8 {
        return switch (self.kind) {
            .font => if (std.mem.startsWith(u8, self.bytes, "ttcf"))
                "font/collection"
            else if (std.mem.startsWith(u8, self.bytes, "wOF2"))
                "font/woff2"
            else if (std.mem.startsWith(u8, self.bytes, "wOFF"))
                "font/woff"
            else
                "font/sfnt",
            .svg => "image/svg+xml",
            .pdf, .math_pdf => "application/pdf",
            .raster => if (std.mem.startsWith(u8, self.bytes, "\x89PNG\r\n\x1a\n"))
                "image/png"
            else if (std.mem.startsWith(u8, self.bytes, "GIF87a") or std.mem.startsWith(u8, self.bytes, "GIF89a"))
                "image/gif"
            else if (self.bytes.len >= 2 and self.bytes[0] == 0xff and self.bytes[1] == 0xd8)
                "image/jpeg"
            else
                "application/octet-stream",
        };
    }
};

pub const Graph = struct {
    entries: []Resource = &.{},

    pub fn deinit(self: *Graph, allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
        self.* = .{};
    }

    pub fn find(self: *const Graph, id: Id) ?*const Resource {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, &entry.id, &id)) return entry;
        }
        return null;
    }
};

pub const Builder = struct {
    entries: std.ArrayList(Resource) = .empty,

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    pub fn addPath(
        self: *Builder,
        allocator: std.mem.Allocator,
        io: std.Io,
        kind: Kind,
        path: []const u8,
    ) !Id {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        errdefer allocator.free(bytes);
        const id = identify(kind, bytes);
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, &entry.id, &id)) {
                allocator.free(bytes);
                if (entry.kind != kind) return error.RenderResourceKindConflict;
                return id;
            }
        }
        const name = try allocator.dupe(u8, std.fs.path.basename(path));
        errdefer allocator.free(name);
        try self.entries.append(allocator, .{ .id = id, .kind = kind, .name = name, .bytes = bytes });
        return id;
    }

    pub fn take(self: *Builder, allocator: std.mem.Allocator) !Graph {
        const entries = try self.entries.toOwnedSlice(allocator);
        self.* = .{};
        return .{ .entries = entries };
    }
};

pub fn identify(kind: Kind, bytes: []const u8) Id {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("ss-render-resource-v1\x00");
    hasher.update(@tagName(kind));
    hasher.update("\x00");
    hasher.update(bytes);
    var id: Id = undefined;
    hasher.final(&id);
    return id;
}

pub fn extensionFor(kind: Kind, bytes: []const u8) []const u8 {
    return switch (kind) {
        .font => if (std.mem.startsWith(u8, bytes, "OTTO"))
            "otf"
        else if (std.mem.startsWith(u8, bytes, "ttcf"))
            "ttc"
        else if (std.mem.startsWith(u8, bytes, "wOF2"))
            "woff2"
        else if (std.mem.startsWith(u8, bytes, "wOFF"))
            "woff"
        else
            "ttf",
        .svg => "svg",
        .pdf, .math_pdf => "pdf",
        .raster => if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n"))
            "png"
        else if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a"))
            "gif"
        else if (bytes.len >= 2 and bytes[0] == 0xff and bytes[1] == 0xd8)
            "jpg"
        else
            "bin",
    };
}
