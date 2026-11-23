const std = @import("std");
const project = @import("project");
const allocation_testing = @import("allocation_testing");
const packages = project.packages;
const testing = std.testing;

test "package manifest: dependencies accept all TOML declaration forms" {
    const sources = [_][]const u8{
        "[package]\nname = 'parts'\nentry = 'parts/lib.ss'\n[dependencies]\nbase = { git = 'https://example.invalid/base', tag = 'v1' }\n",
        "package.name = 'parts'\npackage.entry = 'parts/lib.ss'\ndependencies.base.git = 'https://example.invalid/base'\ndependencies.base.tag = 'v1'\n",
        "package = { name = 'parts', entry = 'parts/lib.ss' }\ndependencies = { base = { git = 'https://example.invalid/base', tag = 'v1' } }\n",
    };
    for (sources) |source| {
        var manifest = try packages.manifest.Manifest.parse(testing.allocator, source);
        defer manifest.deinit();
        try testing.expectEqualStrings("parts", manifest.data.package.?.name);
        try testing.expectEqualStrings("parts/lib.ss", manifest.data.package.?.entry);
        try testing.expectEqual(@as(usize, 1), manifest.data.dependencies.len);
        const dependency = manifest.data.dependencies[0];
        try testing.expectEqualStrings("base", dependency.name);
        try testing.expectEqualStrings("v1", dependency.source.tag.?);
    }
    var config = try project.parseSource(testing.allocator, "/tmp/package/ss.toml", "[package]\nname = 'parts'\n");
    defer config.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp/package/lib.ss", config.entry);
    try testing.expectError(error.MissingProjectEntry, project.parseSource(testing.allocator, "/tmp/package/ss.toml", "[package]\nname = 'parts'\nentry = 'lib.ss'\n[project]\nasset_base_dir = '.'\n"));
}

test "package manifest: rejects ambiguous sources and escaping entries" {
    const cases = [_]struct { source: []const u8, err: anyerror }{
        .{ .source = "[package]", .err = error.MissingPackageName },
        .{ .source = "[package]\nname = 'bad-name'", .err = error.InvalidPackageName },
        .{ .source = "[package]\nname = 'with'", .err = error.InvalidPackageName },
        .{ .source = "[package]\nname = ''", .err = error.InvalidPackageName },
        .{ .source = "[dependencies]\nx = { git = 'url', tag = 'v1', branch = 'main' }", .err = error.InvalidDependencySource },
        .{ .source = "[dependencies]\nx = { rev = 'abc' }", .err = error.InvalidDependencySource },
        .{ .source = "[dependencies]\nx = { git = '-option' }", .err = error.InvalidDependencySource },
        .{ .source = "[dependencies]\nx = { git = 'ext::command' }", .err = error.InvalidDependencySource },
        .{ .source = "[dependencies]\n'bad-name' = { git = 'url' }", .err = error.InvalidDependencyName },
        .{ .source = "[dependencies]\nx = 'url'", .err = error.InvalidConfigTable },
        .{ .source = "[dependencies]\nx = { git = 'url', typo = 'main' }", .err = error.UnknownConfigKey },
        .{ .source = "[package]\nname = 'parts'\nentry = '../lib.ss'", .err = error.InvalidPackageEntry },
        .{ .source = "[package]\nname = 'parts'\nentry = '/lib.ss'", .err = error.InvalidPackageEntry },
        .{ .source = "[package]\nname = 'parts'\nentry = 'lib'", .err = error.InvalidPackageEntry },
    };
    for (cases) |case| try testing.expectError(case.err, packages.manifest.Manifest.parse(testing.allocator, case.source));
}

test "package manifest: allocation failures release every parsed declaration" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseManifest, .{});
}

fn parseManifest(allocator: std.mem.Allocator) !void {
    var manifest = try packages.manifest.Manifest.parse(allocator,
        \\[package]
        \\name = 'parts'
        \\entry = 'parts/lib.ss'
        \\[dependencies]
        \\z = { git = 'https://example.invalid/z', branch = 'main' }
        \\a = { git = 'https://example.invalid/a', tag = 'v1' }
    );
    defer manifest.deinit();
    try testing.expectEqualStrings("a", manifest.data.dependencies[0].name);
}

