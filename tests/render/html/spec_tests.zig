const std = @import("std");
const render = @import("render");
const html = @import("render_html");
const render_support = @import("render_test_support");

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
    var resources = render.ResourceBuilder{};
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

    try html.write(testing.allocator, testing.io, &ir, output, .{});
    const second = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/index.html", testing.allocator, .unlimited);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
}

test "HTML renderer emits structured MathML without SVG or PDF fallback" {
    const output = ".ss-cache/test-render-html/math";
    const resource_path = ".ss-cache/test-render-html/math-source.pdf";
    std.Io.Dir.cwd().deleteTree(testing.io, output) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, output) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, ".ss-cache/test-render-html");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = resource_path, .data = "%PDF-1.4\n", .flags = .{ .truncate = true } });
    defer std.Io.Dir.cwd().deleteFile(testing.io, resource_path) catch {};

    var resource_builder = render.ResourceBuilder{};
    defer resource_builder.deinit(testing.allocator);
    const pdf_resource = try resource_builder.addPath(testing.allocator, testing.io, .math_pdf, resource_path);
    var resources = try resource_builder.take(testing.allocator);
    errdefer resources.deinit(testing.allocator);

    var math_builder = render.MathBuilder{};
    defer math_builder.deinit(testing.allocator);
    const tree = try math_builder.add(testing.allocator, "x_1^2 + \\frac{\\alpha}{\\sqrt{y}}", .display);
    var math = try math_builder.take(testing.allocator);
    errdefer math.deinit(testing.allocator);

    var pages = try testing.allocator.alloc(render.Page, 1);
    pages[0] = .{ .page_id = 9, .index = 0, .width = 1280, .height = 720 };
    var ir = render.Ir{ .resources = resources, .math = math, .pages = pages };
    resources = .{};
    math = .{};
    defer ir.deinit(testing.allocator);
    try addDocumentSemantics(&ir);
    try pages[0].appendMath(
        testing.allocator,
        43,
        .{ .x = 80, .y = 100, .width = 400, .height = 100 },
        tree,
        pdf_resource,
        0,
        .crop,
    );

    try html.write(testing.allocator, testing.io, &ir, output, .{});
    const document = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/index.html", testing.allocator, .unlimited);
    defer testing.allocator.free(document);
    try testing.expect(std.mem.indexOf(u8, document, "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<msubsup>") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<mfrac>") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<msqrt>") != null);
    try testing.expect(std.mem.indexOf(u8, document, "α") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<svg") == null);
    try testing.expect(std.mem.indexOf(u8, document, "data-pdf-src") == null);
}

test "HTML renderer preserves semantic headings ordered lists and links" {
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
    nodes[4] = .{ .id = 5, .role = .list, .list_ordered = true, .list_start = 3, .children = try testing.allocator.dupe(render.SemanticId, &.{6}) };
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
    try testing.expect(std.mem.indexOf(u8, document, "<ol data-ss-semantic-id=\"5\" start=\"3\">") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<a data-ss-semantic-id=\"9\" href=\"https://example.com/reference\">the reference</a>") != null);
}
