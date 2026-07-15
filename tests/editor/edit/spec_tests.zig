const std = @import("std");
const edit = @import("editor_edit");

test "absolute position replaces page constraints and inserts top-left anchors" {
    const allocator = std.testing.allocator;
    const source =
        \\page demo
        \\let item = text!("Move me")
        \\~ item.left == page.left + 72
        \\~ item.top == page.top - 96
        \\end
        \\
    ;
    const left_start = std.mem.indexOf(u8, source, "~ item.left").?;
    const left_end = left_start + std.mem.indexOfScalar(u8, source[left_start..], '\n').?;
    const top_start = std.mem.indexOf(u8, source, "~ item.top").?;
    const top_end = top_start + std.mem.indexOfScalar(u8, source[top_start..], '\n').?;
    var result = (try edit.absolutePosition(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        "item",
        120,
        140,
        &.{
            .{ .start = left_start, .end = left_end },
            .{ .start = top_start, .end = top_end },
        },
        null,
    )).?;
    defer result.deinit(allocator);

    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings(
        \\page demo
        \\let item = text!("Move me")
        \\~!~ item.left == page.left + 120
        \\~!~ item.top == page.top - 140
        \\end
        \\
    , updated);
}

test "relative position keeps relation anchors and changes offsets" {
    const allocator = std.testing.allocator;
    const source =
        \\~ item.center_x == guide.right + 12
        \\~ item.bottom == page.bottom + 30
        \\
    ;
    const first_end = std.mem.indexOfScalar(u8, source, '\n').?;
    var result = try edit.preserveRelations(allocator, source, &.{
        .{
            .span = .{ .start = 0, .end = first_end },
            .target = "item",
            .target_anchor = "center_x",
            .source = "guide",
            .source_anchor = "right",
            .offset = 32,
        },
        .{
            .span = .{ .start = first_end + 1, .end = source.len - 1 },
            .target = "item",
            .target_anchor = "bottom",
            .source = "page",
            .source_anchor = "bottom",
            .offset = 20,
        },
    });
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings(
        \\~ item.center_x == guide.right + 32
        \\~ item.bottom == page.bottom + 20
        \\
    , updated);
}

test "relative position accepts compact constraint spacing" {
    const allocator = std.testing.allocator;
    const source = "\t~\titem.center_x==guide.right+12\n";
    var result = try edit.preserveRelations(allocator, source, &.{.{
        .span = .{ .start = 1, .end = source.len - 1 },
        .target = "item",
        .target_anchor = "center_x",
        .source = "guide",
        .source_anchor = "right",
        .offset = 32,
    }});
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("\t~ item.center_x == guide.right + 32\n", updated);
}

test "relative position preserves the constraint update marker" {
    const allocator = std.testing.allocator;
    const source = "  ~!~item.left == page.left + 12\n";
    var result = try edit.preserveRelations(allocator, source, &.{.{
        .span = .{ .start = 2, .end = source.len - 1 },
        .target = "item",
        .target_anchor = "left",
        .source = "page",
        .source_anchor = "left",
        .offset = 48,
    }});
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("  ~!~ item.left == page.left + 48\n", updated);
}

test "absolute position binds an unbound component call" {
    const allocator = std.testing.allocator;
    const source =
        \\page demo
        \\head! "Move me"
        \\end
        \\
    ;
    const statement_start = std.mem.indexOf(u8, source, "head!").?;
    const statement_end = statement_start + std.mem.indexOfScalar(u8, source[statement_start..], '\n').?;
    var result = (try edit.absolutePosition(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        "head_item",
        120,
        140,
        &.{},
        .{ .statement = .{ .start = statement_start, .end = statement_end } },
    )).?;
    defer result.deinit(allocator);

    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings(
        \\page demo
        \\let head_item = head! "Move me"
        \\~!~ head_item.left == page.left + 120
        \\~!~ head_item.top == page.top - 140
        \\end
        \\
    , updated);
}

test "absolute position converts line text before binding it" {
    const allocator = std.testing.allocator;
    const source =
        \\page demo
        \\  head! Move me
        \\end
        \\
    ;
    const statement_start = std.mem.indexOf(u8, source, "head!").?;
    const statement_end = statement_start + std.mem.indexOfScalar(u8, source[statement_start..], '\n').?;
    var result = (try edit.absolutePosition(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        "head_item",
        120,
        140,
        &.{},
        .{ .statement = .{ .start = statement_start, .end = statement_end } },
    )).?;
    defer result.deinit(allocator);

    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings(
        \\page demo
        \\  let head_item = head! <<
        \\  Move me
        \\  >>
        \\  ~!~ head_item.left == page.left + 120
        \\  ~!~ head_item.top == page.top - 140
        \\end
        \\
    , updated);
}
