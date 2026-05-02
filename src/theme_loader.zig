const std = @import("std");

const max_theme_bytes = 256 * 1024;

const EmbeddedTheme = struct {
    name: []const u8,
    source: []const u8,
};

const embedded_themes = [_]EmbeddedTheme{
    .{ .name = "base", .source = @embedFile("stdlib/themes/base.ss") },
    .{ .name = "default", .source = @embedFile("stdlib/themes/default.ss") },
    .{ .name = "academic", .source = @embedFile("stdlib/themes/academic.ss") },
    .{ .name = "pop", .source = @embedFile("stdlib/themes/pop.ss") },
};

pub const ThemeModule = struct {
    path: []u8,
    source: []u8,
};

pub fn loadThemeSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    theme_spec: []const u8,
) ![]u8 {
    const module = try loadThemeModule(allocator, io, base_dir, theme_spec);
    allocator.free(module.path);
    return module.source;
}

pub fn loadThemeModule(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    theme_spec: []const u8,
) !ThemeModule {
    if (looksLikePath(theme_spec)) {
        const path = try resolveExplicitPath(allocator, base_dir, theme_spec);
        errdefer allocator.free(path);
        const source = readThemeFile(allocator, io, path) catch |err| switch (err) {
            error.FileNotFound => return error.UnknownTheme,
            else => return err,
        };
        return .{ .path = path, .source = source };
    }

    const project_theme_path = try std.fmt.allocPrint(allocator, "{s}/themes/{s}.ss", .{ base_dir, theme_spec });
    defer allocator.free(project_theme_path);
    if (try tryReadThemeFile(allocator, io, project_theme_path)) |bytes| {
        return .{
            .path = try allocator.dupe(u8, project_theme_path),
            .source = bytes,
        };
    }

    if (embeddedThemeSource(theme_spec)) |source| {
        return .{
            .path = try std.fmt.allocPrint(allocator, "<embedded:{s}>", .{theme_spec}),
            .source = try allocator.dupe(u8, source),
        };
    }

    const cwd_theme_path = try std.fmt.allocPrint(allocator, "themes/{s}.ss", .{theme_spec});
    defer allocator.free(cwd_theme_path);
    if (tryReadThemeFile(allocator, io, cwd_theme_path) catch |err| return err) |bytes| {
        return .{
            .path = try allocator.dupe(u8, cwd_theme_path),
            .source = bytes,
        };
    }

    return error.UnknownTheme;
}

pub fn resolveThemeSourcePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    theme_spec: []const u8,
) ![]u8 {
    const module = try loadThemeModule(allocator, io, base_dir, theme_spec);
    allocator.free(module.source);
    return module.path;
}

pub fn formatUnknownThemeMessage(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    theme_spec: []const u8,
) ![]u8 {
    if (looksLikePath(theme_spec)) {
        const resolved = try resolveExplicitPath(allocator, base_dir, theme_spec);
        defer allocator.free(resolved);
        return std.fmt.allocPrint(
            allocator,
            "UnknownTheme: theme file was not found: {s}",
            .{resolved},
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "UnknownTheme: theme '{s}' was not found. searched: {s}/themes/{s}.ss, themes/{s}.ss; embedded stdlib themes: base, default, academic, pop",
        .{ theme_spec, base_dir, theme_spec, theme_spec },
    );
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

fn embeddedThemeSource(theme_spec: []const u8) ?[]const u8 {
    for (embedded_themes) |theme| {
        if (std.mem.eql(u8, theme.name, theme_spec)) return theme.source;
    }
    return null;
}
