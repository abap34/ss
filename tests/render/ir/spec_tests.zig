const std = @import("std");
const render_ir = @import("render");

const testing = std.testing;

fn addDocumentSemantics(ir: *render_ir.Ir) !void {
    const nodes = try testing.allocator.alloc(render_ir.SemanticNode, 1);
    nodes[0] = .{ .id = 1, .role = .document };
    ir.semantics = .{ .root = 1, .nodes = nodes };
}

test "render IR page owns placed text and references stable resources" {
    var page = render_ir.Page{
        .page_id = 10,
        .index = 2,
        .width = 1280,
        .height = 720,
    };
    defer page.deinit(testing.allocator);

    var text = [_]u8{ 'i', 't', 'e', 'm' };
    var family = [_]u8{ 'S', 'a', 'n', 's' };
    try page.appendText(
        testing.allocator,
        42,
        12,
        34,
        180,
        &text,
        .{ .family = &family, .weight = 500, .style = .normal, .stretch = .normal },
        24,
        .{ .r = 0.1, .g = 0.2, .b = 0.3 },
        false,
        false,
    );
    const resource: render_ir.ResourceId = @splat(1);
    try page.appendSvg(
        testing.allocator,
        42,
        .{ .x = 20, .y = 40, .width = 16, .height = 16 },
        resource,
        .{ .r = 1, .g = 0, .b = 0 },
    );

    text[0] = 'X';
    family[0] = 'X';

    try testing.expectEqualStrings("item", page.items.items[0].text.layout.source_text);
    try testing.expectEqualStrings("Sans", page.items.items[0].text.layout.runs[0].font_family);
    try testing.expectEqual(resource, page.items.items[1].svg.resource);
    try testing.expectEqual(@as(?u32, 42), page.items.items[0].nodeId());
}

test "render IR page preserves PDF placement and annotations" {
    var page = render_ir.Page{
        .page_id = 7,
        .index = 0,
        .width = 1280,
        .height = 720,
    };
    defer page.deinit(testing.allocator);

    try page.appendPdfPage(
        testing.allocator,
        9,
        .{ .x = 100, .y = 80, .width = 400, .height = 240 },
        @splat(2),
        3,
        .trim,
        true,
    );
    try page.appendDestination(testing.allocator, "section", .{ .x = 100, .y = 80 });
    try page.appendLink(
        testing.allocator,
        .destination,
        "section",
        .{ .x = 100, .y = 80, .width = 120, .height = 24 },
    );

    try testing.expect(page.hasPdfPages());
    const pdf = page.items.items[0].pdf_page;
    try testing.expectEqual(@as(usize, 3), pdf.page_index);
    try testing.expectEqual(render_ir.CoordinateSpace.origin, "page-top-left");
    try testing.expectEqualStrings("section", page.destinations.items[0].name);
    try testing.expectEqualStrings("section", page.links.items[0].target);
}

test "render IR validation accepts deterministic page and item order" {
    var pages = try testing.allocator.alloc(render_ir.Page, 1);
    pages[0] = .{ .page_id = 1, .index = 0, .width = 1280, .height = 720 };
    var ir = render_ir.Ir{ .pages = pages };
    defer ir.deinit(testing.allocator);
    try addDocumentSemantics(&ir);
    try pages[0].appendFillRect(
        testing.allocator,
        null,
        .{ .x = 0, .y = 0, .width = 1280, .height = 720 },
        .{ .r = 1, .g = 1, .b = 1 },
    );

    try ir.validate();
    try testing.expectEqual(@as(render_ir.ItemId, 1 << 32), pages[0].items.items[0].header().item_id);
}

test "render IR validation rejects non-finite geometry and unstable ordering" {
    var pages = try testing.allocator.alloc(render_ir.Page, 1);
    pages[0] = .{ .page_id = 1, .index = 0, .width = 1280, .height = 720 };
    var ir = render_ir.Ir{ .pages = pages };
    defer ir.deinit(testing.allocator);
    try addDocumentSemantics(&ir);
    try pages[0].appendFillRect(
        testing.allocator,
        null,
        .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .{ .r = 1, .g = 1, .b = 1 },
    );

    pages[0].items.items[0].fill_rect.header.paint_index = 2;
    try testing.expectError(error.InvalidPaintIndex, ir.validate());
    pages[0].items.items[0].fill_rect.header.paint_index = 0;
    pages[0].items.items[0].fill_rect.rect.x = std.math.nan(f64);
    try testing.expectError(error.InvalidItemGeometry, ir.validate());
}

test "math IR parses structured expressions and deduplicates equal inputs" {
    var builder = render_ir.MathBuilder{};
    defer builder.deinit(testing.allocator);

    const source = "x_1^2 + \\frac{\\alpha}{\\sqrt{y}}";
    const first = try builder.add(testing.allocator, source, .display);
    const second = try builder.add(testing.allocator, source, .display);
    try testing.expectEqual(first, second);

    var catalog = try builder.take(testing.allocator);
    defer catalog.deinit(testing.allocator);
    const tree = catalog.find(first) orelse return error.MissingMathTree;
    try testing.expectEqual(render_ir.MathInputKind.display, tree.input_kind);
    try testing.expectEqualStrings(source, tree.source);

    var has_scripts = false;
    var has_fraction = false;
    var has_square_root = false;
    var has_alpha = false;
    for (tree.nodes) |node| switch (node.kind) {
        .subscript_superscript => has_scripts = true,
        .fraction => has_fraction = true,
        .square_root => has_square_root = true,
        .identifier => if (node.text) |text| {
            if (std.mem.eql(u8, text, "α")) has_alpha = true;
        },
        else => {},
    };
    try testing.expect(has_scripts);
    try testing.expect(has_fraction);
    try testing.expect(has_square_root);
    try testing.expect(has_alpha);
}

test "math IR distinguishes raw TeX and rejects unsupported structured commands" {
    var builder = render_ir.MathBuilder{};
    defer builder.deinit(testing.allocator);

    try testing.expectError(
        error.UnsupportedMathSyntax,
        builder.add(testing.allocator, "\\unsupported{x}", .display),
    );
    const raw_id = try builder.add(testing.allocator, "\\unsupported{x}", .raw);
    var catalog = try builder.take(testing.allocator);
    defer catalog.deinit(testing.allocator);
    const raw = catalog.find(raw_id) orelse return error.MissingMathTree;
    try testing.expectEqual(render_ir.MathInputKind.raw, raw.input_kind);
    try testing.expectEqual(render_ir.MathNodeKind.raw_tex, raw.nodes[raw.root].kind);
}
