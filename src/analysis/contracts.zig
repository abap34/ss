const std = @import("std");
const ast = @import("ast");
const core = @import("core");

pub const FunctionContract = struct {
    min_param_count: usize,
    max_param_count: usize,
    returns_value: bool,
};

pub fn runtimeKind(value: core.Value) core.ValueTag {
    return switch (value) {
        .none => .none,
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
    const actual = runtimeKind(value);
    if (actual != expected) {
        try ir.addValidationDiagnostic(.@"error", page_id, null, origin, .{
            .type_mismatch = .{ .code = code, .expected = expected, .actual = actual },
        });
        return error.InvalidValueTag;
    }
}

pub fn ensureValueConformsToType(
    ir: anytype,
    page_id: ?core.NodeId,
    value: core.Value,
    expected: ast.Type,
    origin: []const u8,
    code: core.TypeMismatchCode,
) !void {
    if (valueConformsToType(value, expected)) return;

    const actual = runtimeKind(value);
    if (expectedRuntimeKind(expected)) |expected_kind| {
        try ir.addValidationDiagnostic(.@"error", page_id, null, origin, .{
            .type_mismatch = .{ .code = code, .expected = expected_kind, .actual = actual },
        });
    } else {
        try ir.addValidationDiagnostic(.@"error", page_id, null, origin, .{
            .user_report = .{
                .message = try std.fmt.allocPrint(
                    ir.allocator,
                    "TypeMismatch: expected {s}, got {s}",
                    .{ expectedRuntimeLabel(expected), @tagName(actual) },
                ),
            },
        });
    }
    return error.InvalidValueTag;
}

pub fn valueConformsToType(value: core.Value, expected: ast.Type) bool {
    if (expected.kind == .any) return true;
    if (expected.kind == .optional) {
        if (runtimeKind(value) == .none) return true;
        const child = expected.optional_child orelse return false;
        return valueConformsToType(value, child.*);
    }
    const expected_kind = expectedRuntimeKind(expected) orelse return false;
    return runtimeKind(value) == expected_kind;
}

fn expectedRuntimeKind(expected: ast.Type) ?core.ValueTag {
    return switch (expected.kind) {
        .none => .none,
        .document => .document,
        .page => .page,
        .object => .object,
        .metadata => .metadata,
        .selection => .selection,
        .anchor => .anchor,
        .function => .function,
        .style => .style,
        .string, .color, .enum_type => .string,
        .number => .number,
        .boolean => .boolean,
        .constraints => .constraints,
        .void => .void,
        .optional, .any => null,
    };
}

fn expectedRuntimeLabel(expected: ast.Type) []const u8 {
    return expected.label();
}

pub fn functionRefFor(allocator: std.mem.Allocator, func: ast.FunctionDecl) !core.FunctionRef {
    _ = allocator;
    const contract = functionContract(func);
    return .{
        .name = func.name,
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
