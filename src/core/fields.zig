const std = @import("std");
const ast = @import("ast");
const model = @import("model");
const value_text = @import("value_text.zig");

const Node = model.Node;
const Value = model.Value;

pub const ValueSlot = struct {
    value: Value,
    owned: bool = false,

    pub fn deinit(self: *ValueSlot, allocator: std.mem.Allocator) void {
        if (self.owned) self.value.deinit(allocator);
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

pub fn get(allocator: std.mem.Allocator, ir: anytype, node: *const Node, key: []const u8) !?ValueSlot {
    if (model.nodeField(node, key)) |found| return .{ .value = found };
    return defaultValue(allocator, ir, node, key);
}

pub fn getWithEnv(allocator: std.mem.Allocator, node: *const Node, key: []const u8, sema: anytype) !?ValueSlot {
    if (model.nodeField(node, key)) |found| return .{ .value = found };
    return defaultValueWithEnv(allocator, node, key, sema);
}

pub fn read(
    allocator: std.mem.Allocator,
    ir: anytype,
    node: *const Node,
    key: []const u8,
    path: []const []const u8,
    comptime as: ReadAs,
) ?ReadResult(as) {
    return readSlotPath(allocator, get(allocator, ir, node, key), path, as);
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

pub fn readWithEnv(
    allocator: std.mem.Allocator,
    node: *const Node,
    key: []const u8,
    path: []const []const u8,
    sema: anytype,
    comptime as: ReadAs,
) ?ReadResult(as) {
    return readSlotPath(allocator, getWithEnv(allocator, node, key, sema), path, as);
}

pub fn className(ir: anytype, node: *const Node) ?[]const u8 {
    return switch (node.kind) {
        .document => "Doc",
        .page => "PageContext",
        .object => if (node.role) |role| roleClass(ir, role) else null,
    };
}

pub fn classNameWithEnv(node: *const Node, sema: anytype) ?[]const u8 {
    return switch (node.kind) {
        .document => "Doc",
        .page => "PageContext",
        .object => if (node.role) |role| sema.roleClass(role) else null,
    };
}

pub fn roleClass(ir: anytype, role_name: []const u8) ?[]const u8 {
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
        for (module.program.object_extensions.items) |extension| {
            for (extension.roles.items) |role| {
                if (std.mem.eql(u8, role, role_name)) return extension.target;
            }
        }
        for (module.program.objects.items) |decl| {
            for (decl.roles.items) |role| {
                if (std.mem.eql(u8, role, role_name)) return decl.name;
            }
        }
    }
    return null;
}

fn defaultValue(allocator: std.mem.Allocator, ir: anytype, node: *const Node, key: []const u8) !?ValueSlot {
    const class_name = className(ir, node) orelse return null;
    const descriptor = fieldDescriptor(ir, class_name, key) orelse return null;
    return try parseDefault(allocator, descriptor.default_property_value, descriptor.value_type);
}

fn defaultValueWithEnv(allocator: std.mem.Allocator, node: *const Node, key: []const u8, sema: anytype) !?ValueSlot {
    const class_name = classNameWithEnv(node, sema) orelse return null;
    const descriptor = sema.field(class_name, key) orelse return null;
    return try parseDefault(allocator, descriptor.default_property_value, descriptor.value_type);
}

fn parseDefault(allocator: std.mem.Allocator, maybe_text: ?[]const u8, ty: ast.Type) !?ValueSlot {
    const text = maybe_text orelse return null;
    const parsed = if (isNoneDefault(text))
        Value{ .none = {} }
    else
        try value_text.typedPropertyValue(allocator, text, ty);
    return .{ .value = parsed, .owned = true };
}

const FieldDescriptor = struct {
    default_property_value: ?[]const u8,
    value_type: ast.Type,
};

fn fieldDescriptor(ir: anytype, class_name: []const u8, field_name: []const u8) ?FieldDescriptor {
    var current: ?[]const u8 = class_name;
    while (current) |name| {
        if (fieldDescriptorInClass(ir, name, field_name)) |descriptor| return descriptor;
        current = classBase(ir, name);
    }
    return null;
}

fn fieldDescriptorInClass(ir: anytype, class_name: []const u8, field_name: []const u8) ?FieldDescriptor {
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
        for (module.program.object_extensions.items) |extension| {
            if (!std.mem.eql(u8, extension.target, class_name)) continue;
            for (extension.fields.items) |field| {
                if (std.mem.eql(u8, field.name, field_name)) return .{
                    .default_property_value = field.default_property_value,
                    .value_type = field.value_type,
                };
            }
        }
        for (module.program.objects.items) |decl| {
            if (!std.mem.eql(u8, decl.name, class_name)) continue;
            for (decl.fields.items) |field| {
                if (std.mem.eql(u8, field.name, field_name)) return .{
                    .default_property_value = field.default_property_value,
                    .value_type = field.value_type,
                };
            }
        }
    }
    return null;
}

fn classBase(ir: anytype, class_name: []const u8) ?[]const u8 {
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
        for (module.program.objects.items) |decl| {
            if (std.mem.eql(u8, decl.name, class_name)) return decl.base;
        }
    }
    return null;
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
