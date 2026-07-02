const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const analysis_env = @import("env.zig");
const syntax_hole = @import("../syntax/hole.zig");

const Type = ast.Type;
pub const HoleType = syntax_hole.HoleType;

pub const TypeInfo = struct {
    ty: Type = Type.any,
    hole: ?HoleType = null,
    object_class: ?[]const u8 = null,
    string_literal: ?[]const u8 = null,
    function_labels: []const []const u8 = &.{},
};

pub const TypeEnv = analysis_env.ValueEnv(TypeInfo);

pub fn infoFromType(ty: Type) TypeInfo {
    if (holeIdFromType(ty)) |hole_id| return infoFromHole(hole_id);
    return .{
        .ty = ty,
        .object_class = if (ty.kind == .object) ty.class_name else if (ty.kind == .selection and ty.param == .object) ty.param_class_name else null,
    };
}

pub fn infoFromHole(hole_id: ast.HoleId) TypeInfo {
    return .{
        // HoleType の意味は hole フィールドが持つ．ty は穴を見落とした経路で成功しにくい値にする．
        .ty = Type.none,
        .hole = .{ .hole_id = hole_id },
    };
}

pub fn typeLabelAlloc(allocator: std.mem.Allocator, ty: Type) ![]const u8 {
    return ty.formatAlloc(allocator);
}

pub fn typeInfoLabelAlloc(allocator: std.mem.Allocator, info: TypeInfo) ![]const u8 {
    if (info.hole != null or info.ty.kind == .hole) return allocator.dupe(u8, "HoleType");
    return typeLabelAlloc(allocator, info.ty);
}

pub fn mergeTypeInfo(allocator: std.mem.Allocator, a: TypeInfo, b: TypeInfo) !TypeInfo {
    if (a.hole != null) return a;
    if (b.hole != null) return b;
    return .{
        .ty = a.ty,
        .object_class = mergeObjectClass(a.object_class, b.object_class),
        .string_literal = mergeStringLiteral(a.string_literal, b.string_literal),
        .function_labels = try mergeFunctionLabels(allocator, a.function_labels, b.function_labels),
    };
}

pub fn singleFunctionLabel(allocator: std.mem.Allocator, label: []const u8) ![]const []const u8 {
    const labels = try allocator.alloc([]const u8, 1);
    labels[0] = label;
    return labels;
}

pub fn mergeFunctionLabels(
    allocator: std.mem.Allocator,
    left: []const []const u8,
    right: []const []const u8,
) ![]const []const u8 {
    if (left.len == 0) return right;
    if (right.len == 0) return left;
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    for (left) |label| try appendUniqueLabel(allocator, &out, label);
    for (right) |label| try appendUniqueLabel(allocator, &out, label);
    return try out.toOwnedSlice(allocator);
}

fn appendUniqueLabel(allocator: std.mem.Allocator, labels: *std.ArrayList([]const u8), label: []const u8) !void {
    for (labels.items) |existing| {
        if (std.mem.eql(u8, existing, label)) return;
    }
    try labels.append(allocator, label);
}

pub fn mergeObjectClass(a: ?[]const u8, b: ?[]const u8) ?[]const u8 {
    if (a == null) return b;
    if (b == null) return a;
    if (std.mem.eql(u8, a.?, b.?)) return a;
    return null;
}

pub fn mergeStringLiteral(a: ?[]const u8, b: ?[]const u8) ?[]const u8 {
    if (a == null) return b;
    if (b == null) return a;
    if (std.mem.eql(u8, a.?, b.?)) return a;
    return null;
}

pub fn resolveStringLiteral(env: *const TypeEnv, expr: ast.Expr) ?[]const u8 {
    return switch (expr) {
        .string => |literal| literal.text,
        .ident => |ident| if (env.get(ident.name)) |info| info.string_literal else null,
        else => null,
    };
}

pub fn isPropertyTarget(info: TypeInfo) bool {
    return switch (info.ty.kind) {
        .document, .page, .object => true,
        .selection => info.ty.param == .object or info.ty.param == .any,
        else => false,
    };
}

pub fn targetClassForInfo(info: TypeInfo) ?[]const u8 {
    if (info.hole != null) return null;
    return switch (info.ty.kind) {
        .document => "Doc",
        .page => "PageContext",
        .object => info.object_class,
        .selection => if (info.ty.param == .object or info.ty.param == .any) info.object_class else null,
        else => null,
    };
}

pub const Assignability = union(enum) {
    assignable,
    blocked_by_hole: ast.HoleId,
    mismatch,
};

pub fn assignability(actual: TypeInfo, expected: Type) Assignability {
    if (actual.hole) |hole| return .{ .blocked_by_hole = hole.hole_id };
    if (holeIdFromType(actual.ty)) |hole_id| return .{ .blocked_by_hole = hole_id };
    if (holeIdFromType(expected)) |hole_id| return .{ .blocked_by_hole = hole_id };
    return if (Type.accepts(expected, actual.ty)) .assignable else .mismatch;
}

pub fn holeIdFromType(ty: Type) ?ast.HoleId {
    if (ty.kind != .hole) return null;
    return ty.hole_id;
}

pub fn ensureType(
    ir: ?*core.Ir,
    allocator: std.mem.Allocator,
    actual: TypeInfo,
    expected: Type,
    origin: []const u8,
    code: core.TypeMismatchCode,
) !void {
    return ensureTypeWithHoles(ir, allocator, actual, expected, origin, code, null);
}

pub fn ensureTypeWithHoles(
    ir: ?*core.Ir,
    allocator: std.mem.Allocator,
    actual: TypeInfo,
    expected: Type,
    origin: []const u8,
    code: core.TypeMismatchCode,
    holes: ?*syntax_hole.Result,
) !void {
    _ = code;
    switch (assignability(actual, expected)) {
        .assignable => return,
        .blocked_by_hole => |hole_id| {
            if (holes) |table| try table.setExpectedType(allocator, hole_id, expected);
            return;
        },
        .mismatch => {},
    }
    if (ir) |sink| {
        const actual_label = try typeInfoLabelAlloc(allocator, actual);
        defer allocator.free(actual_label);
        const expected_label = try typeLabelAlloc(allocator, expected);
        defer allocator.free(expected_label);
        const message = try std.fmt.allocPrint(sink.allocator, "TypeMismatch: expected {s}, got {s}", .{ expected_label, actual_label });
        try sink.addValidationDiagnostic(.@"error", null, null, origin, .{
            .user_report = .{ .message = message },
        });
    }
    return error.InvalidType;
}
