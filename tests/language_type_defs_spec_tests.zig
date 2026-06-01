const std = @import("std");
const type_defs = @import("type_defs");

const testing = std.testing;

test "type defs spec: enum bodies accept identifier case lists" {
    try testing.expect(type_defs.isEnumBody("left | center | right"));
    try testing.expect(type_defs.isEnumBody("Left | Center | RIGHT"));
    try testing.expect(type_defs.isEnumBody("  _unset | active_2 \n"));
    try testing.expect(type_defs.isEnumBody("String | Number"));
    try testing.expect(!type_defs.isEnumBody(""));
    try testing.expect(!type_defs.isEnumBody("left |"));
    try testing.expect(!type_defs.isEnumBody("| left"));
    try testing.expect(!type_defs.isEnumBody("left || right"));
    try testing.expect(!type_defs.isEnumBody("left right"));
}

test "type defs spec: enum lookup matches complete case names" {
    try testing.expect(type_defs.enumContains("left | center | right", "left"));
    try testing.expect(type_defs.enumContains("left | center | right", "right"));
    try testing.expect(type_defs.enumContains("Left | Center | RIGHT", "Left"));
    try testing.expect(type_defs.enumContains("Left | Center | RIGHT", "RIGHT"));
    try testing.expect(!type_defs.enumContains("left | center | right", "lef"));
    try testing.expect(!type_defs.enumContains("left | center | right", "Left"));
    try testing.expect(!type_defs.enumContains("left |", "left"));
}

test "type defs spec: duplicate enum cases are reported by name" {
    try testing.expectEqual(@as(?[]const u8, null), try type_defs.duplicateEnumCase(testing.allocator, "left | center | right"));
    const duplicate = try type_defs.duplicateEnumCase(testing.allocator, "left | center | left");
    try testing.expect(duplicate != null);
    try testing.expectEqualStrings("left", duplicate.?);
}

test "type defs spec: enum labels preserve user-facing case order" {
    const label = try type_defs.enumLabel(testing.allocator, "String | Number | Done");
    defer testing.allocator.free(label);
    try testing.expectEqualStrings("String | Number | Done", label);
}
