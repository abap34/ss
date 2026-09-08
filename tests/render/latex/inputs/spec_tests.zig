const std = @import("std");
const latex = @import("latex_inputs");
const utils = @import("utils");
const testing = std.testing;

test "latex inputs: recorder paths honor working directories and exclude outputs" {
    try testing.checkAllAllocationFailures(testing.allocator, recorderPaths, .{});
}

fn recorderPaths(allocator: std.mem.Allocator) !void {
    const paths = try latex.recorderPaths(allocator,
        \\PWD /project
        \\INPUT styles/my preamble.tex
        \\INPUT ./styles/my preamble.tex
        \\INPUT /outside/math.tex
        \\INPUT /cache/build/main.tex
        \\INPUT /cache/build/main.aux
        \\OUTPUT /cache/build/main.aux
        \\INPUT saved.aux
        \\OUTPUT saved.aux
        \\PWD /project/nested
        \\INPUT second.tex
        \\INPUT /cache/build-sibling/input.tex
        \\
    , "/initial", "/cache/build");
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }
    const expected = [_][]const u8{ "/cache/build-sibling/input.tex", "/outside/math.tex", "/project/nested/second.tex", "/project/styles/my preamble.tex" };
    try testing.expectEqual(expected.len, paths.len);
    for (expected, paths) |want, actual| try testing.expectEqualStrings(want, actual);
}

test "latex inputs: manifests own validated paths through allocation failures" {
    try testing.checkAllAllocationFailures(testing.allocator, parseManifest, .{});
    const invalid = [_][]const u8{
        "{}",
        "{\"inputs\":[]}",
        "{\"version\":2,\"inputs\":[]}",
        "{\"inputs\":[{\"path\":\"relative.tex\",\"fingerprint\":{\"present\":true,\"digest\":1}}]}",
        "{\"inputs\":[{\"path\":\"/b\",\"fingerprint\":{\"present\":true,\"digest\":1}},{\"path\":\"/a\",\"fingerprint\":{\"present\":true,\"digest\":1}}]}",
    };
    for (invalid) |text| try testing.expectError(error.InvalidPdfCache, latex.parse(testing.allocator, text));
}

fn parseManifest(allocator: std.mem.Allocator) !void {
    const text = try allocator.dupe(u8, "{\"version\":1,\"inputs\":[{\"path\":\"/project/in\\\"put.tex\",\"fingerprint\":{\"present\":true,\"digest\":42}}]}");
    var parsed = latex.parse(allocator, text) catch |err| {
        allocator.free(text);
        return err;
    };
    allocator.free(text);
    defer parsed.deinit();
    try testing.expectEqualStrings("/project/in\"put.tex", parsed.value.inputs[0].path);
    try testing.expectEqual(@as(u64, 42), parsed.value.inputs[0].fingerprint.digest);
}

test "latex inputs: changes and missing inputs invalidate retained manifests" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const allocator = testing.allocator;
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer allocator.free(root);
    const first = try std.fs.path.resolve(allocator, &.{ root, "first.tex" });
    defer allocator.free(first);
    const second = try std.fs.path.resolve(allocator, &.{ root, "second.tex" });
    defer allocator.free(second);
    try utils.fs.writeFile(testing.io, first, "first");
    try utils.fs.writeFile(testing.io, second, "second");
    var observed = utils.FileInputs.init(allocator);
    defer observed.deinit();
    var cache = @import("render_resources").SourceCache.init(allocator, testing.io);
    defer cache.deinit();
    const context = latex.Context{ .allocator = allocator, .io = testing.io, .cache = &cache, .observed = &observed };
    const inputs = try latex.capture(context, &.{ first, second });
    defer latex.free(allocator, inputs);
    try testing.expect(try latex.matches(context, inputs));
    const original = latex.digest(inputs);
    try utils.fs.writeFile(testing.io, first, "changed");
    observed.clear();
    try testing.expect(!try latex.matches(context, inputs));
    try testing.expectEqual(@as(usize, 2), observed.items().len);
    const changed = try latex.capture(context, &.{ first, second });
    defer latex.free(allocator, changed);
    try testing.expect(original != latex.digest(changed));
    try std.Io.Dir.cwd().deleteFile(testing.io, first);
    try testing.expect(!try latex.matches(context, inputs));
    try utils.fs.writeFile(testing.io, first, "first");
    try testing.expect(try latex.matches(context, inputs));
}

test "latex inputs: missing file diagnostics retain unopened external paths" {
    var observed = utils.FileInputs.init(testing.allocator);
    defer observed.deinit();
    try latex.recordMissingInputs(&observed,
        \\! LaTeX Error: File `../outside/missing.tex' not found.
        \\! I can't find file `/absolute/my missing
        \\input'.
        \\File 'unrelated.tex' was opened successfully.
        \\! Package pdftex.def Error: File 'image.png' not found: using draft setting.
    , "/project");
    const paths = observed.items();
    const expected = [_][]const u8{ "/absolute/my missinginput", "/absolute/my missinginput.tex", "/outside/missing.tex", "/project/image.png" };
    try testing.expectEqual(expected.len, paths.len);
    for (expected, paths) |want, actual| try testing.expectEqualStrings(want, actual.path);
}
