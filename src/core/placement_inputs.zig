const std = @import("std");
const ast = @import("ast");
const model = @import("model");

/// A small may-analysis shared by the call checker and the scheduler. Bottom
/// means no evidence has arrived; runtime values of unknown truth are both.
pub const Alternatives = enum(u2) {
    bottom = 0,
    no = 1,
    yes = 2,
    either = 3,

    pub fn from(value: bool) Alternatives {
        return if (value) .yes else .no;
    }

    pub fn join(a: Alternatives, b: Alternatives) Alternatives {
        return @fromBackingInt(@intCast(@backingInt(a) | @backingInt(b)));
    }

    pub fn negate(self: Alternatives) Alternatives {
        return switch (self) {
            .no => .yes,
            .yes => .no,
            else => self,
        };
    }

    pub fn orUnknown(self: Alternatives) Alternatives {
        return if (self == .bottom) .either else self;
    }
};

// Page index after stage expansion, before the execution graph assigns node IDs.
pub const PageKey = struct { module_id: u32, index: usize };

// Facts about normal evaluation, kept separately from a selection's possible
// elements. An empty selection is a value; first(empty) produces no value.
pub const ReadPath = struct {
    items: Alternatives = .bottom,
    no_value: bool = false,
    unknown_target: bool = false,

    pub fn eql(a: ReadPath, b: ReadPath) bool {
        return std.meta.eql(a, b);
    }

    pub fn join(a: ReadPath, b: ReadPath) ReadPath {
        if (a.no_value) return b;
        if (b.no_value) return a;
        return .{ .items = a.items.join(b.items), .unknown_target = a.unknown_target or b.unknown_target };
    }

    pub fn selection(self: ReadPath, items: Alternatives) ReadPath {
        var path = self;
        path.items = items;
        return path;
    }

    pub fn membership(self: ReadPath) Alternatives {
        return if (self.items == .bottom) .either else self.items;
    }

    pub fn element(self: ReadPath) ReadPath {
        return if (self.items == .no) .{ .no_value = true } else self.selection(.bottom);
    }

    // An empty collection contributes its membership, never a candidate
    // element. Non-selection values use the ordinary value join.
    pub fn emptyOperand(left: ReadPath, right: ReadPath) ?enum { left, right } {
        if (left.items == .bottom or right.items == .bottom or left.items == right.items) return null;
        return if (left.items == .no) .left else if (right.items == .no) .right else null;
    }

    pub fn filtered(self: ReadPath, predicate: Alternatives) ReadPath {
        return self.selection(if (self.items == .no or predicate == .no) .no else if (predicate == .yes) self.membership() else .either);
    }

    pub const SetOp = enum { sum, intersection, difference };

    pub fn setMembership(op: SetOp, left: ReadPath, right: ReadPath) Alternatives {
        const a = left.membership();
        const b = right.membership();
        return switch (op) {
            .sum => if (a == .yes or b == .yes) .yes else if (a == .no) b else if (b == .no) a else .either,
            .intersection => if (a == .no or b == .no) .no else .either,
            .difference => if (a == .no) .no else if (b == .no) a else .either,
        };
    }

    // Called after discovery, in the caller's abstract argument environment.
    pub fn reads(self: ReadPath, targets: BindingTargets) error{UnresolvedPlacementReference}![]const u32 {
        if (self.no_value) return &.{};
        if (self.unknown_target or targets.ids.len == 0) return error.UnresolvedPlacementReference;
        return targets.ids;
    }
};

// Generation-owned immutable input facts shared by call and dependency analysis.
// Closures borrow syntax from the same generation and own their captured facts.
pub const Value = struct {
    path: ReadPath = .{},
    unknown: bool = false,
    truth: Alternatives = .bottom,
    present: Alternatives = .bottom,
    targets: BindingTargets = .{},
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
        page: ?PageKey,
        placement: struct { call: u64, path: []const usize },
    };
};

pub const Closure = struct {
    pub const ScheduledBinding = struct { name: []const u8, id: u32 };

    module_id: u32,
    lambda: ast.LambdaExpr,
    bindings: []const Value.Field,
    // Scheduled captures point into Store.bindings. Expanding them recursively
    // would turn a finite cyclic environment into an infinite value tree.
    scheduled: []const ScheduledBinding = &.{},
};

pub const Entry = struct { input: ast.Type, receiver: Value };

// Group closed dereference facts by the unit that will evaluate the read.
// The statement identity is from the expanded module, so two callers or two
// stages sharing a callee (and a source span) never acquire each other's edges.
pub const ReadUnit = struct {
    statement: *const ast.Statement,
    phase: enum { statement, display, drawing } = .statement,
    call: u64 = 0,
    step: usize = 0,

    pub fn display(self: ReadUnit, call: u64, step: usize) ReadUnit {
        return .{ .statement = self.statement, .phase = .display, .call = call, .step = step };
    }

    pub fn drawing(self: ReadUnit, call: u64) ReadUnit {
        return .{ .statement = self.statement, .phase = .drawing, .call = call };
    }
};

pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    bindings: []const Value = &.{},
    reads: std.AutoHashMapUnmanaged(ReadUnit, BindingTargets) = .empty,

    pub fn recordRead(self: *Store, unit: ReadUnit, targets: BindingTargets) !void {
        const arena = self.arena.allocator();
        const entry = try self.reads.getOrPut(arena, unit);
        const old: BindingTargets = if (entry.found_existing) entry.value_ptr.* else .{};
        const all = try old.merge(targets, arena);
        // merge can borrow either input; the observation was made in a shorter-lived arena.
        entry.value_ptr.* = if (all.ids.ptr == targets.ids.ptr) .{ .ids = try arena.dupe(u32, all.ids) } else all;
    }

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .arena = .init(allocator) };
    }

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
    }

    pub fn clear(self: *Store) void {
        _ = self.arena.reset(.free_all);
        self.reads = .empty;
        self.entries = .empty;
        self.bindings = &.{};
    }
};

// Sorted, immutable binding IDs. Copies through records and closures share the
// same set; joining an existing subset allocates nothing.
pub const BindingTargets = struct {
    ids: []const u32 = &.{},

    pub fn eql(a: BindingTargets, b: BindingTargets) bool {
        return std.mem.eql(u32, a.ids, b.ids);
    }

    pub fn one(allocator: std.mem.Allocator, id: u32) !BindingTargets {
        return .{ .ids = try allocator.dupe(u32, &.{id}) };
    }

    pub fn merge(a: BindingTargets, b: BindingTargets, allocator: std.mem.Allocator) !BindingTargets {
        if (a.ids.len == 0) return b;
        if (b.ids.len == 0 or a.ids.ptr == b.ids.ptr and a.ids.len == b.ids.len) return a;
        var i: usize = 0;
        var j: usize = 0;
        var shared: usize = 0;
        while (i < a.ids.len and j < b.ids.len) {
            if (a.ids[i] == b.ids[j]) {
                shared += 1;
                i += 1;
                j += 1;
            } else if (a.ids[i] < b.ids[j]) i += 1 else j += 1;
        }
        if (shared == b.ids.len) return a;
        if (shared == a.ids.len) return b;
        const result = try allocator.alloc(u32, a.ids.len + b.ids.len - shared);
        i = 0;
        j = 0;
        for (result) |*id| {
            if (j == b.ids.len or (i < a.ids.len and a.ids[i] < b.ids[j])) {
                id.* = a.ids[i];
                i += 1;
            } else {
                id.* = b.ids[j];
                j += 1;
                if (i < a.ids.len and a.ids[i] == id.*) i += 1;
            }
        }
        return .{ .ids = result };
    }
};
