const std = @import("std");
const edit = @import("editor_edit");
const shape = edit.shape;
const icon = edit.icon;

fn relationSource(source: []const u8, target: []const u8, source_endpoint: []const u8, offset: ?[]const u8) edit.RelationSource {
    const target_start = std.mem.indexOf(u8, source, target).?;
    const source_start = std.mem.indexOfPos(u8, source, target_start + target.len, source_endpoint).?;
    return .{
        .target = .{ .start = target_start, .end = target_start + target.len },
        .source = .{ .start = source_start, .end = source_start + source_endpoint.len },
        .offset = if (offset) |text| blk: {
            const offset_start = std.mem.indexOfPos(u8, source, source_start + source_endpoint.len, text).?;
            break :blk .{ .start = offset_start, .end = offset_start + text.len };
        } else null,
    };
}

fn existingUpdate(source: []const u8, target: []const u8, source_endpoint: []const u8, offset: ?[]const u8, horizontal: bool) edit.ExistingUpdate {
    return .{ .source = relationSource(source, target, source_endpoint, offset), .horizontal = horizontal };
}

fn numericTokenAfter(source: []const u8, marker: []const u8) edit.ByteSpan {
    const start = std.mem.indexOf(u8, source, marker).? + marker.len;
    var end = start;
    while (end < source.len and (std.ascii.isDigit(source[end]) or source[end] == '.' or source[end] == '-')) end += 1;
    return .{ .start = start, .end = end };
}

fn readFixture(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const full_path = try std.fs.path.join(allocator, &.{ "tests/fixtures/editor/edit", path });
    defer allocator.free(full_path);
    return try std.Io.Dir.cwd().readFileAlloc(std.testing.io, full_path, allocator, .limited(64 * 1024));
}

fn expectFixtureOutput(allocator: std.mem.Allocator, path: []const u8, actual: []const u8) !void {
    const expected_path = try std.fs.path.join(allocator, &.{ "expected", path });
    defer allocator.free(expected_path);
    const expected = try readFixture(allocator, expected_path);
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, actual);
}

test "shape insertion emits a canonical rectangle source block" {
    const allocator = std.testing.allocator;
    const source =
        \\page Example
        \\end
        \\
    ;
    var result = (try shape.insert(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        null,
        "rectangle_item",
        .{ .rectangle = .{
            .bounds = .{ .x = 24, .y = 36, .width = 160, .height = 100 },
            .fill = .{ .enabled = true, .color = "#e8f1ff", .opacity = 0.8 },
            .stroke = .{ .enabled = true, .color = "#2563eb", .width = 1.6, .style = .solid },
        } },
    )).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings(
        \\page Example
        \\  let rectangle_item = rectangle!(160, 100, VectorStyle { fill = solid_fill(c"#e8f1ff", 0.8) stroke = solid_stroke(c"#2563eb", 1.6) })
        \\  ~!~ rectangle_item.left == page.left + 24
        \\  ~!~ rectangle_item.top == page.top - 36
        \\end
        \\
    , updated);
}

test "icon insertion emits a canonical object and absolute placement" {
    const allocator = std.testing.allocator;
    const source =
        \\page Example
        \\end
        \\
    ;
    var result = (try icon.insert(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        null,
        "star_icon",
        "fa-solid:star",
        .{ .x = 24, .y = 36, .width = 72, .height = 80 },
        "#2563eb",
    )).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings(
        \\page Example
        \\  let star_icon = icon!("fa-solid:star", 72, 80, c"#2563eb")
        \\  ~!~ star_icon.left == page.left + 24
        \\  ~!~ star_icon.top == page.top - 36
        \\end
        \\
    , updated);
}

test "shape insertion preserves circle dimensions and disabled paint" {
    const allocator = std.testing.allocator;
    const source =
        \\page Empty
        \\end
        \\
    ;
    var result = (try shape.insert(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        null,
        "circle_item",
        .{ .circle = .{
            .bounds = .{ .x = 0, .y = 0, .width = 80, .height = 80 },
            .fill = .{ .enabled = false, .color = "#ffffff", .opacity = 1 },
            .stroke = .{ .enabled = false, .color = "#000000", .width = 2, .style = .dotted },
        } },
    )).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "circle!(80, VectorStyle") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "fill = no_fill()") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "stroke = no_stroke()") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "page.left + 0") == null);
}

