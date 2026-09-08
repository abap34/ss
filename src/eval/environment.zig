const std = @import("std");
const core = @import("core");

pub const Binding = struct {
    value: core.Value,
    owned: bool,

    pub fn deinit(self: *Binding, allocator: std.mem.Allocator) void {
        if (self.owned) self.value.deinit(allocator);
    }
};

// Parent frames and borrowed values must outlive this frame. Only local owned
// bindings are released; aggregate updates operate on owned expression results.
pub const Environment = struct {
    bindings: std.StringHashMap(Binding),
    parent: ?*const Environment = null,

    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{ .bindings = .init(allocator) };
    }

    pub fn child(allocator: std.mem.Allocator, parent: *const Environment) Environment {
        return .{ .bindings = .init(allocator), .parent = parent };
    }

    pub fn deinit(self: *Environment) void {
        var values = self.bindings.valueIterator();
        while (values.next()) |binding| binding.deinit(self.bindings.allocator);
        self.bindings.deinit();
    }

    pub fn get(self: *const Environment, name: []const u8) ?core.Value {
        var frame: ?*const Environment = self;
        while (frame) |current| {
            if (current.bindings.get(name)) |binding| return binding.value;
            frame = current.parent;
        }
        return null;
    }

    // Ownership transfers even when insertion fails.
    pub fn put(self: *Environment, name: []const u8, binding: Binding) !void {
        var moved = binding;
        errdefer moved.deinit(self.bindings.allocator);
        const entry = try self.bindings.getOrPut(name);
        if (entry.found_existing) entry.value_ptr.deinit(self.bindings.allocator);
        entry.value_ptr.* = moved;
    }

    pub fn putOwned(self: *Environment, name: []const u8, value: core.Value) !void {
        return self.put(name, .{ .value = value, .owned = true });
    }

    pub fn putBorrowed(self: *Environment, name: []const u8, value: core.Value) !void {
        return self.put(name, .{ .value = value, .owned = false });
    }

    pub fn capture(allocator: std.mem.Allocator, source: *const Environment, names: []const []const u8) !Environment {
        var result = Environment.init(allocator);
        errdefer result.deinit();
        for (names) |name| {
            // Declarations are resolved in the lambda's defining module.
            const value = source.get(name) orelse continue;
            try result.putOwned(name, try value.clone(allocator));
        }
        return result;
    }
};
