const std = @import("std");

const max_theme_bytes = 256 * 1024;

pub fn loadThemeSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    theme_spec: []const u8,
) ![]u8 {
    const path = try resolveThemeSourcePath(allocator, io, base_dir, theme_spec);
    defer allocator.free(path);
    return readThemeFile(allocator, io, path);
}

pub fn resolveThemeSourcePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    theme_spec: []const u8,
) ![]u8 {
    if (looksLikePath(theme_spec)) {
        const path = try resolveExplicitPath(allocator, base_dir, theme_spec);
        if (tryReadThemeFile(allocator, io, path) catch |err| return err) |bytes| {
            allocator.free(bytes);
            return path;
        }
        allocator.free(path);
        return error.UnknownTheme;
    }

    const candidates = [_][]const u8{
        try std.fmt.allocPrint(allocator, "{s}/themes/{s}.ss", .{ base_dir, theme_spec }),
        try std.fmt.allocPrint(allocator, "stdlib/themes/{s}.ss", .{theme_spec}),
        try std.fmt.allocPrint(allocator, "themes/{s}.ss", .{theme_spec}),
    };
    defer {
        for (candidates) |candidate| allocator.free(candidate);
    }

    for (candidates) |candidate| {
        if (tryReadThemeFile(allocator, io, candidate) catch |err| return err) |bytes| {
            allocator.free(bytes);
            return try allocator.dupe(u8, candidate);
        }
    }

    return error.UnknownTheme;
}

fn looksLikePath(theme_spec: []const u8) bool {
    return std.mem.indexOfScalar(u8, theme_spec, '/') != null or
        std.mem.indexOfScalar(u8, theme_spec, '\\') != null or
        std.mem.endsWith(u8, theme_spec, ".ss");
}

fn resolveExplicitPath(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    theme_spec: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(theme_spec)) {
        return allocator.dupe(u8, theme_spec);
    }
    return std.fs.path.join(allocator, &.{ base_dir, theme_spec });
}

fn readThemeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_theme_bytes));
}

fn tryReadThemeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !?[]u8 {
    return readThemeFile(allocator, io, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}