test "package lock: identity includes source and commit and rejects invalid edges" {
    var buffer: [64]u8 = undefined;
    const commit = "0123456789012345678901234567890123456789";
    const id = packages.lock.identity("url", commit, &buffer);
    const package = packages.lock.Package{ .name = "base", .id = id, .git = "url", .commit = commit, .entry = "lib.ss", .dependencies = &.{} };
    const edge = packages.lock.Edge{ .name = "base", .source = .{ .git = "url", .tag = "v1" }, .package = id };
    try packages.lock.validate(testing.allocator, .{ .packages = &.{package}, .dependencies = &.{edge} });
    var changed = package;
    changed.id = "../outside";
    try testing.expectError(error.InvalidPackageLock, packages.lock.validate(testing.allocator, .{ .packages = &.{changed} }));
    try testing.expectError(error.InvalidPackageLock, packages.lock.validate(testing.allocator, .{ .packages = &.{package}, .dependencies = &.{ edge, edge } }));
    try testing.expectError(error.InvalidPackageLock, packages.lock.validate(testing.allocator, .{ .dependencies = &.{edge} }));
    try testing.expectError(error.InvalidPackageLock, packages.lock.validate(testing.allocator, .{ .version = 2 }));
    try testing.expect(packages.lock.matches(&.{edge}, &.{.{ .name = "base", .source = edge.source }}));
    try testing.expect(!packages.lock.matches(&.{edge}, &.{.{ .name = "base", .source = .{ .git = "url", .branch = "main" } }}));
}

test "package lock: global source selections, scoped names and identity cycles" {
    try checkGraph(testing.allocator);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, checkGraph, .{});
}

fn checkGraph(a: std.mem.Allocator) !void {
    var buffers: [3][64]u8 = undefined;
    const commits = [_][]const u8{
        "1111111111111111111111111111111111111111",
        "2222222222222222222222222222222222222222",
        "3333333333333333333333333333333333333333",
    };
    const old = packages.lock.Package{ .name = "base", .git = "base-url", .commit = commits[0], .id = packages.lock.identity("base-url", commits[0], &buffers[0]), .entry = "lib.ss", .dependencies = &.{} };
    const new = packages.lock.Package{ .name = "base", .git = "base-url", .commit = commits[1], .id = packages.lock.identity("base-url", commits[1], &buffers[1]), .entry = "lib.ss", .dependencies = &.{} };
    const old_edge = packages.lock.Edge{ .name = "base", .source = .{ .git = "base-url", .tag = "v1" }, .package = old.id };
    var new_edge = old_edge;
    new_edge.package = new.id;
    const wrapper = packages.lock.Package{ .name = "wrapper", .git = "wrapper-url", .commit = commits[2], .id = packages.lock.identity("wrapper-url", commits[2], &buffers[2]), .entry = "lib.ss", .dependencies = &.{new_edge} };
    const wrapper_edge = packages.lock.Edge{ .name = "wrapper", .source = .{ .git = "wrapper-url" }, .package = wrapper.id };
    try expectInvalidLock(a, .{ .packages = &.{ old, new, wrapper }, .dependencies = &.{ old_edge, wrapper_edge } });
    var distinct = wrapper;
    new_edge.source = .{ .git = "base-url", .branch = "main" };
    distinct.dependencies = &.{new_edge};
    try packages.lock.validate(a, .{ .packages = &.{ old, new, distinct }, .dependencies = &.{ old_edge, wrapper_edge } });
    var wrong_name = old_edge;
    wrong_name.name = "alias";
    try expectInvalidLock(a, .{ .packages = &.{old}, .dependencies = &.{wrong_name} });
    try expectInvalidLock(a, .{ .packages = &.{old} }); // Unreachable package.
    var cyclic = old;
    cyclic.dependencies = &.{old_edge};
    try expectInvalidLock(a, .{ .packages = &.{cyclic}, .dependencies = &.{old_edge} });
    var index = try packages.lock.Index.init(a, .{ .packages = &.{cyclic}, .dependencies = &.{old_edge} });
    defer index.deinit();
    const path = (try packages.lock.cycle(a, .{ .packages = &.{cyclic}, .dependencies = &.{old_edge} }, &index)).?;
    defer a.free(path);
    try testing.expectEqualSlices(usize, &.{ 0, 0 }, path);
}

fn expectInvalidLock(a: std.mem.Allocator, data: packages.lock.Data) !void {
    packages.lock.validate(a, data) catch |err| switch (err) {
        error.InvalidPackageLock => return,
        else => return err,
    };
    return error.ExpectedInvalidPackageLock;
}
