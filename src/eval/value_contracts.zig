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
        .path => .path,
        .number => .number,
        .boolean => .boolean,
        .constraints => .constraints,
        .void => .void,
    };
}

pub fn ensureValueType(
    state: anytype,
    page_id: ?core.NodeId,
    value: core.Value,
    expected: core.ValueTag,
    origin: []const u8,
) !void {
    return ensureValueTypeWithCode(state, page_id, value, expected, origin, .UnmatchedArgumentType);
}

pub fn ensureValueTypeWithCode(
    state: anytype,
    page_id: ?core.NodeId,
    value: core.Value,
    expected: core.ValueTag,
    origin: []const u8,
    code: core.TypeMismatchCode,
) !void {
    const actual = runtimeKind(value);
    if (actual != expected) {
        try state.addValidationDiagnostic(.@"error", page_id, null, origin, .{
            .type_mismatch = .{ .code = code, .expected = expected, .actual = actual },
        });
        return error.InvalidValueTag;
    }
}

pub fn ensureValueConformsToType(
    state: anytype,
    page_id: ?core.NodeId,
    value: core.Value,
    expected: ast.Type,
    origin: []const u8,
    code: core.TypeMismatchCode,
) !void {
    if (valueConformsToType(state, value, expected)) return;

    const actual = runtimeKind(value);
    if (expectedRuntimeKind(expected)) |expected_kind| {
        try state.addValidationDiagnostic(.@"error", page_id, null, origin, .{
            .type_mismatch = .{ .code = code, .expected = expected_kind, .actual = actual },
        });
    } else {
        try state.addValidationDiagnostic(.@"error", page_id, null, origin, .{
            .user_report = .{
                .message = try std.fmt.allocPrint(
                    state.allocator,
                    "TypeMismatch: expected {s}, got {s}",
                    .{ expectedRuntimeLabel(expected), @tagName(actual) },
                ),
            },
        });
    }
    return error.InvalidValueTag;
}

pub fn valueConformsToType(state: anytype, value: core.Value, expected: ast.Type) bool {
    if (expected.kind == .hole) return false;
    if (expected.kind == .any) return true;
    if (expected.kind == .optional) {
        if (runtimeKind(value) == .none) return true;
        const child = expected.optional_child orelse return false;
        return valueConformsToType(state, value, child.*);
    }
    if (expected.kind == .enum_type) {
        const expected_name = expected.enum_name orelse return false;
        return switch (value) {
            .enum_case => |case| case.module_id == expected.nominal_module_id and std.mem.eql(u8, case.enum_name, expected_name),
            else => false,
        };
    }
    if (expected.kind == .record) {
        const expected_name = expected.class_name orelse return false;
        return switch (value) {
            .record => |record| record.module_id == expected.nominal_module_id and std.mem.eql(u8, record.type_name, expected_name),
            else => false,
        };
    }
    if (expected.kind == .object and expected.class_name != null) {
        const id = expected.nominalId() orelse return false;
        if (value != .object) return false;
        const node = state.getNode(value.object) orelse return false;
        const actual_id = core.fields.classId(state, node) orelse return false;
        return id.eql(actual_id);
    }
    if (expected.kind == .selection and expected.param != .any and expected.param != .none) {
        if (value != .selection) return false;
        if ((expected.param == .object and value.selection.item_tag != .object) or
            (expected.param == .page and value.selection.item_tag != .page)) return false;
        if (expected.selectionItemId()) |id| {
            for (value.selection.ids.items) |node_id| {
                const node = state.getNode(node_id) orelse return false;
                const actual_id = core.fields.classId(state, node) orelse return false;
                if (!id.eql(actual_id)) return false;
            }
        }
        return true;
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
        .path => .path,
        .number => .number,
        .boolean => .boolean,
        .constraints => .constraints,
        .void => .void,
        .optional, .any, .hole => null,
    };
}

fn expectedRuntimeLabel(expected: ast.Type) []const u8 {
    return expected.label();
}
