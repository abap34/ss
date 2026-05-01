const std = @import("std");

pub const Object = struct {
    allocator: std.mem.Allocator,
    first: bool = true,

    pub fn begin(allocator: std.mem.Allocator) Object {
        std.debug.print("{{", .{});
        return .{ .allocator = allocator };
    }

    pub fn end(self: *Object) void {
        _ = self;
        std.debug.print("}}", .{});
    }

    pub fn arrayField(self: *Object, key: []const u8) !Array {
        try self.fieldName(key);
        std.debug.print("[", .{});
        return .{ .allocator = self.allocator };
    }

    pub fn stringField(self: *Object, key: []const u8, value: []const u8) !void {
        try self.fieldName(key);
        try string(self.allocator, value);
    }

    pub fn enumTagField(self: *Object, key: []const u8, value: anytype) !void {
        try self.stringField(key, @tagName(value));
    }

    pub fn intField(self: *Object, key: []const u8, value: anytype) !void {
        try self.fieldName(key);
        std.debug.print("{d}", .{value});
    }

    pub fn optionalStringField(self: *Object, key: []const u8, value: ?[]const u8) !void {
        try self.fieldName(key);
        if (value) |text| {
            try string(self.allocator, text);
        } else {
            nullValue();
        }
    }

    fn fieldName(self: *Object, key: []const u8) !void {
        try self.comma();
        try string(self.allocator, key);
        std.debug.print(":", .{});
    }

    fn comma(self: *Object) !void {
        if (self.first) {
            self.first = false;
        } else {
            std.debug.print(",", .{});
        }
    }
};

pub const Array = struct {
    allocator: std.mem.Allocator,
    first: bool = true,

    pub fn end(self: *Array) void {
        _ = self;
        std.debug.print("]", .{});
    }

    pub fn objectItem(self: *Array) !Object {
        try self.comma();
        std.debug.print("{{", .{});
        return .{ .allocator = self.allocator };
    }

    pub fn stringItem(self: *Array, value: []const u8) !void {
        try self.comma();
        try string(self.allocator, value);
    }

    fn comma(self: *Array) !void {
        if (self.first) {
            self.first = false;
        } else {
            std.debug.print(",", .{});
        }
    }
};

pub fn newline() void {
    std.debug.print("\n", .{});
}

fn string(allocator: std.mem.Allocator, value: []const u8) !void {
    const escaped = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(escaped);
    std.debug.print("{s}", .{escaped});
}

fn nullValue() void {
    std.debug.print("null", .{});
}

pub fn appendFieldPrefix(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), key: []const u8) !void {
    try appendString(allocator, buffer, key);
    try buffer.appendSlice(allocator, ": ");
}

pub fn appendTrailingComma(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), trailing_comma: bool) !void {
    if (trailing_comma) try buffer.appendSlice(allocator, ", ");
}

pub fn appendObjectFieldStart(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), key: []const u8) !void {
    try appendFieldPrefix(allocator, buffer, key);
    try buffer.append(allocator, '{');
}

pub fn appendFieldString(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    value: []const u8,
    trailing_comma: bool,
) !void {
    try appendFieldPrefix(allocator, buffer, key);
    try appendString(allocator, buffer, value);
    try appendTrailingComma(allocator, buffer, trailing_comma);
}

pub fn appendFieldInt(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    value: anytype,
    trailing_comma: bool,
) !void {
    try appendFieldPrefix(allocator, buffer, key);
    try appendInt(allocator, buffer, value);
    try appendTrailingComma(allocator, buffer, trailing_comma);
}

pub fn appendFieldFloat(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    value: f32,
    trailing_comma: bool,
) !void {
    try appendFieldPrefix(allocator, buffer, key);
    try appendFloat(allocator, buffer, value, "{d:.1}");
    try appendTrailingComma(allocator, buffer, trailing_comma);
}

pub fn appendFieldNull(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    trailing_comma: bool,
) !void {
    try appendFieldPrefix(allocator, buffer, key);
    try buffer.appendSlice(allocator, "null");
    try appendTrailingComma(allocator, buffer, trailing_comma);
}

pub fn appendFieldBool(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    value: bool,
    trailing_comma: bool,
) !void {
    try appendFieldPrefix(allocator, buffer, key);
    try buffer.appendSlice(allocator, if (value) "true" else "false");
    try appendTrailingComma(allocator, buffer, trailing_comma);
}

pub fn appendFieldOptionalString(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    value: ?[]const u8,
    trailing_comma: bool,
) !void {
    if (value) |text| {
        try appendFieldString(allocator, buffer, key, text, trailing_comma);
    } else {
        try appendFieldNull(allocator, buffer, key, trailing_comma);
    }
}

pub fn appendFieldOptionalInt(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    value: anytype,
    trailing_comma: bool,
) !void {
    if (value) |number| {
        try appendFieldInt(allocator, buffer, key, number, trailing_comma);
    } else {
        try appendFieldNull(allocator, buffer, key, trailing_comma);
    }
}

pub fn appendFieldOptionalEnumTag(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    value: anytype,
    trailing_comma: bool,
) !void {
    if (value) |tagged| {
        try appendFieldString(allocator, buffer, key, @tagName(tagged), trailing_comma);
    } else {
        try appendFieldNull(allocator, buffer, key, trailing_comma);
    }
}

pub fn appendInt(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(text);
    try buffer.appendSlice(allocator, text);
}

pub fn appendFloatValue(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: f32) !void {
    try appendFloat(allocator, buffer, value, "{d:.4}");
}

pub fn appendString(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: []const u8) !void {
    const escaped = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(escaped);
    try buffer.appendSlice(allocator, escaped);
}

fn appendFloat(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    value: f32,
    comptime fmt: []const u8,
) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, .{value});
    defer allocator.free(text);
    try buffer.appendSlice(allocator, text);
}
