const std = @import("std");
const render_ir = @import("render");

const testing = std.testing;

test "render IR page owns placed text and resource paths" {
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
    var path = [_]u8{ 'i', 'c', 'o', 'n', '.', 's', 'v', 'g' };
    try page.appendSvg(
        testing.allocator,
        42,
        .{ .x = 20, .y = 40, .width = 16, .height = 16 },
        &path,
        .{ .r = 1, .g = 0, .b = 0 },
    );

    text[0] = 'X';
    family[0] = 'X';
    path[0] = 'X';

    try testing.expectEqualStrings("item", page.items.items[0].text.text);
    try testing.expectEqualStrings("Sans", page.items.items[0].text.font_family);
    try testing.expectEqualStrings("icon.svg", page.items.items[1].svg.path);
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
        "/tmp/source.pdf",
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
