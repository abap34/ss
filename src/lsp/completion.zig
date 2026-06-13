const std = @import("std");

const JsonObject = std.json.ObjectMap;
const JsonArray = std.json.Array;

pub const AccessSeparator = enum {
    dot,
    double_colon,
};

pub const AccessContext = struct {
    receiver: []const u8,
    separator: AccessSeparator,
    separator_offset: usize,
};

pub const PropertyTarget = union(enum) {
    class: []const u8,
    any_object,
};

pub fn accessBeforeOffset(source: []const u8, offset: usize) ?AccessContext {
    var cursor = @min(offset, source.len);
    while (cursor > 0 and isIdentChar(source[cursor - 1])) cursor -= 1;

    const separator: AccessSeparator, const separator_offset: usize = if (cursor >= 2 and std.mem.eql(u8, source[cursor - 2 .. cursor], "::"))
        .{ .double_colon, cursor - 2 }
    else if (cursor >= 1 and source[cursor - 1] == '.')
        .{ .dot, cursor - 1 }
    else
        return null;

    var receiver_start = separator_offset;
    while (receiver_start > 0 and isReceiverChar(source[receiver_start - 1])) receiver_start -= 1;
    if (receiver_start == separator_offset) return null;

    return .{
        .receiver = source[receiver_start..separator_offset],
        .separator = separator,
        .separator_offset = separator_offset,
    };
}

pub fn propertyTargetForVariable(variable: *const JsonObject) ?PropertyTarget {
    if (nonEmptyStringField(variable, "objectClass")) |class_name| return .{ .class = class_name };
    const type_label = stringField(variable, "type") orelse return null;
    if (std.mem.eql(u8, type_label, "Document")) return .{ .class = "Doc" };
    if (std.mem.eql(u8, type_label, "Page")) return .{ .class = "PageContext" };
    if (isObjectLikeTypeLabel(type_label)) return .any_object;
    return null;
}

pub fn fieldAppliesToTarget(root: *const JsonObject, field: *const JsonObject, target: PropertyTarget) bool {
    switch (target) {
        .any_object => return true,
        .class => |class_name| {
            const field_class = stringField(field, "class") orelse return false;
            return classContains(root, class_name, field_class);
        },
    }
}

fn classContains(root: *const JsonObject, class_name: []const u8, expected: []const u8) bool {
    var current: ?[]const u8 = class_name;
    while (current) |name| {
        if (std.mem.eql(u8, name, expected)) return true;
        current = classBase(root, name);
    }
    return false;
}

fn classBase(root: *const JsonObject, class_name: []const u8) ?[]const u8 {
    const decls = objectFieldObject(root, "declarations") orelse return null;
    const classes = arrayFieldObject(decls, "classes") orelse return null;
    var index = classes.items.len;
    while (index > 0) {
        index -= 1;
        const item = classes.items[index];
        if (item != .object) continue;
        if (!std.mem.eql(u8, stringField(&item.object, "name") orelse "", class_name)) continue;
        return nonEmptyStringField(&item.object, "base");
    }
    return null;
}

fn isObjectLikeTypeLabel(type_label: []const u8) bool {
    return std.mem.eql(u8, type_label, "Object") or
        std.mem.startsWith(u8, type_label, "Object<") or
        std.mem.eql(u8, type_label, "Selection<Object>") or
        std.mem.startsWith(u8, type_label, "Selection<Object<") or
        std.mem.eql(u8, type_label, "Selection<Any>");
}

fn nonEmptyStringField(object: *const JsonObject, key: []const u8) ?[]const u8 {
    const value = stringField(object, key) orelse return null;
    return if (value.len == 0) null else value;
}

fn stringField(object: *const JsonObject, key: []const u8) ?[]const u8 {
    const value = @constCast(object).getPtr(key) orelse return null;
    return if (value.* == .string) value.string else null;
}

fn objectFieldObject(object: *const JsonObject, key: []const u8) ?*const JsonObject {
    const child = @constCast(object).getPtr(key) orelse return null;
    if (child.* != .object) return null;
    return &child.object;
}

fn arrayFieldObject(object: *const JsonObject, key: []const u8) ?*const JsonArray {
    const child = @constCast(object).getPtr(key) orelse return null;
    if (child.* != .array) return null;
    return &child.array;
}

fn isIdentChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '!';
}

fn isReceiverChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