test "shape insertion precedes the first existing constraint" {
    const allocator = std.testing.allocator;
    const source =
        \\page Ordered
        \\  let existing_item = rectangle!(20, 20)
        \\  ~ existing_item.left == page.left + 10
        \\end
        \\
    ;
    const constraint_start = std.mem.indexOf(u8, source, "~ existing_item").?;
    var result = (try shape.insert(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        constraint_start,
        "arrow_shape_item",
        .{ .arrow = .{
            .bounds = .{ .x = 30, .y = 40, .width = 170, .height = 90 },
            .fill = .{ .enabled = true, .color = "#fef3c7", .opacity = 1 },
            .stroke = .{ .enabled = true, .color = "#92400e", .width = 1.5, .style = .dashed },
        } },
    )).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    const inserted_start = std.mem.indexOf(u8, updated, "let arrow_shape_item").?;
    const existing_constraint = std.mem.indexOf(u8, updated, "~ existing_item").?;
    try std.testing.expect(inserted_start < existing_constraint);
    try std.testing.expect(std.mem.indexOf(u8, updated, "dashed_stroke(c\"#92400e\", 1.5)") != null);
}

test "line insertion emits local endpoints without a fill" {
    const allocator = std.testing.allocator;
    const source =
        \\page Lines
        \\end
        \\
    ;
    var result = (try shape.insert(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        null,
        "line_item",
        .{ .line = .{
            .bounds = .{ .x = 24, .y = 36, .width = 160, .height = 80 },
            .start = .{ .x = 0, .y = 1 },
            .end = .{ .x = 1, .y = 0 },
            .stroke = .{ .enabled = true, .color = "#2563eb", .width = 2, .style = .dash_dot },
        } },
    )).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings(
        \\page Lines
        \\  let line_item = line!(160, 80, LineStyle { start_x = 0 start_y = 1 end_x = 1 end_y = 0 stroke = dash_dot_stroke(c"#2563eb", 2) })
        \\  ~!~ line_item.left == page.left + 24
        \\  ~!~ line_item.top == page.top - 36
        \\end
        \\
    , updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "fill") == null);
}

test "line geometry edits preserve endpoint order in canonical source" {
    const allocator = std.testing.allocator;
    const source =
        \\page Lines
        \\  let line_item = line!(160, 1, LineStyle { start_x = 0 start_y = 0.5 end_x = 1 end_y = 0.5 stroke = solid_stroke(c"#2563eb", 2) })
        \\  ~!~ line_item.left == page.left + 40
        \\  ~!~ line_item.top == page.top - 49.5
        \\end
        \\
    ;
    const geometry = shape.normalizeLine(
        .{ .x = 250, .y = 80 },
        .{ .x = 70, .y = 80 },
        1280,
        720,
    ).?;
    try std.testing.expectEqual(@as(f64, 70), geometry.bounds.x);
    try std.testing.expectEqual(@as(f64, 79.5), geometry.bounds.y);
    try std.testing.expectEqual(@as(f64, 1), geometry.start.x);
    try std.testing.expectEqual(@as(f64, 0), geometry.end.x);

    var result = try shape.lineGeometryEdits(allocator, .{
        .width = numericTokenAfter(source, "line!("),
        .height = numericTokenAfter(source, "line!(160, "),
        .start_x = numericTokenAfter(source, "start_x = "),
        .start_y = numericTokenAfter(source, "start_y = "),
        .end_x = numericTokenAfter(source, "end_x = "),
        .end_y = numericTokenAfter(source, "end_y = "),
    }, geometry);
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(
        u8,
        updated,
        "line!(180, 1, LineStyle { start_x = 1 start_y = 0.5 end_x = 0 end_y = 0.5",
    ) != null);
}

