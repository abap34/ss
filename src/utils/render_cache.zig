const std = @import("std");

pub const path = ".ss-cache/render";

const cache_size_kib: u64 = 1024;
const cache_size_mib: u64 = cache_size_kib * 1024;
const cache_size_gib: u64 = cache_size_mib * 1024;

pub const Stats = struct {
    files: usize = 0,
    directories: usize = 0,
    bytes: u64 = 0,
};

const FileEntry = struct {
    path: []u8,
    size: u64,
    mtime_ns: i96,
};

pub fn clear(io: std.Io) !void {
    std.Io.Dir.cwd().deleteTree(io, path) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
}

pub fn stats(io: std.Io, allocator: std.mem.Allocator) !Stats {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    defer dir.close(io);

    var result = Stats{};
    var walker = try dir.walkSelectively(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            result.directories += 1;
            try walker.enter(io, entry);
            continue;
        }

        const file_stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        if (file_stat.kind == .directory) continue;
        result.files += 1;
        result.bytes += file_stat.size;
    }

    return result;
}

pub fn pruneFromEnv(io: std.Io, allocator: std.mem.Allocator) !void {
    const max_bytes = configuredMaxBytes() orelse return;
    try prune(io, allocator, max_bytes);
}

fn configuredMaxBytes() ?u64 {
    const raw = std.c.getenv("SS_CACHE_MAX_BYTES") orelse return null;
    const text = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
    if (text.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(text, "off")) return null;
    return parseByteBudget(text) catch null;
}

fn parseByteBudget(text: []const u8) !u64 {
    const suffix = text[text.len - 1];
    const multiplier: u64 = switch (suffix) {
        'k', 'K' => cache_size_kib,
        'm', 'M' => cache_size_mib,
        'g', 'G' => cache_size_gib,
        'b', 'B' => 1,
        else => 1,
    };
    const number_text = if (std.ascii.isAlphabetic(suffix)) text[0 .. text.len - 1] else text;
    const trimmed = std.mem.trim(u8, number_text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidCacheBudget;
    const value = try std.fmt.parseUnsigned(u64, trimmed, 10);
    return std.math.mul(u64, value, multiplier) catch error.InvalidCacheBudget;
}

fn prune(io: std.Io, allocator: std.mem.Allocator, max_bytes: u64) !void {
    var files = std.ArrayList(FileEntry).empty;
    defer {
        for (files.items) |entry| allocator.free(entry.path);
        files.deinit(allocator);
    }

    const current = try collectFiles(io, allocator, &files);
    if (current.bytes <= max_bytes) return;

    std.sort.heap(FileEntry, files.items, {}, fileOlderThan);
    var remaining = current.bytes;
    for (files.items) |entry| {
        if (remaining <= max_bytes) break;
        const full_path = try std.fs.path.join(allocator, &.{ path, entry.path });
        defer allocator.free(full_path);
        std.Io.Dir.cwd().deleteFile(io, full_path) catch continue;
        remaining -|= entry.size;
    }
}

fn collectFiles(io: std.Io, allocator: std.mem.Allocator, files: *std.ArrayList(FileEntry)) !Stats {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    defer dir.close(io);

    var result = Stats{};
    var walker = try dir.walkSelectively(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            result.directories += 1;
            try walker.enter(io, entry);
            continue;
        }

        const file_stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        if (file_stat.kind == .directory) continue;
        result.files += 1;
        result.bytes += file_stat.size;
        try files.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .size = file_stat.size,
            .mtime_ns = file_stat.mtime.nanoseconds,
        });
    }

    return result;
}

fn fileOlderThan(_: void, lhs: FileEntry, rhs: FileEntry) bool {
    if (lhs.mtime_ns == rhs.mtime_ns) return std.mem.lessThan(u8, lhs.path, rhs.path);
    return lhs.mtime_ns < rhs.mtime_ns;
}
