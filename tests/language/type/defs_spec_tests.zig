const std = @import("std");
const type_defs = @import("type_defs");

const testing = std.testing;

const Case = struct {
    name: []const u8,
};

test "type defs spec: enum lookup matches complete case names" {
    const cases = [_]Case{ .{ .name = "left" }, .{ .name = "center" }, .{ .name = "right" } };
    const mixed = [_]Case{ .{ .name = "Left" }, .{ .name = "Center" }, .{ .name = "RIGHT" } };
    try testing.expect(type_defs.enumCasesContain(&cases, "left"));
    try testing.expect(type_defs.enumCasesContain(&cases, "right"));
    try testing.expect(type_defs.enumCasesContain(&mixed, "Left"));
    try testing.expect(type_defs.enumCasesContain(&mixed, "RIGHT"));
    try testing.expect(!type_defs.enumCasesContain(&cases, "lef"));
    try testing.expect(!type_defs.enumCasesContain(&cases, "Left"));
}

test "type defs spec: duplicate enum cases are reported by name" {
    const valid = [_]Case{ .{ .name = "left" }, .{ .name = "center" }, .{ .name = "right" } };
    const invalid = [_]Case{ .{ .name = "left" }, .{ .name = "center" }, .{ .name = "left" } };
    try testing.expectEqual(@as(?[]const u8, null), try type_defs.duplicateEnumCase(testing.allocator, &valid));
    const duplicate = try type_defs.duplicateEnumCase(testing.allocator, &invalid);
    try testing.expect(duplicate != null);
    try testing.expectEqualStrings("left", duplicate.?);
}

test "type defs spec: enum labels preserve user-facing case order" {
    const cases = [_]Case{ .{ .name = "String" }, .{ .name = "Number" }, .{ .name = "Done" } };
    const label = try type_defs.enumCasesLabel(testing.allocator, &cases);
    defer testing.allocator.free(label);
    try testing.expectEqualStrings("String | Number | Done", label);
}
