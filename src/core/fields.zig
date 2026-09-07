const std = @import("std");
const ast = @import("ast");
const model = @import("model");
const value_text = @import("value_text.zig");

const Node = model.Node;
const Value = model.Value;

pub const ValueSlot = struct {
    value: Value,
    owned: bool = false,
    owns_tagged_text: bool = false,

    pub fn deinit(self: *ValueSlot, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        if (self.owns_tagged_text) {
            value_text.deinitParsedPropertyValue(allocator, &self.value);
        } else {
            self.value.deinit(allocator);
        }
    }
};

pub const ReadAs = enum {
    text,
    number,
};

pub fn ReadResult(comptime as: ReadAs) type {
    return switch (as) {
        .text => []const u8,
        .number => f32,
    };
}

pub fn get(allocator: std.mem.Allocator, state: anytype, node: *const Node, key: []const u8) !?ValueSlot {
    if (model.nodeField(node, key)) |found| return .{ .value = found };
    return defaultValue(allocator, state, node, key);
}

pub fn read(
    allocator: std.mem.Allocator,
    state: anytype,
    node: *const Node,
    key: []const u8,
    path: []const []const u8,
    comptime as: ReadAs,
) ?ReadResult(as) {
    return readSlotPath(allocator, get(allocator, state, node, key), path, as);
}

pub fn readExplicit(
    node: *const Node,
    key: []const u8,
    path: []const []const u8,
    comptime as: ReadAs,
) ?ReadResult(as) {
    const value = model.nodeField(node, key) orelse return null;
    const field = pathValue(value, path) orelse return null;
    return readValue(field, as);
}

pub fn className(state: anytype, node: *const Node) ?[]const u8 {
    return switch (node.kind) {
        .document => "Doc",
        .page => "PageContext",
        .object => if (node.role) |role| roleClass(state, role) else null,
    };
}

pub fn roleClass(state: anytype, role_name: []const u8) ?[]const u8 {
    return state.declaration_index.roleClass(role_name);
}

fn defaultValue(allocator: std.mem.Allocator, state: anytype, node: *const Node, key: []const u8) !?ValueSlot {
    const class_name = className(state, node) orelse return null;
    const descriptor = state.declaration_index.field(class_name, key) orelse return null;
    const text = descriptor.default_property_value orelse return null;
    if (!isNoneDefault(text) and value_text.typedPropertyValueOwnsTaggedText(descriptor.value_type)) {
        return .{ .value = try state.cachedFieldDefault(text, descriptor.value_type) };
    }
    return try parseDefault(allocator, descriptor.default_property_value, descriptor.value_type);
}

fn parseDefault(allocator: std.mem.Allocator, maybe_text: ?[]const u8, ty: ast.Type) !?ValueSlot {
    const text = maybe_text orelse return null;
    const parsed = if (isNoneDefault(text))
        Value{ .none = {} }
    else
        try value_text.typedPropertyValue(allocator, text, ty);
    return .{
        .value = parsed,
        .owned = true,
        .owns_tagged_text = !isNoneDefault(text) and value_text.typedPropertyValueOwnsTaggedText(ty),
    };
}

fn readSlotPath(
    allocator: std.mem.Allocator,
    slot_result: anyerror!?ValueSlot,
    path: []const []const u8,
    comptime as: ReadAs,
) ?ReadResult(as) {
    var slot = (slot_result catch return null) orelse return null;
    defer slot.deinit(allocator);
    const field = pathValue(slot.value, path) orelse return null;
    return readValue(field, as);
}

pub fn pathValue(value_to_read: Value, path: []const []const u8) ?Value {
    var current = value_to_read;
    for (path) |field_name| {
        current = switch (current) {
            .record => |record| record.field(field_name) orelse return null,
            else => return null,
        };
    }
    return current;
}

fn readValue(value_to_read: Value, comptime as: ReadAs) ?ReadResult(as) {
    return switch (as) {
        .text => valueText(value_to_read),
        .number => valueNumber(value_to_read),
    };
}

fn valueText(value_to_read: Value) ?[]const u8 {
    return switch (value_to_read) {
        .string => |text| text,
        .enum_case => |case| case.case_name,
        else => null,
    };
}

fn valueNumber(value_to_read: Value) ?f32 {
    return switch (value_to_read) {
        .number => |number_value| if (std.math.isFinite(number_value)) number_value else null,
        .string => |text| blk: {
            const parsed = std.fmt.parseFloat(f32, text) catch return null;
            break :blk if (std.math.isFinite(parsed)) parsed else null;
        },
        else => null,
    };
}

fn isNoneDefault(value_text_value: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, value_text_value, " \t\r\n"), "none");
}
