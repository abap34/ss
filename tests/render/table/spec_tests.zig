const std = @import("std");
const core = @import("core");
const table_layout = @import("table_layout");
const render_text = @import("render_text");
const testing = std.testing;

fn paint() core.render_policy.TextPaint {
    var result = std.mem.zeroes(core.render_policy.TextPaint);
    result.font = .{ .family = "DejaVu Serif", .weight = 400, .style = .italic, .stretch = .normal };
    result.bold_font = result.font;
    result.bold_font.weight = 700;
    result.italic_font = result.font;
    result.code_font = result.font;
    result.font_size = 24;
    result.line_height = 20;
    result.markdown_underline = .{ .offset = 15, .width = 4 };
    result.markdown_table_cell_pad_x = 5;
    result.markdown_table_cell_pad_y = 7;
    result.markdown_table_border = .{ .r = 0, .g = 0, .b = 0 };
    result.markdown_table_line_width = 2;
    return result;
}

test "table rows contain wrapped cell ink and decoration overhangs" {
    var document = try core.markdown.parseMarkdownContent(
        testing.allocator,
        "| Left | Center | Right |\n| :--- | :---: | ---: |\n| _j_ | Several words wrap inside this cell | |\n| last | end | value |",
    );
    defer document.deinit();
    var layout = try table_layout.prepare(.{ .assets = .{ .allocator = testing.allocator, .io = testing.io, .asset_base_dir = ".", .cache_dir = ".ss-cache/test-table-layout" } }, document.blocks.items[0].table.?, paint(), 302);
    defer layout.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), layout.columns);
    try testing.expectEqual(@as(f32, 100), layout.column_width);
    try testing.expectEqual(.center, layout.rows[1].cells[1].alignment);
    try testing.expectEqual(.right, layout.rows[1].cells[2].alignment);
    try testing.expect(layout.rows[1].cells[1].content.height > 20);
    var bottom: f32 = 0;
    for (layout.rows) |row| {
        try testing.expectEqual(bottom, row.top);
        for (row.cells) |cell| if (cell.content.ink_bounds) |ink| {
            try testing.expect(row.content_top + ink.y >= row.top + 7 - 0.001);
            try testing.expect(row.content_top + ink.y + ink.height <= row.top + row.height - 7 + 0.001);
        };
        bottom += row.height;
    }
    try testing.expectEqual(layout.height, bottom);
    try testing.expect(layout.rows[1].cells[0].content.ink_bounds.?.y + layout.rows[1].cells[0].content.ink_bounds.?.height > 20);
}

test "table layouts retain shared native paragraphs after cache teardown" {
    var document = try core.markdown.parseMarkdownContent(testing.allocator, "| same | same |\n| --- | --- |\n| more | more |");
    defer document.deinit();
    var layout = blk: {
        var cache = render_text.Cache.init(testing.allocator, testing.io);
        defer cache.deinit();
        cache.paragraphs.max_entries = 1;
        break :blk try table_layout.prepare(.{ .assets = .{ .allocator = testing.allocator, .io = testing.io, .asset_base_dir = ".", .cache_dir = ".ss-cache/test-table-layout" }, .text_cache = &cache }, document.blocks.items[0].table.?, paint(), 302);
    };
    defer layout.deinit(testing.allocator);
    for (layout.rows) |row| {
        const first = row.cells[0].content.segments[0].content.paragraph.prepared.layout;
        const second = row.cells[1].content.segments[0].content.paragraph.prepared.layout;
        try testing.expect(first == second);
        try testing.expect(first.native.glyph_count > 0);
        try testing.expect(first.source.len > 0);
    }
}

test "table preparation releases partially prepared rows through allocation failures" {
    var document = try core.markdown.parseMarkdownContent(testing.allocator, "| a | b |\n| --- | --- |\n| _j_ | **text** |");
    defer document.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, prepareTable, .{document.blocks.items[0].table.?});
}

fn prepareTable(allocator: std.mem.Allocator, table: core.markdown.TableData) !void {
    var layout = try table_layout.prepare(.{ .assets = .{ .allocator = allocator, .io = testing.io, .asset_base_dir = ".", .cache_dir = ".ss-cache/test-table-layout" } }, table, paint(), 302);
    defer layout.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), layout.rows.len);
}

const CancellationProbe = struct {
    var checks: usize = 0;
    var cancel_at: usize = std.math.maxInt(usize);

    fn check(_: ?*anyopaque) error{Canceled}!void {
        checks += 1;
        if (checks == cancel_at) return error.Canceled;
    }
};

test "table preparation releases retained cells at each cancellation boundary" {
    var document = try core.markdown.parseMarkdownContent(testing.allocator, "| a | b |\n| --- | --- |\n| first | second |\n| third | fourth |");
    defer document.deinit();
    var vtable = testing.io.vtable.*;
    vtable.checkCancel = CancellationProbe.check;
    const io = std.Io{ .userdata = testing.io.userdata, .vtable = &vtable };
    const ctx: table_layout.Context = .{ .assets = .{ .allocator = testing.allocator, .io = io, .asset_base_dir = ".", .cache_dir = ".ss-cache/test-table-layout" } };
    CancellationProbe.checks = 0;
    CancellationProbe.cancel_at = std.math.maxInt(usize);
    var complete = try table_layout.prepare(ctx, document.blocks.items[0].table.?, paint(), 302);
    complete.deinit(testing.allocator);
    const boundaries = CancellationProbe.checks;
    try testing.expect(boundaries > document.blocks.items[0].table.?.rows.items.len);
    for (1..boundaries + 1) |boundary| {
        CancellationProbe.checks = 0;
        CancellationProbe.cancel_at = boundary;
        try testing.expectError(error.Canceled, table_layout.prepare(ctx, document.blocks.items[0].table.?, paint(), 302));
        try testing.expectEqual(boundary, CancellationProbe.checks);
    }
}
