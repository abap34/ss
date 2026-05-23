const std = @import("std");
const ast = @import("ast");
const core = @import("core");

pub const FunctionContract = struct {
    min_param_count: usize,
    max_param_count: usize,
    returns_value: bool,
    result_sort: core.SemanticSort,
};

pub fn valueSort(value: core.Value) core.SemanticSort {
    return switch (value) {
        .code => .code,
        .document => .document,
        .page => .page,
        .object => .object,
        .metadata => .metadata,
        .selection => .selection,
        .anchor => .anchor,
        .function => .function,
        .style => .style,
        .string => .string,
        .number => .number,
        .boolean => .boolean,
        .constraints => .constraints,
        .fragment => .fragment,
        .void => .void,
    };
}

pub fn ensureValueSort(
    ir: anytype,
    page_id: ?core.NodeId,
    value: core.Value,
    expected: core.SemanticSort,
    origin: []const u8,
) !void {
    return ensureValueSortWithCode(ir, page_id, value, expected, origin, .UnmatchedArgumentType);
}

pub fn ensureValueSortWithCode(
    ir: anytype,
    page_id: ?core.NodeId,
    value: core.Value,
    expected: core.SemanticSort,
    origin: []const u8,
    code: core.TypeMismatchCode,
) !void {
    const actual = valueSort(value);
    if (actual == .code) {
        const code_value = value.code;
        if (expected == .code or code_value.sort() == expected) return;
    }
    if (actual != expected) {
        try ir.addValidationDiagnostic(.@"error", page_id, null, origin, .{
            .type_mismatch = .{ .code = code, .expected = expected, .actual = actual },
        });
        return error.InvalidSemanticSort;
    }
}

pub fn functionRefFor(allocator: std.mem.Allocator, func: ast.FunctionDecl) !core.FunctionRef {
    const contract = functionContract(func);
    const param_sorts = try allocator.alloc(core.SemanticSort, func.params.items.len);
    for (func.params.items, 0..) |param, index| {
        param_sorts[index] = param.sort;
    }
    return .{
        .name = func.name,
        .param_count = contract.max_param_count,
        .param_sorts = param_sorts,
        .returns_value = contract.returns_value,
        .result_sort = contract.result_sort,
        .effect = .unknown,
    };
}

pub fn functionContract(func: ast.FunctionDecl) FunctionContract {
    return .{
        .min_param_count = requiredParamCount(func),
        .max_param_count = func.params.items.len,
        .returns_value = functionReturnsValue(func),
        .result_sort = func.result_sort,
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
    return func.result_sort != .void;
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
