const std = @import("std");
const allocation_testing = @import("allocation_testing");
const artifacts = @import("artifacts");
const resources = @import("render_resources");
const utils = @import("utils");
const testing = std.testing;
const root = ".test-tmp/render-artifacts";

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
    try allocation_testing.checkAllAllocationFailures(testing.allocator, produceIcon, .{});
}

fn produceIcon(allocator: std.mem.Allocator) !void {
    try reset();
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    const icon = try artifacts.renderIconToSvg(context(allocator), "fa:star");
    defer allocator.free(icon.path);
    try testing.expect(icon.width > 0 and icon.height > 0);
}

const InputProbe = struct {
    var path: []const u8 = "";
    var stats: usize = 0;
    calls: usize = 0,
    change: bool = false,

    fn stat(userdata: ?*anyopaque, directory: std.Io.Dir, name: []const u8, options: std.Io.Dir.StatFileOptions) std.Io.Dir.StatFileError!std.Io.File.Stat {
        if (std.mem.eql(u8, name, path)) stats += 1;
        return testing.io.vtable.dirStatFile(userdata, directory, name, options);
    }

    fn observe(context_ptr: *anyopaque, name: []const u8, _: utils.file_inputs.Kind) !u64 {
        const self: *@This() = @ptrCast(@alignCast(context_ptr));
        self.calls += 1;
        if (self.change) try utils.fs.writeFile(testing.io, name, "changed during observation");
        return self.calls;
    }
};

test "cached LaTeX inputs are observed before one validation pass" {
    try reset();
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    const input = try utils.fs.absolutePath(testing.io, testing.allocator, root ++ "/input.tex");
    defer testing.allocator.free(input);
    try utils.fs.writeFile(testing.io, input, "original");
    InputProbe.path = input;
    defer InputProbe.path = "";
    var vtable = testing.io.vtable.*;
    vtable.dirStatFile = InputProbe.stat;
    const io = std.Io{ .userdata = testing.io.userdata, .vtable = &vtable };
    var cache = resources.SourceCache.init(testing.allocator, io);
    defer cache.deinit();
    const fingerprint = try cache.fileFingerprint(input);
    const manifest = try std.json.Stringify.valueAlloc(testing.allocator, .{
        .version = 1,
        .inputs = .{.{ .path = input, .fingerprint = fingerprint }},
    }, .{});
    defer testing.allocator.free(manifest);
    const reference_path = root ++ "/value.ref";
    const reference = try std.fmt.allocPrint(testing.allocator, "0\t20\t30\t0\t30\tbatch.pdf\n{s}\n", .{manifest});
    defer testing.allocator.free(reference);
    try utils.fs.writeFile(testing.io, reference_path, reference);
    try utils.fs.writeFile(testing.io, root ++ "/batch.pdf", "%PDF-1.4\n%%EOF\n");
    var observed = utils.FileInputs.init(testing.allocator);
    defer observed.deinit();
    var probe = InputProbe{};
    observed.observer = .{ .context = &probe, .capture = InputProbe.observe };
    var ctx = context(testing.allocator);
    ctx.io = io;
    ctx.resource_cache = &cache;
    ctx.file_inputs = &observed;
    InputProbe.stats = 0;
    const asset = (try artifacts.cachedLatexReference(ctx, reference_path)).?;
    defer testing.allocator.free(asset.path);
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(@as(usize, 1), InputProbe.stats);
    // The observer can capture a changed file; validation must reject the old PDF.
    observed.clear();
    try observed.record(".", root ++ "/unrelated.tex", .file);
    probe.change = true;
    try testing.expect((try artifacts.cachedLatexReference(ctx, reference_path)) == null);
    try testing.expectEqual(@as(usize, 1), observed.items().len);
    try testing.expect(!observed.paths.contains(input));
    try testing.expectEqual(@as(usize, 3), probe.calls);
}
