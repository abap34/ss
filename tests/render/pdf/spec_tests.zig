const std = @import("std");
const pdf_backend = @import("pdf_backend");
const pdf_document = @import("pdf_document");
const render = @import("render");
const render_support = @import("render_test_support");
const render_resources = @import("render_resources");

const c = @cImport({
    @cInclude("backend.h");
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

fn expectUriLinkRect(json: []const u8, uri: []const u8, expected: [4]f64) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const qpdf_entries = parsed.value.object.get("qpdf") orelse return error.ExpectedPdfJsonTextMissing;
    for (qpdf_entries.array.items) |entry_group| {
        var entries = entry_group.object.iterator();
        while (entries.next()) |entry| {
            const wrapper = switch (entry.value_ptr.*) {
                .object => |value| value,
                else => continue,
            };
            const value = wrapper.get("value") orelse continue;
            const dictionary = switch (value) {
                .object => |object| object,
                else => continue,
            };
            const action_value = dictionary.get("/A") orelse continue;
            const action = switch (action_value) {
                .object => |object| object,
                else => continue,
            };
            const uri_value = action.get("/URI") orelse continue;
            const actual_uri = switch (uri_value) {
                .string => |string| if (std.mem.startsWith(u8, string, "u:")) string[2..] else string,
                else => continue,
            };
            if (!std.mem.eql(u8, actual_uri, uri)) continue;
            const rect_value = dictionary.get("/Rect") orelse return error.ExpectedPdfJsonTextMissing;
            const rect = switch (rect_value) {
                .array => |array| array,
                else => return error.ExpectedPdfJsonTextMissing,
            };
            if (rect.items.len != expected.len) return error.ExpectedPdfJsonTextMissing;
            for (rect.items, expected) |component, expected_component| {
                const actual = switch (component) {
                    .integer => |integer| @as(f64, @floatFromInt(integer)),
                    .float => |float| float,
                    else => return error.ExpectedPdfJsonTextMissing,
                };
                try testing.expectApproxEqAbs(expected_component, actual, 0.001);
            }
            return;
        }
    }
    return error.ExpectedPdfJsonTextMissing;
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

fn qpdfQdf(allocator: std.mem.Allocator, io: std.Io, pdf_path: []const u8, qdf_path: []const u8) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "qpdf", "--qdf", "--object-streams=disable", "--stream-data=uncompress", pdf_path, qdf_path },
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return std.Io.Dir.cwd().readFileAlloc(io, qdf_path, allocator, .limited(2 * 1024 * 1024)),
        else => {},
    }
    return error.QpdfQdfFailed;
}

fn pdfTextIfAvailable(allocator: std.mem.Allocator, io: std.Io, pdf_path: []const u8) !?[]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "pdftotext", pdf_path, "-" },
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(128 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    allocator.free(result.stdout);
    return error.PdfTextExtractionFailed;
}

