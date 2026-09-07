const std = @import("std");
const builtin = @import("builtin");
const watch = @import("watch");

const testing = std.testing;

test "watch spec: fingerprint changes when a missing explicit import appears outside asset base" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    const project_dir = try std.fs.path.join(allocator, &.{ root, "project" });
    defer allocator.free(project_dir);
    const dep_dir = try std.fs.path.join(allocator, &.{ root, "dep" });
    defer allocator.free(dep_dir);
    try std.Io.Dir.cwd().createDirPath(testing.io, project_dir);
    try std.Io.Dir.cwd().createDirPath(testing.io, dep_dir);

    const entry_path = try std.fs.path.join(allocator, &.{ project_dir, "main.ss" });
    defer allocator.free(entry_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = entry_path,
        .data = "import ../dep/missing\npage main\nend\n",
        .flags = .{ .truncate = true },
    });

    const options = watch.Options{
        .input_path = entry_path,
        .asset_base_dir = project_dir,
    };
    const before = try watch.fingerprint(testing.io, allocator, options);

    const missing_path = try std.fs.path.join(allocator, &.{ dep_dir, "missing.ss" });
    defer allocator.free(missing_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = missing_path,
        .data = "page imported\nend\n",
        .flags = .{ .truncate = true },
    });

    const after = try watch.fingerprint(testing.io, allocator, options);
    try testing.expect(before != after);
}

test "watch spec: fingerprint failures retain the exact watched path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const relative_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(relative_root);
    const root = try std.fs.path.resolve(allocator, &.{relative_root});
    defer allocator.free(root);

    const entry_path = try std.fs.path.join(allocator, &.{ root, "main.ss" });
    defer allocator.free(entry_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = entry_path,
        .data = "page main\nend\n",
        .flags = .{ .truncate = true },
    });

    const input_blocker = try writeBlocker(allocator, root, "input-blocker");
    defer allocator.free(input_blocker);
    const blocked_input = try std.fs.path.join(allocator, &.{ input_blocker, "slide.ss" });
    defer allocator.free(blocked_input);
    try expectFingerprintFailure(.{
        .input_path = blocked_input,
        .asset_base_dir = root,
    }, .input_file, blocked_input);

    const project_blocker = try writeBlocker(allocator, root, "project-blocker");
    defer allocator.free(project_blocker);
    const blocked_project = try std.fs.path.join(allocator, &.{ project_blocker, "ss.toml" });
    defer allocator.free(blocked_project);
    try expectFingerprintFailure(.{
        .input_path = entry_path,
        .asset_base_dir = root,
        .project_file = blocked_project,
    }, .project_configuration, blocked_project);

    const query_blocker = try writeBlocker(allocator, root, "query-blocker");
    defer allocator.free(query_blocker);
    const blocked_query = try std.fs.path.join(allocator, &.{ query_blocker, "highlights.scm" });
    defer allocator.free(blocked_query);
    try expectFingerprintFailure(.{
        .input_path = entry_path,
        .asset_base_dir = root,
        .highlight_languages = &.{.{
            .name = @constCast("snippet"),
            .parser = @constCast("python"),
            .query = blocked_query,
        }},
    }, .highlight_query, blocked_query);

    const import_blocker = try writeBlocker(allocator, root, "import-blocker");
    defer allocator.free(import_blocker);
    const import_entry = try std.fs.path.join(allocator, &.{ root, "imports.ss" });
    defer allocator.free(import_entry);
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = import_entry,
        .data = "import ./import-blocker/dep\npage main\nend\n",
        .flags = .{ .truncate = true },
    });
    const blocked_import = try std.fs.path.join(allocator, &.{ import_blocker, "dep.ss" });
    defer allocator.free(blocked_import);
    try expectFingerprintFailure(.{
        .input_path = import_entry,
        .asset_base_dir = root,
    }, .imported_source, blocked_import);

    const asset_blocker = try writeBlocker(allocator, root, "asset-blocker");
    defer allocator.free(asset_blocker);
    const blocked_asset_base = try std.fs.path.join(allocator, &.{ asset_blocker, "assets" });
    defer allocator.free(blocked_asset_base);
    try expectFingerprintFailure(.{
        .input_path = entry_path,
        .asset_base_dir = blocked_asset_base,
    }, .asset_base, blocked_asset_base);
}

fn writeBlocker(allocator: std.mem.Allocator, root: []const u8, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ root, name });
    errdefer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = path,
        .data = "not a directory\n",
        .flags = .{ .truncate = true },
    });
    return path;
}

