const std = @import("std");
const app = @import("app");
const utils = @import("utils");

const testing = std.testing;

test "app output spec: render APIs reject colliding output paths before writing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    const input = try std.fs.path.join(allocator, &.{ root, "slide.ss" });
    defer allocator.free(input);
    const output = try std.fs.path.join(allocator, &.{ root, "protected-output" });
    defer allocator.free(output);
    const cache = try std.fs.path.join(allocator, &.{ root, "render-cache" });
    defer allocator.free(cache);
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = input,
        .data = "page main\nend\n",
        .flags = .{ .truncate = true },
    });

    const previous_level = utils.err.diagnosticLevel();
    defer utils.err.setDiagnosticLevel(previous_level);
    utils.err.setDiagnosticLevel(.off);
    const source = app.SourceRequest{
        .input_path = input,
        .asset_base_dir = root,
    };

    try writeSentinel(output);
    var pdf_progress = utils.progress.Progress.disabled(app.render_progress_steps);
    try testing.expectError(error.DiagnosticsFailed, app.writePdf(testing.io, allocator, .{
        .source = source,
        .output_path = output,
        .options = .{
            .render = .{ .cache_dir = cache },
            .diagnostics_json_path = output,
        },
    }, &pdf_progress));
    try expectSentinel(output);

    try writeSentinel(output);
    var html_progress = utils.progress.Progress.disabled(app.render_progress_steps);
    try testing.expectError(error.DiagnosticsFailed, app.writeHtml(testing.io, allocator, .{
        .source = source,
        .output_path = output,
        .options = .{
            .render = .{ .cache_dir = cache },
            .diagnostics_json_path = output,
        },
    }, &html_progress));
    try expectSentinel(output);

    try writeSentinel(output);
    var combined_progress = utils.progress.Progress.disabled(app.pdf_and_html_progress_steps);
    try testing.expectError(error.DiagnosticsFailed, app.writePdfAndHtml(testing.io, allocator, .{
        .source = source,
        .pdf_output_path = output,
        .html_output_path = output,
        .options = .{ .render = .{ .cache_dir = cache } },
    }, &combined_progress));
    try expectSentinel(output);
}

fn writeSentinel(path: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = path,
        .data = "sentinel\n",
        .flags = .{ .truncate = true },
    });
}

fn expectSentinel(path: []const u8) !void {
    const contents = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("sentinel\n", contents);
}