fn expectFileMissing(io: std.Io, file_path: []const u8) !void {
    std.Io.Dir.cwd().access(io, file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.ExpectedTemporaryFileCleanup;
}

fn documentSemantics(allocator: std.mem.Allocator, page_count: usize) !render.SemanticTree {
    const nodes = try allocator.alloc(render.SemanticNode, page_count + 1);
    const page_ids = try allocator.alloc(render.SemanticId, page_count);
    for (0..page_count) |index| {
        const id: render.SemanticId = @intCast(index + 2);
        page_ids[index] = id;
        nodes[index + 1] = .{ .id = id, .role = .page };
    }
    nodes[0] = .{ .id = 1, .role = .document, .children = page_ids };
    return .{ .root = 1, .nodes = nodes };
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
    c.ss_pdf_fill_rect(pdf, 20, 20, 120, 24, 0, 0, 0);
    c.ss_pdf_end_link(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_begin_dest_link(pdf, 20, 60, 120, 24, "target"));
    c.ss_pdf_fill_rect(pdf, 20, 60, 120, 24, 0, 0, 0);
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

test "render PDF spec: page renderer replays and composes ordered resources" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const source_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/page-source.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(source_path);
    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/page-composed.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(output_path);

    var source_pages = [_]render.Page{.{
        .page_id = 1,
        .index = 0,
        .width = 320,
        .height = 180,
    }};
    defer source_pages[0].deinit(allocator);
    try source_pages[0].appendFillRect(allocator, null, .{ .x = 0, .y = 0, .width = 320, .height = 180 }, .{ .r = 1, .g = 1, .b = 1 });
    var source_resource_builder = render_resources.Builder{};
    defer source_resource_builder.deinit(allocator);
    var source_font_builder = render.FontBuilder{};
    defer source_font_builder.deinit(allocator);
    try render_support.appendText(
        allocator,
        testing.io,
        &source_pages[0],
        &source_resource_builder,
        &source_font_builder,
        10,
        20,
        60,
        260,
        "selectable page text",
        .{ .family = "sans-serif", .weight = 400, .style = .normal, .stretch = .normal },
        24,
        .{ .r = 0, .g = 0, .b = 0 },
    );
    try source_pages[0].appendLink(allocator, .uri, "https://example.com/page", .{ .x = 20, .y = 36, .width = 240, .height = 32 });
    var source_semantics = try documentSemantics(allocator, source_pages.len);
    defer source_semantics.deinit(allocator);
    const source_catalogs = try render_support.takeCatalogs(allocator, &source_resource_builder, &source_font_builder);
    defer {
        var owned_resources = source_catalogs.resources;
        owned_resources.deinit(allocator);
        var owned_fonts = source_catalogs.fonts;
        owned_fonts.deinit(allocator);
    }
    const source_ir = render.Ir{
        .resources = source_catalogs.resources,
        .fonts = source_catalogs.fonts,
        .semantics = source_semantics,
        .pages = &source_pages,
    };
    try pdf_backend.render(allocator, testing.io, &source_ir, 0, source_path);

    var composed_pages = [_]render.Page{.{
        .page_id = 2,
        .index = 0,
        .width = 320,
        .height = 180,
    }};
    defer composed_pages[0].deinit(allocator);
    try composed_pages[0].appendFillRect(allocator, null, .{ .x = 0, .y = 0, .width = 320, .height = 180 }, .{ .r = 1, .g = 1, .b = 1 });
    var resource_builder = render_resources.Builder{};
    defer resource_builder.deinit(allocator);
    const source_resource = try resource_builder.addPath(allocator, testing.io, .pdf, source_path);
    var resources = try resource_builder.take(allocator);
    defer resources.deinit(allocator);
    try composed_pages[0].appendPdfPage(
        allocator,
        11,
        .{ .x = 20, .y = 20, .width = 280, .height = 140 },
        source_resource,
        0,
        .crop,
        true,
    );
    composed_pages[0].items.items[1].pdf_page.header.transform.x0 = 6;
    composed_pages[0].items.items[1].pdf_page.header.clip = .{ .rect = .{ .x = 20, .y = 20, .width = 260, .height = 120 } };
    composed_pages[0].items.items[1].pdf_page.header.opacity = 0.75;
    composed_pages[0].items.items[1].pdf_page.header.blend_mode = .multiply;
    try composed_pages[0].appendStrokeLine(
        allocator,
        12,
        .{ .x = 20, .y = 20 },
        .{ .x = 300, .y = 160 },
        2,
        .{ .r = 1, .g = 0, .b = 0 },
        0,
        0,
    );
    var composed_semantics = try documentSemantics(allocator, composed_pages.len);
    defer composed_semantics.deinit(allocator);
    const composed_ir = render.Ir{ .resources = resources, .semantics = composed_semantics, .pages = &composed_pages };
    try pdf_backend.render(allocator, testing.io, &composed_ir, 0, output_path);

    const json = try qpdfJson(allocator, testing.io, output_path);
    defer allocator.free(json);
    try expectContains(json, "\"/Subtype\": \"/Form\"");
    try expectContains(json, "\"/BM\": \"/Multiply\"");
    try expectContains(json, "\"/ca\": 0.75");
    try expectContains(json, "https://example.com/page");
    if (try pdfTextIfAvailable(allocator, testing.io, output_path)) |text| {
        defer allocator.free(text);
        try expectContains(text, "selectable page text");
    }
    const first_layer_path = try std.fmt.allocPrint(allocator, "{s}.layer-0.pdf", .{output_path});
    defer allocator.free(first_layer_path);
    const second_layer_path = try std.fmt.allocPrint(allocator, "{s}.layer-1.pdf", .{output_path});
    defer allocator.free(second_layer_path);
    try expectFileMissing(testing.io, first_layer_path);
    try expectFileMissing(testing.io, second_layer_path);
}

test "render PDF spec: document renderer publishes and reuses content-addressed output" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    const cache = try std.fs.path.join(allocator, &.{ root, "render-cache" });
    defer allocator.free(cache);
    const first_path = try std.fs.path.join(allocator, &.{ root, "first.pdf" });
    defer allocator.free(first_path);
    const second_path = try std.fs.path.join(allocator, &.{ root, "second.pdf" });
    defer allocator.free(second_path);

    var pages = try allocator.alloc(render.Page, 2);
    pages[0] = .{ .page_id = 1, .index = 0, .width = 320, .height = 180 };
    pages[1] = .{ .page_id = 2, .index = 1, .width = 320, .height = 180 };
    var ir = render.Ir{ .pages = pages };
    defer ir.deinit(allocator);
    ir.semantics = try documentSemantics(allocator, pages.len);
    var text_resources = render_resources.Builder{};
    defer text_resources.deinit(allocator);
    var text_fonts = render.FontBuilder{};
    defer text_fonts.deinit(allocator);
    try render_support.appendText(
        allocator,
        testing.io,
        &pages[0],
        &text_resources,
        &text_fonts,
        10,
        20,
        60,
        260,
        "first cached page",
        .{ .family = "sans-serif", .weight = 400, .style = .normal, .stretch = .normal },
        24,
        .{ .r = 0, .g = 0, .b = 0 },
    );
    try render_support.appendText(
        allocator,
        testing.io,
        &pages[1],
        &text_resources,
        &text_fonts,
        11,
        20,
        60,
        260,
        "second cached page",
        .{ .family = "sans-serif", .weight = 400, .style = .normal, .stretch = .normal },
        24,
        .{ .r = 0, .g = 0, .b = 0 },
    );
    const text_catalogs = try render_support.takeCatalogs(allocator, &text_resources, &text_fonts);
    ir.resources = text_catalogs.resources;
    ir.fonts = text_catalogs.fonts;

    try pdf_document.write(allocator, testing.io, &ir, first_path, .{ .cache_dir = cache }, null);
    try pdf_document.write(allocator, testing.io, &ir, second_path, .{ .cache_dir = cache }, null);
    const first = try std.Io.Dir.cwd().readFileAlloc(testing.io, first_path, allocator, .unlimited);
    defer allocator.free(first);
    const second = try std.Io.Dir.cwd().readFileAlloc(testing.io, second_path, allocator, .unlimited);
    defer allocator.free(second);
    try testing.expectEqualSlices(u8, first, second);
    if (try pdfTextIfAvailable(allocator, testing.io, second_path)) |text| {
        defer allocator.free(text);
        try expectContains(text, "first cached page");
        try expectContains(text, "second cached page");
    }
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

    try writeQpdfTestLayer(allocator, base_path, "base", null);
    try writeQpdfTestLayer(allocator, source_path, "selectable form text", "https://example.com/form");

    var source_width: f64 = 0;
    var source_height: f64 = 0;
    try testing.expectEqual(@as(c_int, 0), c.ss_qpdf_page_size(source_path_z.ptr, 0, 1, &source_width, &source_height));
    try testing.expectApproxEqAbs(@as(f64, 320), source_width, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 180), source_height, 0.001);

    const layers = [_]c.SsQpdfLayer{
        qpdfLayer(base_path_z.ptr, 0, 0, 320, 180, false),
        qpdfLayer(source_path_z.ptr, 40, 30, 160, 90, true),
    };
    try testing.expectEqual(@as(c_int, 0), c.ss_qpdf_compose(output_path_z.ptr, &layers, layers.len));

    const json = try qpdfJson(allocator, testing.io, output_path);
    defer allocator.free(json);
    try expectContains(json, "\"/Subtype\": \"/Form\"");
    try expectContains(json, "https://example.com/form");
    if (try pdfTextIfAvailable(allocator, testing.io, output_path)) |text| {
        defer allocator.free(text);
        try expectContains(text, "selectable form text");
    }
}

