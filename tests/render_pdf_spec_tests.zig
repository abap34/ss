const std = @import("std");

const c = @cImport({
    @cInclude("pdf.h");
});

const testing = std.testing;

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing expected PDF JSON text: {s}\n", .{needle});
        return error.ExpectedPdfJsonTextMissing;
    }
}

fn qpdfJson(allocator: std.mem.Allocator, io: std.Io, pdf_path: []const u8) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "qpdf", "--json", pdf_path },
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    allocator.free(result.stdout);
    return error.QpdfJsonFailed;
}

test "render PDF spec: Cairo shim writes URI and destination link annotations" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const pdf_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/links.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(pdf_path);
    const pdf_path_z = try allocator.dupeZ(u8, pdf_path);
    defer allocator.free(pdf_path_z);

    const pdf = c.ss_pdf_create(pdf_path_z.ptr, 320, 180) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_begin_page(pdf, 320, 180);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_add_destination(pdf, "target", 20, 20));
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_begin_uri_link(pdf, 20, 20, 120, 24, "https://example.com"));
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_draw_text(pdf, 20, 20, 120, 24, "external", "sans-serif 12", 12, 0, 0, 0, 0));
    c.ss_pdf_end_link(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_begin_dest_link(pdf, 20, 60, 120, 24, "target"));
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_draw_text(pdf, 20, 60, 120, 24, "internal", "sans-serif 12", 12, 0, 0, 0, 0));
    c.ss_pdf_end_link(pdf);
    c.ss_pdf_end_page(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_finish(pdf));

    const json = try qpdfJson(allocator, testing.io, pdf_path);
    defer allocator.free(json);
    try expectContains(json, "\"/Annots\"");
    try expectContains(json, "\"/Subtype\": \"/Link\"");
    try expectContains(json, "\"/S\": \"/URI\"");
    try expectContains(json, "https://example.com");
    try expectContains(json, "\"/Dest\": \"u:target\"");
}