fn expectFingerprintFailure(
    options: watch.Options,
    expected_target: watch.FingerprintTarget,
    expected_path: []const u8,
) !void {
    var inspection = try watch.inspectFingerprint(testing.io, testing.allocator, options);
    defer inspection.deinit(testing.allocator);
    switch (inspection) {
        .value => return error.ExpectedFingerprintFailure,
        .failure => |failure| {
            try testing.expectEqual(expected_target, failure.target);
            try testing.expectEqualStrings(expected_path, failure.path);
            try testing.expect(failure.cause == error.NotDir);
        },
    }
}

test "watch spec: unchanged inspections retain only cached import edges" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(root);
    const entry_path = try std.fs.path.join(testing.allocator, &.{ root, "main.ss" });
    defer testing.allocator.free(entry_path);
    const dependency = try std.fs.path.join(testing.allocator, &.{ root, "dependency.ss" });
    defer testing.allocator.free(dependency);
    try writeSource(entry_path, "import ./dependency\npage main\nend\n");
    try writeSource(dependency, "fn value() -> Number\nreturn 1\nend\n");
    var accounting = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = accounting.allocator();
    var cache = watch.ImportCache.init(allocator);
    defer cache.deinit();
    const options = watch.Options{ .input_path = entry_path, .asset_base_dir = root };
    const first = try inspectWithCache(allocator, options, &cache);
    const retained = accounting.allocated_bytes - accounting.freed_bytes;
    for (0..100) |_| {
        try testing.expectEqual(first, try inspectWithCache(allocator, options, &cache));
        try testing.expectEqual(retained, accounting.allocated_bytes - accounting.freed_bytes);
    }
    try testing.expectEqual(@as(usize, 2), cache.parsed_modules);
    try testing.expectEqual(@as(usize, 2), cache.entries.count());

    try writeSource(dependency, "fn value() -> Number\nreturn 200\nend\n");
    try testing.expect(first != try inspectWithCache(allocator, options, &cache));
    try testing.expectEqual(@as(usize, 3), cache.parsed_modules);
}

test "watch spec: import replacement evicts obsolete edges and malformed edits preserve known edges" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    const entry_path = try std.fs.path.join(allocator, &.{ root, "main.ss" });
    defer allocator.free(entry_path);
    const empty_assets = try std.fs.path.join(allocator, &.{ root, "assets" });
    defer allocator.free(empty_assets);
    try std.Io.Dir.cwd().createDirPath(testing.io, empty_assets);
    var cache = watch.ImportCache.init(allocator);
    defer cache.deinit();
    const options = watch.Options{ .input_path = entry_path, .asset_base_dir = empty_assets };
    for (0..30) |index| {
        const dependency = try std.fmt.allocPrint(allocator, "{s}/dependency_{d}.ss", .{ root, index });
        defer allocator.free(dependency);
        const source = try std.fmt.allocPrint(allocator, "import ./dependency_{d}\npage main\nend\n", .{index});
        defer allocator.free(source);
        try writeSource(dependency, "fn value() -> Number\nreturn 1\nend\n");
        try writeSource(entry_path, source);
        _ = try inspectWithCache(allocator, options, &cache);
        try testing.expectEqual(@as(usize, 2), cache.entries.count());
    }
    try writeSource(entry_path, "import ./dependency_29\npage main\nlet incomplete =\nend\n");
    const incomplete = try inspectWithCache(allocator, options, &cache);
    const parsed_before = cache.parsed_modules;
    try testing.expectEqual(incomplete, try inspectWithCache(allocator, options, &cache));
    try testing.expectEqual(parsed_before, cache.parsed_modules);
    try testing.expectEqual(@as(usize, 2), cache.entries.count());
    try writeSource(entry_path, "page main\nend\n");
    const removed = try inspectWithCache(allocator, options, &cache);
    try testing.expectEqual(@as(usize, 1), cache.entries.count());
    const old_dependency = try std.fs.path.join(allocator, &.{ root, "dependency_29.ss" });
    defer allocator.free(old_dependency);
    try writeSource(old_dependency, "fn value() -> Number\nreturn 500\nend\n");
    try testing.expectEqual(removed, try inspectWithCache(allocator, options, &cache));
}

fn writeSource(path: []const u8, contents: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = contents, .flags = .{ .truncate = true } });
}

fn inspectWithCache(allocator: std.mem.Allocator, options: watch.Options, cache: *watch.ImportCache) !u64 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var inspection = try watch.inspectFingerprintWithCache(testing.io, arena.allocator(), options, cache);
    defer inspection.deinit(arena.allocator());
    return switch (inspection) {
        .value => |value| value,
        .failure => |failure| failure.cause,
    };
}
