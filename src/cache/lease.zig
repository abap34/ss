const std = @import("std");
const publish = @import("publish.zig");

pub const Lease = struct {
    pid: i64,
    run_id: []const u8,
    owner_id: []const u8,
    protected_generations: []const []const u8 = &.{},
};

pub fn write(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    lease: Lease,
) !void {
    const tmp = try publish.tempPath(allocator, path, "json");
    defer allocator.free(tmp);
    errdefer publish.deleteFileIfExists(io, tmp);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"schema\":1,\"pid\":");
    try appendInt(allocator, &out, lease.pid);
    try out.appendSlice(allocator, ",\"runId\":");
    try appendJsonString(allocator, &out, lease.run_id);
    try out.appendSlice(allocator, ",\"ownerId\":");
    try appendJsonString(allocator, &out, lease.owner_id);
    try out.appendSlice(allocator, ",\"protectedGenerations\":[");
    for (lease.protected_generations, 0..) |generation, index| {
        if (index != 0) try out.append(allocator, ',');
        try appendJsonString(allocator, &out, generation);
    }
    try out.appendSlice(allocator, "]}");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = out.items, .flags = .{ .truncate = true } });
    try publish.replaceFile(io, tmp, path);
}

pub fn processIsLive(pid: i64) bool {
    if (pid <= 0 or pid > std.math.maxInt(std.c.pid_t)) return false;
    const normalized: std.c.pid_t = @intCast(pid);
    const signal: std.c.SIG = @enumFromInt(0);
    return switch (std.c.errno(std.c.kill(normalized, signal))) {
        .SUCCESS, .PERM => true,
        .SRCH => false,
        else => true,
    };
}

pub fn fileBelongsToLiveProcess(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(text);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const pid_value = parsed.value.object.getPtr("pid") orelse return false;
    if (pid_value.* != .integer) return false;
    return processIsLive(pid_value.integer);
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
}

fn appendInt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}
