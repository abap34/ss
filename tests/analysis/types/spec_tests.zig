const std = @import("std");
const analysis_types = @import("analysis").types;
const Type = @import("language_type").Type;

const testing = std.testing;

test "analysis type spec: hole type blocks assignability without becoming any" {
    const hole_info = analysis_types.infoFromHole(7);

    switch (analysis_types.assignability(hole_info, Type.string)) {
        .blocked_by_hole => |id| try testing.expectEqual(@as(u32, 7), id),
        else => return error.ExpectedBlockedByHole,
    }

    const label = try analysis_types.typeInfoLabelAlloc(testing.allocator, hole_info);
    defer testing.allocator.free(label);
    try testing.expectEqualStrings("HoleType", label);

    try analysis_types.ensureType(null, testing.allocator, hole_info, Type.string, .{});
}

test "analysis type spec: syntax type holes are not accepted as any" {
    const annotation = Type.hole(3);
    try testing.expect(!Type.accepts(Type.string, annotation));
    try testing.expect(!Type.accepts(annotation, Type.string));

    switch (analysis_types.assignability(analysis_types.infoFromType(Type.number), annotation)) {
        .blocked_by_hole => |id| try testing.expectEqual(@as(u32, 3), id),
        else => return error.ExpectedBlockedByHole,
    }

    switch (analysis_types.assignability(analysis_types.infoFromType(annotation), Type.string)) {
        .blocked_by_hole => |id| try testing.expectEqual(@as(u32, 3), id),
        else => return error.ExpectedBlockedByHole,
    }
}

test "analysis type spec: known type mismatch remains a mismatch" {
    const number_info = analysis_types.infoFromType(Type.number);

    try testing.expectEqual(analysis_types.Assignability.mismatch, analysis_types.assignability(number_info, Type.string));
    try testing.expectError(
        error.InvalidType,
        analysis_types.ensureType(null, testing.allocator, number_info, Type.string, .{}),
    );
}

test "analysis type spec: holes nested in type arguments block assignment" {
    const incomplete = Type.selectionType(Type.selectionType(Type.hole(9)));
    const complete = Type.selectionType(Type.selection(.placement));
    switch (analysis_types.assignability(.{ .ty = incomplete }, complete)) {
        .blocked_by_hole => |id| try testing.expectEqual(@as(u32, 9), id),
        else => return error.ExpectedBlockedByHole,
    }
    switch (analysis_types.assignability(.{ .ty = complete }, incomplete)) {
        .blocked_by_hole => |id| try testing.expectEqual(@as(u32, 9), id),
        else => return error.ExpectedBlockedByHole,
    }
}
