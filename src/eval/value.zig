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
        .enum_case => |case| case.case_name,
        .record => |record| try recordPropertyString(allocator, record),
        .number => |number_value| std.fmt.allocPrint(allocator, "{d}", .{number_value}),
        .boolean => |boolean_value| if (boolean_value) "true" else "false",
        else => error.ExpectedStringArgument,
    };
}

pub fn propertyStringNeedsFree(value: core.Value) bool {
    return switch (value) {
        .number => true,
        .record => true,
        .boolean => false,
        else => false,
    };
}

pub fn parsePropertyValue(allocator: std.mem.Allocator, text: []const u8) !core.Value {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    return try parseTaggedValue(allocator, parsed.value);
}

fn recordPropertyString(allocator: std.mem.Allocator, record: core.RecordValue) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendTaggedValueJson(allocator, &out, .{ .record = record });
    return out.toOwnedSlice(allocator);
}

fn appendTaggedValueJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: core.Value) !void {
    switch (value) {
        .none => {
            try out.appendSlice(allocator, "{\"kind\":\"none\"}");
        },
        .string => |text| {
            try out.appendSlice(allocator, "{\"kind\":\"string\",\"value\":");
            try appendJsonString(allocator, out, text);
            try out.append(allocator, '}');
        },
        .enum_case => |case| {
            try out.appendSlice(allocator, "{\"kind\":\"enum\",\"type\":");
            try appendJsonString(allocator, out, case.enum_name);
            try out.appendSlice(allocator, ",\"case\":");
            try appendJsonString(allocator, out, case.case_name);
            try out.append(allocator, '}');
        },
        .record => |record| {
            try out.appendSlice(allocator, "{\"kind\":\"record\",\"type\":");
            try appendJsonString(allocator, out, record.type_name);
            try out.appendSlice(allocator, ",\"fields\":[");
            for (record.fields.items, 0..) |field, index| {
                if (index > 0) try out.append(allocator, ',');
                try out.appendSlice(allocator, "{\"name\":");
                try appendJsonString(allocator, out, field.name);
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

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const escaped = try std.json.Stringify.valueAlloc(allocator, text, .{});
    defer allocator.free(escaped);
    try out.appendSlice(allocator, escaped);
}

fn parseTaggedValue(allocator: std.mem.Allocator, value: std.json.Value) !core.Value {
    if (value != .object) return error.InvalidValueTag;
    const object = value.object;
    const kind_value = object.get("kind") orelse return error.InvalidValueTag;
    if (kind_value != .string) return error.InvalidValueTag;
    const kind = kind_value.string;
    if (std.mem.eql(u8, kind, "none")) return .{ .none = {} };
    if (std.mem.eql(u8, kind, "string")) {
        const raw = object.get("value") orelse return error.InvalidValueTag;
        if (raw != .string) return error.InvalidValueTag;
        return .{ .string = try allocator.dupe(u8, raw.string) };
    }
    if (std.mem.eql(u8, kind, "enum")) {
        const type_value = object.get("type") orelse return error.InvalidValueTag;
        const case_value = object.get("case") orelse return error.InvalidValueTag;
        if (type_value != .string or case_value != .string) return error.InvalidValueTag;
        return .{ .enum_case = .{
            .enum_name = try allocator.dupe(u8, type_value.string),
            .case_name = try allocator.dupe(u8, case_value.string),
        } };
    }
    if (std.mem.eql(u8, kind, "record")) {
        const type_value = object.get("type") orelse return error.InvalidValueTag;
        const fields_value = object.get("fields") orelse return error.InvalidValueTag;
        if (type_value != .string or fields_value != .array) return error.InvalidValueTag;
        var record = core.RecordValue.init(try allocator.dupe(u8, type_value.string));
        errdefer record.deinit(allocator);
        for (fields_value.array.items) |field_item| {
            if (field_item != .object) return error.InvalidValueTag;
            const field_object = field_item.object;
            const name_value = field_object.get("name") orelse return error.InvalidValueTag;
            const nested_value = field_object.get("value") orelse return error.InvalidValueTag;
            if (name_value != .string) return error.InvalidValueTag;
            const explicit = if (field_object.get("explicit")) |explicit_value| blk: {
                if (explicit_value != .bool) return error.InvalidValueTag;
                break :blk explicit_value.bool;
            } else true;
            try record.fields.append(allocator, .{
                .name = try allocator.dupe(u8, name_value.string),
                .value = try parseTaggedValue(allocator, nested_value),
                .explicit = explicit,
            });
        }
        return .{ .record = record };
    }
    if (std.mem.eql(u8, kind, "number")) {
        const raw = object.get("value") orelse return error.InvalidValueTag;
        return switch (raw) {
            .integer => |integer| .{ .number = @floatFromInt(integer) },
            .float => |float| .{ .number = @floatCast(float) },
            else => error.InvalidValueTag,
        };
    }
    if (std.mem.eql(u8, kind, "bool")) {
        const raw = object.get("value") orelse return error.InvalidValueTag;
        if (raw != .bool) return error.InvalidValueTag;
        return .{ .boolean = raw.bool };
    }
    return error.InvalidValueTag;
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
