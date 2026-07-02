const std = @import("std");
const ast = @import("ast");
const model = @import("model");
const utils = @import("utils");

const json = utils.json;

pub fn propertyString(allocator: std.mem.Allocator, value: model.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        .enum_case => |case| case.case_name,
        .record => |record| try recordPropertyString(allocator, record),
        .number => |number_value| std.fmt.allocPrint(allocator, "{d}", .{number_value}),
        .boolean => |boolean_value| if (boolean_value) "true" else "false",
        else => error.ExpectedStringArgument,
    };
}

pub fn propertyStringNeedsFree(value: model.Value) bool {
    return switch (value) {
        .number => true,
        .record => true,
        .boolean => false,
        else => false,
    };
}

pub fn parsePropertyValue(allocator: std.mem.Allocator, text: []const u8) !model.Value {
    var parsed = try json.parseValue(allocator, text, .{});
    defer parsed.deinit();
    return try parseTaggedValue(allocator, parsed.value);
}

pub fn typedPropertyValue(allocator: std.mem.Allocator, text: []const u8, ty: ast.Type) !model.Value {
    if (ty.kind == .optional) {
        const child = ty.optional_child orelse return .{ .string = text };
        return typedPropertyValue(allocator, text, child.*);
    }
    return switch (ty.kind) {
        .none => .{ .none = {} },
        .hole => error.InvalidValueTag,
        .string, .color => .{ .string = text },
        .enum_type => .{ .enum_case = .{
            .enum_name = ty.enum_name orelse "",
            .case_name = text,
        } },
        .record => blk: {
            var parsed = try parsePropertyValue(allocator, text);
            if (parsed != .record) {
                parsed.deinit(allocator);
                return error.InvalidValueTag;
            }
            if (ty.class_name) |expected| {
                if (!std.mem.eql(u8, parsed.record.type_name, expected)) {
                    parsed.deinit(allocator);
                    return error.InvalidValueTag;
                }
            }
            break :blk parsed;
        },
        .number => .{ .number = std.fmt.parseFloat(f32, text) catch return error.InvalidValueTag },
        .boolean => blk: {
            if (std.mem.eql(u8, text, "true")) break :blk .{ .boolean = true };
            if (std.mem.eql(u8, text, "false")) break :blk .{ .boolean = false };
            return error.InvalidValueTag;
        },
        else => .{ .string = text },
    };
}

fn recordPropertyString(allocator: std.mem.Allocator, record: model.RecordValue) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendTaggedValueJson(allocator, &out, .{ .record = record });
    return out.toOwnedSlice(allocator);
}

fn appendTaggedValueJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: model.Value) !void {
    switch (value) {
        .none => {
            try out.appendSlice(allocator, "{\"kind\":\"none\"}");
        },
        .string => |text| {
            try out.appendSlice(allocator, "{\"kind\":\"string\",\"value\":");
            try json.appendString(allocator, out, text);
            try out.append(allocator, '}');
        },
        .enum_case => |case| {
            try out.appendSlice(allocator, "{\"kind\":\"enum\",\"type\":");
            try json.appendString(allocator, out, case.enum_name);
            try out.appendSlice(allocator, ",\"case\":");
            try json.appendString(allocator, out, case.case_name);
            try out.append(allocator, '}');
        },
        .record => |record| {
            try out.appendSlice(allocator, "{\"kind\":\"record\",\"type\":");
            try json.appendString(allocator, out, record.type_name);
            try out.appendSlice(allocator, ",\"fields\":[");
            for (record.fields.items, 0..) |field, index| {
                if (index > 0) try out.append(allocator, ',');
                try out.appendSlice(allocator, "{\"name\":");
                try json.appendString(allocator, out, field.name);
                try out.appendSlice(allocator, ",\"explicit\":");
                try out.appendSlice(allocator, if (field.explicit) "true" else "false");
                try out.appendSlice(allocator, ",\"value\":");
                try appendTaggedValueJson(allocator, out, field.value);
                try out.append(allocator, '}');
            }
            try out.appendSlice(allocator, "]}");
        },
        .number => |number_value| {
            try out.appendSlice(allocator, "{\"kind\":\"number\",\"value\":");
            const text = try std.fmt.allocPrint(allocator, "{d}", .{number_value});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
            try out.append(allocator, '}');
        },
        .boolean => |boolean_value| {
            try out.appendSlice(allocator, if (boolean_value) "{\"kind\":\"bool\",\"value\":true}" else "{\"kind\":\"bool\",\"value\":false}");
        },
        else => return error.ExpectedStringArgument,
    }
}

fn parseTaggedValue(allocator: std.mem.Allocator, value: json.Value) !model.Value {
    if (value != .object) return error.InvalidValueTag;
    const object = &value.object;
    const kind = json.stringField(object, "kind") orelse return error.InvalidValueTag;
    if (std.mem.eql(u8, kind, "none")) return .{ .none = {} };
    if (std.mem.eql(u8, kind, "string")) {
        const raw = json.stringField(object, "value") orelse return error.InvalidValueTag;
        return .{ .string = try allocator.dupe(u8, raw) };
    }
    if (std.mem.eql(u8, kind, "enum")) {
        const type_value = json.stringField(object, "type") orelse return error.InvalidValueTag;
        const case_value = json.stringField(object, "case") orelse return error.InvalidValueTag;
        return .{ .enum_case = .{
            .enum_name = try allocator.dupe(u8, type_value),
            .case_name = try allocator.dupe(u8, case_value),
        } };
    }
    if (std.mem.eql(u8, kind, "record")) {
        const type_value = json.stringField(object, "type") orelse return error.InvalidValueTag;
        const fields = json.arrayFieldObject(object, "fields") orelse return error.InvalidValueTag;
        var record = model.RecordValue.init(try allocator.dupe(u8, type_value));
        errdefer record.deinit(allocator);
        for (fields.items) |field_item| {
            if (field_item != .object) return error.InvalidValueTag;
            const field_object = &field_item.object;
            const name_value = json.stringField(field_object, "name") orelse return error.InvalidValueTag;
            const nested_value = json.fieldValue(field_object, "value") orelse return error.InvalidValueTag;
            const explicit = if (json.fieldValue(field_object, "explicit")) |explicit_value| blk: {
                if (explicit_value.* != .bool) return error.InvalidValueTag;
                break :blk explicit_value.bool;
            } else true;
            try record.fields.append(allocator, .{
                .name = try allocator.dupe(u8, name_value),
                .value = try parseTaggedValue(allocator, nested_value.*),
                .explicit = explicit,
            });
        }
        return .{ .record = record };
    }
    if (std.mem.eql(u8, kind, "number")) {
        const raw = json.numberField(object, "value") orelse return error.InvalidValueTag;
        return .{ .number = @floatCast(raw) };
    }
    if (std.mem.eql(u8, kind, "bool")) {
        const raw = json.boolField(object, "value") orelse return error.InvalidValueTag;
        return .{ .boolean = raw };
    }
    return error.InvalidValueTag;
}
