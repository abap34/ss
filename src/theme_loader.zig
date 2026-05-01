const std = @import("std");

const max_theme_bytes = 256 * 1024;

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
    if (tryReadThemeFile(allocator, io, project_theme_path) catch |err| return err) |bytes| {
        return .{
            .path = try allocator.dupe(u8, project_theme_path),
            .source = bytes,
        };
    }

    if (try resolveBundledThemePath(allocator, io, theme_spec)) |path| {
        errdefer allocator.free(path);
        const source = try readThemeFile(allocator, io, path);
        return .{ .path = path, .source = source };
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
    io: std.Io,
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

    const bundled_note = if (tryBundledThemeCandidatePaths(allocator, io, theme_spec)) |paths| blk: {
        defer {
            for (paths) |path| allocator.free(path);
            allocator.free(paths);
        }
        if (paths.len == 0) break :blk "no bundled stdlib theme candidates were available";
        break :blk try std.fmt.allocPrint(
            allocator,
            "bundled stdlib candidates: {s}",
            .{paths[0]},
        );
    } else "no bundled stdlib theme candidates were available";
    defer if (std.mem.startsWith(u8, bundled_note, "bundled stdlib candidates:")) allocator.free(bundled_note);
    return std.fmt.allocPrint(
        allocator,
        "UnknownTheme: theme '{s}' was not found. searched: {s}/themes/{s}.ss, themes/{s}.ss; {s}",
        .{ theme_spec, base_dir, theme_spec, theme_spec, bundled_note },
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

fn resolveBundledThemePath(allocator: std.mem.Allocator, io: std.Io, theme_spec: []const u8) !?[]u8 {
    const candidates = tryBundledThemeCandidatePaths(allocator, io, theme_spec) orelse return null;
    defer {
        for (candidates) |candidate| allocator.free(candidate);
        allocator.free(candidates);
    }

    for (candidates) |candidate| {
        if (tryReadThemeFile(allocator, io, candidate) catch |err| return err) |bytes| {
            allocator.free(bytes);
            return try allocator.dupe(u8, candidate);
        }
    }
    return null;
}

fn tryBundledThemeCandidatePaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    theme_spec: []const u8,
) ?[][]u8 {
    const exe_dir = std.process.executableDirPathAlloc(io, allocator) catch return null;
    defer allocator.free(exe_dir);

    var candidates = std.ArrayList([]u8).empty;
    errdefer {
        for (candidates.items) |candidate| allocator.free(candidate);
        candidates.deinit(allocator);
    }

    const relative_roots = [_][]const u8{
        "../stdlib/themes",
        "../../stdlib/themes",
    };
    for (relative_roots) |relative_root| {
        const root = std.fs.path.join(allocator, &.{ exe_dir, relative_root }) catch continue;
        defer allocator.free(root);
        const candidate = std.fmt.allocPrint(allocator, "{s}/{s}.ss", .{ root, theme_spec }) catch continue;
        candidates.append(allocator, candidate) catch {
            allocator.free(candidate);
            continue;
        };
    }

    return candidates.toOwnedSlice(allocator) catch null;
}
