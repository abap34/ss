const std = @import("std");
const c = @import("pdf_ffi").c;
const render_text = @import("render_text");
const native = @cImport({
    @cInclude("stdlib.h");
    @cInclude("fontconfig/fontconfig.h");
});
const testing = std.testing;

fn replacePreservingMtime(path: []const u8, bytes: []const u8) !void {
    const replacement = try std.fmt.allocPrint(testing.allocator, "{s}.replacement", .{path});
    defer testing.allocator.free(replacement);
    const original = try std.Io.Dir.cwd().openFile(testing.io, path, .{});
    const before = try original.stat(testing.io);
    original.close(testing.io);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = replacement, .data = bytes });
    try std.Io.Dir.cwd().setTimestamps(testing.io, replacement, .{ .modify_timestamp = .{ .new = before.mtime } });
    try std.Io.Dir.cwd().rename(replacement, std.Io.Dir.cwd(), path, testing.io);
    const updated = try std.Io.Dir.cwd().openFile(testing.io, path, .{});
    defer updated.close(testing.io);
    const after = try updated.stat(testing.io);
    try testing.expectEqual(before.size, after.size);
    try testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
    try testing.expect(before.inode != after.inode);
}

fn expectUnchanged(expected: render_text.FontEnvironment) !void {
    for (0..3) |_| {
        const actual = try render_text.fontEnvironmentRefresh();
        try testing.expectEqual(expected.generation, actual.generation);
        try testing.expectEqualSlices(u8, &expected.id, &actual.id);
    }
}

// This test has its own process because application font registrations last until exit.
test "font input reuse detects configuration and font replacements and removals" {
    const root = ".ss-cache/test-render-font-environment";
    const config_path = root ++ "/fonts.conf";
    const font_path = root ++ "/registered.ttf";
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, root);

    const default_config = native.FcConfigFilename(null);
    try testing.expect(default_config != null);
    defer native.FcStrFree(default_config);
    const default_path = std.mem.span(@as([*:0]const u8, @ptrCast(default_config)));
    var escaped_path: std.ArrayList(u8) = .empty;
    defer escaped_path.deinit(testing.allocator);
    for (default_path) |byte| switch (byte) {
        '&' => try escaped_path.appendSlice(testing.allocator, "&amp;"),
        '<' => try escaped_path.appendSlice(testing.allocator, "&lt;"),
        '>' => try escaped_path.appendSlice(testing.allocator, "&gt;"),
        else => try escaped_path.append(testing.allocator, byte),
    };
    const initial_config = try std.fmt.allocPrint(testing.allocator, "<?xml version=\"1.0\"?><!DOCTYPE fontconfig SYSTEM \"urn:fontconfig:fonts.dtd\"><fontconfig><include ignore_missing=\"no\">{s}</include><!-- a --></fontconfig>\n", .{escaped_path.items});
    defer testing.allocator.free(initial_config);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = config_path, .data = initial_config });
    const absolute_config = native.realpath(config_path, null);
    try testing.expect(absolute_config != null);
    defer native.free(absolute_config);
    const previous_environment = native.getenv("FONTCONFIG_FILE");
    const saved_environment = if (previous_environment != null)
        try testing.allocator.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(previous_environment))))
    else
        null;
    defer if (saved_environment) |value| testing.allocator.free(value);
    defer if (saved_environment) |value| {
        _ = native.setenv("FONTCONFIG_FILE", value, 1);
    } else {
        _ = native.unsetenv("FONTCONFIG_FILE");
    };
    try testing.expectEqual(@as(c_int, 0), native.setenv("FONTCONFIG_FILE", absolute_config, 1));
    try testing.expect(native.FcInitReinitialize() != 0);
    const first = try render_text.fontEnvironmentRefresh();
    try expectUnchanged(first);

    const changed_config = try testing.allocator.dupe(u8, initial_config);
    defer testing.allocator.free(changed_config);
    const comment = std.mem.indexOf(u8, changed_config, "<!-- a -->").?;
    changed_config[comment + 5] = 'b';
    try replacePreservingMtime(config_path, changed_config);
    const configured = try render_text.fontEnvironmentRefresh();
    try testing.expect(configured.generation > first.generation);
    try testing.expect(!std.mem.eql(u8, &first.id, &configured.id));
    try testing.expectError(error.FontEnvironmentChanged, render_text.refreshAndValidateFontEnvironment(first));
    try expectUnchanged(configured);

    var shape = std.mem.zeroes(c.SsTextShape);
    try testing.expectEqual(@as(c_int, 0), c.ss_text_shape("font input seed", "sans-serif", 400, 0, 4, 16, 320, 0, &shape));
    defer c.ss_text_shape_free(&shape);
    try testing.expect(shape.run_count != 0 and shape.runs[0].font_path != null);
    const original_font_path = std.mem.span(@as([*:0]const u8, @ptrCast(shape.runs[0].font_path)));
    const font_bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, original_font_path, testing.allocator, .limited(64 * 1024 * 1024));
    defer testing.allocator.free(font_bytes);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = font_path, .data = font_bytes });
    try testing.expectEqual(@as(c_int, 0), c.ss_font_register(font_path));
    const registered = try render_text.fontEnvironmentRefresh();
    try expectUnchanged(registered);
    try replacePreservingMtime(font_path, font_bytes);
    const replaced = try render_text.fontEnvironmentRefresh();
    try testing.expect(replaced.generation > registered.generation);
    try testing.expect(!std.mem.eql(u8, &registered.id, &replaced.id));
    try testing.expectError(error.FontEnvironmentChanged, render_text.refreshAndValidateFontEnvironment(registered));
    try expectUnchanged(replaced);
    try std.Io.Dir.cwd().deleteFile(testing.io, font_path);
    try testing.expectError(error.FontEnvironmentRefreshFailed, render_text.fontEnvironmentRefresh());
}
