const std = @import("std");
const c = @import("pdf_ffi").c;
const render = @import("render");
const html = @import("render_html");
const render_math = @import("render_math");
const render_support = @import("render_test_support");
const render_resources = @import("render_resources");

const testing = std.testing;

fn addDocumentSemantics(ir: *render.Ir) !void {
    const nodes = try testing.allocator.alloc(render.SemanticNode, ir.pages.len + 1);
    const page_ids = try testing.allocator.alloc(render.SemanticId, ir.pages.len);
    for (ir.pages, 0..) |_, index| {
        const id: render.SemanticId = @intCast(index + 2);
        page_ids[index] = id;
        nodes[index + 1] = .{ .id = id, .role = .page };
    }
    nodes[0] = .{ .id = 1, .role = .document, .children = page_ids };
    ir.semantics = .{ .root = 1, .nodes = nodes };
}

fn expectValidManifestResources(output: []const u8, manifest: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, manifest, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expectEqual(@as(i64, 1), object.get("schema").?.integer);
    try testing.expectEqualStrings("ss-html-bundle", object.get("kind").?.string);
    const manifest_resources = object.get("resources").?.array.items;
    try testing.expect(manifest_resources.len != 0);
    for (manifest_resources) |resource_value| {
        const resource = resource_value.object;
        const resource_id = resource.get("resource_id").?.string;
        const media_type = resource.get("media_type").?.string;
        const digest = resource.get("digest").?.string;
        const relative_path = resource.get("path").?.string;
        try testing.expectEqual(@as(usize, 64), resource_id.len);
        try testing.expect(std.mem.allEqual(u8, resource_id, '0') == false);
        try testing.expect(media_type.len != 0);
        try testing.expect(std.mem.startsWith(u8, digest, "sha256:"));
        try testing.expectEqual(@as(usize, 71), digest.len);
        try testing.expect(!std.fs.path.isAbsolute(relative_path));
        try testing.expect(std.mem.indexOf(u8, relative_path, "..") == null);
        try testing.expect(std.mem.indexOfScalar(u8, relative_path, '\\') == null);

        const path = try std.fs.path.join(testing.allocator, &.{ output, relative_path });
        defer testing.allocator.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited);
        defer testing.allocator.free(bytes);
        try testing.expectEqual(@as(i64, @intCast(bytes.len)), resource.get("bytes").?.integer);
        var actual_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &actual_digest, .{});
        const actual_hex = std.fmt.bytesToHex(actual_digest, .lower);
        try testing.expectEqualStrings(digest["sha256:".len..], &actual_hex);
    }
}

