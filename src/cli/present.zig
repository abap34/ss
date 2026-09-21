const std = @import("std");
const utils = @import("utils");
const builtin = @import("builtin");

pub fn defaultOutputPath(allocator: std.mem.Allocator, io: std.Io, entry_path: []const u8) ![]const u8 {
    const directory = ".ss-cache/present";
    try std.Io.Dir.cwd().createDirPath(io, directory);
    return std.fmt.allocPrint(allocator, directory ++ "/{x}.html", .{std.hash.Wyhash.hash(0, entry_path)});
}

pub fn documentUrl(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const absolute = try utils.fs.absolutePath(io, allocator, path);
    defer allocator.free(absolute);
    const uri = std.Uri{
        .scheme = "file",
        .host = .{ .raw = "" },
        .path = .{ .raw = absolute },
    };
    return std.fmt.allocPrint(allocator, "{f}", .{uri.fmt(.all)});
}

pub fn openBrowser(io: std.Io, url: []const u8) !void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .linux => &.{ "xdg-open", url },
        else => return error.BrowserOpenUnsupported,
    };
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer child.kill(io);
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.BrowserOpenFailed,
        else => return error.BrowserOpenFailed,
    }
}
