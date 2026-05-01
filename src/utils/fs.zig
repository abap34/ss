const std = @import("std");

pub fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

pub fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .truncate = true },
    });
}

pub fn siblingPathWithExtension(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    ext: []const u8,
) ![]const u8 {
    const dir = std.fs.path.dirname(input_path) orelse ".";
    const stem = std.fs.path.stem(input_path);
    return std.fmt.allocPrint(allocator, "{s}/{s}.{s}", .{ dir, stem, ext });
}

pub fn fileExists(allocator: std.mem.Allocator, path: []const u8) bool {
    const zpath = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(zpath);
    return std.c.access(zpath.ptr, 0) == 0;
}
