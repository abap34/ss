const std = @import("std");

const language_names = @import("../language/names.zig");

pub fn isDiscardBindingName(name: []const u8) bool {
    return language_names.isDiscardBindingName(name);
}

pub fn ValueEnv(comptime Value: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        values: std.StringHashMap(Value),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .values = std.StringHashMap(Value).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.values.deinit();
        }

        pub fn clone(self: *const Self) !Self {
            return .{
                .allocator = self.allocator,
                .values = try self.values.clone(),
            };
        }

        pub fn bind(self: *Self, name: []const u8, value: Value) !void {
            try self.values.put(name, value);
        }

        pub fn bindLet(self: *Self, name: []const u8, value: Value) !bool {
            if (isDiscardBindingName(name)) return false;
            try self.bind(name, value);
            return true;
        }

        pub fn lookup(self: *const Self, name: []const u8) ?Value {
            return self.values.get(name);
        }

        pub fn contains(self: *const Self, name: []const u8) bool {
            return self.values.contains(name);
        }

        pub fn put(self: *Self, name: []const u8, value: Value) !void {
            try self.bind(name, value);
        }

        pub fn get(self: *const Self, name: []const u8) ?Value {
            return self.lookup(name);
        }
    };
}

pub const NameEnv = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) NameEnv {
        return .{
            .allocator = allocator,
            .values = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *NameEnv) void {
        self.values.deinit();
    }

    pub fn clone(self: *const NameEnv) !NameEnv {
        return .{
            .allocator = self.allocator,
            .values = try self.values.clone(),
        };
    }

    pub fn put(self: *NameEnv, name: []const u8) !void {
        try self.values.put(name, {});
    }

    pub fn bind(self: *NameEnv, name: []const u8) !void {
        try self.put(name);
    }

    pub fn bindLet(self: *NameEnv, name: []const u8) !bool {
        if (isDiscardBindingName(name)) return false;
        try self.put(name);
        return true;
    }

    pub fn contains(self: *const NameEnv, name: []const u8) bool {
        return self.values.contains(name);
    }
};

pub fn CloneEnv(
    comptime Value: type,
    comptime cloneValue: fn (std.mem.Allocator, Value) anyerror!Value,
    comptime deinitValue: fn (*Value) void,
) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        values: std.StringHashMap(Value),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .values = std.StringHashMap(Value).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var iterator = self.values.valueIterator();
            while (iterator.next()) |value| deinitValue(value);
            self.values.deinit();
        }

        pub fn clone(self: *const Self) !Self {
            var out = init(self.allocator);
            errdefer out.deinit();
            var iterator = self.values.iterator();
            while (iterator.next()) |entry| {
                try out.bind(entry.key_ptr.*, entry.value_ptr.*);
            }
            return out;
        }

        pub fn bind(self: *Self, name: []const u8, value: Value) !void {
            var owned = try cloneValue(self.allocator, value);
            errdefer deinitValue(&owned);
            const entry = try self.values.getOrPut(name);
            if (entry.found_existing) deinitValue(entry.value_ptr);
            entry.value_ptr.* = owned;
        }

        pub fn bindLet(self: *Self, name: []const u8, value: Value) !bool {
            if (isDiscardBindingName(name)) return false;
            try self.bind(name, value);
            return true;
        }

        pub fn lookup(self: *const Self, name: []const u8) ?Value {
            return self.values.get(name);
        }

        pub fn contains(self: *const Self, name: []const u8) bool {
            return self.values.contains(name);
        }

        pub fn put(self: *Self, name: []const u8, value: Value) !void {
            try self.bind(name, value);
        }

        pub fn get(self: *const Self, name: []const u8) ?Value {
            return self.lookup(name);
        }
    };
}
