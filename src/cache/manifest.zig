const std = @import("std");
const publish = @import("publish.zig");

pub const PageManifest = struct {
    hashes: []u64,

    pub fn deinit(self: *PageManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.hashes);
    }
};

pub fn readPageManifest(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !PageManifest {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCacheManifest;
    const value = parsed.value.object.getPtr("pageHashes") orelse return error.InvalidCacheManifest;
    if (value.* != .array) return error.InvalidCacheManifest;
    const hashes = try allocator.alloc(u64, value.array.items.len);
    errdefer allocator.free(hashes);
    for (value.array.items, 0..) |item, index| {
        if (item != .string) return error.InvalidCacheManifest;
        hashes[index] = std.fmt.parseUnsigned(u64, item.string, 16) catch return error.InvalidCacheManifest;
    }
    return .{ .hashes = hashes };
}

pub fn writePageManifest(allocator: std.mem.Allocator, io: std.Io, path: []const u8, hashes: []const u64) !void {
    const tmp = try publish.tempPath(allocator, path, "json");
    defer allocator.free(tmp);
    errdefer publish.deleteFileIfExists(io, tmp);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"schema\":1,\"pageHashes\":[");
    for (hashes, 0..) |hash, index| {
        if (index != 0) try out.append(allocator, ',');
        const text = try std.fmt.allocPrint(allocator, "\"{x}\"", .{hash});
        defer allocator.free(text);
        try out.appendSlice(allocator, text);
    }
    try out.appendSlice(allocator, "]}");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = out.items, .flags = .{ .truncate = true } });
    try publish.replaceFile(io, tmp, path);
}
