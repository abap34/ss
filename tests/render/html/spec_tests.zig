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

fn deleteOutput(path: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(testing.io, path) catch {};
    cwd.deleteTree(testing.io, path) catch {};
}

fn prepareOutput(path: []const u8) !void {
    deleteOutput(path);
    const parent = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(testing.io, parent);
}

fn embeddedStyleSheet(document: []const u8) ![]u8 {
    const prefix = "<script type=\"text/plain\" data-ss-stylesheet>data:text/css;charset=utf-8;base64,";
    const start = (std.mem.indexOf(u8, document, prefix) orelse return error.MissingEmbeddedStyleSheet) + prefix.len;
    const end_offset = std.mem.indexOf(u8, document[start..], "</script>") orelse return error.InvalidEmbeddedStyleSheet;
    const encoded = document[start .. start + end_offset];
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try testing.allocator.alloc(u8, size);
    errdefer testing.allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    return decoded;
}

fn firstEmbeddedResource(document: []const u8) ![]u8 {
    const prefix = "<script type=\"application/octet-stream\" data-ss-resource=\"";
    const tag_start = std.mem.indexOf(u8, document, prefix) orelse return error.MissingEmbeddedResource;
    const body_offset = std.mem.indexOfScalar(u8, document[tag_start..], '>') orelse return error.InvalidEmbeddedResource;
    const start = tag_start + body_offset + 1;
    const end_offset = std.mem.indexOf(u8, document[start..], "</script>") orelse return error.InvalidEmbeddedResource;
    const encoded = document[start .. start + end_offset];
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try testing.allocator.alloc(u8, size);
    errdefer testing.allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    return decoded;
}

fn pdfItemOpeningTag(document: []const u8, copy_annotations: bool) ![]const u8 {
    const policy = if (copy_annotations) "data-copy-annotations=\"true\"" else "data-copy-annotations=\"false\"";
    const policy_index = std.mem.indexOf(u8, document, policy) orelse return error.MissingPdfItem;
    const start = std.mem.lastIndexOf(u8, document[0..policy_index], "<div class=\"ss-item ss-pdf\"") orelse return error.MissingPdfItem;
    const end_offset = std.mem.indexOfScalar(u8, document[policy_index..], '>') orelse return error.InvalidPdfItem;
    return document[start .. policy_index + end_offset + 1];
}

