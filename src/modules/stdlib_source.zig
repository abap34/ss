const std = @import("std");
const build_options = @import("build_options");

const project = @import("../project.zig");
const utils = @import("utils");

/// Resolve a `std:` module spec to its source file on disk, so editors can
/// navigate to real files; execution always uses the embedded stdlib sources.
/// Candidate roots, in priority order:
///   1. SS_STDLIB_DIR — explicit user override
///   2. the checkout the binary was built from (dev builds)
///   3. `<prefix>/<installed_stdlib_subdir>` relative to the executable, so
///      an installed prefix stays relocatable
/// The result is a pure function of the process environment; nothing is
/// cached because callers are rare (editor navigation) and probing is cheap.
pub fn modulePath(io: std.Io, allocator: std.mem.Allocator, spec: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, spec, "std:")) return null;
    const module_name = spec["std:".len..];
    if (module_name.len == 0 or std.mem.indexOfScalar(u8, module_name, '\\') != null) return null;
    const relative = try std.fmt.allocPrint(allocator, "{s}.ss", .{module_name});
    defer allocator.free(relative);

    if (envRoot()) |root| {
        if (try pathFromRoot(allocator, root, relative)) |path| return path;
    }
    if (try pathFromRoot(allocator, build_options.source_stdlib_dir, relative)) |path| return path;
    if (try installedRoot(io, allocator)) |root| {
        defer allocator.free(root);
        if (try pathFromRoot(allocator, root, relative)) |path| return path;
    }
    return null;
}

fn envRoot() ?[]const u8 {
    const raw = std.c.getenv("SS_STDLIB_DIR") orelse return null;
    const value = std.mem.span(raw);
    return if (value.len == 0) null else value;
}

/// An installed binary lives in `<prefix>/bin`, with the standard library at
/// `<prefix>/<installed_stdlib_subdir>`.
fn installedRoot(io: std.Io, allocator: std.mem.Allocator) !?[]u8 {
    const exe_dir = std.process.executableDirPathAlloc(io, allocator) catch return null;
    defer allocator.free(exe_dir);
    const prefix = std.fs.path.dirname(exe_dir) orelse return null;
    return try std.fs.path.join(allocator, &.{ prefix, build_options.installed_stdlib_subdir });
}

fn pathFromRoot(allocator: std.mem.Allocator, root: []const u8, relative: []const u8) !?[]u8 {
    if (root.len == 0) return null;
    const joined = try std.fs.path.join(allocator, &.{ root, relative });
    defer allocator.free(joined);
    const absolute = try project.absolutePath(allocator, joined);
    if (utils.fs.fileExists(allocator, absolute)) return absolute;
    allocator.free(absolute);
    return null;
}