test "HTML renderer writes deterministic normal elements with escaped text" {
    const output = ".ss-cache/test-render-html/basic";
    std.Io.Dir.cwd().deleteTree(testing.io, output) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, output) catch {};

    var pages = try testing.allocator.alloc(render.Page, 1);
    pages[0] = .{ .page_id = 8, .index = 0, .width = 1280, .height = 720 };
    var ir = render.Ir{ .pages = pages };
    defer ir.deinit(testing.allocator);
    try addDocumentSemantics(&ir);
    try pages[0].appendFillRect(
        testing.allocator,
        null,
        .{ .x = 0, .y = 0, .width = 1280, .height = 720 },
        .{ .r = 1, .g = 1, .b = 1 },
    );
    var resources = render_resources.Builder{};
    defer resources.deinit(testing.allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(testing.allocator);
    try render_support.appendText(
        testing.allocator,
        testing.io,
        &pages[0],
        &resources,
        &fonts,
        42,
        72,
        120,
        500,
        "<selectable & text>",
        .{ .family = "sans", .weight = 400, .style = .normal, .stretch = .normal },
        24,
        .{ .r = 0, .g = 0, .b = 0 },
    );
    const catalogs = try render_support.takeCatalogs(testing.allocator, &resources, &fonts);
    ir.resources = catalogs.resources;
    ir.fonts = catalogs.fonts;

    try html.write(testing.allocator, testing.io, &ir, output, .{});
    const first = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/index.html", testing.allocator, .unlimited);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "<section class=\"ss-page\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "<span class=\"ss-item ss-text\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "&lt;") != null);
    try testing.expect(std.mem.indexOf(u8, first, "&amp;") != null);
    try testing.expect(std.mem.indexOf(u8, first, "&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, first, "<svg") == null);
    try testing.expect(std.mem.indexOf(u8, first, "foreignObject") == null);
    try testing.expect(std.mem.indexOf(u8, first, "application/pdf") == null);
    try testing.expect(std.mem.indexOf(u8, first, "ss.js") == null);
    try testing.expect(std.mem.indexOf(u8, first, "data-pango-baseline") == null);
    const first_css = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/ss.css", testing.allocator, .unlimited);
    defer testing.allocator.free(first_css);
    const first_manifest = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/manifest.json", testing.allocator, .unlimited);
    defer testing.allocator.free(first_manifest);
    try expectValidManifestResources(output, first_manifest);

    try html.write(testing.allocator, testing.io, &ir, output, .{});
    const second = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/index.html", testing.allocator, .unlimited);
    defer testing.allocator.free(second);
    const second_css = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/ss.css", testing.allocator, .unlimited);
    defer testing.allocator.free(second_css);
    const second_manifest = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/manifest.json", testing.allocator, .unlimited);
    defer testing.allocator.free(second_manifest);
    try testing.expectEqualStrings(first, second);
    try testing.expectEqualStrings(first_css, second_css);
    try testing.expectEqualStrings(first_manifest, second_manifest);
}

test "HTML renderer keeps emoji selectable when the resolved font forbids embedding" {
    const output = ".ss-cache/test-render-html/emoji";
    std.Io.Dir.cwd().deleteTree(testing.io, output) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, output) catch {};

    var pages = try testing.allocator.alloc(render.Page, 1);
    pages[0] = .{ .page_id = 1, .index = 0, .width = 320, .height = 180 };
    var ir = render.Ir{ .pages = pages };
    defer ir.deinit(testing.allocator);
    try addDocumentSemantics(&ir);
    var resources = render_resources.Builder{};
    defer resources.deinit(testing.allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(testing.allocator);
    try render_support.appendText(
        testing.allocator,
        testing.io,
        &pages[0],
        &resources,
        &fonts,
        7,
        20,
        60,
        240,
        "selectable 👍 emoji",
        .{ .family = "sans", .weight = 400, .style = .normal, .stretch = .normal },
        24,
        .{ .r = 0, .g = 0, .b = 0 },
    );
    const catalogs = try render_support.takeCatalogs(testing.allocator, &resources, &fonts);
    ir.resources = catalogs.resources;
    ir.fonts = catalogs.fonts;

    try html.write(testing.allocator, testing.io, &ir, output, .{});
    const document = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/index.html", testing.allocator, .unlimited);
    defer testing.allocator.free(document);
    const css = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/ss.css", testing.allocator, .unlimited);
    defer testing.allocator.free(css);
    const manifest = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/manifest.json", testing.allocator, .unlimited);
    defer testing.allocator.free(manifest);
    try testing.expect(std.mem.indexOf(u8, document, "👍") != null);
    try testing.expect(std.mem.indexOf(u8, manifest, "\"local_fonts\":[") != null);
    if (std.mem.indexOf(u8, css, "Apple Color Emoji") != null) {
        try testing.expect(std.mem.indexOf(u8, css, "local('Apple Color Emoji')") != null);
    }
}

test "HTML renderer applies page labels transforms clips opacity and blending" {
    const output = ".ss-cache/test-render-html/effects";
    std.Io.Dir.cwd().deleteTree(testing.io, output) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, output) catch {};

    var pages = try testing.allocator.alloc(render.Page, 1);
    pages[0] = .{
        .page_id = 8,
        .index = 0,
        .name = try testing.allocator.dupe(u8, "Effects & labels"),
        .width = 320,
        .height = 180,
    };
    var ir = render.Ir{ .pages = pages };
    defer ir.deinit(testing.allocator);
    try addDocumentSemantics(&ir);
    try pages[0].appendFillRect(
        testing.allocator,
        42,
        .{ .x = 20, .y = 30, .width = 80, .height = 40 },
        .{ .r = 1, .g = 0, .b = 0 },
    );
    const header = &pages[0].items.items[0].fill_rect.header;
    header.transform = .{ .xx = 2, .yy = 1.5, .x0 = 5, .y0 = 7 };
    header.clip = .{ .rect = .{ .x = 30, .y = 35, .width = 50, .height = 20 } };
    header.opacity = 0.5;
    header.blend_mode = .screen;

    try html.write(testing.allocator, testing.io, &ir, output, .{});
    const generated = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/index.html", testing.allocator, .unlimited);
    defer testing.allocator.free(generated);
    try testing.expect(std.mem.indexOf(u8, generated, "aria-label=\"Effects &amp; labels\"") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "opacity:0.500000;mix-blend-mode:screen;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "transform:translate(25.000000000pt,22.000000000pt) matrix(2.000000000000,0.000000000000,0.000000000000,1.500000000000,0,0);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "clip-path:polygon(10.000000pt 5.000000pt,60.000000pt 5.000000pt,60.000000pt 25.000000pt,10.000000pt 25.000000pt);") != null);
}

