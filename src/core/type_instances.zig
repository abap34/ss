const std = @import("std");
const ast = @import("ast");
const model = @import("model");

const TypeContext = struct {
    pub fn hash(_: TypeContext, ty: ast.Type) u64 {
        var hasher = std.hash.Wyhash.init(0);
        ty.hashInto(&hasher);
        return hasher.final();
    }

    pub fn eql(_: TypeContext, a: ast.Type, b: ast.Type) bool {
        return ast.Type.eql(a, b);
    }
};

pub const Instance = struct {
    ty: ast.Type,
    declaration: ast.RecordDecl,
    status: enum { checking, checked, failed } = .checking,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(*Instance) = .empty,
    index: std.HashMap(ast.Type, *Instance, TypeContext, std.hash_map.default_max_load_percentage),
    construction_targets: std.AutoHashMap(u64, *Instance),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator, .index = .init(allocator), .construction_targets = .init(allocator) };
    }

    pub fn deinit(self: *Store) void {
        self.index.deinit();
        self.construction_targets.deinit();
        for (self.entries.items) |entry| {
            entry.ty.deinit(self.allocator);
            entry.declaration.deinit(self.allocator);
            self.allocator.destroy(entry);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn find(self: *const Store, ty: ast.Type) ?*Instance {
        return self.index.get(ty);
    }

    pub fn construction(self: *const Store, expr: ast.RecordExpr) ?*Instance {
        return self.construction_targets.get(expr.analysis_id orelse return null);
    }

    pub fn isChecking(self: *const Store, definition: model.NominalId) bool {
        for (self.entries.items) |entry| {
            if (entry.status == .checking and entry.ty.nominalId().?.eql(definition)) return true;
        }
        return false;
    }

    /// Adopts the declaration on success and clones the complete concrete type.
    pub fn add(self: *Store, ty: ast.Type, declaration: ast.RecordDecl) !*Instance {
        var owned_type = try ty.clone(self.allocator);
        errdefer owned_type.deinit(self.allocator);
        const entry = try self.allocator.create(Instance);
        errdefer self.allocator.destroy(entry);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        entry.* = .{ .ty = owned_type, .declaration = declaration };
        try self.index.put(entry.ty, entry);
        self.entries.appendAssumeCapacity(entry);
        return entry;
    }
};

/// The substitutions borrow their replacements from the applied type.
pub fn substitutions(allocator: std.mem.Allocator, ty: ast.Type, decl: ast.RecordDecl) ![]ast.Type.Substitution {
    if (ty.arguments.len != decl.type_params.items.len) return error.InvalidType;
    const result = try allocator.alloc(ast.Type.Substitution, ty.arguments.len);
    for (result, ty.arguments, 0..) |*binding, argument, index| {
        binding.* = .{
            .parameter = .{ .module_id = ty.nominal_module_id.?, .declaration_start = decl.span.start, .index = @intCast(index) },
            .replacement = argument,
        };
    }
    return result;
}
