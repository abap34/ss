const std = @import("std");
const ast = @import("ast");
const model = @import("model");

// Generation-owned immutable input facts shared by call and dependency analysis.
// Closures borrow syntax from the same generation and own their captured facts.
pub const Value = struct {
    unknown: bool = false,
    candidates: []const Callable = &.{},
    fields: []const Field = &.{},
    children: []const Value = &.{},
    reference: ?Reference = null,
    string_literal: ?[]const u8 = null,
    selected_types: []const ast.Type = &.{},

    pub const Field = struct { name: []const u8, value: Value };
    pub const Callable = union(enum) { function: model.FunctionKey, closure: *const Closure };
    pub const Reference = union(enum) {
        unknown,
        document,
        page,
        placement: struct { call: u64, path: []const usize },
    };
};

pub const Closure = struct {
    module_id: u32,
    lambda: ast.LambdaExpr,
    bindings: []const Value.Field,
};

pub const Entry = struct { input: ast.Type, receiver: Value };

pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .arena = .init(allocator) };
    }

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
    }

    pub fn clear(self: *Store) void {
        _ = self.arena.reset(.free_all);
        self.entries = .empty;
    }
};