test "HTML renderer emits structured MathML without SVG or PDF fallback" {
    const output = ".ss-cache/test-render-html/math";
    std.Io.Dir.cwd().deleteTree(testing.io, output) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, output) catch {};

    var resource_builder = render_resources.Builder{};
    defer resource_builder.deinit(testing.allocator);
    var font_builder = render.FontBuilder{};
    defer font_builder.deinit(testing.allocator);

    var math_builder = render.MathBuilder{};
    defer math_builder.deinit(testing.allocator);
    const tree = try math_builder.add(testing.allocator, "x_1^2 + \\frac{\\alpha}{\\sqrt{y}}", .display);
    const tree_value = math_builder.find(tree) orelse return error.MissingMathTree;
    const math_layout = try render_math.layout(
        testing.allocator,
        testing.io,
        &resource_builder,
        &font_builder,
        tree_value,
        .{
            .font_size = 48,
            .display = true,
        },
    );
    const rect = render.Rect{ .x = 80, .y = 100, .width = math_layout.width, .height = math_layout.height };
    const catalogs = try render_support.takeCatalogs(testing.allocator, &resource_builder, &font_builder);
    var resources = catalogs.resources;
    errdefer resources.deinit(testing.allocator);
    var fonts = catalogs.fonts;
    errdefer fonts.deinit(testing.allocator);
    var math = try math_builder.take(testing.allocator);
    errdefer math.deinit(testing.allocator);

    var pages = try testing.allocator.alloc(render.Page, 1);
    pages[0] = .{ .page_id = 9, .index = 0, .width = 1280, .height = 720 };
    var ir = render.Ir{ .resources = resources, .fonts = fonts, .math = math, .pages = pages };
    resources = .{};
    fonts = .{};
    math = .{};
    defer ir.deinit(testing.allocator);
    try pages[0].appendStructuredMath(
        testing.allocator,
        43,
        rect,
        tree,
        math_layout,
        .{ .r = 0, .g = 0, .b = 0 },
    );
    pages[0].items.items[0].setSemanticId(3);
    pages[0].reading_order = try testing.allocator.dupe(render.SemanticId, &.{3});
    const semantic_nodes = try testing.allocator.alloc(render.SemanticNode, 3);
    semantic_nodes[0] = .{
        .id = 1,
        .role = .document,
        .children = try testing.allocator.dupe(render.SemanticId, &.{2}),
    };
    semantic_nodes[1] = .{
        .id = 2,
        .role = .page,
        .children = try testing.allocator.dupe(render.SemanticId, &.{3}),
    };
    semantic_nodes[2] = .{
        .id = 3,
        .role = .math,
        .items = try testing.allocator.dupe(render.ItemId, &.{pages[0].items.items[0].header().item_id}),
        .text = try testing.allocator.dupe(u8, "x_1^2 + \\frac{\\alpha}{\\sqrt{y}}"),
        .math_tree = tree,
    };
    ir.semantics = .{ .root = 1, .nodes = semantic_nodes };

    try html.write(testing.allocator, testing.io, &ir, output, .{});
    const document = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/index.html", testing.allocator, .unlimited);
    defer testing.allocator.free(document);
    try testing.expect(std.mem.indexOf(u8, document, "class=\"ss-mathml\" xmlns=\"http://www.w3.org/1998/Math/MathML\"") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, document, "class=\"ss-mathml\""));
    try testing.expect(std.mem.indexOf(u8, document, "<div class=\"ss-semantic-layer\"><math") != null);
    try testing.expect(std.mem.indexOf(u8, document, "ss-math-text") != null);
    try testing.expect(std.mem.indexOf(u8, document, "ss-math-rule") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<msubsup>") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<mfrac>") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<msqrt>") != null);
    try testing.expect(std.mem.indexOf(u8, document, "α") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<svg") == null);
    try testing.expect(std.mem.indexOf(u8, document, "data-pdf-src") == null);
    const css = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/ss.css", testing.allocator, .unlimited);
    defer testing.allocator.free(css);
    try testing.expect(std.mem.indexOf(u8, css, "ascent-override:0.000000000%") == null);
}

