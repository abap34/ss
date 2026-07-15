const std = @import("std");
const render_html = @import("../render/html.zig");

var temporary_counter: usize = 0;

pub const Asset = struct {
    kind: render_html.ResourceKind,
    resource_id: render_html.ResourceId,
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
        try publishResource(allocator, io, storage_path, source.bytes);
        const absolute_path = try std.fs.path.resolve(allocator, &.{ cwd_buffer[0..cwd_length], storage_path });
        errdefer allocator.free(absolute_path);
        const relative_path = try allocator.dupe(u8, source.relative_path);
        errdefer allocator.free(relative_path);
        try assets.append(allocator, .{
            .kind = source.kind,
            .resource_id = source.resource,
            .relative_path = relative_path,
            .path = absolute_path,
        });
    }
    return .{ .assets = try assets.toOwnedSlice(allocator) };
}

fn publishResource(allocator: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (try fileHasSize(io, path, bytes.len)) return;
    const serial = @atomicRmw(usize, &temporary_counter, .Add, 1, .monotonic);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp-{d}-{d}", .{ path, std.c.getpid(), serial });
    defer allocator.free(temporary);
    const cwd = std.Io.Dir.cwd();
    errdefer cwd.deleteFile(io, temporary) catch {};
    try cwd.writeFile(io, .{ .sub_path = temporary, .data = bytes, .flags = .{ .truncate = true } });
    cwd.rename(temporary, cwd, path, io) catch |err| {
        if (try fileHasSize(io, path, bytes.len)) {
            cwd.deleteFile(io, temporary) catch {};
            return;
        }
        return err;
    };
}

fn fileHasSize(io: std.Io, path: []const u8, expected: usize) !bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io);
    const info = try file.stat(io);
    return info.kind == .file and info.size == expected;
}
