const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const contracts = @import("../analysis/contracts.zig");

pub const Arity = struct {
    min: usize,
    max: usize,
};

pub fn arity(func: ast.FunctionDecl) Arity {
    return .{
        .min = contracts.requiredParamCount(func),
        .max = func.params.items.len,
    };
}

pub fn requireArity(actual: usize, func: ast.FunctionDecl) !void {
    const range = arity(func);
    if (actual < range.min or actual > range.max) return error.InvalidArity;
}

pub fn requireReturnsValue(func: ast.FunctionDecl) !void {
    if (!contracts.functionContract(func).returns_value) return error.FunctionDoesNotReturnValue;
}

pub fn functionRefFor(allocator: std.mem.Allocator, func: ast.FunctionDecl) !core.FunctionRef {
    return contracts.functionRefFor(allocator, func);
}