test "HTML renderer writes deterministic normal elements with escaped text" {
    const output = ".ss-cache/test-render-html/basic.html";
    try prepareOutput(output);
    defer deleteOutput(output);

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

    try html.write(testing.allocator, testing.io, &ir, output);
    const first = try std.Io.Dir.cwd().readFileAlloc(testing.io, output, testing.allocator, .unlimited);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "<section class=\"ss-page\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "data-ss-page-index=\"1\" data-ss-active=\"true\" aria-hidden=\"false\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "<span class=\"ss-item ss-text\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "&lt;") != null);
    try testing.expect(std.mem.indexOf(u8, first, "&amp;") != null);
    try testing.expect(std.mem.indexOf(u8, first, "&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, first, "<svg") == null);
    try testing.expect(std.mem.indexOf(u8, first, "foreignObject") == null);
    try testing.expect(std.mem.indexOf(u8, first, "application/pdf") == null);
    try testing.expect(std.mem.indexOf(u8, first, "ss.js") == null);
    try testing.expect(std.mem.indexOf(u8, first, "data-pango-baseline") == null);
    try testing.expect(std.mem.indexOf(u8, first, "data-ss-baseline-y=\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "data:text/css;charset=utf-8;base64,") != null);
    try testing.expect(std.mem.indexOf(u8, first, "html:not([data-ss-ready]):not([data-ss-error]) body{visibility:hidden}") != null);
    const first_css = try embeddedStyleSheet(first);
    defer testing.allocator.free(first_css);
    try testing.expect(std.mem.indexOf(u8, first_css, ".ss-page") != null);
    try testing.expect(std.mem.indexOf(u8, first_css, "ss-resource:font:") != null);
    try testing.expect(std.mem.indexOf(u8, first_css, "ascent-override") == null);
    try testing.expect(std.mem.indexOf(u8, first_css, "descent-override") == null);
    try testing.expect(std.mem.indexOf(u8, first_css, "line-gap-override") == null);
    try testing.expect(std.mem.indexOf(u8, first, "data-ss-resource=\"ss-resource:font:") != null);
    const first_resource = try firstEmbeddedResource(first);
    defer testing.allocator.free(first_resource);
    try testing.expect(first_resource.len > 48 * 1024);

    try html.write(testing.allocator, testing.io, &ir, output);
    const second = try std.Io.Dir.cwd().readFileAlloc(testing.io, output, testing.allocator, .unlimited);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
}

test "HTML renderer leaves a directory destination intact" {
    const output = ".ss-cache/test-render-html/directory-output";
    try prepareOutput(output);
    try std.Io.Dir.cwd().createDirPath(testing.io, output);
    defer deleteOutput(output);

    const pages = try testing.allocator.alloc(render.Page, 0);
    var ir = render.Ir{ .pages = pages };
    defer ir.deinit(testing.allocator);
    try addDocumentSemantics(&ir);

    try testing.expectError(error.OutputPathNotFile, html.write(testing.allocator, testing.io, &ir, output));
    var directory = try std.Io.Dir.cwd().openDir(testing.io, output, .{});
    directory.close(testing.io);
}

test "HTML renderer keeps emoji selectable when the resolved font forbids embedding" {
    const output = ".ss-cache/test-render-html/emoji.html";
    try prepareOutput(output);
    defer deleteOutput(output);

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

    try html.write(testing.allocator, testing.io, &ir, output);
    const document = try std.Io.Dir.cwd().readFileAlloc(testing.io, output, testing.allocator, .unlimited);
    defer testing.allocator.free(document);
    const css = try embeddedStyleSheet(document);
    defer testing.allocator.free(css);
    try testing.expect(std.mem.indexOf(u8, document, "👍") != null);
    if (std.mem.indexOf(u8, css, "Apple Color Emoji") != null) {
        try testing.expect(std.mem.indexOf(u8, css, "local('Apple Color Emoji')") != null);
    }
}

test "HTML renderer applies page labels transforms clips opacity and blending" {
    const output = ".ss-cache/test-render-html/effects.html";
    try prepareOutput(output);
    defer deleteOutput(output);

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
    try pages[0].appendRoundedRect(
        testing.allocator,
        43,
        .{ .x = 120, .y = 60, .width = 80, .height = 40 },
        10,
        null,
        .{ .r = 0, .g = 0, .b = 1 },
        6,
    );

    try html.write(testing.allocator, testing.io, &ir, output);
    const generated = try std.Io.Dir.cwd().readFileAlloc(testing.io, output, testing.allocator, .unlimited);
    defer testing.allocator.free(generated);
    try testing.expect(std.mem.indexOf(u8, generated, "aria-label=\"Effects &amp; labels\"") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "opacity:0.500000;mix-blend-mode:screen;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "transform:translate(25.000000000pt,22.000000000pt) matrix(2.000000000000,0.000000000000,0.000000000000,1.500000000000,0,0);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "clip-path:polygon(10.000000pt 5.000000pt,60.000000pt 5.000000pt,60.000000pt 25.000000pt,10.000000pt 25.000000pt);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "left:117.000000pt;top:57.000000pt;width:86.000000pt;height:46.000000pt;border:6.000000pt solid") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "border-radius:13.000000pt") != null);
}

test "HTML renderer emits structured MathML without SVG or PDF fallback" {
    const output = ".ss-cache/test-render-html/math.html";
    try prepareOutput(output);
    defer deleteOutput(output);

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

    try html.write(testing.allocator, testing.io, &ir, output);
    const document = try std.Io.Dir.cwd().readFileAlloc(testing.io, output, testing.allocator, .unlimited);
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
    const css = try embeddedStyleSheet(document);
    defer testing.allocator.free(css);
    try testing.expect(std.mem.indexOf(u8, css, "ascent-override") == null);
}

test "HTML renderer packages PDF.js with explicit page geometry" {
    const output = ".ss-cache/test-render-html/pdf.html";
    const resource_path = ".ss-cache/test-render-html/pdf-source.pdf";
    try prepareOutput(output);
    defer deleteOutput(output);
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
    ir.resources.entries[0].metadata.pdf.pages[0].user_unit = 2;
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
    try pages[0].appendPdfPage(
        testing.allocator,
        45,
        .{ .x = 20, .y = 30, .width = 240, .height = 120 },
        pdf_resource,
        0,
        .crop,
        false,
    );

    try html.write(testing.allocator, testing.io, &ir, output);
    const document = try std.Io.Dir.cwd().readFileAlloc(testing.io, output, testing.allocator, .unlimited);
    defer testing.allocator.free(document);
    try testing.expect(std.mem.indexOf(u8, document, "class=\"ss-item ss-pdf\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "data-view-box=\"0.000000000,0.000000000,120.000000000,60.000000000\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "data-rotation=\"0\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "data-canvas-background=\"transparent\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "data-copy-annotations=\"true\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<canvas") == null);
    const css = try embeddedStyleSheet(document);
    defer testing.allocator.free(css);
    try testing.expect(std.mem.indexOf(u8, css, ".ss-pdf .textLayer { overflow: visible;") != null);
    try testing.expect(std.mem.indexOf(u8, css, ".ss-pdf [data-main-rotation=\"90\"]") != null);
    try testing.expect(std.mem.indexOf(u8, css, "html[data-ss-print-layout] .ss-document > .ss-page") != null);
    const interactive_pdf = try pdfItemOpeningTag(document, true);
    try testing.expect(std.mem.indexOf(u8, interactive_pdf, "aria-hidden") == null);
    const decorative_pdf = try pdfItemOpeningTag(document, false);
    try testing.expect(std.mem.indexOf(u8, decorative_pdf, "aria-hidden=\"true\"") != null);
    try testing.expect(std.mem.count(u8, document, "class=\"ss-pdf-layer ss-pdf-text\" aria-hidden=\"true\"") == 2);
    try testing.expect(std.mem.indexOf(u8, document, "class=\"ss-pdf-layer ss-pdf-annotations\" aria-hidden") == null);
    try testing.expect(std.mem.indexOf(u8, document, "data-pdf-src=\"ss-resource:pdf:") != null);
    try testing.expect(std.mem.indexOf(u8, document, "data-media-type=\"application/pdf\"") != null);
    try testing.expect(std.mem.count(u8, document, "data:text/javascript;charset=utf-8;base64,") >= 5);
    try testing.expect(std.mem.indexOf(u8, document, "<script type=\"importmap\">") != null);
    try testing.expect(std.mem.indexOf(u8, document, "\"@ss/pdf/controller\":\"data:text/javascript;charset=utf-8;base64,") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<script type=\"module\">") != null);
    try testing.expect(std.mem.indexOf(u8, document, "globalThis.ssDocument=Object.freeze({prepareForPrint,finishPrint,print:printDocument})") != null);
    try testing.expect(std.mem.indexOf(u8, document, "data-ss-third-party-license=\"pdf.js\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "Apache License") != null);
    try testing.expect(std.mem.indexOf(u8, document, "pdfjs/") == null);
}

test "HTML renderer preserves semantic headings zero-based ordered lists and links" {
    const output = ".ss-cache/test-render-html/semantics.html";
    try prepareOutput(output);
    defer deleteOutput(output);

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

    try html.write(testing.allocator, testing.io, &ir, output);
    const document = try std.Io.Dir.cwd().readFileAlloc(testing.io, output, testing.allocator, .unlimited);
    defer testing.allocator.free(document);
    try testing.expect(std.mem.indexOf(u8, document, "<h2 data-ss-semantic-id=\"3\"><span data-ss-semantic-id=\"4\">Overview</span></h2>") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<ol data-ss-semantic-id=\"5\" start=\"0\">") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<a data-ss-semantic-id=\"9\" href=\"https://example.com/reference\">the reference</a>") != null);
}
