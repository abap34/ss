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
    try expectCString(c.ss_pdf_gdk_pixbuf_version_string());
    try testing.expect(c.ss_pdf_fontconfig_version() > 0);
    try expectCString(c.ss_pdf_harfbuzz_version_string());
    try expectCString(c.ss_qpdf_version_string());
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
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_draw_text(pdf, 20, 20, 120, "external", "sans-serif", 400, 0, 4, 12, 0, 0, 0, 0));
    c.ss_pdf_end_link(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_begin_dest_link(pdf, 20, 60, 120, 24, "target"));
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_draw_text(pdf, 20, 60, 120, "internal", "sans-serif", 400, 0, 4, 12, 0, 0, 0, 0));
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

test "render PDF spec: Cairo shim draws baseline text without a clipping frame" {
    try expectBaselineTextDrawn(false);
    try expectBaselineTextDrawn(true);
}

fn expectBaselineTextDrawn(preserve_color_glyphs: bool) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const pdf_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/text-clip.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(pdf_path);
    const pdf_path_z = try allocator.dupeZ(u8, pdf_path);
    defer allocator.free(pdf_path_z);

    const pdf = c.ss_pdf_create(pdf_path_z.ptr, 320, 180) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_begin_page(pdf, 320, 180);

    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_begin_recording(pdf));
    const baseline_y: f64 = 58;
    const result = if (preserve_color_glyphs)
        c.ss_pdf_draw_color_text_baseline(
            pdf,
            20,
            baseline_y,
            260,
            "Ag Ag Ag Ag Ag Ag Ag Ag Ag",
            "sans-serif",
            400,
            0,
            4,
            48,
            0,
            0,
            0,
            1,
        )
    else
        c.ss_pdf_draw_text_baseline(
            pdf,
            20,
            baseline_y,
            260,
            "Ag Ag Ag Ag Ag Ag Ag Ag Ag",
            "sans-serif",
            400,
            0,
            4,
            48,
            0,
            0,
            0,
            1,
        );
    try testing.expectEqual(@as(c_int, 0), result);
    var ink: c.SsPdfRecordingExtents = undefined;
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_recording_ink_extents(pdf, &ink));
    try expectInkCrossesBaseline(ink, baseline_y);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_paint_recording_fit(pdf, 320, 180, 1));

    c.ss_pdf_end_page(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_finish(pdf));
}

fn expectInkCrossesBaseline(ink: c.SsPdfRecordingExtents, baseline_y: f64) !void {
    const eps = 1.0;
    try testing.expect(ink.height > 0);
    try testing.expect(ink.y < baseline_y - eps);
    try testing.expect(ink.y + ink.height > baseline_y + eps);
}

test "render PDF spec: raster shim decodes and draws without a converted PNG" {
    var width: f64 = 0;
    var height: f64 = 0;
    try testing.expectEqual(@as(c_int, 0), c.ss_raster_size("assets/logo.png", &width, &height));
    try testing.expect(width > 0);
    try testing.expect(height > 0);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const pdf_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/raster.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(pdf_path);
    const pdf_path_z = try allocator.dupeZ(u8, pdf_path);
    defer allocator.free(pdf_path_z);

    const pdf = c.ss_pdf_create(pdf_path_z.ptr, 320, 180) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_begin_page(pdf, 320, 180);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_draw_raster(pdf, "assets/logo.png", 20, 20, 120, 120));
    c.ss_pdf_end_page(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_finish(pdf));
}

test "render PDF spec: libqpdf composes a selectable page form and copies links" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const base_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/base.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(base_path);
    const source_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/source.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(source_path);
    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/composed.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(output_path);
    const base_path_z = try allocator.dupeZ(u8, base_path);
    defer allocator.free(base_path_z);
    const source_path_z = try allocator.dupeZ(u8, source_path);
    defer allocator.free(source_path_z);
    const output_path_z = try allocator.dupeZ(u8, output_path);
    defer allocator.free(output_path_z);

    try writeQpdfTestLayer(base_path_z, "base", null);
    try writeQpdfTestLayer(source_path_z, "selectable form text", "https://example.com/form");

    var source_width: f64 = 0;
    var source_height: f64 = 0;
    try testing.expectEqual(@as(c_int, 0), c.ss_qpdf_page_size(source_path_z.ptr, 0, 1, &source_width, &source_height));
    try testing.expectApproxEqAbs(@as(f64, 320), source_width, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 180), source_height, 0.001);

    const layers = [_]c.SsQpdfLayer{
        .{ .path = base_path_z.ptr, .page_index = 0, .box = 1, .x = 0, .y = 0, .width = 320, .height = 180, .copy_annotations = 0 },
        .{ .path = source_path_z.ptr, .page_index = 0, .box = 1, .x = 40, .y = 30, .width = 160, .height = 90, .copy_annotations = 1 },
    };
    try testing.expectEqual(@as(c_int, 0), c.ss_qpdf_compose(output_path_z.ptr, &layers, layers.len));

    const json = try qpdfJson(allocator, testing.io, output_path);
    defer allocator.free(json);
    try expectContains(json, "\"/Subtype\": \"/Form\"");
    try expectContains(json, "https://example.com/form");
}

fn writeQpdfTestLayer(path: [:0]const u8, text: [*:0]const u8, uri: ?[*:0]const u8) !void {
    const pdf = c.ss_pdf_create(path.ptr, 320, 180) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_begin_page(pdf, 320, 180);
    if (uri) |target| {
        try testing.expectEqual(@as(c_int, 0), c.ss_pdf_begin_uri_link(pdf, 20, 20, 220, 30, target));
    }
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_draw_text(pdf, 20, 20, 260, text, "sans-serif", 400, 0, 4, 18, 0, 0, 0, 0));
    if (uri != null) c.ss_pdf_end_link(pdf);
    c.ss_pdf_end_page(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_finish(pdf));
}
