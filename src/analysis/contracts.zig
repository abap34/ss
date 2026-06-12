const std = @import("std");
const ast = @import("ast");
const core = @import("core");

pub const FunctionContract = struct {
    min_param_count: usize,
    max_param_count: usize,
    returns_value: bool,
};

pub fn functionRefFor(allocator: std.mem.Allocator, func: ast.FunctionDecl) !core.FunctionRef {
    return functionRefForInModule(allocator, 0, func);
}

pub fn functionRefForInModule(allocator: std.mem.Allocator, module_id: core.SourceModuleId, func: ast.FunctionDecl) !core.FunctionRef {
    _ = allocator;
    const contract = functionContract(func);
    return .{
        .name = func.name,
        .module_id = module_id,
        .param_count = contract.max_param_count,
        .returns_value = contract.returns_value,
    };
}

pub fn functionContract(func: ast.FunctionDecl) FunctionContract {
    return .{
        .min_param_count = requiredParamCount(func),
        .max_param_count = func.params.items.len,
        .returns_value = functionReturnsValue(func),
    };
}

pub fn requiredParamCount(func: ast.FunctionDecl) usize {
    var required: usize = 0;
    for (func.params.items) |param| {
        if (param.default_value == null) required += 1;
    }
    return required;
}

pub fn functionReturnsValue(func: ast.FunctionDecl) bool {
    return func.result_type.kind != .void;
}

pub fn functionBodyReturns(statements: []const ast.Statement) bool {
    for (statements) |stmt| {
        switch (stmt.kind) {
            .return_expr => return true,
            .return_void => return true,
            .if_stmt => |if_stmt| {
                if (functionBodyReturns(if_stmt.then_statements.items) and functionBodyReturns(if_stmt.else_statements.items)) return true;
            },
            else => {},
        }
    }
    return false;
}
