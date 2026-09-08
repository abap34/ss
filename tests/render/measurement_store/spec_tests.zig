const std = @import("std");
const core = @import("core");
const measurements = @import("render_measurements");
const testing = std.testing;

const root = ".ss-cache/tests/measurement-store";
const path = root ++ "/measurements.tsv";

test "measurement storage preserves exact geometry and atomically replaces records" {
    try std.Io.Dir.cwd().createDirPath(testing.io, root);
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    const value = core.LayoutMeasurement{
        .width = 47.995,
        .height = 36,
        .ink_bounds = .{ .x = -5, .y = -0.5, .width = 53, .height = 38 },
        .first_baseline = 26.375,
        .measured_width = 47.995,
        .cache_key = 73,
    };
    {
        var store = try measurements.Store.init(testing.allocator, testing.io, root);
        defer store.deinit();
        try store.put(73, value);
        try store.flush();
    }
    var restored = try measurements.Store.init(testing.allocator, testing.io, root);
    defer restored.deinit();
    try testing.expectEqualDeep(value, (try restored.get(73)).?);
    // A retained generation remains usable if a different process replaces the file.
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "replaced" });
    try testing.expectEqualDeep(value, (try restored.get(73)).?);
    var changed = value;
    changed.height = 72;
    try restored.put(73, changed);
    try restored.flush();
    var next = try measurements.Store.init(testing.allocator, testing.io, root);
    defer next.deinit();
    try testing.expectEqualDeep(changed, (try next.get(73)).?);
}

test "measurement storage rejects malformed and non-finite geometry" {
    try std.Io.Dir.cwd().createDirPath(testing.io, root);
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = path,
        .data = "ss-layout-measurements-v2\t" ++ measurements.version ++ "\n" ++
            "1\t3f800000\t3f800000\t-\t-\t-\t-\t-\t-\n" ++
            "2\t7f800000\t3f800000\t-\t-\t-\t-\t-\t-\n" ++
            "3\t3f800000\t3f800000\t-\t0\t-\t-\t-\t-\n" ++
            "4\t3f800000\t3f800000\t0\t0\tbf800000\t3f800000\t-\t-\n" ++
            "5\t3f800000\t3f800000\t-\t-\t-\t-\t7fc00000\t-\n" ++
            "6\t3f800000\t3f800000\t-\t-\t-\t-\t-\t0\n" ++
            "7\t3f800000\t3f800000\t-\t-\t-\t-\t-\t-\textra\n",
    });
    var store = try measurements.Store.init(testing.allocator, testing.io, root);
    defer store.deinit();
    try testing.expectEqual(@as(usize, 1), store.persistent.count());
    try testing.expect((try store.get(1)) != null);
    for (2..8) |key| try testing.expect((try store.get(key)) == null);
}

test "measurement storage propagates allocation failures without leaking" {
    try std.Io.Dir.cwd().createDirPath(testing.io, root);
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = path,
        .data = "ss-layout-measurements-v2\t" ++ measurements.version ++ "\n1\t3f800000\t3f800000\t-\t-\t-\t-\t-\t-\n",
    });
    try testing.checkAllAllocationFailures(testing.allocator, exerciseStorage, .{});
}

test "retained measurement storage evicts the least recently used record" {
    try std.Io.Dir.cwd().createDirPath(testing.io, root);
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    var store = try measurements.Store.init(testing.allocator, testing.io, root);
    defer store.deinit();
    for (0..measurements.capacity) |key| try store.put(key, .{ .width = 20, .height = 40, .cache_key = key });
    try testing.expect((try store.get(0)) != null);
    try store.put(measurements.capacity, .{ .width = 30, .height = 50, .cache_key = measurements.capacity });
    try testing.expectEqual(measurements.capacity, store.run.count());
    try testing.expect((try store.get(1)) == null);
    try testing.expect((try store.get(0)) != null);
    try store.flush();
    var restored = try measurements.Store.init(testing.allocator, testing.io, root);
    defer restored.deinit();
    try testing.expectEqual(measurements.capacity, restored.persistent.count());
    try testing.expect((try restored.get(1)) == null);
    try testing.expect((try restored.get(0)) != null);
}

fn exerciseStorage(allocator: std.mem.Allocator) !void {
    var store = try measurements.Store.init(allocator, testing.io, root);
    defer store.deinit();
    try testing.expect((try store.get(1)) != null);
    try store.put(2, .{ .width = 20, .height = 40, .cache_key = 2 });
    try store.flush();
}
