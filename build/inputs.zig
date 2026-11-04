const std = @import("std");

pub fn pathFromRoot(b: *std.Build, path: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    return b.root.joinString(b.allocator, path) catch @panic("OOM");
}

pub fn readFile(b: *std.Build, path: []const u8, limit: std.Io.Limit) ![]u8 {
    b.dependOnFileContents(b.path(path));
    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, pathFromRoot(b, path), b.allocator, limit);
}

pub fn access(b: *std.Build, path: []const u8) !void {
    b.graph.poisonCache();
    return std.Io.Dir.cwd().access(b.graph.io, pathFromRoot(b, path), .{});
}
