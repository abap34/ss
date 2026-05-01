const std = @import("std");

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
        try writeByte(.{ .buffer = .{ .value = buffer, .allocator = allocator } }, '{');
        return .{ .allocator = allocator, .sink = .{ .buffer = .{ .value = buffer, .allocator = allocator } } };
    }

    pub fn end(self: *Object) void {
        writeByte(self.sink, '}') catch unreachable;
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

    pub fn end(self: *Array) void {
        writeByte(self.sink, ']') catch unreachable;
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

fn string(allocator: std.mem.Allocator, sink: Sink, value: []const u8) !void {
    const escaped = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(escaped);
    try writeBytes(sink, escaped);
}

fn int(allocator: std.mem.Allocator, sink: Sink, value: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(text);
    try writeBytes(sink, text);
}

fn float(allocator: std.mem.Allocator, sink: Sink, value: f32, comptime fmt: []const u8) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, .{value});
    defer allocator.free(text);
    try writeBytes(sink, text);
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
