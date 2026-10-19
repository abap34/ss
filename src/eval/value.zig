const core = @import("core");

pub fn placementMember(state: *core.DocumentState, id: core.NodeId, name: []const u8) !core.Value {
    const node = state.getNode(id) orelse return error.UnknownNode;
    const placement = node.placement orelse return error.InvalidValueTag;
    if (placement.value == .group and @import("std").mem.eql(u8, name, "layout")) return core.group_composition.layoutValue(state, node);
    return switch (@import("../language/placement.zig").member(name) orelse return error.UnknownField) {
        .value => try placement.value.clone(state.allocator),
        .page => .{ .page = placement.page_id },
        .document => .{ .document = state.graph.document_id },
        .anchor => |anchor| .{ .anchor = .{ .node = .{ .node_id = id, .anchor = anchor } } },
    };
}

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
