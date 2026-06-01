const std = @import("std");
const ast = @import("ast");
const core = @import("core");

pub const FunctionContract = struct {
    min_param_count: usize,
    max_param_count: usize,
    returns_value: bool,
    result_tag: core.ValueTag,
};

pub fn valueTag(value: core.Value) core.ValueTag {
    return switch (value) {
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
        .void => .void,
    };
}

pub fn ensureValueType(
    ir: anytype,
    page_id: ?core.NodeId,
    value: core.Value,
    expected: core.ValueTag,
    origin: []const u8,
) !void {
    return ensureValueTypeWithCode(ir, page_id, value, expected, origin, .UnmatchedArgumentType);
}

pub fn ensureValueTypeWithCode(
    ir: anytype,
    page_id: ?core.NodeId,
    value: core.Value,
    expected: core.ValueTag,
    origin: []const u8,
    code: core.TypeMismatchCode,
) !void {
    const actual = valueTag(value);
    if (actual != expected) {
        try ir.addValidationDiagnostic(.@"error", page_id, null, origin, .{
            .type_mismatch = .{ .code = code, .expected = expected, .actual = actual },
        });
        return error.InvalidValueTag;
    }
}

pub fn functionRefFor(allocator: std.mem.Allocator, func: ast.FunctionDecl) !core.FunctionRef {
    _ = allocator;
    const contract = functionContract(func);
    return .{
        .name = func.name,
        .param_count = contract.max_param_count,
        .returns_value = contract.returns_value,
        .effect = .unknown,
    };
}

pub fn functionContract(func: ast.FunctionDecl) FunctionContract {
    return .{
        .min_param_count = requiredParamCount(func),
        .max_param_count = func.params.items.len,
        .returns_value = functionReturnsValue(func),
        .result_tag = func.result_tag,
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
    return func.result_tag != .void;
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
