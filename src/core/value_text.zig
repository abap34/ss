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
        .path => |path| try pathPropertyString(allocator, path),
        .number => |number_value| std.fmt.allocPrint(allocator, "{d}", .{number_value}),
        .boolean => |boolean_value| if (boolean_value) "true" else "false",
        else => error.ExpectedStringArgument,
    };
}

pub fn propertyStringNeedsFree(value: model.Value) bool {
    return switch (value) {
        .number => true,
        .record => true,
        .path => true,
        .boolean => false,
        else => false,
    };
}

pub fn parsePropertyValue(allocator: std.mem.Allocator, text: []const u8) !model.Value {
    var parsed = try json.parseValue(allocator, text, .{});
    defer parsed.deinit();
    return try parseTaggedValue(allocator, parsed.value);
}

pub fn typedPropertyValueOwnsTaggedText(ty: ast.Type) bool {
    if (ty.kind == .optional) {
        const child = ty.optional_child orelse return false;
        return typedPropertyValueOwnsTaggedText(child.*);
    }
    return ty.kind == .record or ty.kind == .path;
}

pub fn deinitParsedPropertyValue(allocator: std.mem.Allocator, value: *model.Value) void {
    switch (value.*) {
        .string => |text| allocator.free(text),
        .enum_case => |case| {
            allocator.free(case.enum_name);
            allocator.free(case.case_name);
        },
        .record => |*record| deinitParsedRecordValue(allocator, record),
        .path => |*path| path.deinit(allocator),
        else => value.deinit(allocator),
    }
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
            errdefer deinitParsedPropertyValue(allocator, &parsed);
            if (parsed != .record) {
                return error.InvalidValueTag;
            }
            if (ty.class_name) |expected| {
                if (!std.mem.eql(u8, parsed.record.type_name, expected)) {
                    return error.InvalidValueTag;
                }
            }
            break :blk parsed;
        },
        .path => blk: {
            var parsed = try parsePropertyValue(allocator, text);
            errdefer deinitParsedPropertyValue(allocator, &parsed);
            if (parsed != .path) return error.InvalidValueTag;
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

fn deinitParsedRecordValue(allocator: std.mem.Allocator, record: *model.RecordValue) void {
    allocator.free(record.type_name);
    for (record.fields.items) |*field| {
        allocator.free(field.name);
        deinitParsedPropertyValue(allocator, &field.value);
    }
    record.fields.deinit(allocator);
}

fn recordPropertyString(allocator: std.mem.Allocator, record: model.RecordValue) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendTaggedValueJson(allocator, &out, .{ .record = record });
    return out.toOwnedSlice(allocator);
}

