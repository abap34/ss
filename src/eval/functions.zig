const ast = @import("ast");

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
