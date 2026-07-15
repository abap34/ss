const std = @import("std");
const edit = @import("editor_edit");

test "absolute position preserves regular constraints and appends updates" {
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
        \\~ item.left == page.left + 72
        \\~ item.top == page.top - 96
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
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{
        .{
            .action = .{ .replace = .{ .start = 0, .end = first_end } },
            .target = "item",
            .target_anchor = "center_x",
            .source = "guide",
            .source_anchor = "right",
            .evaluated_offset = 12,
            .delta = 20,
        },
        .{
            .action = .{ .replace = .{ .start = first_end + 1, .end = source.len - 1 } },
            .target = "item",
            .target_anchor = "bottom",
            .source = "page",
            .source_anchor = "bottom",
            .evaluated_offset = 30,
            .delta = -10,
        },
    })).?;
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
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{.{
        .action = .{ .replace = .{ .start = 1, .end = source.len - 1 } },
        .target = "item",
        .target_anchor = "center_x",
        .source = "guide",
        .source_anchor = "right",
        .evaluated_offset = 12,
        .delta = 20,
    }})).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("\t~ item.center_x == guide.right + 32\n", updated);
}

test "relative position accepts spaces around endpoint separators" {
    const allocator = std.testing.allocator;
    const source = "~ item . center_x == guide . right + 12\n";
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{.{
        .action = .{ .replace = .{ .start = 0, .end = source.len - 1 } },
        .target = "item",
        .target_anchor = "center_x",
        .source = "guide",
        .source_anchor = "right",
        .evaluated_offset = 12,
        .delta = 20,
    }})).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("~ item.center_x == guide.right + 32\n", updated);
}

test "relative position matches nested object paths with separator spacing" {
    const allocator = std.testing.allocator;
    const source = "~ parts . root . center_x == guides . primary . right + 12\n";
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{.{
        .action = .{ .replace = .{ .start = 0, .end = source.len - 1 } },
        .target = "parts.root",
        .target_anchor = "center_x",
        .source = "guides.primary",
        .source_anchor = "right",
        .evaluated_offset = 12,
        .delta = 20,
    }})).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("~ parts.root.center_x == guides.primary.right + 32\n", updated);
}

test "relative position rejects whitespace inside an object path segment" {
    const allocator = std.testing.allocator;
    const source = "~ parts root.left == page.left + 12\n";
    try std.testing.expectError(error.InvalidConstraintOrigin, edit.relativePosition(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        &.{.{
            .action = .{ .replace = .{ .start = 0, .end = source.len - 1 } },
            .target = "partsroot",
            .target_anchor = "left",
            .source = "page",
            .source_anchor = "left",
            .evaluated_offset = 12,
            .delta = 20,
        }},
    ));
}

test "relative position preserves the constraint update marker" {
    const allocator = std.testing.allocator;
    const source = "  ~!~item.left == page.left + 12\n";
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{.{
        .action = .{ .replace = .{ .start = 2, .end = source.len - 1 } },
        .target = "item",
        .target_anchor = "left",
        .source = "page",
        .source_anchor = "left",
        .evaluated_offset = 12,
        .delta = 36,
    }})).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("  ~!~ item.left == page.left + 48\n", updated);
}

test "relative position preserves symbolic offsets and line suffixes" {
    const allocator = std.testing.allocator;
    const source =
        \\~ item.center_x == guide.right + horizontal_gap; // horizontal relation
        \\~ item.bottom == guide.top - vertical_gap
        \\
    ;
    const first_end = std.mem.indexOfScalar(u8, source, '\n').?;
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{
        .{
            .action = .{ .replace = .{ .start = 0, .end = first_end } },
            .target = "item",
            .target_anchor = "center_x",
            .source = "guide",
            .source_anchor = "right",
            .evaluated_offset = 20,
            .delta = 35,
        },
        .{
            .action = .{ .replace = .{ .start = first_end + 1, .end = source.len - 1 } },
            .target = "item",
            .target_anchor = "bottom",
            .source = "guide",
            .source_anchor = "top",
            .evaluated_offset = -30,
            .delta = -25,
        },
    })).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings(
        \\~ item.center_x == guide.right + (horizontal_gap) + 35; // horizontal relation
        \\~ item.bottom == guide.top + (-(vertical_gap)) - 25
        \\
    , updated);
}

test "relative position appends caller updates for inherited relations" {
    const allocator = std.testing.allocator;
    const source =
        \\page demo
        \\let item = movable!()
        \\end
        \\
    ;
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{
        .{
            .action = .{ .append_update = null },
            .target = "item",
            .target_anchor = "left",
            .source = "page",
            .source_anchor = "left",
            .evaluated_offset = 72,
            .delta = 28,
        },
        .{
            .action = .{ .append_update = null },
            .target = "item",
            .target_anchor = "top",
            .source = "page",
            .source_anchor = "top",
            .evaluated_offset = -96,
            .delta = -24,
        },
    })).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings(
        \\page demo
        \\let item = movable!()
        \\~!~ item.left == page.left + 100
        \\~!~ item.top == page.top - 120
        \\end
        \\
    , updated);
}

