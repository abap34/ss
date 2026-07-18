const std = @import("std");
const render_ir = @import("render");
const render_support = @import("render_test_support");
const render_resources = @import("render_resources");

const testing = std.testing;

fn addDocumentSemantics(ir: *render_ir.Ir) !void {
    const nodes = try testing.allocator.alloc(render_ir.SemanticNode, ir.pages.len + 1);
    const page_ids = try testing.allocator.alloc(render_ir.SemanticId, ir.pages.len);
    for (ir.pages, 0..) |_, index| {
        const id: render_ir.SemanticId = @intCast(index + 2);
        page_ids[index] = id;
        nodes[index + 1] = .{ .id = id, .role = .page };
    }
    nodes[0] = .{ .id = 1, .role = .document, .children = page_ids };
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

    var resources = render_resources.Builder{};
    defer resources.deinit(testing.allocator);
    var fonts = render_ir.FontBuilder{};
    defer fonts.deinit(testing.allocator);
    var text = [_]u8{ 'i', 't', 'e', 'm' };
    try render_support.appendText(
        testing.allocator,
        testing.io,
        &page,
        &resources,
        &fonts,
        42,
        12,
        34,
        180,
        &text,
        .{ .family = "Sans", .weight = 500, .style = .normal, .stretch = .normal },
        24,
        .{ .r = 0.1, .g = 0.2, .b = 0.3 },
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

    try testing.expectEqualStrings("item", page.items.items[0].text.layout.source_text);
    try testing.expect(fonts.instances.items.len > 0);
    try testing.expect(fonts.instances.items[0].family.len > 0);
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

test "stroke ink bounds follow the line normal without extending butt caps" {
    var page = render_ir.Page{
        .page_id = 1,
        .index = 0,
        .width = 1280,
        .height = 720,
    };
    defer page.deinit(testing.allocator);

    try page.appendStrokeLine(testing.allocator, null, .{ .x = 10, .y = 20 }, .{ .x = 40, .y = 20 }, 10, .{ .r = 0, .g = 0, .b = 0 }, 0, 0);
    try page.appendStrokeLine(testing.allocator, null, .{ .x = 10, .y = 20 }, .{ .x = 10, .y = 60 }, 10, .{ .r = 0, .g = 0, .b = 0 }, 0, 0);
    try page.appendStrokeLine(testing.allocator, null, .{ .x = 10, .y = 20 }, .{ .x = 40, .y = 60 }, 10, .{ .r = 0, .g = 0, .b = 0 }, 0, 0);

    const horizontal = page.items.items[0].header().ink_bounds;
    try testing.expectEqual(render_ir.Rect{ .x = 10, .y = 15, .width = 30, .height = 10 }, horizontal);
    const vertical = page.items.items[1].header().ink_bounds;
    try testing.expectEqual(render_ir.Rect{ .x = 5, .y = 20, .width = 10, .height = 40 }, vertical);
    const diagonal = page.items.items[2].header().ink_bounds;
    try testing.expectEqual(render_ir.Rect{ .x = 6, .y = 17, .width = 38, .height = 46 }, diagonal);
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

test "render IR validation rejects invalid colors and page names" {
    var pages = try testing.allocator.alloc(render_ir.Page, 1);
    pages[0] = .{ .page_id = 1, .index = 0, .width = 320, .height = 180 };
    var ir = render_ir.Ir{ .pages = pages };
    defer ir.deinit(testing.allocator);
    try addDocumentSemantics(&ir);
    try pages[0].appendFillRect(
        testing.allocator,
        null,
        .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .{ .r = 1, .g = 1, .b = 1 },
    );

    try ir.validate();
    pages[0].items.items[0].fill_rect.color.r = 1.01;
    try testing.expectError(error.InvalidItemGeometry, ir.validate());
    pages[0].items.items[0].fill_rect.color.r = 1;
    pages[0].name = try testing.allocator.dupe(u8, &.{0xff});
    try testing.expectError(error.InvalidPageName, ir.validate());
}

test "render IR validation rejects non-basename resource names" {
    var pages = try testing.allocator.alloc(render_ir.Page, 1);
    pages[0] = .{ .page_id = 1, .index = 0, .width = 320, .height = 180 };
    var ir = render_ir.Ir{ .pages = pages };
    defer ir.deinit(testing.allocator);
    try addDocumentSemantics(&ir);

    const bytes = try testing.allocator.dupe(u8, &.{0});
    const entries = try testing.allocator.alloc(render_ir.Resource, 1);
    entries[0] = .{
        .id = render_ir.identifyResource(.raster, bytes),
        .kind = .raster,
        .name = try testing.allocator.dupe(u8, "asset.png"),
        .bytes = bytes,
        .metadata = .{ .raster = .{
            .pixel_width = 1,
            .pixel_height = 1,
            .oriented_width = 1,
            .oriented_height = 1,
            .orientation = .normal,
            .color_space = .unknown,
            .has_alpha = false,
        } },
    };
    ir.resources = .{ .entries = entries };

    try ir.validate();
    testing.allocator.free(entries[0].name);
    entries[0].name = try testing.allocator.dupe(u8, "../asset.png");
    try testing.expectError(error.InvalidResource, ir.validate());
}

test "render IR fingerprints page source and visual effect metadata" {
    var pages = try testing.allocator.alloc(render_ir.Page, 1);
    pages[0] = .{
        .page_id = 1,
        .index = 0,
        .name = try testing.allocator.dupe(u8, "Overview"),
        .width = 320,
        .height = 180,
    };
    var ir = render_ir.Ir{ .pages = pages };
    defer ir.deinit(testing.allocator);
    try addDocumentSemantics(&ir);
    try pages[0].appendFillRect(
        testing.allocator,
        7,
        .{ .x = 10, .y = 20, .width = 30, .height = 40 },
        .{ .r = 1, .g = 1, .b = 1 },
    );
    const header = &pages[0].items.items[0].fill_rect.header;
    header.source = .{ .module_id = 2, .start = 10, .end = 20 };
    header.transform.x0 = 4;
    header.clip = .{ .rect = .{ .x = 12, .y = 22, .width = 20, .height = 30 } };
    header.opacity = 0.75;
    header.blend_mode = .multiply;
    try ir.validate();

    const original = ir.fingerprint();
    const original_page = render_ir.pageFingerprint(&pages[0]);
    header.source.?.end += 1;
    try testing.expect(!std.mem.eql(u8, &original, &ir.fingerprint()));
    try testing.expectEqualSlices(u8, &original_page, &render_ir.pageFingerprint(&pages[0]));
    header.source.?.end -= 1;
    pages[0].name[0] = 'o';
    try testing.expect(!std.mem.eql(u8, &original, &ir.fingerprint()));
    try testing.expectEqualSlices(u8, &original_page, &render_ir.pageFingerprint(&pages[0]));

    header.opacity = 0.5;
    try testing.expect(!std.mem.eql(u8, &original_page, &render_ir.pageFingerprint(&pages[0])));
}

test "render IR validation rejects invalid source and clip ranges" {
    var pages = try testing.allocator.alloc(render_ir.Page, 1);
    pages[0] = .{ .page_id = 1, .index = 0, .width = 320, .height = 180 };
    var ir = render_ir.Ir{ .pages = pages };
    defer ir.deinit(testing.allocator);
    try addDocumentSemantics(&ir);
    try pages[0].appendFillRect(
        testing.allocator,
        7,
        .{ .x = 10, .y = 20, .width = 30, .height = 40 },
        .{ .r = 1, .g = 1, .b = 1 },
    );
    const header = &pages[0].items.items[0].fill_rect.header;
    header.source = .{ .module_id = 2, .start = 20, .end = 10 };
    try testing.expectError(error.InvalidItemGeometry, ir.validate());
    header.source.?.end = 20;
    header.clip = .{ .rect = .{ .x = 0, .y = 0, .width = -1, .height = 10 } };
    try testing.expectError(error.InvalidBounds, ir.validate());
}

test "render IR validates resolved fonts and bidirectional text partitions" {
    var pages = try testing.allocator.alloc(render_ir.Page, 1);
    pages[0] = .{ .page_id = 1, .index = 0, .width = 1280, .height = 720 };
    var ir = render_ir.Ir{ .pages = pages };
    defer ir.deinit(testing.allocator);
    try addDocumentSemantics(&ir);

    var resources = render_resources.Builder{};
    defer resources.deinit(testing.allocator);
    var fonts = render_ir.FontBuilder{};
    defer fonts.deinit(testing.allocator);
    try render_support.appendText(
        testing.allocator,
        testing.io,
        &pages[0],
        &resources,
        &fonts,
        42,
        20,
        80,
        500,
        "office 😀 العربية",
        .{ .family = "Sans", .weight = 400, .style = .normal, .stretch = .normal },
        24,
        .{ .r = 0, .g = 0, .b = 0 },
    );
    const catalogs = try render_support.takeCatalogs(testing.allocator, &resources, &fonts);
    ir.resources = catalogs.resources;
    ir.fonts = catalogs.fonts;

    try ir.validate();
    const layout = pages[0].items.items[0].text.layout;
    try testing.expect(layout.runs.len >= 2);
    try testing.expect(layout.clusters.len > 0);
    var found_right_to_left = false;
    for (layout.runs) |run| {
        try testing.expect(ir.fonts.find(run.font_instance) != null);
        if (run.direction == .right_to_left) found_right_to_left = true;
    }
    for (layout.clusters) |cluster| {
        try testing.expect(cluster.logical_bounds.isValid());
        try testing.expect(cluster.ink_bounds.isValid());
        try testing.expect(cluster.source.start < cluster.source.end);
        try testing.expect(cluster.glyph_range.start < cluster.glyph_range.end);
    }
    try testing.expect(found_right_to_left);

    const line_run_start = layout.lines[0].run_range.start;
    layout.lines[0].run_range.start += 1;
    try testing.expectError(error.InvalidItemGeometry, ir.validate());
    layout.lines[0].run_range.start = line_run_start;

    const run_cluster_start = layout.runs[0].cluster_range.start;
    layout.runs[0].cluster_range.start += 1;
    try testing.expectError(error.InvalidItemGeometry, ir.validate());
    layout.runs[0].cluster_range.start = run_cluster_start;
}

test "font instances use content-derived identities and deterministic catalog order" {
    var builder = render_ir.FontBuilder{};
    defer builder.deinit(testing.allocator);
    const resource: render_ir.ResourceId = @splat(7);
    const first = try builder.add(testing.allocator, testing.io, .{
        .resource = resource,
        .face_index = 1,
        .family = "Example Sans",
        .postscript_name = "ExampleSans-Regular",
        .weight = 400,
        .style = .normal,
        .stretch = .normal,
        .ascent_ratio = 0.8,
        .descent_ratio = 0.2,
        .line_gap_ratio = 0,
        .underline_position_ratio = -0.1,
        .underline_thickness_ratio = 0.05,
        .strikethrough_position_ratio = 0.3,
        .strikethrough_thickness_ratio = 0.05,
    });
    const second = try builder.add(testing.allocator, testing.io, .{
        .resource = resource,
        .face_index = 0,
        .family = "Example Sans",
        .postscript_name = "ExampleSans-Regular",
        .weight = 400,
        .style = .normal,
        .stretch = .normal,
        .ascent_ratio = 0.8,
        .descent_ratio = 0.2,
        .line_gap_ratio = 0,
        .underline_position_ratio = -0.1,
        .underline_thickness_ratio = 0.05,
        .strikethrough_position_ratio = 0.3,
        .strikethrough_thickness_ratio = 0.05,
    });
    const duplicate = try builder.add(testing.allocator, testing.io, .{
        .resource = resource,
        .face_index = 1,
        .family = "Example Sans",
        .postscript_name = "ExampleSans-Regular",
        .weight = 400,
        .style = .normal,
        .stretch = .normal,
        .ascent_ratio = 0.8,
        .descent_ratio = 0.2,
        .line_gap_ratio = 0,
        .underline_position_ratio = -0.1,
        .underline_thickness_ratio = 0.05,
        .strikethrough_position_ratio = 0.3,
        .strikethrough_thickness_ratio = 0.05,
    });
    const different_metrics = try builder.add(testing.allocator, testing.io, .{
        .resource = resource,
        .face_index = 1,
        .family = "Example Sans",
        .postscript_name = "ExampleSans-Regular",
        .weight = 400,
        .style = .normal,
        .stretch = .normal,
        .ascent_ratio = 0.8,
        .descent_ratio = 0.2,
        .line_gap_ratio = 0,
        .underline_position_ratio = -0.12,
        .underline_thickness_ratio = 0.05,
        .strikethrough_position_ratio = 0.3,
        .strikethrough_thickness_ratio = 0.05,
    });
    try testing.expectEqual(first, duplicate);
    try testing.expect(!std.mem.eql(u8, &first, &second));
    try testing.expect(!std.mem.eql(u8, &first, &different_metrics));

    var catalog = try builder.take(testing.allocator);
    defer catalog.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), catalog.instances.len);
    for (catalog.instances[1..], catalog.instances[0 .. catalog.instances.len - 1]) |current, previous| {
        try testing.expect(std.mem.order(u8, &previous.id, &current.id) == .lt);
    }
}

test "semantic validation rejects unsafe link targets" {
    var pages = try testing.allocator.alloc(render_ir.Page, 1);
    pages[0] = .{ .page_id = 1, .index = 0, .width = 320, .height = 180 };
    pages[0].reading_order = try testing.allocator.dupe(render_ir.SemanticId, &.{3});
    var ir = render_ir.Ir{ .pages = pages };
    defer ir.deinit(testing.allocator);
    const nodes = try testing.allocator.alloc(render_ir.SemanticNode, 3);
    nodes[0] = .{ .id = 1, .role = .document, .children = try testing.allocator.dupe(render_ir.SemanticId, &.{2}) };
    nodes[1] = .{ .id = 2, .role = .page, .children = try testing.allocator.dupe(render_ir.SemanticId, &.{3}) };
    nodes[2] = .{
        .id = 3,
        .role = .link,
        .text = try testing.allocator.dupe(u8, "unsafe"),
        .link_kind = .uri,
        .link_target = try testing.allocator.dupe(u8, "javascript:alert(1)"),
    };
    ir.semantics = .{ .root = 1, .nodes = nodes };
    try testing.expectError(error.InvalidSemantics, ir.validate());
}

test "annotation validation rejects unsafe URI targets" {
    var pages = try testing.allocator.alloc(render_ir.Page, 1);
    pages[0] = .{ .page_id = 1, .index = 0, .width = 320, .height = 180 };
    var ir = render_ir.Ir{ .pages = pages };
    defer ir.deinit(testing.allocator);
    try addDocumentSemantics(&ir);
    try pages[0].appendLink(testing.allocator, .uri, "javascript:alert(1)", .{ .x = 0, .y = 0, .width = 10, .height = 10 });
    try testing.expectError(error.InvalidAnnotation, ir.validate());
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

test "render IR validation rejects malformed math catalogs" {
    var pages = try testing.allocator.alloc(render_ir.Page, 1);
    pages[0] = .{ .page_id = 1, .index = 0, .width = 320, .height = 180 };
    var ir = render_ir.Ir{ .pages = pages };
    defer ir.deinit(testing.allocator);
    try addDocumentSemantics(&ir);

    var builder = render_ir.MathBuilder{};
    defer builder.deinit(testing.allocator);
    _ = try builder.add(testing.allocator, "x", .display);
    ir.math = try builder.take(testing.allocator);

    try ir.validate();
    ir.math.trees[0].id = 2;
    try testing.expectError(error.InvalidItemGeometry, ir.validate());
    ir.math.trees[0].id = 1;
    ir.math.trees[0].nodes[0].kind = .fraction;

    try testing.expectError(error.InvalidItemGeometry, ir.validate());
}
