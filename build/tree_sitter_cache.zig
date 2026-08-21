//! Management steps for the shared tree-sitter staging cache
//! (`~/.ss/cache/tree-sitter`). The cache is written and read only by
//! `zig build`, so its layout (`<cache>/bundles/<manifest-hash>/`) and its
//! maintenance live here; the runtime binary knows nothing about it.
//! "Current" always means the manifest hash of this checkout, so pruning
//! from one checkout never removes another concern's bundle by accident —
//! only stale hashes and staging leftovers.

const std = @import("std");
const Step = std.Build.Step;

const Command = enum { stats, clean, prune };

pub fn addSteps(b: *std.Build, cache_root: []const u8, manifest_hash: []const u8) void {
    addStep(b, .stats, "tree-sitter-stats", "Show tree-sitter cache size and bundle count", cache_root, manifest_hash);
    addStep(b, .prune, "tree-sitter-prune", "Remove stale tree-sitter bundles and staging leftovers", cache_root, manifest_hash);
    addStep(b, .clean, "tree-sitter-clean", "Delete the shared tree-sitter cache", cache_root, manifest_hash);
}

const CacheStep = struct {
    step: Step,
    command: Command,
    cache_root: []const u8,
    manifest_hash: []const u8,

    fn make(step: *Step, options: Step.MakeOptions) anyerror!void {
        _ = options;
        const self: *CacheStep = @fieldParentPtr("step", step);
        const b = step.owner;
        const io = b.graph.io;
        const allocator = b.allocator;
        switch (self.command) {
            .stats => {
                const bundle_root = b.pathJoin(&.{ self.cache_root, "bundles", self.manifest_hash });
                const total = try stats(io, allocator, self.cache_root);
                const current = try stats(io, allocator, bundle_root);
                const bundles = try bundleCount(io, allocator, self.cache_root);
                std.debug.print("tree-sitter cache: {s}\n", .{self.cache_root});
                std.debug.print("current manifest hash: {s}\n", .{self.manifest_hash});
                std.debug.print("current bundle: {s}\n", .{bundle_root});
                std.debug.print("bundles: {d}\n", .{bundles});
                std.debug.print("total:\n", .{});
                printTotals(total);
                std.debug.print("current bundle:\n", .{});
                printTotals(current);
            },
            .clean => {
                const before = try stats(io, allocator, self.cache_root);
                try deleteTreeIfExists(io, self.cache_root);
                std.debug.print("cleared tree-sitter cache: {s}\n", .{self.cache_root});
                std.debug.print("removed: ", .{});
                printByteSize(before.bytes);
                std.debug.print("\n", .{});
            },
            .prune => {
                const before = try stats(io, allocator, self.cache_root);
                const result = try prune(io, allocator, self.cache_root, self.manifest_hash);
                const after = try stats(io, allocator, self.cache_root);
                std.debug.print("pruned tree-sitter cache: {s}\n", .{self.cache_root});
                std.debug.print("removed bundles: {d}\n", .{result.removed_bundles});
                std.debug.print("removed build dirs: {d}\n", .{result.removed_build_dirs});
                std.debug.print("freed: ", .{});
                printByteSize(before.bytes -| after.bytes);
                std.debug.print("\n", .{});
            },
        }
    }
};

fn addStep(
    b: *std.Build,
    command: Command,
    name: []const u8,
    description: []const u8,
    cache_root: []const u8,
    manifest_hash: []const u8,
) void {
    const cache_step = b.allocator.create(CacheStep) catch @panic("OOM");
    cache_step.* = .{
        .step = Step.init(.{ .id = .custom, .name = name, .owner = b, .makeFn = CacheStep.make }),
        .command = command,
        .cache_root = cache_root,
        .manifest_hash = manifest_hash,
    };
    b.step(name, description).dependOn(&cache_step.step);
}

const Stats = struct {
    files: usize = 0,
    directories: usize = 0,
    bytes: u64 = 0,
};

const PruneResult = struct {
    removed_bundles: usize = 0,
    removed_build_dirs: usize = 0,
};

fn stats(io: std.Io, allocator: std.mem.Allocator, root_path: []const u8) !Stats {
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

fn bundleCount(io: std.Io, allocator: std.mem.Allocator, root_path: []const u8) !usize {
    const bundles_path = try std.fs.path.join(allocator, &.{ root_path, "bundles" });

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

fn prune(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_path: []const u8,
    current_manifest_hash: []const u8,
) !PruneResult {
    const bundles_path = try std.fs.path.join(allocator, &.{ root_path, "bundles" });

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

        if (std.mem.startsWith(u8, entry.name, ".building-")) {
            try deleteTreeIfExists(io, entry_path);
            result.removed_build_dirs += 1;
            continue;
        }

        if (!std.mem.eql(u8, entry.name, current_manifest_hash)) {
            try deleteTreeIfExists(io, entry_path);
            result.removed_bundles += 1;
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

fn printTotals(totals: Stats) void {
    std.debug.print("files: {d}\n", .{totals.files});
    std.debug.print("directories: {d}\n", .{totals.directories});
    std.debug.print("size: ", .{});
    printByteSize(totals.bytes);
    std.debug.print("\n", .{});
}

fn printByteSize(bytes: u64) void {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var unit_index: usize = 0;
    var divisor: u64 = 1;
    while (unit_index + 1 < units.len and bytes >= divisor * 1024) {
        unit_index += 1;
        divisor *= 1024;
    }

    if (unit_index == 0) {
        std.debug.print("{d} {s}", .{ bytes, units[unit_index] });
        return;
    }
    const scaled = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(divisor));
    std.debug.print("{d:.1} {s}", .{ scaled, units[unit_index] });
}
