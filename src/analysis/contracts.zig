const std = @import("std");
const ast = @import("ast");
const core = @import("core");

pub fn functionRefForInModule(allocator: std.mem.Allocator, module_id: core.SourceModuleId, func: ast.FunctionDecl) !core.FunctionRef {
    _ = allocator;
    return .{
        .name = func.name,
        .module_id = module_id,
    };
}

pub fn requiredParamCount(func: ast.FunctionDecl) usize {
    var required: usize = 0;
    for (func.params.items) |param| {
        if (param.default_value == null) required += 1;
    }
    return required;
}

pub fn functionBodyReturns(statements: []const ast.Statement) bool {
    for (statements) |stmt| {
        switch (stmt.kind) {
            .return_expr => return true,
            .return_void => return true,
            .drawing => |block| {
                if (functionBodyReturns(block.then_statements.items)) return true;
            },
            .if_stmt => |if_stmt| {
                if (functionBodyReturns(if_stmt.then_statements.items) and functionBodyReturns(if_stmt.else_statements.items)) return true;
            },
            else => {},
        }
    }
    return false;
}
