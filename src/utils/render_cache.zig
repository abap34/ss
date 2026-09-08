const std = @import("std");
const fs = @import("fs.zig");
pub const LatexReference = @import("render_cache/latex_reference.zig").LatexReference;

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

pub const Stats = fs.DirectoryStats;

const FileEntry = struct {
    path: []u8,
    size: u64,
    mtime_ns: i96,
    group: usize,
    next: ?usize = null,
};

const ArtifactGroup = struct {
    first: ?usize = null,
    mtime_ns: i96 = std.math.minInt(i96),
};

pub const Lease = struct {
    io: std.Io,
    guard: ?std.Io.File,

    pub fn acquire(io: std.Io) !Lease {
        return .{ .io = io, .guard = try openGuard(io, .shared, false) };
    }

    pub fn deinit(self: *Lease) void {
        if (self.guard) |guard| guard.close(self.io);
        self.guard = null;
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
    return fs.directoryStats(io, allocator, path);
}

pub fn pruneConfigured(io: std.Io, allocator: std.mem.Allocator, config: Config) !void {
    if (!config.automatic_pruning) return;
    const guard = openGuard(io, .exclusive, true) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return err,
    };
    defer guard.close(io);
    if (!try pruneDue(io, config.prune_interval_seconds)) return;
    try prune(io, allocator, artifacts_path, try config.maxBytes());
    try touchPruneStamp(io);
}

fn pruneDue(io: std.Io, interval_seconds: u64) !bool {
    if (interval_seconds == 0) return true;
    const interval_ns = @as(i128, @intCast(interval_seconds)) * std.time.ns_per_s;
    const stat = fs.statFile(io, prune_stamp_path) catch |err| switch (err) {
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

    const groups = try groupArtifacts(io, allocator, root_path, files.items);
    defer allocator.free(groups);
    var order = std.ArrayList(usize).empty;
    defer order.deinit(allocator);
    for (groups, 0..) |group, index| {
        if (group.first != null) try order.append(allocator, index);
    }
    const context = GroupOrder{ .files = files.items, .groups = groups };
    std.sort.heap(usize, order.items, context, GroupOrder.olderThan);
    var remaining = current.bytes;
    for (order.items) |group_index| {
        if (remaining <= max_bytes) break;
        var member = groups[group_index].first;
        var references_removed = true;
        while (member) |index| {
            const entry = files.items[index];
            member = entry.next;
            if (index == group_index) continue;
            if (try deleteArtifact(io, allocator, root_path, entry)) {
                remaining -|= entry.size;
            } else {
                references_removed = false;
            }
        }
        // Remove references before their PDF, retaining it if a reference could not be removed.
        if (references_removed and try deleteArtifact(io, allocator, root_path, files.items[group_index])) {
            remaining -|= files.items[group_index].size;
        }
    }
}

fn groupArtifacts(io: std.Io, allocator: std.mem.Allocator, root_path: []const u8, files: []FileEntry) ![]ArtifactGroup {
    var by_path = std.StringHashMap(usize).init(allocator);
    defer by_path.deinit();
    for (files, 0..) |entry, index| try by_path.put(entry.path, index);
    for (files) |*entry| {
        if (!std.mem.endsWith(u8, entry.path, ".ref")) continue;
        const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.path });
        defer allocator.free(full_path);
        const contents = fs.readFileAllocLimited(io, allocator, full_path, .limited(LatexReference.read_limit)) catch |err| switch (err) {
            error.FileNotFound, error.StreamTooLong => continue,
            else => return err,
        };
        defer allocator.free(contents);
        const reference = LatexReference.parse(contents) catch continue;
        const target_path = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(entry.path) orelse "", reference.pdf_name });
        defer allocator.free(target_path);
        entry.group = by_path.get(target_path) orelse continue;
    }
    const groups = try allocator.alloc(ArtifactGroup, files.len);
    @memset(groups, .{});
    for (files, 0..) |*entry, index| {
        const group = &groups[entry.group];
        entry.next = group.first;
        group.first = index;
        group.mtime_ns = @max(group.mtime_ns, entry.mtime_ns);
    }
    return groups;
}

fn deleteArtifact(io: std.Io, allocator: std.mem.Allocator, root_path: []const u8, entry: FileEntry) !bool {
    const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.path });
    defer allocator.free(full_path);
    std.Io.Dir.cwd().deleteFile(io, full_path) catch |err| return err == error.FileNotFound;
    return true;
}

fn collectFiles(io: std.Io, allocator: std.mem.Allocator, root_path: []const u8, files: *std.ArrayList(FileEntry)) !Stats {
    var collector = FileCollector{ .allocator = allocator, .files = files };
    return fs.walkFiles(io, allocator, root_path, &collector);
}

const FileCollector = struct {
    allocator: std.mem.Allocator,
    files: *std.ArrayList(FileEntry),

    pub fn visit(self: *FileCollector, relative_path: []const u8, stat: std.Io.File.Stat) !void {
        const owned_path = try self.allocator.dupe(u8, relative_path);
        errdefer self.allocator.free(owned_path);
        try self.files.append(self.allocator, .{
            .path = owned_path,
            .size = stat.size,
            .mtime_ns = stat.mtime.nanoseconds,
            .group = self.files.items.len,
        });
    }
};

const GroupOrder = struct {
    files: []const FileEntry,
    groups: []const ArtifactGroup,

    fn olderThan(self: GroupOrder, lhs: usize, rhs: usize) bool {
        if (self.groups[lhs].mtime_ns == self.groups[rhs].mtime_ns) return std.mem.lessThan(u8, self.files[lhs].path, self.files[rhs].path);
        return self.groups[lhs].mtime_ns < self.groups[rhs].mtime_ns;
    }
};

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