test "relative position preserves a local symbolic relation when appending an update" {
    const allocator = std.testing.allocator;
    const source =
        \\page demo
        \\let item = movable!()
        \\~ item.left == page.left + horizontal_gap
        \\end
        \\
    ;
    const relation_start = std.mem.indexOf(u8, source, "~ item.left").?;
    const relation_end = relation_start + std.mem.indexOfScalar(u8, source[relation_start..], '\n').?;
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{.{
        .action = .{ .append_update = .{ .start = relation_start, .end = relation_end } },
        .target = "item",
        .target_anchor = "left",
        .source = "page",
        .source_anchor = "left",
        .evaluated_offset = 72,
        .delta = 28,
    }})).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings(
        \\page demo
        \\let item = movable!()
        \\~ item.left == page.left + horizontal_gap
        \\~!~ item.left == page.left + (horizontal_gap) + 28
        \\end
        \\
    , updated);
}

test "relative position rejects a stale relation before replacing it" {
    const allocator = std.testing.allocator;
    const source = "~ item.left == page.left + 12\n";
    try std.testing.expectError(error.InvalidConstraintOrigin, edit.relativePosition(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        &.{.{
            .action = .{ .replace = .{ .start = 0, .end = source.len - 1 } },
            .target = "item",
            .target_anchor = "left",
            .source = "guide",
            .source_anchor = "right",
            .evaluated_offset = 12,
            .delta = 20,
        }},
    ));
}

test "relative position rejects a stale local relation before appending an update" {
    const allocator = std.testing.allocator;
    const source =
        \\page demo
        \\let item = movable!()
        \\~ item.left == page.left + 12
        \\end
        \\
    ;
    const relation_start = std.mem.indexOf(u8, source, "~ item.left").?;
    const relation_end = relation_start + std.mem.indexOfScalar(u8, source[relation_start..], '\n').?;
    try std.testing.expectError(error.InvalidConstraintOrigin, edit.relativePosition(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        &.{.{
            .action = .{ .append_update = .{ .start = relation_start, .end = relation_end } },
            .target = "item",
            .target_anchor = "left",
            .source = "guide",
            .source_anchor = "right",
            .evaluated_offset = 12,
            .delta = 20,
        }},
    ));
}

test "relative position does not emit numeric terms that round to zero" {
    const allocator = std.testing.allocator;
    const source = "~ item.left == page.left + horizontal_gap\n";
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{.{
        .action = .{ .replace = .{ .start = 0, .end = source.len - 1 } },
        .target = "item",
        .target_anchor = "left",
        .source = "page",
        .source_anchor = "left",
        .evaluated_offset = 72,
        .delta = 0.001,
    }})).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("~ item.left == page.left + horizontal_gap\n", updated);
}

test "relative position emits positive and negative terms above the rounding threshold" {
    const allocator = std.testing.allocator;
    const source =
        \\~ item.left == page.left + horizontal_gap
        \\~ item.top == page.top + vertical_gap
        \\
    ;
    const first_end = std.mem.indexOfScalar(u8, source, '\n').?;
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{
        .{
            .action = .{ .replace = .{ .start = 0, .end = first_end } },
            .target = "item",
            .target_anchor = "left",
            .source = "page",
            .source_anchor = "left",
            .evaluated_offset = 72,
            .delta = 0.006,
        },
        .{
            .action = .{ .replace = .{ .start = first_end + 1, .end = source.len - 1 } },
            .target = "item",
            .target_anchor = "top",
            .source = "page",
            .source_anchor = "top",
            .evaluated_offset = -96,
            .delta = -0.006,
        },
    })).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings(
        \\~ item.left == page.left + (horizontal_gap) + 0.01
        \\~ item.top == page.top + (vertical_gap) - 0.01
        \\
    , updated);
}

test "absolute position updates existing override without removing regular constraints" {
    const allocator = std.testing.allocator;
    const source =
        \\page demo
        \\let item = text!("Move me")
        \\~ item.left == page.left + horizontal_gap
        \\~ item.top == page.top - 96
        \\~!~ item.right == page.right - 40; // previous editor position
        \\end
        \\
    ;
    const update_start = std.mem.indexOf(u8, source, "~!~ item.right").?;
    const update_end = update_start + std.mem.indexOfScalar(u8, source[update_start..], '\n').?;
    var result = (try edit.absolutePosition(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        "item",
        120,
        140,
        &.{.{ .start = update_start, .end = update_end }},
        null,
    )).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings(
        \\page demo
        \\let item = text!("Move me")
        \\~ item.left == page.left + horizontal_gap
        \\~ item.top == page.top - 96
        \\~!~ item.left == page.left + 120; // previous editor position
        \\~!~ item.top == page.top - 140
        \\end
        \\
    , updated);
}

test "absolute position processes a repeated update location once" {
    const allocator = std.testing.allocator;
    const source =
        \\page demo
        \\let item = text!("Move me")
        \\~!~ item.left == page.left + 40
        \\end
        \\
    ;
    const update_start = std.mem.indexOf(u8, source, "~!~ item.left").?;
    const update_end = update_start + std.mem.indexOfScalar(u8, source[update_start..], '\n').?;
    const update_span = edit.ByteSpan{ .start = update_start, .end = update_end };
    var result = (try edit.absolutePosition(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        "item",
        120,
        140,
        &.{ update_span, update_span },
        null,
    )).?;
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.edits.len);
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
