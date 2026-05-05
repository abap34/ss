const std = @import("std");
const model = @import("model");

const Node = model.Node;

pub fn property(ir: anytype, node: *const Node, key: []const u8) ?[]const u8 {
    if (model.nodeProperty(node, key)) |value| return value;
    return defaultProperty(ir, node, key);
}

pub fn defaultProperty(ir: anytype, node: *const Node, key: []const u8) ?[]const u8 {
    const class_name = classNameForNode(ir, node) orelse return null;
    const value = fieldDefault(ir, class_name, key) orelse return null;
    return unquoteDefault(value);
}

pub fn classNameForNode(ir: anytype, node: *const Node) ?[]const u8 {
    return switch (node.kind) {
        .document => "DocumentObject",
        .page => "PageObject",
        .object => if (node.role) |role| roleClass(ir, role) else null,
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

pub fn fieldDefault(ir: anytype, class_name: []const u8, field_name: []const u8) ?[]const u8 {
    var current: ?[]const u8 = class_name;
    while (current) |name| {
        if (fieldDefaultInClass(ir, name, field_name)) |value| return value;
        current = classBase(ir, name);
    }
    return null;
}

fn fieldDefaultInClass(ir: anytype, class_name: []const u8, field_name: []const u8) ?[]const u8 {
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
        for (module.program.object_extensions.items) |extension| {
            if (!std.mem.eql(u8, extension.target, class_name)) continue;
            for (extension.fields.items) |field| {
                if (std.mem.eql(u8, field.name, field_name)) return field.default_value;
            }
        }
        for (module.program.objects.items) |decl| {
            if (!std.mem.eql(u8, decl.name, class_name)) continue;
            for (decl.fields.items) |field| {
                if (std.mem.eql(u8, field.name, field_name)) return field.default_value;
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

fn unquoteDefault(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}