fn pathPropertyString(allocator: std.mem.Allocator, path: model.Path) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendTaggedValueJson(allocator, &out, .{ .path = path });
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
        .object => |id| {
            try out.appendSlice(allocator, "{\"kind\":\"object\",\"value\":");
            const text = try std.fmt.allocPrint(allocator, "{d}", .{id});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
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
        .path => |path| {
            try out.appendSlice(allocator, "{\"kind\":\"path\",\"commands\":[");
            for (path.commands, 0..) |command, index| {
                if (index > 0) try out.append(allocator, ',');
                switch (command) {
                    .move_to => |point| try appendPathPointJson(allocator, out, "move", point),
                    .line_to => |point| try appendPathPointJson(allocator, out, "line", point),
                    .cubic_to => |cubic| {
                        try out.appendSlice(allocator, "{\"verb\":\"cubic\",\"control1_x\":");
                        try appendFloatJson(allocator, out, cubic.control1.x);
                        try out.appendSlice(allocator, ",\"control1_y\":");
                        try appendFloatJson(allocator, out, cubic.control1.y);
                        try out.appendSlice(allocator, ",\"control2_x\":");
                        try appendFloatJson(allocator, out, cubic.control2.x);
                        try out.appendSlice(allocator, ",\"control2_y\":");
                        try appendFloatJson(allocator, out, cubic.control2.y);
                        try out.appendSlice(allocator, ",\"x\":");
                        try appendFloatJson(allocator, out, cubic.end.x);
                        try out.appendSlice(allocator, ",\"y\":");
                        try appendFloatJson(allocator, out, cubic.end.y);
                        try out.append(allocator, '}');
                    },
                    .close => try out.appendSlice(allocator, "{\"verb\":\"close\"}"),
                }
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

fn appendPathPointJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), verb: []const u8, point: model.PathPoint) !void {
    try out.appendSlice(allocator, "{\"verb\":");
    try json.appendString(allocator, out, verb);
    try out.appendSlice(allocator, ",\"x\":");
    try appendFloatJson(allocator, out, point.x);
    try out.appendSlice(allocator, ",\"y\":");
    try appendFloatJson(allocator, out, point.y);
    try out.append(allocator, '}');
}

fn appendFloatJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: f32) !void {
    if (!std.math.isFinite(value)) return error.InvalidValueTag;
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
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
    if (std.mem.eql(u8, kind, "object")) {
        const raw = json.numberField(object, "value") orelse return error.InvalidValueTag;
        if (!std.math.isFinite(raw) or raw < 0 or raw > std.math.maxInt(model.NodeId) or @trunc(raw) != raw) {
            return error.InvalidValueTag;
        }
        return .{ .object = @intFromFloat(raw) };
    }
    if (std.mem.eql(u8, kind, "record")) {
        const type_value = json.stringField(object, "type") orelse return error.InvalidValueTag;
        const fields = json.arrayFieldObject(object, "fields") orelse return error.InvalidValueTag;
        var record = model.RecordValue.init(try allocator.dupe(u8, type_value));
        errdefer deinitParsedRecordValue(allocator, &record);
        for (fields.items) |field_item| {
            if (field_item != .object) return error.InvalidValueTag;
            const field_object = &field_item.object;
            const name_value = json.stringField(field_object, "name") orelse return error.InvalidValueTag;
            const nested_value = json.fieldValue(field_object, "value") orelse return error.InvalidValueTag;
            const explicit = if (json.fieldValue(field_object, "explicit")) |explicit_value| blk: {
                if (explicit_value.* != .bool) return error.InvalidValueTag;
                break :blk explicit_value.bool;
            } else true;
            const field_name = try allocator.dupe(u8, name_value);
            var field_name_moved = false;
            errdefer if (!field_name_moved) allocator.free(field_name);
            var field_value = try parseTaggedValue(allocator, nested_value.*);
            var field_value_moved = false;
            errdefer if (!field_value_moved) deinitParsedPropertyValue(allocator, &field_value);
            try record.fields.append(allocator, .{
                .name = field_name,
                .value = field_value,
                .explicit = explicit,
            });
            field_name_moved = true;
            field_value_moved = true;
        }
        return .{ .record = record };
    }
    if (std.mem.eql(u8, kind, "path")) {
        const commands_value = json.fieldValue(object, "commands") orelse return error.InvalidValueTag;
        if (commands_value.* != .array) return error.InvalidValueTag;
        var commands = std.ArrayList(model.PathCommand).empty;
        errdefer commands.deinit(allocator);
        for (commands_value.array.items) |command_value| {
            if (command_value != .object) return error.InvalidValueTag;
            const command_object = &command_value.object;
            const verb = json.stringField(command_object, "verb") orelse return error.InvalidValueTag;
            const command: model.PathCommand = if (std.mem.eql(u8, verb, "move"))
                .{ .move_to = try parsePathPoint(command_object) }
            else if (std.mem.eql(u8, verb, "line"))
                .{ .line_to = try parsePathPoint(command_object) }
            else if (std.mem.eql(u8, verb, "cubic"))
                .{ .cubic_to = .{
                    .control1 = try parsePathPointNamed(command_object, "control1_x", "control1_y"),
                    .control2 = try parsePathPointNamed(command_object, "control2_x", "control2_y"),
                    .end = try parsePathPoint(command_object),
                } }
            else if (std.mem.eql(u8, verb, "close"))
                .{ .close = {} }
            else
                return error.InvalidValueTag;
            if (!command.isFinite()) return error.InvalidValueTag;
            try commands.append(allocator, command);
        }
        return .{ .path = .init(try commands.toOwnedSlice(allocator)) };
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

fn parsePathPoint(object: *const json.ObjectMap) !model.PathPoint {
    return parsePathPointNamed(object, "x", "y");
}

fn parsePathPointNamed(object: *const json.ObjectMap, x_name: []const u8, y_name: []const u8) !model.PathPoint {
    const x = json.numberField(object, x_name) orelse return error.InvalidValueTag;
    const y = json.numberField(object, y_name) orelse return error.InvalidValueTag;
    const point: model.PathPoint = .{ .x = @floatCast(x), .y = @floatCast(y) };
    if (!point.isFinite()) return error.InvalidValueTag;
    return point;
}
