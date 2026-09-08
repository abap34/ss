const std = @import("std");
const generated = @import("editor_edit").generated;
const testing = std.testing;

fn replacement(start: usize, end: usize) generated.Replacement {
    return .{
        .index = 0,
        .expected = .{ .target_node = 2, .target_anchor = .left, .source = .{ .page = .left }, .offset = 10, .origin = "generated origin" },
        .offset_span = .{ .start = start, .end = end },
        .literal_scale = 1,
        .new_offset = 20,
    };
}

fn editWith(replacements: []const generated.Replacement) generated.Edit {
    return .{
        .path = "example.ss",
        .base_source = "x=10; y=30;",
        .source = "x=20; y=40;",
        .base_generation = 3,
        .base_snapshot_id = "snapshot-3",
        .node_id = 2,
        .page_id = 1,
        .mode = .absolute,
        .replacements = replacements,
    };
}

test "generated edits reject changes outside distinct fixed-width numeric spans" {
    var edits = editWith(&.{ replacement(2, 4), replacement(8, 10) });
    try testing.expect(edits.onlyChangesOffsets());
    edits.replacements = &.{ replacement(8, 10), replacement(2, 4) };
    try testing.expect(edits.onlyChangesOffsets());
    for ([_][]const generated.Replacement{
        &.{replacement(2, 4)},
        &.{ replacement(2, 4), replacement(2, 4) },
        &.{ replacement(2, 9), replacement(8, 10) },
        &.{ replacement(2, 2), replacement(8, 10) },
        &.{ replacement(2, 4), replacement(8, 12) },
        &.{ replacement(2, 4), replacement(12, 14) },
    }) |invalid| {
        edits.replacements = invalid;
        try testing.expect(!edits.onlyChangesOffsets());
    }
    edits = editWith(&.{ replacement(2, 4), replacement(8, 10) });
    edits.source = "z=20; y=40;";
    try testing.expect(!edits.onlyChangesOffsets());
    edits.source = "x=10; y=40;";
    try testing.expect(!edits.onlyChangesOffsets());
    edits.source = "x=2\n; y=40;";
    try testing.expect(!edits.onlyChangesOffsets());
    edits.source = "x=200; y=40;";
    try testing.expect(!edits.onlyChangesOffsets());
}

fn cloneAndRelease(allocator: std.mem.Allocator) !void {
    const edits = editWith(&.{ replacement(2, 4), replacement(8, 10) });
    var cloned = try edits.clone(allocator);
    defer cloned.deinit(allocator);
    try testing.expect(cloned.onlyChangesOffsets());
    try testing.expectEqualStrings(edits.path, cloned.path);
    try testing.expectEqualStrings(edits.base_source, cloned.base_source);
    try testing.expectEqualStrings(edits.source, cloned.source);
    try testing.expectEqualStrings(edits.base_snapshot_id, cloned.base_snapshot_id);
    try testing.expect(cloned.path.ptr != edits.path.ptr);
    try testing.expect(cloned.base_source.ptr != edits.base_source.ptr);
    try testing.expect(cloned.source.ptr != edits.source.ptr);
    try testing.expect(cloned.base_snapshot_id.ptr != edits.base_snapshot_id.ptr);
    try testing.expect(cloned.replacements.ptr != edits.replacements.ptr);
    for (cloned.replacements, edits.replacements) |owned, borrowed| {
        try testing.expectEqualStrings(borrowed.expected.origin.?, owned.expected.origin.?);
        try testing.expect(borrowed.expected.origin.?.ptr != owned.expected.origin.?.ptr);
    }
}

test "generated edit copies retain all borrowed inputs and release partial allocations" {
    try cloneAndRelease(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, cloneAndRelease, .{});
}