test "render PDF spec: libqpdf omits source links when annotation copying is disabled" {
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

    try writeQpdfTestLayer(allocator, base_path, "base", null);
    try writeQpdfTestLayer(allocator, source_path, "text without copied link", "https://example.com/omitted");
    const layers = [_]c.SsQpdfLayer{
        qpdfLayer(base_path_z.ptr, 0, 0, 320, 180, false),
        qpdfLayer(source_path_z.ptr, 40, 30, 160, 90, false),
    };
    try testing.expectEqual(@as(c_int, 0), c.ss_qpdf_compose(output_path_z.ptr, &layers, layers.len));

    const json = try qpdfJson(allocator, testing.io, output_path);
    defer allocator.free(json);
    try testing.expect(!contains(json, "https://example.com/omitted"));
    if (try pdfTextIfAvailable(allocator, testing.io, output_path)) |text| {
        defer allocator.free(text);
        try expectContains(text, "text without copied link");
    }
}

test "render PDF spec: libqpdf applies layer effects to content and copied links" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const base_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/base.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(base_path);
    const source_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/source.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(source_path);
    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/composed.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(output_path);
    const qdf_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/composed.qdf.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(qdf_path);
    const base_path_z = try allocator.dupeZ(u8, base_path);
    defer allocator.free(base_path_z);
    const source_path_z = try allocator.dupeZ(u8, source_path);
    defer allocator.free(source_path_z);
    const output_path_z = try allocator.dupeZ(u8, output_path);
    defer allocator.free(output_path_z);

    try writeQpdfTestLayer(allocator, base_path, "base", null);
    try writeQpdfTestLayer(allocator, source_path, "effected selectable text", "https://example.com/effected");
    var layers = [_]c.SsQpdfLayer{
        qpdfLayer(base_path_z.ptr, 0, 0, 320, 180, false),
        qpdfLayer(source_path_z.ptr, 40, 30, 160, 90, true),
    };
    layers[1].effects = .{
        .xx = 1,
        .yx = 0,
        .xy = 0,
        .yy = 1,
        .x0 = 12,
        .y0 = -8,
        .has_clip = 1,
        .clip_x = 40,
        .clip_y = 30,
        .clip_width = 120,
        .clip_height = 80,
        .opacity = 0.5,
        .blend_mode = 1,
    };
    try testing.expectEqual(@as(c_int, 0), c.ss_qpdf_compose(output_path_z.ptr, &layers, layers.len));

    const json = try qpdfJson(allocator, testing.io, output_path);
    defer allocator.free(json);
    try expectContains(json, "\"/BM\": \"/Multiply\"");
    try expectContains(json, "\"/ca\": 0.5");
    try expectContains(json, "https://example.com/effected");
    try expectUriLinkRect(json, "https://example.com/effected", .{ 62, 87, 172, 102 });

    const qdf = try qpdfQdf(allocator, testing.io, output_path, qdf_path);
    defer allocator.free(qdf);
    try expectContains(qdf, "1 0 0 1 12 -8 cm");
    try expectContains(qdf, "40 30 120 80 re W n");
    try expectContains(qdf, "/SsState1 gs");
}

