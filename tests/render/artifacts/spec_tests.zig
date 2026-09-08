const std = @import("std");
const artifacts = @import("artifacts");
const resources = @import("render_resources");
const testing = std.testing;
const root = ".ss-cache/test-render-artifacts";

fn reset() !void {
    try std.Io.Dir.cwd().deleteTree(testing.io, root);
    try std.Io.Dir.cwd().createDirPath(testing.io, root);
}

fn context(allocator: std.mem.Allocator) artifacts.Context {
    return .{ .allocator = allocator, .io = testing.io, .asset_base_dir = root, .cache_dir = root };
}

fn canceledRead(_: ?*anyopaque, _: std.Io.File, _: []const []u8, _: u64) std.Io.File.ReadPositionalError!usize {
    return error.Canceled;
}

test "artifact validation preserves a cached PDF when reading is canceled" {
    try reset();
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    const path = root ++ "/valid.pdf";
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "%PDF-1.4\n%%EOF\n" });
    var vtable = testing.io.vtable.*;
    vtable.fileReadPositional = canceledRead;
    var ctx = context(testing.allocator);
    ctx.io = .{ .userdata = testing.io.userdata, .vtable = &vtable };
    try testing.expectError(error.Canceled, artifacts.cachedPdfAvailable(ctx, path));
    try testing.expect(artifacts.fileExists(path));
    try testing.expect(try artifacts.cachedPdfAvailable(context(testing.allocator), path));
}

test "artifact validation preserves a cached PDF on allocation failure" {
    try reset();
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    const path = root ++ "/valid.pdf";
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "%PDF-1.4\n%%EOF\n" });
    var allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, artifacts.cachedPdfAvailable(context(allocator.allocator()), path));
    try testing.expect(artifacts.fileExists(path));
}

test "artifact validation removes incomplete PDFs" {
    try reset();
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    const path = root ++ "/incomplete.pdf";
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "%PDF-1.4\ninterrupted" });
    try testing.expect(!try artifacts.cachedPdfAvailable(context(testing.allocator), path));
    try testing.expect(!artifacts.fileExists(path));
}

test "icon production owns paths and shares decoded resources without an IR builder" {
    try reset();
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    var cache = resources.SourceCache.init(testing.allocator, testing.io);
    defer cache.deinit();
    var ctx = context(testing.allocator);
    ctx.resource_cache = &cache;
    const first = try artifacts.renderIconToSvg(ctx, "fa:star");
    defer testing.allocator.free(first.path);
    const second = try artifacts.renderIconToSvg(ctx, "fa:star");
    defer testing.allocator.free(second.path);
    try testing.expect(first.path.ptr != second.path.ptr);
    try testing.expectEqualStrings(first.path, second.path);
    try testing.expect(first.width > 0 and first.height > 0);
    try testing.expectEqual(first.width, second.width);
    const size = try artifacts.svgAsset(ctx, first.path);
    try testing.expectEqual(first.height, size.height);
    var builder = resources.Builder{};
    defer builder.deinit(testing.allocator);
    builder.cache = &cache;
    const count = cache.sources.items.len;
    _ = try builder.addPath(testing.allocator, testing.io, .svg, first.path);
    try testing.expectEqual(count, cache.sources.items.len);
    try testing.expectEqual(@as(usize, 1), builder.entries.items.len);
}

test "icon production releases owned outputs through every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, produceIcon, .{});
}

fn produceIcon(allocator: std.mem.Allocator) !void {
    try reset();
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    const icon = try artifacts.renderIconToSvg(context(allocator), "fa:star");
    defer allocator.free(icon.path);
    try testing.expect(icon.width > 0 and icon.height > 0);
}
