const std = @import("std");
const ast = @import("ast");
const syntax = @import("../../syntax.zig");
const utils = @import("utils");

// Each tree owns the original spelling of names, including names borrowed by
// ast.Type. Semantic resolution may mutate the compiler's separate tree.
const Tree = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    source: []const u8,
    module: *const ast.Module,

    fn capture(allocator: std.mem.Allocator, path: []const u8, source: []const u8, module: ast.Module) !Tree {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const result = try owned.create(ast.Module);
        result.* = try copySyntax(owned, module);
        const owned_path = try owned.dupe(u8, path);
        const owned_source = try owned.dupe(u8, source);
        return .{
            .arena = arena,
            .path = owned_path,
            .source = owned_source,
            .module = result,
        };
    }

    fn parse(allocator: std.mem.Allocator, path: []const u8, source: []const u8, cancellation: ?utils.Cancellation) !Tree {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const owned_path = try owned.dupe(u8, path);
        const owned_source = try owned.dupe(u8, source);
        const parsed = try syntax.parseRecoveringWithOptions(owned, owned_source, owned_path, .{ .cancellation = cancellation });
        const module = try owned.create(ast.Module);
        module.* = parsed.module;
        return .{ .arena = arena, .path = owned_path, .source = owned_source, .module = module };
    }
};

pub const Storage = struct {
    allocator: std.mem.Allocator,
    trees: std.ArrayList(Tree) = .empty,

    pub fn init(allocator: std.mem.Allocator) Storage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Storage) void {
        for (self.trees.items) |*tree| tree.arena.deinit();
        self.trees.deinit(self.allocator);
    }

    pub fn capture(self: *Storage, path: []const u8, source: []const u8, module: ast.Module) !void {
        try self.trees.ensureUnusedCapacity(self.allocator, 1);
        self.trees.appendAssumeCapacity(try Tree.capture(self.allocator, path, source, module));
    }

    pub fn forSource(self: *const Storage, path: []const u8, source: []const u8) ?*const ast.Module {
        for (self.trees.items) |tree| {
            if (std.mem.eql(u8, tree.path, path) and std.mem.eql(u8, tree.source, source)) return tree.module;
        }
        return null;
    }

    pub fn replace(self: *Storage, path: []const u8, source: []const u8, cancellation: ?utils.Cancellation) !void {
        for (self.trees.items) |*tree| {
            if (!std.mem.eql(u8, tree.path, path)) continue;
            const replacement = try Tree.parse(self.allocator, path, source, cancellation);
            tree.arena.deinit();
            tree.* = replacement;
            return;
        }
    }
};

// The AST contains only values, slices, and owned tree pointers. Copy every
// string here: ordinary AST clones intentionally borrow type names. Arena
// ownership also releases a partially copied tree after allocation failure.
fn copySyntax(allocator: std.mem.Allocator, value: anytype) anyerror!@TypeOf(value) {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .one => blk: {
                const result = try allocator.create(pointer.child);
                result.* = try copySyntax(allocator, value.*);
                break :blk result;
            },
            .slice => blk: {
                if (pointer.child == u8) break :blk try allocator.dupe(u8, value);
                const result = try allocator.alloc(pointer.child, value.len);
                for (value, result) |item, *copy| copy.* = try copySyntax(allocator, item);
                break :blk result;
            },
            else => @compileError("Unsupported AST pointer"),
        },
        .optional => if (value) |item| try copySyntax(allocator, item) else null,
        .@"union" => switch (value) {
            inline else => |item, tag| @unionInit(T, @tagName(tag), try copySyntax(allocator, item)),
        },
        .@"struct" => |structure| blk: {
            var result: T = undefined;
            inline for (structure.fields) |field| @field(result, field.name) = try copySyntax(allocator, @field(value, field.name));
            if (@hasField(T, "items") and @hasField(T, "capacity")) result.capacity = result.items.len;
            break :blk result;
        },
        else => value,
    };
}
