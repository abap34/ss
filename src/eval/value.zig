const std = @import("std");
const core = @import("core");

pub fn string(value: core.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.ExpectedStringArgument,
    };
}

pub fn propertyString(allocator: std.mem.Allocator, value: core.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        .number => |number_value| std.fmt.allocPrint(allocator, "{d}", .{number_value}),
        .boolean => |boolean_value| if (boolean_value) "true" else "false",
        else => error.ExpectedStringArgument,
    };
}

pub fn propertyStringNeedsFree(value: core.Value) bool {
    return switch (value) {
        .number => true,
        .boolean => false,
        else => false,
    };
}

pub fn number(value: core.Value) !f32 {
    return switch (value) {
        .number => |number_value| number_value,
        else => error.ExpectedNumberArgument,
    };
}

pub fn boolean(value: core.Value) !bool {
    return switch (value) {
        .boolean => |boolean_value| boolean_value,
        else => error.ExpectedBooleanArgument,
    };
}
