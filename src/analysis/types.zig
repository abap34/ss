const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const analysis_env = @import("env.zig");
const syntax_hole = @import("../syntax/hole.zig");

const Type = ast.Type;
pub const HoleType = syntax_hole.HoleType;

// Optional facts use null only for unknown. An unreached return uses ?TypeInfo.
pub const TypeInfo = struct {
    ty: Type = Type.any,
    hole: ?HoleType = null,
    failed: bool = false,
    object_class: ?core.NominalId = null,
    string_literal: ?[]const u8 = null,
    function_labels: []const []const u8 = &.{},
};

pub const TypeEnv = analysis_env.ValueEnv(TypeInfo);

pub fn infoFromType(ty: Type) TypeInfo {
    if (holeIdFromType(ty)) |hole_id| return infoFromHole(hole_id);
    return .{
        .ty = ty,
        .object_class = if (ty.kind == .object) ty.nominalId() else if (ty.kind == .selection and ty.selectionItem().kind == .object) ty.selectionItemId() else null,
    };
}

pub fn infoFromHole(hole_id: ast.HoleId) TypeInfo {
    return .{
        // The hole field carries HoleType semantics. Keep ty difficult to accept if a path overlooks the hole.
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

pub fn joinTypeInfo(allocator: std.mem.Allocator, a: TypeInfo, b: TypeInfo) !TypeInfo {
    if (a.failed) return a;
    if (b.failed) return b;
    if (a.hole != null) return a;
    if (b.hole != null) return b;
    return .{
        .ty = a.ty,
        .object_class = joinObjectClass(a.object_class, b.object_class),
        .string_literal = joinStringLiteral(a.string_literal, b.string_literal),
        .function_labels = try joinFunctionLabels(allocator, a.function_labels, b.function_labels),
    };
}

// The annotation and actual value constrain the same value, unlike a control-flow join.
pub fn refineTypeInfo(annotation: TypeInfo, actual: TypeInfo) TypeInfo {
    if (annotation.hole != null) return annotation;
    if (actual.hole != null) return actual;
    var result = actual;
    result.ty = annotation.ty;
    result.object_class = meetObjectClass(annotation.object_class, actual.object_class);
    return result;
}

// Distinct nominal classes have an empty intersection. Without an empty-selection
// fact, retaining either operand is a sound approximation of that intersection.
pub fn meetObjectClass(a: ?core.NominalId, b: ?core.NominalId) ?core.NominalId {
    return a orelse b;
}

pub fn singleFunctionLabel(allocator: std.mem.Allocator, label: []const u8) ![]const []const u8 {
    const labels = try allocator.alloc([]const u8, 1);
    labels[0] = label;
    return labels;
}

fn joinFunctionLabels(
    allocator: std.mem.Allocator,
    left: []const []const u8,
    right: []const []const u8,
) ![]const []const u8 {
    if (left.len == 0 or right.len == 0) return &.{};
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

pub fn joinObjectClass(a: ?core.NominalId, b: ?core.NominalId) ?core.NominalId {
    if (a == null or b == null) return null;
    if (a.?.eql(b.?)) return a;
    return null;
}

pub fn joinStringLiteral(a: ?[]const u8, b: ?[]const u8) ?[]const u8 {
    if (a == null or b == null) return null;
    if (std.mem.eql(u8, a.?, b.?)) return a;
    return null;
}

// Bound static string construction independently of runtime string operations.
pub const max_static_string_bytes = 64 * 1024;

pub fn concatStringLiterals(allocator: std.mem.Allocator, left: ?[]const u8, right: ?[]const u8) !?[]const u8 {
    const a = left orelse return null;
    const b = right orelse return null;
    if (a.len > max_static_string_bytes or b.len > max_static_string_bytes - a.len) return null;
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ a, b });
}

pub fn resolveStringLiteral(env: *const TypeEnv, expr: ast.Expr) ?[]const u8 {
    return switch (expr) {
        .string => |literal| literal.text,
        .ident => |ident| if (env.get(ident.name)) |info| info.string_literal else null,
        else => null,
    };
}

pub fn isPropertyReadTarget(info: TypeInfo) bool {
    return switch (info.ty.kind) {
        .document, .page, .object => true,
        else => false,
    };
}

pub fn isPropertyTarget(info: TypeInfo) bool {
    return switch (info.ty.kind) {
        .document, .page, .object => true,
        .selection => info.ty.selectionItem().kind == .object,
        else => false,
    };
}

pub fn targetClassForInfo(info: TypeInfo, sema: *const @import("../language/env.zig").SemanticEnv) ?core.NominalId {
    if (info.hole != null) return null;
    return switch (info.ty.kind) {
        .document => sema.builtinClass("Doc"),
        .page => sema.builtinClass("PageContext"),
        .object => info.object_class,
        .selection => if (info.ty.selectionItem().kind == .object) info.object_class else null,
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
    if (ty.kind == .hole) return ty.hole_id;
    for (ty.arguments) |argument| if (holeIdFromType(argument)) |id| return id;
    if (ty.optional_child) |child| if (holeIdFromType(child.*)) |id| return id;
    for (ty.fn_params) |param| if (holeIdFromType(param)) |id| return id;
    if (ty.fn_result) |result| if (holeIdFromType(result.*)) |id| return id;
    return null;
}

pub fn ensureType(
    state: ?*core.DocumentState,
    allocator: std.mem.Allocator,
    actual: TypeInfo,
    expected: Type,
    origin: core.SourceOrigin,
    code: core.TypeMismatchCode,
) !void {
    return ensureTypeWithHoles(state, allocator, actual, expected, origin, code, null);
}

pub fn ensureTypeWithHoles(
    state: ?*core.DocumentState,
    allocator: std.mem.Allocator,
    actual: TypeInfo,
    expected: Type,
    origin: core.SourceOrigin,
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
    if (state) |sink| {
        const actual_label = try typeInfoLabelAlloc(allocator, actual);
        defer allocator.free(actual_label);
        const expected_label = try typeLabelAlloc(allocator, expected);
        defer allocator.free(expected_label);
        const message = try std.fmt.allocPrint(sink.allocator, "expected {s}, got {s}", .{ expected_label, actual_label });
        try sink.addValidationDiagnostic(.@"error", null, null, origin, .{
            .user_report = .{ .code = "TypeMismatch", .message = message },
        });
    }
    return error.InvalidType;
}

// Stored properties must have a function-free value type. Object and
// page references do not embed the properties of their referents.
pub fn isPropertyStorable(allocator: std.mem.Allocator, sema: *const @import("../language/env.zig").SemanticEnv, ty: Type) !bool {
    var pending = std.ArrayList(Type).empty;
    defer pending.deinit(allocator);
    var visited = std.ArrayList(core.NominalId).empty;
    defer visited.deinit(allocator);
    try pending.append(allocator, ty);
    while (pending.pop()) |current| {
        switch (current.kind) {
            .function, .any => return false,
            .optional => if (current.optional_child) |child| {
                try pending.append(allocator, child.*);
            },
            .record => {
                const id = current.nominalId() orelse return false;
                var seen = false;
                for (visited.items) |previous| if (previous.eql(id)) {
                    seen = true;
                    break;
                };
                if (seen) continue;
                try visited.append(allocator, id);
                const record = sema.record(id.module_id, id.name) orelse return false;
                for (record.decl.fields.items) |field| try pending.append(allocator, field.value_type);
            },
            else => {},
        }
    }
    return true;
}
