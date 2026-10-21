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

pub fn functionRefForInModule(allocator: std.mem.Allocator, module_id: core.SourceModuleId, func: ast.FunctionDecl) !core.FunctionRef {
    return contracts.functionRefForInModule(allocator, module_id, func);
}
