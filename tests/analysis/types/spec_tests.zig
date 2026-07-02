const std = @import("std");
const core = @import("core");
const analysis_types = @import("analysis").types;
const syntax_hole = @import("analysis").syntax_hole;
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

    try analysis_types.ensureType(null, testing.allocator, hole_info, Type.string, "", .UnmatchedArgumentType);
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

test "analysis type spec: blocked hole records expected type when a table is provided" {
    var holes = syntax_hole.Result{
        .holes = try testing.allocator.alloc(syntax_hole.Hole, 1),
        .diagnostics = try testing.allocator.alloc(syntax_hole.Diagnostic, 0),
    };
    holes.holes[0] = .{
        .id = 0,
        .kind = .expr,
        .span = .{ .start = 0, .end = 0 },
        .expected = .expression,
    };
    defer holes.deinit(testing.allocator);

    const hole_info = analysis_types.infoFromHole(0);
    try analysis_types.ensureTypeWithHoles(null, testing.allocator, hole_info, Type.color, "", .UnmatchedArgumentType, &holes);
    try testing.expect(holes.holes[0].expected_type != null);
    try testing.expectEqual(Type.Kind.color, holes.holes[0].expected_type.?.kind);
}

test "analysis type spec: known type mismatch remains a mismatch" {
    const number_info = analysis_types.infoFromType(Type.number);

    try testing.expectEqual(analysis_types.Assignability.mismatch, analysis_types.assignability(number_info, Type.string));
    try testing.expectError(
        error.InvalidType,
        analysis_types.ensureType(null, testing.allocator, number_info, Type.string, "", core.TypeMismatchCode.UnmatchedArgumentType),
    );
}
