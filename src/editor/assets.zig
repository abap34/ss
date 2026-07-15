const std = @import("std");
const render_html = @import("../render/html.zig");

var temporary_counter: usize = 0;

pub const Asset = struct {
    kind: render_html.ResourceKind,
    resource_id: render_html.ResourceId,
    digest: [32]u8,
    media_type: []const u8,
    relative_path: []u8,
    path: []u8,

    fn deinit(self: *Asset, allocator: std.mem.Allocator) void {
        allocator.free(self.relative_path);
        allocator.free(self.path);
    }
};

pub const Set = struct {
    assets: []Asset = &.{},

    pub fn deinit(self: *Set, allocator: std.mem.Allocator) void {
        for (self.assets) |*asset| asset.deinit(allocator);
        allocator.free(self.assets);
        self.* = .{};
    }
};

pub fn publish(
    allocator: std.mem.Allocator,
    io: std.Io,
    fragment: *const render_html.Fragment,
    cache_directory: []const u8,
) !Set {
    const storage_directory = try std.fs.path.join(allocator, &.{ cache_directory, "editor" });
    defer allocator.free(storage_directory);
    try std.Io.Dir.cwd().createDirPath(io, storage_directory);
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = try std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer);

    var assets = std.ArrayList(Asset).empty;
    errdefer {
        for (assets.items) |*asset| asset.deinit(allocator);
        assets.deinit(allocator);
    }
    for (fragment.assets.assets) |source| {
        const storage_path = try std.fs.path.join(allocator, &.{ storage_directory, source.relative_path });
        defer allocator.free(storage_path);
        if (std.fs.path.dirname(storage_path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
        try publishResource(allocator, io, storage_path, source.bytes, source.digest);
        const absolute_path = try std.fs.path.resolve(allocator, &.{ cwd_buffer[0..cwd_length], storage_path });
        errdefer allocator.free(absolute_path);
        const relative_path = try allocator.dupe(u8, source.relative_path);
        errdefer allocator.free(relative_path);
        try assets.append(allocator, .{
            .kind = source.kind,
            .resource_id = source.resource,
            .digest = source.digest,
            .media_type = source.media_type,
            .relative_path = relative_path,
            .path = absolute_path,
        });
    }
    return .{ .assets = try assets.toOwnedSlice(allocator) };
}

fn publishResource(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
    digest: [32]u8,
) !void {
    if (try fileMatches(io, path, bytes.len, digest)) return;
    const serial = @atomicRmw(usize, &temporary_counter, .Add, 1, .monotonic);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp-{d}-{d}", .{ path, std.c.getpid(), serial });
    defer allocator.free(temporary);
    const cwd = std.Io.Dir.cwd();
    errdefer cwd.deleteFile(io, temporary) catch {};
    try cwd.writeFile(io, .{ .sub_path = temporary, .data = bytes, .flags = .{ .truncate = true } });
    cwd.rename(temporary, cwd, path, io) catch |err| {
        if (try fileMatches(io, path, bytes.len, digest)) {
            cwd.deleteFile(io, temporary) catch {};
            return;
        }
        return err;
    };
}

fn fileMatches(io: std.Io, path: []const u8, expected_size: usize, expected_digest: [32]u8) !bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io);
    const info = try file.stat(io);
    if (info.kind != .file or info.size != expected_size) return false;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < info.size) {
        var vectors = [_][]u8{buffer[0..@intCast(@min(@as(u64, buffer.len), info.size - offset))]};
        const count = try file.readPositional(io, vectors[0..], offset);
        if (count == 0) return false;
        hasher.update(buffer[0..count]);
        offset += count;
    }
    var actual: [32]u8 = undefined;
    hasher.final(&actual);
    return std.mem.eql(u8, &actual, &expected_digest);
}
