const std = @import("std");
const lease = @import("lease.zig");

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

pub fn stats(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) !Stats {
    var files = std.ArrayList(FileEntry).empty;
    defer {
        for (files.items) |entry| allocator.free(entry.path);
        files.deinit(allocator);
    }
    return collectFiles(allocator, io, root_path, &files);
}

pub fn pruneBySize(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, max_bytes: u64) !void {
    var files = std.ArrayList(FileEntry).empty;
    defer {
        for (files.items) |entry| allocator.free(entry.path);
        files.deinit(allocator);
    }

    const current = try collectFiles(allocator, io, root_path, &files);
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

pub fn activeLeaseExists(allocator: std.mem.Allocator, io: std.Io, leases_path: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(io, leases_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isFinalLeaseFile(entry.name)) continue;
        const path = try std.fs.path.join(allocator, &.{ leases_path, entry.name });
        defer allocator.free(path);
        if (try lease.fileBelongsToLiveProcess(allocator, io, path)) return true;
    }
    return false;
}

pub fn pruneGenerationsExcept(
    allocator: std.mem.Allocator,
    io: std.Io,
    generations_dir: []const u8,
    leases_path: []const u8,
    current_generation: []const u8,
) !void {
    try pruneStaleLeases(allocator, io, leases_path);
    if (try activeLeaseExists(allocator, io, leases_path)) return;

    var dir = std.Io.Dir.cwd().openDir(io, generations_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, current_generation)) continue;
        if (std.mem.startsWith(u8, entry.name, ".building-")) continue;
        const victim = try std.fs.path.join(allocator, &.{ generations_dir, entry.name });
        defer allocator.free(victim);
        std.Io.Dir.cwd().deleteTree(io, victim) catch {};
    }
}

pub fn pruneStaleLeases(allocator: std.mem.Allocator, io: std.Io, leases_path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, leases_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isFinalLeaseFile(entry.name)) continue;
        const path = try std.fs.path.join(allocator, &.{ leases_path, entry.name });
        defer allocator.free(path);
        if (try lease.fileBelongsToLiveProcess(allocator, io, path)) continue;
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
}

fn collectFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    files: *std.ArrayList(FileEntry),
) !Stats {
    var dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
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
        const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        if (stat.kind == .directory) continue;
        result.files += 1;
        result.bytes += stat.size;
        try files.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .size = stat.size,
            .mtime_ns = stat.mtime.nanoseconds,
        });
    }
    return result;
}

fn fileOlderThan(_: void, lhs: FileEntry, rhs: FileEntry) bool {
    if (lhs.mtime_ns == rhs.mtime_ns) return std.mem.lessThan(u8, lhs.path, rhs.path);
    return lhs.mtime_ns < rhs.mtime_ns;
}

fn isFinalLeaseFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".json") and std.mem.indexOf(u8, name, ".tmp-") == null;
}
