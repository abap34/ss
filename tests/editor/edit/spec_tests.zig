const std = @import("std");
const edit = @import("editor_edit");

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
