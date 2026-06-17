const std = @import("std");
const scene = @import("../scene.zig");

pub const AllowedRoots = struct {
    workspace: []const u8,
    cache: []const u8,
};

pub fn resourcePathAllowed(path: []const u8, roots: AllowedRoots) bool {
    return isInside(path, roots.workspace) or isInside(path, roots.cache);
}

pub fn localPath(resource: scene.Resource) []const u8 {
    return resource.path;
}

fn isInside(path: []const u8, root: []const u8) bool {
    if (root.len == 0) return false;
    if (std.mem.eql(u8, path, root)) return true;
    return path.len > root.len and
        path[root.len] == std.fs.path.sep and
        std.mem.eql(u8, path[0..root.len], root);
}
