const std = @import("std");
const Type = @import("ast").Type;

// Query facts borrow these types until their snapshot is destroyed.
pub const Storage = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) Storage {
        return .{ .arena = .init(allocator) };
    }

    pub fn deinit(self: *Storage) void {
        self.arena.deinit();
    }

    pub fn retain(self: *Storage, source: Type) anyerror!Type {
        const allocator = self.arena.allocator();
        var result = source;
        if (source.class_name) |name| result.class_name = try allocator.dupe(u8, name);
        if (source.param_class_name) |name| result.param_class_name = try allocator.dupe(u8, name);
        if (source.enum_name) |name| result.enum_name = try allocator.dupe(u8, name);
        if (source.optional_child) |child| {
            result.optional_child = try allocator.create(Type);
            result.optional_child.?.* = try self.retain(child.*);
        }
        if (source.fn_result) |child| {
            result.fn_result = try allocator.create(Type);
            result.fn_result.?.* = try self.retain(child.*);
        }
        result.fn_params = try allocator.alloc(Type, source.fn_params.len);
        for (source.fn_params, result.fn_params) |param, *retained| retained.* = try self.retain(param);
        return result;
    }
};
