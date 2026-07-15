const std = @import("std");
const render = @import("render");
const html = @import("render_html");

const testing = std.testing;

fn addDocumentSemantics(ir: *render.Ir) !void {
    const nodes = try testing.allocator.alloc(render.SemanticNode, 1);
    nodes[0] = .{ .id = 1, .role = .document };
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
    try pages[0].appendText(
        testing.allocator,
        42,
        72,
        120,
        500,
        "<selectable & text>",
        .{ .family = "sans", .weight = 400, .style = .normal, .stretch = .normal },
        24,
        .{ .r = 0, .g = 0, .b = 0 },
        false,
        false,
    );

    try html.write(testing.allocator, testing.io, &ir, output, .{});
    const first = try std.Io.Dir.cwd().readFileAlloc(testing.io, output ++ "/index.html", testing.allocator, .unlimited);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "<section class=\"ss-page\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "<span class=\"ss-item ss-text\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "&lt;selectable &amp; text&gt;") != null);
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
