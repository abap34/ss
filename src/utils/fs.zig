const std = @import("std");
const Cancellation = @import("cancellation.zig").Cancellation;

/// Return an owned asset path, resolving relative requests from the asset base.
pub fn resolveAssetPath(allocator: std.mem.Allocator, base_dir: []const u8, requested: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(requested)) return allocator.dupe(u8, requested);
    return std.fs.path.join(allocator, &.{ base_dir, requested });
}

pub fn absolutePath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

pub fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return readFileAllocLimited(io, allocator, path, .unlimited);
}

pub fn readFileAllocLimited(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    limit: std.Io.Limit,
) ![]u8 {
    return readFileAllocWithOptions(io, allocator, path, .{ .limit = limit });
}

pub const ReadOptions = struct {
    limit: std.Io.Limit = .unlimited,
    cancellation: ?Cancellation = null,
};

pub fn readFileAllocWithOptions(io: std.Io, allocator: std.mem.Allocator, path: []const u8, options: ReadOptions) ![]u8 {
    if (options.cancellation) |cancellation| try cancellation.check();
    // std.Io carries cancellation through the read itself. The explicit token
    // also rejects a result canceled before or during the read.
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, options.limit) catch |err|
        return normalizePathError(io, path, err);
    errdefer allocator.free(contents);
    if (options.cancellation) |cancellation| try cancellation.check();
    return contents;
}

pub const DirectoryStats = struct {
    files: usize = 0,
    directories: usize = 0,
    bytes: u64 = 0,
};

pub fn directoryStats(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !DirectoryStats {
    return walkFiles(io, allocator, path, struct {
        pub fn visit(_: @This(), _: []const u8, _: std.Io.File.Stat) !void {}
    }{});
}

// Visitor paths are relative to the root and borrowed until the next visit.
// Directory symlinks are not traversed; unavailable leaf entries are skipped.
pub fn walkFiles(io: std.Io, allocator: std.mem.Allocator, path: []const u8, visitor: anytype) !DirectoryStats {
    var dir = openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer dir.close(io);
    var result = DirectoryStats{};
    var walker = try dir.walkSelectively(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            result.directories += 1;
            try walker.enter(io, entry);
            continue;
        }
        const stat = entry.dir.statFile(io, entry.basename, .{}) catch |err| switch (err) {
            error.Canceled => return err,
            else => continue,
        };
        if (stat.kind == .directory) continue;
        result.files += 1;
        result.bytes += stat.size;
        try visitor.visit(entry.path, stat);
    }
    return result;
}

pub fn statFile(io: std.Io, path: []const u8) !std.Io.Dir.Stat {
    return std.Io.Dir.cwd().statFile(io, path, .{}) catch |err|
        return normalizePathError(io, path, err);
}

pub fn openDir(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    return std.Io.Dir.cwd().openDir(io, path, options) catch |err|
        return normalizePathError(io, path, err);
}

fn normalizePathError(io: std.Io, path: []const u8, err: anyerror) anyerror {
    if (err != error.FileNotFound) return err;

    var ancestor = std.fs.path.dirname(path) orelse return err;
    const cwd = std.Io.Dir.cwd();
    while (ancestor.len != 0) {
        const stat = cwd.statFile(io, ancestor, .{}) catch |ancestor_err| switch (ancestor_err) {
            error.FileNotFound => {
                const parent = std.fs.path.dirname(ancestor) orelse return err;
                if (std.mem.eql(u8, parent, ancestor)) return err;
                ancestor = parent;
                continue;
            },
            error.NotDir => return error.NotDir,
            else => return ancestor_err,
        };
        return if (stat.kind == .directory) err else error.NotDir;
    }
    return err;
}

pub fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var atomic = try cwd.createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

pub fn validateOutputParent(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    const stat = statFile(io, parent) catch |err| switch (err) {
        error.FileNotFound => return error.OutputParentNotFound,
        else => return err,
    };
    if (stat.kind != .directory) return error.OutputParentNotDirectory;
}

pub fn siblingPathWithExtension(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    ext: []const u8,
) ![]const u8 {
    const dir = std.fs.path.dirname(input_path) orelse ".";
    const stem = std.fs.path.stem(input_path);
    return std.fmt.allocPrint(allocator, "{s}/{s}.{s}", .{ dir, stem, ext });
}

pub fn fileExists(allocator: std.mem.Allocator, path: []const u8) !bool {
    const zpath = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(zpath);
    while (true) {
        const result = std.c.access(zpath.ptr, 0);
        switch (std.posix.errno(result)) {
            .SUCCESS => return true,
            .INTR => continue,
            .NOENT, .NOTDIR => return false,
            .ACCES, .PERM => return error.AccessDenied,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .IO => return error.InputOutput,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}