test "HTML renderer packages PDF.js with explicit page geometry" {
    const output = ".ss-cache/test-render-html/pdf";
    const resource_path = ".ss-cache/test-render-html/pdf-source.pdf";
    std.Io.Dir.cwd().deleteTree(testing.io, output) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, output) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, ".ss-cache/test-render-html");
    const resource_path_z = try testing.allocator.dupeZ(u8, resource_path);
    defer testing.allocator.free(resource_path_z);
    const pdf = c.ss_pdf_create(resource_path_z.ptr, 120, 60) orelse return error.CairoCreateFailed;
    c.ss_pdf_end_page(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_finish(pdf));
    c.ss_pdf_destroy(pdf);
    defer std.Io.Dir.cwd().deleteFile(testing.io, resource_path) catch {};

    var resource_builder = render_resources.Builder{};
    defer resource_builder.deinit(testing.allocator);
    const pdf_resource = try resource_builder.addPath(testing.allocator, testing.io, .pdf, resource_path);
    var resources = try resource_builder.take(testing.allocator);
    errdefer resources.deinit(testing.allocator);
    var pages = try testing.allocator.alloc(render.Page, 1);
    pages[0] = .{ .page_id = 10, .index = 0, .width = 320, .height = 180 };
    var ir = render.Ir{ .resources = resources, .pages = pages };
    resources = .{};
    defer ir.deinit(testing.allocator);
    try addDocumentSemantics(&ir);
    try pages[0].appendPdfPage(
        testing.allocator,
        44,
        .{ .x = 20, .y = 30, .width = 240, .height = 120 },
        pdf_resource,
        0,
        .crop,
        true,
    );

    try html.write(testing.allocator, testing.io, &ir, output, .{});
    const document = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/index.html", testing.allocator, .unlimited);
    defer testing.allocator.free(document);
    try testing.expect(std.mem.indexOf(u8, document, "class=\"ss-item ss-pdf\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "data-view-box=\"0.000000000,0.000000000,120.000000000,60.000000000\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "data-rotation=\"0\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "data-copy-annotations=\"true\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<script type=\"module\" src=\"ss.js\"></script>") != null);
    try std.Io.Dir.cwd().access(testing.io, output ++ "/pdfjs/pdf.mjs", .{});
    try std.Io.Dir.cwd().access(testing.io, output ++ "/pdfjs/pdf.worker.mjs", .{});
    try std.Io.Dir.cwd().access(testing.io, output ++ "/pdfjs/LICENSE", .{});
}

test "HTML renderer preserves semantic headings zero-based ordered lists and links" {
    const output = ".ss-cache/test-render-html/semantics";
    std.Io.Dir.cwd().deleteTree(testing.io, output) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, output) catch {};

    var pages = try testing.allocator.alloc(render.Page, 1);
    pages[0] = .{ .page_id = 1, .index = 0, .width = 320, .height = 180 };
    pages[0].reading_order = try testing.allocator.dupe(render.SemanticId, &.{ 3, 5 });
    var ir = render.Ir{ .pages = pages };
    defer ir.deinit(testing.allocator);

    const nodes = try testing.allocator.alloc(render.SemanticNode, 9);
    nodes[0] = .{ .id = 1, .role = .document, .children = try testing.allocator.dupe(render.SemanticId, &.{2}) };
    nodes[1] = .{ .id = 2, .role = .page, .children = try testing.allocator.dupe(render.SemanticId, &.{ 3, 5 }) };
    nodes[2] = .{ .id = 3, .role = .heading, .heading_level = 2, .children = try testing.allocator.dupe(render.SemanticId, &.{4}) };
    nodes[3] = .{ .id = 4, .role = .text, .text = try testing.allocator.dupe(u8, "Overview") };
    nodes[4] = .{ .id = 5, .role = .list, .list_ordered = true, .list_start = 0, .children = try testing.allocator.dupe(render.SemanticId, &.{6}) };
    nodes[5] = .{ .id = 6, .role = .list_item, .children = try testing.allocator.dupe(render.SemanticId, &.{7}) };
    nodes[6] = .{ .id = 7, .role = .paragraph, .children = try testing.allocator.dupe(render.SemanticId, &.{ 8, 9 }) };
    nodes[7] = .{ .id = 8, .role = .text, .text = try testing.allocator.dupe(u8, "Read ") };
    nodes[8] = .{
        .id = 9,
        .role = .link,
        .text = try testing.allocator.dupe(u8, "the reference"),
        .link_kind = .uri,
        .link_target = try testing.allocator.dupe(u8, "https://example.com/reference"),
    };
    ir.semantics = .{ .root = 1, .nodes = nodes };

    try html.write(testing.allocator, testing.io, &ir, output, .{});
    const document = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/index.html", testing.allocator, .unlimited);
    defer testing.allocator.free(document);
    try testing.expect(std.mem.indexOf(u8, document, "<h2 data-ss-semantic-id=\"3\"><span data-ss-semantic-id=\"4\">Overview</span></h2>") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<ol data-ss-semantic-id=\"5\" start=\"0\">") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<a data-ss-semantic-id=\"9\" href=\"https://example.com/reference\">the reference</a>") != null);
}
