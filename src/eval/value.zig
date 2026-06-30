const core = @import("core");

pub fn string(value: core.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.ExpectedStringArgument,
    };
}

pub const propertyString = core.value_text.propertyString;
pub const propertyStringNeedsFree = core.value_text.propertyStringNeedsFree;
pub const parsePropertyValue = core.value_text.parsePropertyValue;

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
