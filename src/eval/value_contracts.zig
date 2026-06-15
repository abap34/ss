const std = @import("std");
const ast = @import("ast");
const core = @import("core");

pub fn runtimeKind(value: core.Value) core.ValueTag {
    return switch (value) {
        .none => .none,
        .document => .document,
        .page => .page,
        .object => .object,
        .selection => .selection,
        .anchor => .anchor,
        .function => .function,
        .string => .string,
        .enum_case => .enum_case,
        .record => .record,
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
    if (expected.kind == .enum_type) {
        const expected_name = expected.enum_name orelse return false;
        return switch (value) {
            .enum_case => |case| std.mem.eql(u8, case.enum_name, expected_name),
            else => false,
        };
    }
    if (expected.kind == .record) {
        const expected_name = expected.class_name orelse return false;
        return switch (value) {
            .record => |record| std.mem.eql(u8, record.type_name, expected_name),
            else => false,
        };
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
        .selection => .selection,
        .anchor => .anchor,
        .function => .function,
        .string, .color => .string,
        .enum_type => .enum_case,
        .record => .record,
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
