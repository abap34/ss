const std = @import("std");
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
        .data = "import ../dep/missing.ss\npage main\nend\n",
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
