const std = @import("std");

pub const Value = std.json.Value;
pub const ObjectMap = std.json.ObjectMap;
pub const ValueArray = std.json.Array;
pub const ParseOptions = std.json.ParseOptions;
pub const ParsedValue = std.json.Parsed(Value);

const Sink = union(enum) {
    stdout,
    buffer: struct {
        value: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
    },
};

pub const Object = struct {
    allocator: std.mem.Allocator,
    sink: Sink,
    first: bool = true,

    pub fn begin(allocator: std.mem.Allocator) Object {
        writeByte(.stdout, '{') catch unreachable;
        return .{ .allocator = allocator, .sink = .stdout };
    }

    pub fn beginBuffer(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !Object {
        const sink: Sink = .{ .buffer = .{ .value = buffer, .allocator = allocator } };
        try writeByte(sink, '{');
        return .{ .allocator = allocator, .sink = sink };
    }

    pub fn end(self: *Object) !void {
        try writeByte(self.sink, '}');
    }

    pub fn objectField(self: *Object, key: []const u8) !Object {
        try self.fieldName(key);
        try writeByte(self.sink, '{');
        return .{ .allocator = self.allocator, .sink = self.sink };
    }

    pub fn arrayField(self: *Object, key: []const u8) !Array {
        try self.fieldName(key);
        try writeByte(self.sink, '[');
        return .{ .allocator = self.allocator, .sink = self.sink };
    }

    pub fn stringField(self: *Object, key: []const u8, value: []const u8) !void {
        try self.fieldName(key);
        try string(self.allocator, self.sink, value);
    }

    pub fn enumTagField(self: *Object, key: []const u8, value: anytype) !void {
        try self.stringField(key, @tagName(value));
    }

    pub fn valueField(self: *Object, key: []const u8, value: Value) !void {
        try self.fieldName(key);
        try jsonValue(self.allocator, self.sink, value);
    }

    pub fn intField(self: *Object, key: []const u8, value: anytype) !void {
        try self.fieldName(key);
        try int(self.allocator, self.sink, value);
    }

    pub fn floatField(self: *Object, key: []const u8, value: f32, comptime fmt: []const u8) !void {
        try self.fieldName(key);
        try float(self.allocator, self.sink, value, fmt);
    }

    pub fn boolField(self: *Object, key: []const u8, value: bool) !void {
        try self.fieldName(key);
        try writeBytes(self.sink, if (value) "true" else "false");
    }

    pub fn optionalBoolField(self: *Object, key: []const u8, value: ?bool) !void {
        try self.fieldName(key);
        if (value) |boolean| {
            try writeBytes(self.sink, if (boolean) "true" else "false");
        } else {
            try writeBytes(self.sink, "null");
        }
    }

    pub fn nullField(self: *Object, key: []const u8) !void {
        try self.fieldName(key);
        try writeBytes(self.sink, "null");
    }

    pub fn optionalStringField(self: *Object, key: []const u8, value: ?[]const u8) !void {
        try self.fieldName(key);
        if (value) |text| {
            try string(self.allocator, self.sink, text);
        } else {
            try writeBytes(self.sink, "null");
        }
    }

    pub fn optionalIntField(self: *Object, key: []const u8, value: anytype) !void {
        try self.fieldName(key);
        if (value) |number| {
            try int(self.allocator, self.sink, number);
        } else {
            try writeBytes(self.sink, "null");
        }
    }

    pub fn optionalEnumTagField(self: *Object, key: []const u8, value: anytype) !void {
        try self.fieldName(key);
        if (value) |tagged| {
            try string(self.allocator, self.sink, @tagName(tagged));
        } else {
            try writeBytes(self.sink, "null");
        }
    }

    pub fn optionalFloatField(self: *Object, key: []const u8, value: ?f32, comptime fmt: []const u8) !void {
        try self.fieldName(key);
        if (value) |number| {
            try float(self.allocator, self.sink, number, fmt);
        } else {
            try writeBytes(self.sink, "null");
        }
    }

    fn fieldName(self: *Object, key: []const u8) !void {
        try self.comma();
        try string(self.allocator, self.sink, key);
        try writeByte(self.sink, ':');
    }

    fn comma(self: *Object) !void {
        if (self.first) {
            self.first = false;
        } else {
            try writeByte(self.sink, ',');
        }
    }
};

pub const Array = struct {
    allocator: std.mem.Allocator,
    sink: Sink,
    first: bool = true,

    pub fn end(self: *Array) !void {
        try writeByte(self.sink, ']');
    }

    pub fn objectItem(self: *Array) !Object {
        try self.comma();
        try writeByte(self.sink, '{');
        return .{ .allocator = self.allocator, .sink = self.sink };
    }

    pub fn arrayItem(self: *Array) !Array {
        try self.comma();
        try writeByte(self.sink, '[');
        return .{ .allocator = self.allocator, .sink = self.sink };
    }

    pub fn stringItem(self: *Array, value: []const u8) !void {
        try self.comma();
        try string(self.allocator, self.sink, value);
    }

    pub fn valueItem(self: *Array, value: Value) !void {
        try self.comma();
        try jsonValue(self.allocator, self.sink, value);
    }

    pub fn intItem(self: *Array, value: anytype) !void {
        try self.comma();
        try int(self.allocator, self.sink, value);
    }

    pub fn floatItem(self: *Array, value: f32, comptime fmt: []const u8) !void {
        try self.comma();
        try float(self.allocator, self.sink, value, fmt);
    }

    pub fn boolItem(self: *Array, value: bool) !void {
        try self.comma();
        try writeBytes(self.sink, if (value) "true" else "false");
    }

    pub fn nullItem(self: *Array) !void {
        try self.comma();
        try writeBytes(self.sink, "null");
    }

    fn comma(self: *Array) !void {
        if (self.first) {
            self.first = false;
        } else {
            try writeByte(self.sink, ',');
        }
    }
};

pub fn newline() void {
    std.debug.print("\n", .{});
}

pub fn appendNewline(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buffer.append(allocator, '\n');
}

pub fn parseValue(allocator: std.mem.Allocator, text: []const u8, options: ParseOptions) !ParsedValue {
    return std.json.parseFromSlice(Value, allocator, text, options);
}

pub fn appendValue(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: Value) !void {
    try jsonValue(allocator, bufferSink(allocator, buffer), value);
}

pub fn appendString(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: []const u8) !void {
    try string(allocator, bufferSink(allocator, buffer), value);
}

pub fn appendInt(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: anytype) !void {
    try int(allocator, bufferSink(allocator, buffer), value);
}

pub fn appendBool(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: bool) !void {
    try writeBytes(bufferSink(allocator, buffer), if (value) "true" else "false");
}

pub fn appendFloat(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: anytype, comptime fmt: []const u8) !void {
    try float(allocator, bufferSink(allocator, buffer), value, fmt);
}

pub fn appendFloat4(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: anytype) !void {
    try appendFloat(allocator, buffer, value, "{d:.4}");
}

pub fn appendNull(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !void {
    try writeBytes(bufferSink(allocator, buffer), "null");
}

pub fn fieldValue(object: *const ObjectMap, key: []const u8) ?*const Value {
    return @constCast(object).getPtr(key);
}

pub fn stringField(object: *const ObjectMap, key: []const u8) ?[]const u8 {
    const value = fieldValue(object, key) orelse return null;
    return if (value.* == .string) value.string else null;
}

pub fn boolField(object: *const ObjectMap, key: []const u8) ?bool {
    const value = fieldValue(object, key) orelse return null;
    return if (value.* == .bool) value.bool else null;
}

pub fn intField(object: *const ObjectMap, key: []const u8) ?i64 {
    const value = fieldValue(object, key) orelse return null;
    return intValue(value.*);
}

pub fn integerField(object: *const ObjectMap, key: []const u8) ?i64 {
    const value = fieldValue(object, key) orelse return null;
    return integerValue(value.*);
}

pub fn usizeField(object: *const ObjectMap, key: []const u8) ?usize {
    const value = intField(object, key) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

pub fn numberField(object: *const ObjectMap, key: []const u8) ?f64 {
    const value = fieldValue(object, key) orelse return null;
    return numberValue(value.*);
}

pub fn objectField(value: Value, key: []const u8) ?*const ObjectMap {
    if (value != .object) return null;
    return objectFieldObject(&value.object, key);
}

pub fn objectFieldObject(object: *const ObjectMap, key: []const u8) ?*const ObjectMap {
    const child = fieldValue(object, key) orelse return null;
    if (child.* != .object) return null;
    return &child.object;
}

pub fn arrayField(value: Value, key: []const u8) ?*const ValueArray {
    if (value != .object) return null;
    return arrayFieldObject(&value.object, key);
}

pub fn arrayFieldObject(object: *const ObjectMap, key: []const u8) ?*const ValueArray {
    const child = fieldValue(object, key) orelse return null;
    if (child.* != .array) return null;
    return &child.array;
}

pub fn intValue(value: Value) ?i64 {
    return switch (value) {
        .integer => |integer| integer,
        .float => |float_value| @intFromFloat(float_value),
        else => null,
    };
}

pub fn integerValue(value: Value) ?i64 {
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

pub fn numberValue(value: Value) ?f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float_value| float_value,
        else => null,
    };
}

fn bufferSink(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) Sink {
    return .{ .buffer = .{ .value = buffer, .allocator = allocator } };
}

fn string(allocator: std.mem.Allocator, sink: Sink, value: []const u8) !void {
    const escaped = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(escaped);
    try writeBytes(sink, escaped);
}

fn jsonValue(allocator: std.mem.Allocator, sink: Sink, value: Value) !void {
    const text = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(text);
    try writeBytes(sink, text);
}

fn int(allocator: std.mem.Allocator, sink: Sink, value: anytype) !void {
    var buf: [32]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{d}", .{value})) |text| {
        try writeBytes(sink, text);
    } else |_| {
        const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
        defer allocator.free(text);
        try writeBytes(sink, text);
    }
}

fn float(allocator: std.mem.Allocator, sink: Sink, value: anytype, comptime fmt: []const u8) !void {
    var buf: [64]u8 = undefined;
    if (std.fmt.bufPrint(&buf, fmt, .{value})) |text| {
        try writeBytes(sink, text);
    } else |_| {
        const text = try std.fmt.allocPrint(allocator, fmt, .{value});
        defer allocator.free(text);
        try writeBytes(sink, text);
    }
}

fn writeByte(sink: Sink, byte: u8) !void {
    switch (sink) {
        .stdout => std.debug.print("{c}", .{byte}),
        .buffer => |buffer| try buffer.value.append(buffer.allocator, byte),
    }
}

fn writeBytes(sink: Sink, text: []const u8) !void {
    switch (sink) {
        .stdout => std.debug.print("{s}", .{text}),
        .buffer => |buffer| try buffer.value.appendSlice(buffer.allocator, text),
    }
}
