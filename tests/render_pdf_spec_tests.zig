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

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn expectInternalDestination(json: []const u8) !void {
    const direct_dest = contains(json, "\"/Dest\": \"u:target\"") or
        contains(json, "\"/Dest\": \"target\"") or
        contains(json, "\"/Dest\": [");
    const goto_action = contains(json, "\"/S\": \"/GoTo\"") and
        (contains(json, "\"/D\": \"u:target\"") or contains(json, "\"/D\": \"target\"") or contains(json, "\"/D\": ["));
    if (direct_dest or goto_action) return;

    std.debug.print("missing expected internal destination annotation in PDF JSON\n", .{});
    return error.ExpectedPdfJsonTextMissing;
}

fn expectCString(ptr: [*c]const u8) !void {
    try testing.expect(ptr != null);
    const sentinel: [*:0]const u8 = @ptrCast(ptr);
    try testing.expect(std.mem.span(sentinel).len > 0);
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

test "render PDF spec: Cairo shim exposes rendering dependency versions" {
    try expectCString(c.ss_pdf_cairo_version_string());
    try expectCString(c.ss_pdf_pango_version_string());
    try expectCString(c.ss_pdf_librsvg_version_string());
    try testing.expect(c.ss_pdf_fontconfig_version() > 0);
    try expectCString(c.ss_pdf_harfbuzz_version_string());
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
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_draw_text(pdf, 20, 20, 120, 24, "external", "sans-serif", 400, 0, 4, 12, 0, 0, 0, 0));
    c.ss_pdf_end_link(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_begin_dest_link(pdf, 20, 60, 120, 24, "target"));
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_draw_text(pdf, 20, 60, 120, 24, "internal", "sans-serif", 400, 0, 4, 12, 0, 0, 0, 0));
    c.ss_pdf_end_link(pdf);
    c.ss_pdf_end_page(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_finish(pdf));

    const json = try qpdfJson(allocator, testing.io, pdf_path);
    defer allocator.free(json);
    try expectContains(json, "\"/Annots\"");
    try expectContains(json, "\"/Subtype\": \"/Link\"");
    try expectContains(json, "\"/S\": \"/URI\"");
    try expectContains(json, "https://example.com");
    try expectInternalDestination(json);
}

test "render PDF spec: Cairo recording fit keeps oversized text inside the page" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const pdf_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/recording-fit.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(pdf_path);
    const pdf_path_z = try allocator.dupeZ(u8, pdf_path);
    defer allocator.free(pdf_path_z);

    const pdf = c.ss_pdf_create(pdf_path_z.ptr, 320, 180) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_begin_page(pdf, 320, 180);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_begin_recording(pdf));
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_draw_text(
        pdf,
        -40,
        -24,
        900,
        80,
        "Oversized recording text reaches past both page edges",
        "sans-serif",
        700,
        0,
        4,
        52,
        0,
        0,
        0,
        0,
    ));

    var ink: c.SsPdfRecordingExtents = undefined;
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_recording_ink_extents(pdf, &ink));
    try testing.expect(ink.x < 0 or ink.y < 0 or ink.x + ink.width > 320 or ink.y + ink.height > 180);

    var fit: c.SsPdfRecordingFit = undefined;
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_recording_fit(pdf, 320, 180, 1, &fit));
    const left = fit.tx + fit.bounds.x * fit.scale;
    const right = fit.tx + (fit.bounds.x + fit.bounds.width) * fit.scale;
    const top = fit.ty + fit.bounds.y * fit.scale;
    const bottom = fit.ty + (fit.bounds.y + fit.bounds.height) * fit.scale;
    const eps = 1e-6;
    try testing.expect(left >= 1 - eps);
    try testing.expect(top >= 1 - eps);
    try testing.expect(right <= 319 + eps);
    try testing.expect(bottom <= 179 + eps);

    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_paint_recording_with_fit(pdf, &fit));
    c.ss_pdf_end_page(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_finish(pdf));
}
