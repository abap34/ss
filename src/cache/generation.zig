const std = @import("std");
const key = @import("key.zig");
const publish = @import("publish.zig");

pub fn readCurrent(allocator: std.mem.Allocator, io: std.Io, current_path: []const u8) !?[]u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, current_path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(text);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.getPtr("generation") orelse return null;
    if (value.* != .string) return null;
    if (!key.safeName(value.string)) return null;
    return try allocator.dupe(u8, value.string);
}

pub fn writeCurrent(allocator: std.mem.Allocator, io: std.Io, current_path: []const u8, generation_id: []const u8) !void {
    const tmp = try publish.tempPath(allocator, current_path, "json");
    defer allocator.free(tmp);
    errdefer publish.deleteFileIfExists(io, tmp);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"schema\":1,\"generation\":");
    const encoded = try std.json.Stringify.valueAlloc(allocator, generation_id, .{});
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
    try out.appendSlice(allocator, "}");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = out.items, .flags = .{ .truncate = true } });
    try publish.replaceFile(io, tmp, current_path);
}

pub fn publishDirectory(io: std.Io, building_dir: []const u8, generation_dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.rename(building_dir, cwd, generation_dir, io) catch |err| {
        if (err == error.PathAlreadyExists) return;
        return err;
    };
}