test "shape style expressions replace only canonical paint values" {
    const allocator = std.testing.allocator;
    const fill = try shape.fillExpression(allocator, .{
        .enabled = true,
        .color = "#123456",
        .opacity = 0.45,
    });
    defer allocator.free(fill);
    const stroke = try shape.strokeExpression(allocator, .{
        .enabled = false,
        .color = "#abcdef",
        .width = 3,
        .style = .solid,
    });
    defer allocator.free(stroke);
    try std.testing.expectEqualStrings("solid_fill(c\"#123456\", 0.45)", fill);
    try std.testing.expectEqualStrings("no_stroke()", stroke);

    const dotted = try shape.strokeExpression(allocator, .{
        .enabled = true,
        .color = "#abcdef",
        .width = 3,
        .style = .dotted,
    });
    defer allocator.free(dotted);
    try std.testing.expectEqualStrings("dotted_stroke(c\"#abcdef\", 3)", dotted);
}

test "absolute position preserves regular constraints and appends updates" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "absolute/page.ss");
    defer allocator.free(source);
    var result = (try edit.absolutePosition(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        "item",
        120,
        140,
        &.{},
        null,
    )).?;
    defer result.deinit(allocator);

    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try expectFixtureOutput(allocator, "absolute/page.ss", updated);
}

