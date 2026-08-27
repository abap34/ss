const std = @import("std");

pub const path = ".ss-cache/render";
const artifacts_path = path ++ "/artifacts";
const prune_stamp_path = artifacts_path ++ "/.prune-stamp";
const cache_parent_path = ".ss-cache";
const guard_path = cache_parent_path ++ "/render.lock";

const bytes_per_mib: u64 = 1024 * 1024;

pub const Config = struct {
    automatic_pruning: bool = true,
    max_size_mib: u64 = 512,
    prune_interval_seconds: u64 = 5 * 60,

    pub fn maxBytes(self: Config) !u64 {
        return std.math.mul(u64, self.max_size_mib, bytes_per_mib) catch error.InvalidCacheMaxSize;
    }
};

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

pub const Lease = struct {
    io: std.Io,
    guard: std.Io.File,

    pub fn acquire(io: std.Io) !Lease {
        return .{ .io = io, .guard = try openGuard(io, .shared, false) };
    }

    pub fn deinit(self: *Lease) void {
        self.guard.close(self.io);
        self.* = undefined;
    }
};

pub fn clear(io: std.Io) !void {
    const guard = openGuard(io, .exclusive, true) catch |err| switch (err) {
        error.WouldBlock => return error.ActiveRenderCacheLease,
        else => return err,
    };
    defer guard.close(io);
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

pub fn pruneConfigured(io: std.Io, allocator: std.mem.Allocator, config: Config) !void {
    if (!config.automatic_pruning) return;
    if (!try pruneDue(io, config.prune_interval_seconds)) return;
    try prune(io, allocator, artifacts_path, try config.maxBytes());
    try touchPruneStamp(io);
}

fn pruneDue(io: std.Io, interval_seconds: u64) !bool {
    if (interval_seconds == 0) return true;
    const interval_ns = @as(i128, @intCast(interval_seconds)) * std.time.ns_per_s;
    const stat = std.Io.Dir.cwd().statFile(io, prune_stamp_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    if (stat.kind != .file) return true;
    const now: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    const mtime_ns: i128 = @intCast(stat.mtime.nanoseconds);
    if (mtime_ns > now) return false;
    return now - mtime_ns >= interval_ns;
}

fn touchPruneStamp(io: std.Io) !void {
    try std.Io.Dir.cwd().createDirPath(io, artifacts_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = prune_stamp_path,
        .data = "",
        .flags = .{ .truncate = true },
    });
}

fn prune(io: std.Io, allocator: std.mem.Allocator, root_path: []const u8, max_bytes: u64) !void {
    var files = std.ArrayList(FileEntry).empty;
    defer {
        for (files.items) |entry| allocator.free(entry.path);
        files.deinit(allocator);
    }

    const current = try collectFiles(io, allocator, root_path, &files);
    if (current.bytes <= max_bytes) return;

    std.sort.heap(FileEntry, files.items, {}, fileOlderThan);
    var remaining = current.bytes;
    for (files.items) |entry| {
        if (remaining <= max_bytes) break;
        const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.path });
        defer allocator.free(full_path);
        std.Io.Dir.cwd().deleteFile(io, full_path) catch continue;
        remaining -|= entry.size;
    }
}

fn collectFiles(io: std.Io, allocator: std.mem.Allocator, root_path: []const u8, files: *std.ArrayList(FileEntry)) !Stats {
    var dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |err| {
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

fn openGuard(io: std.Io, lock: std.Io.File.Lock, nonblocking: bool) !std.Io.File {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, cache_parent_path);
    return cwd.createFile(io, guard_path, .{
        .read = true,
        .truncate = false,
        .lock = lock,
        .lock_nonblocking = nonblocking,
    });
}
