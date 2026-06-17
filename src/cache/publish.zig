const std = @import("std");
const store = @import("store.zig");

var temp_counter: usize = 0;

pub fn tempPath(allocator: std.mem.Allocator, final_path: []const u8, extension: []const u8) ![]u8 {
    const serial = @atomicRmw(usize, &temp_counter, .Add, 1, .monotonic);
    return std.fmt.allocPrint(allocator, "{s}.tmp-{d}-{d}.{s}", .{ final_path, std.c.getpid(), serial, extension });
}

pub fn publishFile(io: std.Io, tmp_path: []const u8, final_path: []const u8) !void {
    if (store.fileExists(final_path)) {
        deleteFileIfExists(io, tmp_path);
        return;
    }
    const cwd = std.Io.Dir.cwd();
    cwd.rename(tmp_path, cwd, final_path, io) catch |err| {
        if (store.fileExists(final_path)) {
            deleteFileIfExists(io, tmp_path);
            return;
        }
        return err;
    };
}

pub fn replaceFile(io: std.Io, tmp_path: []const u8, final_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.rename(tmp_path, cwd, final_path, io) catch |err| {
        deleteFileIfExists(io, final_path);
        cwd.rename(tmp_path, cwd, final_path, io) catch return err;
    };
}

pub fn copyOrLink(io: std.Io, source_path: []const u8, dest_path: []const u8) !void {
    if (store.fileExists(dest_path)) return;
    const cwd = std.Io.Dir.cwd();
    cwd.hardLink(source_path, cwd, dest_path, io, .{}) catch {
        try cwd.copyFile(source_path, cwd, dest_path, io, .{ .make_path = true, .replace = true });
    };
}

pub fn deleteFileIfExists(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}
