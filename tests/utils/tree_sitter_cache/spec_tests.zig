const std = @import("std");
const cache = @import("utils").tree_sitter_cache;
const testing = std.testing;

test "tree-sitter cache: leases protect active sources and their working directories" {
    const io = testing.io;
    const allocator = testing.allocator;
    const root = ".ss-cache/test-tree-sitter-leases";
    const cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(io, root);
    defer cwd.deleteTree(io, root) catch {};
    defer cwd.deleteFile(io, root ++ ".lock") catch {};
    try cwd.createDirPath(io, root ++ "/bundles/current/sources");
    try cwd.createDirPath(io, root ++ "/bundles/obsolete");
    try cwd.createDirPath(io, root ++ "/bundles/.building-current-unique");
    {
        var first = try cache.Lease.acquire(io, allocator, root);
        defer first.deinit();
        var second = try cache.Lease.acquire(io, allocator, root ++ "/");
        defer second.deinit();
        try testing.expectError(error.ActiveTreeSitterCacheLease, cache.clear(io, allocator, root));
        try testing.expectError(error.ActiveTreeSitterCacheLease, cache.prune(io, allocator, root, "current"));
        try cwd.access(io, root ++ "/bundles/.building-current-unique", .{});
        try cwd.access(io, root ++ "/bundles/obsolete", .{});
    }
    const result = try cache.prune(io, allocator, root, "current");
    try testing.expectEqual(@as(usize, 1), result.removed_bundles);
    try testing.expectEqual(@as(usize, 1), result.removed_build_dirs);
    try testing.expectEqual(@as(usize, 1), result.removed_source_dirs);
    try testing.expectEqual(@as(usize, 1), try cache.bundleCount(io, allocator, root));
    try cache.clear(io, allocator, root);
    try testing.expectError(error.FileNotFound, cwd.access(io, root, .{}));
    // Clearing leaves the lock identity intact for a subsequent builder.
    var next = try cache.Lease.acquire(io, allocator, root);
    defer next.deinit();
    try testing.expectError(error.ActiveTreeSitterCacheLease, cache.clear(io, allocator, root));
}
