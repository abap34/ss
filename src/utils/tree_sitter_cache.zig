const std = @import("std");

pub const Stats = struct {
    files: usize = 0,
    directories: usize = 0,
    bytes: u64 = 0,
};

pub const PruneResult = struct {
    removed_bundles: usize = 0,
    removed_build_dirs: usize = 0,
    removed_source_dirs: usize = 0,
};

pub fn stats(io: std.Io, allocator: std.mem.Allocator, root_path: []const u8) !Stats {
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
    }

    return result;
}

pub fn bundleCount(io: std.Io, allocator: std.mem.Allocator, root_path: []const u8) !usize {
    const bundles_path = try std.fs.path.join(allocator, &.{ root_path, "bundles" });
    defer allocator.free(bundles_path);

    var dir = std.Io.Dir.cwd().openDir(io, bundles_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer dir.close(io);

    var count: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .directory and !std.mem.startsWith(u8, entry.name, ".building-")) {
            count += 1;
        }
    }
    return count;
}

pub fn pathExists(allocator: std.mem.Allocator, path: []const u8) bool {
    const zpath = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(zpath);
    return std.c.access(zpath.ptr, std.c.F_OK) == 0;
}

pub fn clear(io: std.Io, root_path: []const u8) !void {
    std.Io.Dir.cwd().deleteTree(io, root_path) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
}

pub fn prune(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_path: []const u8,
    current_manifest_hash: []const u8,
) !PruneResult {
    const bundles_path = try std.fs.path.join(allocator, &.{ root_path, "bundles" });
    defer allocator.free(bundles_path);

    var dir = std.Io.Dir.cwd().openDir(io, bundles_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    defer dir.close(io);

    var result = PruneResult{};
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const entry_path = try std.fs.path.join(allocator, &.{ bundles_path, entry.name });
        defer allocator.free(entry_path);

        if (std.mem.startsWith(u8, entry.name, ".building-")) {
            try deleteTreeIfExists(io, entry_path);
            result.removed_build_dirs += 1;
            continue;
        }

        if (!std.mem.eql(u8, entry.name, current_manifest_hash)) {
            try deleteTreeIfExists(io, entry_path);
            result.removed_bundles += 1;
            continue;
        }

        const sources_path = try std.fs.path.join(allocator, &.{ entry_path, "sources" });
        defer allocator.free(sources_path);
        if (pathExists(allocator, sources_path)) {
            try deleteTreeIfExists(io, sources_path);
            result.removed_source_dirs += 1;
        }
    }
    return result;
}

fn deleteTreeIfExists(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteTree(io, path) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
}