test "relative position keeps relation anchors and changes offsets" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "relative/numeric.ss");
    defer allocator.free(source);
    const first_end = std.mem.indexOfScalar(u8, source, '\n').?;
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{
        .{
            .action = .{ .replace = relationSource(source[0..first_end], "item.center_x", "guide.right", "+ 12") },
            .target = "item",
            .target_anchor = "center_x",
            .source = "guide",
            .source_anchor = "right",
            .evaluated_offset = 12,
            .delta = 20,
        },
        .{
            .action = .{ .replace = relationSource(source, "item.bottom", "page.bottom", "+ 30") },
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
    try expectFixtureOutput(allocator, "relative/numeric.ss", updated);
}

test "relative position accepts compact constraint spacing" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "relative/compact.ss");
    defer allocator.free(source);
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{.{
        .action = .{ .replace = relationSource(source, "item.center_x", "guide.right", "+12") },
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
    try expectFixtureOutput(allocator, "relative/compact.ss", updated);
}

test "relative position accepts spaces around endpoint separators" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "relative/spaced.ss");
    defer allocator.free(source);
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{.{
        .action = .{ .replace = relationSource(source, "item . center_x", "guide . right", "+ 12") },
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
    try expectFixtureOutput(allocator, "relative/spaced.ss", updated);
}

test "relative position matches nested object paths with separator spacing" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "relative/nested.ss");
    defer allocator.free(source);
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{.{
        .action = .{ .replace = relationSource(source, "parts . root . center_x", "guides . primary . right", "+ 12") },
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
    try expectFixtureOutput(allocator, "relative/nested.ss", updated);
}

test "relative position rejects an invalid compiler source span" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "relative/invalid.ss");
    defer allocator.free(source);
    try std.testing.expectError(error.InvalidConstraintOrigin, edit.relativePosition(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        &.{.{
            .action = .{ .replace = .{
                .target = .{ .start = 2, .end = 17 },
                .source = .{ .start = 21, .end = 30 },
                .offset = .{ .start = source.len, .end = source.len + 1 },
            } },
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
    const source = try readFixture(allocator, "relative/update.ss");
    defer allocator.free(source);
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{.{
        .action = .{ .replace = relationSource(source, "item.left", "page.left", "+ 12") },
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
    try expectFixtureOutput(allocator, "relative/update.ss", updated);
}

test "relative position preserves symbolic offsets and line suffixes" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "relative/symbolic.ss");
    defer allocator.free(source);
    const first_end = std.mem.indexOfScalar(u8, source, '\n').?;
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{
        .{
            .action = .{ .replace = relationSource(source[0..first_end], "item.center_x", "guide.right", "+ horizontal_gap") },
            .target = "item",
            .target_anchor = "center_x",
            .source = "guide",
            .source_anchor = "right",
            .evaluated_offset = 20,
            .delta = 35,
        },
        .{
            .action = .{ .replace = relationSource(source, "item.bottom", "guide.top", "- vertical_gap") },
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
    try expectFixtureOutput(allocator, "relative/symbolic.ss", updated);
}

test "relative position appends caller updates for inherited relations" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "relative/inherited.ss");
    defer allocator.free(source);
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
    try expectFixtureOutput(allocator, "relative/inherited.ss", updated);
}

test "relative position preserves a local symbolic relation when appending an update" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "relative/local.ss");
    defer allocator.free(source);
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{.{
        .action = .{ .append_update = relationSource(source, "item.left", "page.left", "+ horizontal_gap") },
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
    try expectFixtureOutput(allocator, "relative/local.ss", updated);
}

test "relative position rejects a stale offset span before replacing it" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "relative/numeric-single.ss");
    defer allocator.free(source);
    try std.testing.expectError(error.InvalidConstraintOrigin, edit.relativePosition(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        &.{.{
            .action = .{ .replace = .{
                .target = .{ .start = 2, .end = 11 },
                .source = .{ .start = 15, .end = 24 },
                .offset = .{ .start = source.len + 1, .end = source.len + 3 },
            } },
            .target = "item",
            .target_anchor = "left",
            .source = "guide",
            .source_anchor = "right",
            .evaluated_offset = 12,
            .delta = 20,
        }},
    ));
}

test "relative position rejects a stale local offset before appending an update" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "relative/local-numeric.ss");
    defer allocator.free(source);
    const relation_start = std.mem.indexOf(u8, source, "~ item.left").?;
    const relation_end = relation_start + std.mem.indexOfScalar(u8, source[relation_start..], '\n').?;
    try std.testing.expectError(error.InvalidConstraintOrigin, edit.relativePosition(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        &.{.{
            .action = .{ .append_update = .{
                .target = .{ .start = relation_start + 2, .end = relation_start + 11 },
                .source = .{ .start = relation_start + 15, .end = relation_start + 24 },
                .offset = .{ .start = relation_end + 1, .end = relation_end + 3 },
            } },
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
    const source = try readFixture(allocator, "relative/symbolic-single.ss");
    defer allocator.free(source);
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{.{
        .action = .{ .replace = relationSource(source, "item.left", "page.left", "+ horizontal_gap") },
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
    try expectFixtureOutput(allocator, "relative/symbolic-single.ss", updated);
}

test "relative position emits positive and negative terms above the rounding threshold" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "relative/threshold.ss");
    defer allocator.free(source);
    const first_end = std.mem.indexOfScalar(u8, source, '\n').?;
    var result = (try edit.relativePosition(allocator, source, .{ .start = 0, .end = source.len }, &.{
        .{
            .action = .{ .replace = relationSource(source[0..first_end], "item.left", "page.left", "+ horizontal_gap") },
            .target = "item",
            .target_anchor = "left",
            .source = "page",
            .source_anchor = "left",
            .evaluated_offset = 72,
            .delta = 0.006,
        },
        .{
            .action = .{ .replace = relationSource(source, "item.top", "page.top", "+ vertical_gap") },
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
    try expectFixtureOutput(allocator, "relative/threshold.ss", updated);
}

test "absolute position updates existing override without removing regular constraints" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "absolute/update.ss");
    defer allocator.free(source);
    var result = (try edit.absolutePosition(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        "item",
        120,
        140,
        &.{existingUpdate(source, "item.right", "page.right", "- 40", true)},
        null,
    )).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try expectFixtureOutput(allocator, "absolute/update.ss", updated);
}

test "absolute position preserves multiline trivia around an existing update" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "absolute/multiline.ss");
    defer allocator.free(source);
    var result = (try edit.absolutePosition(
        allocator,
        source,
        .{ .start = 0, .end = source.len },
        "item",
        120,
        140,
        &.{existingUpdate(source, "item.left", "page.left", "+ 40", true)},
        null,
    )).?;
    defer result.deinit(allocator);
    const updated = try edit.applyEdits(allocator, source, result.edits);
    defer allocator.free(updated);
    try expectFixtureOutput(allocator, "absolute/multiline.ss", updated);
}

test "absolute position binds an unbound component call" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "binding/quoted.ss");
    defer allocator.free(source);
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
    try expectFixtureOutput(allocator, "binding/quoted.ss", updated);
}

test "absolute position converts line text before binding it" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, "binding/line.ss");
    defer allocator.free(source);
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
    try expectFixtureOutput(allocator, "binding/line.ss", updated);
}
