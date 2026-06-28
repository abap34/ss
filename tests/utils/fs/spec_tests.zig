const std = @import("std");
const utils = @import("utils");

const testing = std.testing;

fn writeTmpFile(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8, data: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], name });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = data, .flags = .{ .truncate = true } });
    return path;
}

test "utils fs spec: SVG image dimensions use explicit size attributes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const path = try writeTmpFile(allocator, tmp, "explicit.svg",
        \\<svg xmlns="http://www.w3.org/2000/svg" width="640px" height="360">
        \\</svg>
    );
    defer allocator.free(path);

    const dimensions = try utils.fs.readImageDimensions(allocator, path);
    try testing.expectEqual(@as(f32, 640), dimensions.width);
    try testing.expectEqual(@as(f32, 360), dimensions.height);
}

test "utils fs spec: SVG image dimensions fall back to viewBox" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const path = try writeTmpFile(allocator, tmp, "viewbox.svg",
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 256">
        \\</svg>
    );
    defer allocator.free(path);

    const dimensions = try utils.fs.readImageDimensions(allocator, path);
    try testing.expectEqual(@as(f32, 512), dimensions.width);
    try testing.expectEqual(@as(f32, 256), dimensions.height);
}