fn qpdfLayer(
    path: [*c]const u8,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    copy_annotations: bool,
) c.SsQpdfLayer {
    return .{
        .path = path,
        .page_index = 0,
        .box = 1,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .copy_annotations = @intFromBool(copy_annotations),
        .effects = .{
            .xx = 1,
            .yx = 0,
            .xy = 0,
            .yy = 1,
            .x0 = 0,
            .y0 = 0,
            .has_clip = 0,
            .clip_x = 0,
            .clip_y = 0,
            .clip_width = 0,
            .clip_height = 0,
            .opacity = 1,
            .blend_mode = 0,
        },
    };
}

fn writeQpdfTestLayer(allocator: std.mem.Allocator, path: []const u8, text: []const u8, uri: ?[]const u8) !void {
    var pages = try allocator.alloc(render.Page, 1);
    pages[0] = .{ .page_id = 1, .index = 0, .width = 320, .height = 180 };
    var ir = render.Ir{ .pages = pages };
    defer ir.deinit(allocator);
    ir.semantics = try documentSemantics(allocator, pages.len);
    var resources = render_resources.Builder{};
    defer resources.deinit(allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(allocator);
    try render_support.appendText(
        allocator,
        testing.io,
        &pages[0],
        &resources,
        &fonts,
        1,
        20,
        38,
        260,
        text,
        .{ .family = "sans-serif", .weight = 400, .style = .normal, .stretch = .normal },
        18,
        .{ .r = 0, .g = 0, .b = 0 },
    );
    if (uri) |target| try pages[0].appendLink(allocator, .uri, target, .{ .x = 20, .y = 20, .width = 220, .height = 30 });
    const catalogs = try render_support.takeCatalogs(allocator, &resources, &fonts);
    ir.resources = catalogs.resources;
    ir.fonts = catalogs.fonts;
    try pdf_backend.render(allocator, testing.io, &ir, 0, path);
}
