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
