const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const Type = ast.Type;

pub const TypeInfo = struct {
    ty: Type = Type.any,
    value_tag: core.ValueTag,
    object_class: ?[]const u8 = null,
    string_literal: ?[]const u8 = null,
    function_labels: []const []const u8 = &.{},
};

pub const TypeEnv = std.StringHashMap(TypeInfo);

pub fn infoFromValueTag(value_tag: core.ValueTag) TypeInfo {
    return .{ .ty = Type.fromValueTag(value_tag), .value_tag = value_tag };
}

pub fn infoFromType(ty: Type) TypeInfo {
    return .{
        .ty = ty,
        .value_tag = ty.toValueTag() orelse if (ty.tag == .optional) .none else .void,
        .object_class = if (ty.tag == .object) ty.class_name else if (ty.tag == .selection and ty.param == .object) ty.param_class_name else null,
    };
}

pub fn infoForSelectionItem(tag: core.SelectionItemTag) TypeInfo {
    return infoFromType(Type.fromSelectionItemTag(tag));
}

pub fn typeLabelAlloc(allocator: std.mem.Allocator, ty: Type) ![]const u8 {
    return ty.formatAlloc(allocator);
}

pub fn mergeTypeInfo(allocator: std.mem.Allocator, a: TypeInfo, b: TypeInfo) !TypeInfo {
    return .{
        .ty = a.ty,
        .value_tag = a.value_tag,
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
        .string => |text| text,
        .ident => |name| if (env.get(name)) |info| info.string_literal else null,
        else => null,
    };
}

pub fn isPropertyTarget(info: TypeInfo) bool {
    return switch (info.ty.tag) {
        .document, .page, .object => true,
        .selection => info.ty.param == .object or info.ty.param == .any,
        else => false,
    };
}

pub fn targetClassForInfo(info: TypeInfo) ?[]const u8 {
    return switch (info.ty.tag) {
        .document => "Doc",
        .page => "PageContext",
        .object => info.object_class,
        .selection => if (info.ty.param == .object or info.ty.param == .any) info.object_class else null,
        else => null,
    };
}

pub fn ensureValueTag(
    ir: ?*core.Ir,
    actual: core.ValueTag,
    expected: core.ValueTag,
    origin: []const u8,
    code: core.TypeMismatchCode,
) !void {
    if (actual != expected) {
        if (ir) |sink| {
            try sink.addValidationDiagnostic(.@"error", null, null, origin, .{
                .type_mismatch = .{ .code = code, .expected = expected, .actual = actual },
            });
        }
        return error.InvalidValueTag;
    }
}

pub fn ensureType(
    ir: ?*core.Ir,
    allocator: std.mem.Allocator,
    actual: TypeInfo,
    expected: Type,
    origin: []const u8,
    code: core.TypeMismatchCode,
) !void {
    if (Type.accepts(expected, actual.ty)) return;
    const expected_tag = expected.toValueTag() orelse actual.value_tag;
    if (expected_tag != actual.value_tag and !needsStaticTypeLabel(expected, actual.ty)) {
        return ensureValueTag(ir, actual.value_tag, expected_tag, origin, code);
    }
    if (ir) |sink| {
        const actual_label = try typeLabelAlloc(allocator, actual.ty);
        defer allocator.free(actual_label);
        const expected_label = try typeLabelAlloc(allocator, expected);
        defer allocator.free(expected_label);
        const message = try std.fmt.allocPrint(sink.allocator, "TypeMismatch: expected {s}, got {s}", .{ expected_label, actual_label });
        try sink.addValidationDiagnostic(.@"error", null, null, origin, .{
            .user_report = .{ .message = message },
        });
    }
    return error.InvalidValueTag;
}

fn needsStaticTypeLabel(expected: Type, actual: Type) bool {
    return isSourceLevelRefinement(expected) or isSourceLevelRefinement(actual);
}

fn isSourceLevelRefinement(ty: Type) bool {
    return switch (ty.tag) {
        .color, .enum_type, .optional => true,
        .object => ty.class_name != null,
        .selection => ty.param_class_name != null,
        .function => true,
        else => false,
    };
}
