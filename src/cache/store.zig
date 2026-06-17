const std = @import("std");

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8) Store {
        return .{ .allocator = allocator, .io = io, .root = root };
    }

    pub fn ensure(self: Store) !void {
        try std.Io.Dir.cwd().createDirPath(self.io, self.root);
    }

    pub fn namespacePath(self: Store, namespace: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.root, namespace });
    }

    pub fn ensureNamespace(self: Store, namespace: []const u8) ![]u8 {
        const path = try self.namespacePath(namespace);
        errdefer self.allocator.free(path);
        try std.Io.Dir.cwd().createDirPath(self.io, path);
        return path;
    }

    pub fn filePath(self: Store, namespace: []const u8, file_name: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.root, namespace, file_name });
    }

    pub fn exists(_: Store, path: []const u8) bool {
        return fileExists(path);
    }
};

pub fn fileExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(@ptrCast(&buf), 0) == 0;
}
