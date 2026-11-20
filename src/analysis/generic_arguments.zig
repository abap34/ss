const std = @import("std");
const ast = @import("ast");

/// Collects unique, concrete substitutions from the structural positions of a
/// parameter type. Ordinary argument compatibility is checked after substitution.
pub fn infer(pattern: ast.Type, actual: ast.Type, parameters: []ast.Type.Substitution, known: []bool) !void {
    if (pattern.parameter_id) |id| {
        for (parameters, known) |*binding, *is_known| {
            if (!std.meta.eql(binding.parameter, id)) continue;
            if (!isConcrete(actual)) return;
            if (is_known.*) {
                if (!ast.Type.eql(binding.replacement, actual)) return error.ConflictingTypeArguments;
                return;
            }
            binding.replacement = actual;
            is_known.* = true;
            return;
        }
        return;
    }
    if (pattern.optional_child) |child| {
        if (actual.kind == .none) return;
        return infer(child.*, if (actual.optional_child) |inner| inner.* else actual, parameters, known);
    }
    if (pattern.kind != actual.kind) return;
    if (pattern.fn_params.len == actual.fn_params.len) {
        for (pattern.fn_params, actual.fn_params) |left, right| try infer(left, right, parameters, known);
    }
    if (pattern.fn_result) |result| {
        if (actual.fn_result) |actual_result| try infer(result.*, actual_result.*, parameters, known);
    }
    if (pattern.arguments.len == actual.arguments.len) {
        for (pattern.arguments, actual.arguments) |left, right| try infer(left, right, parameters, known);
    }
}

pub fn isConcrete(ty: ast.Type) bool {
    switch (ty.kind) {
        .any, .hole, .parameter, .none, .void => return false,
        else => {},
    }
    for (ty.arguments) |argument| if (!isConcrete(argument)) return false;
    for (ty.fn_params) |parameter| if (!isConcrete(parameter)) return false;
    if (ty.fn_result) |result| if (result.kind != .void and !isConcrete(result.*)) return false;
    if (ty.optional_child) |child| if (!isConcrete(child.*)) return false;
    return true;
}

pub const Arguments = struct {
    bindings: []ast.Type.Substitution,
    known: []bool,

    pub fn init(allocator: std.mem.Allocator, module_id: u32, start: usize, count: usize) !Arguments {
        const bindings = try allocator.alloc(ast.Type.Substitution, count);
        errdefer allocator.free(bindings);
        const known = try allocator.alloc(bool, count);
        @memset(known, false);
        for (bindings, 0..) |*b, i| b.* = .{
            .parameter = .{ .module_id = module_id, .declaration_start = start, .index = @intCast(i) },
            .replacement = ast.Type.any,
        };
        return .{ .bindings = bindings, .known = known };
    }

    pub fn deinit(self: Arguments, allocator: std.mem.Allocator) void {
        allocator.free(self.known);
        allocator.free(self.bindings);
    }

    pub fn explicit(self: Arguments, supplied: []const ast.Type) !void {
        if (supplied.len != self.bindings.len) return error.InvalidTypeArity;
        for (self.bindings, supplied, self.known) |*b, ty, *k| {
            b.replacement = ty;
            k.* = isConcrete(ty);
        }
    }

    pub fn match(self: Arguments, pattern: ast.Type, actual: ast.Type) !void {
        return infer(pattern, actual, self.bindings, self.known);
    }

    pub fn determines(self: Arguments, result: ast.Type) bool {
        for (self.bindings, self.known) |b, known| if (!known and mentions(result, b.parameter)) return false;
        return true;
    }

    pub fn constrains(self: Arguments, pattern: ast.Type, result: ast.Type) bool {
        for (self.bindings) |b| if (mentions(result, b.parameter) and mentions(pattern, b.parameter)) return true;
        return false;
    }
};

fn containsParameter(ty: ast.Type, id: ?ast.Type.ParameterId) bool {
    if (ty.parameter_id) |p| return id == null or std.meta.eql(p, id.?);
    if (ty.optional_child) |child| if (containsParameter(child.*, id)) return true;
    if (ty.fn_result) |result| if (containsParameter(result.*, id)) return true;
    for (ty.arguments) |arg| if (containsParameter(arg, id)) return true;
    for (ty.fn_params) |param| if (containsParameter(param, id)) return true;
    return false;
}

pub fn hasParameter(ty: ast.Type) bool {
    return containsParameter(ty, null);
}

pub fn mentions(ty: ast.Type, id: ast.Type.ParameterId) bool {
    return containsParameter(ty, id);
}
