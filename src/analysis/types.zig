const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const Type = ast.Type;

pub const TypeInfo = struct {
    ty: Type = Type.any,
    sort: core.SemanticSort,
    object_class: ?[]const u8 = null,
    string_literal: ?[]const u8 = null,
};

pub const TypeEnv = std.StringHashMap(TypeInfo);

pub fn infoFromSort(sort: core.SemanticSort) TypeInfo {
    return .{ .ty = Type.fromSort(sort), .sort = sort };
}

pub fn infoFromType(ty: Type) TypeInfo {
    return .{
        .ty = ty,
        .sort = ty.toRuntimeSort() orelse .fragment,
        .object_class = if (ty.tag == .object) ty.class_name else if (ty.tag == .selection and ty.param == .object) ty.param_class_name else null,
    };
}

pub fn infoForSelectionItem(sort: core.SelectionItemSort) TypeInfo {
    return infoFromType(Type.fromSelectionItemSort(sort));
}

pub fn typeLabelAlloc(allocator: std.mem.Allocator, ty: Type) ![]const u8 {
    return ty.formatAlloc(allocator);
}

pub fn mergeTypeInfo(a: TypeInfo, b: TypeInfo) TypeInfo {
    return .{
        .ty = a.ty,
        .sort = a.sort,
        .object_class = mergeObjectClass(a.object_class, b.object_class),
        .string_literal = mergeStringLiteral(a.string_literal, b.string_literal),
    };
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
        .code => switch (info.ty.param) {
            .document, .page, .object => true,
            else => false,
        },
        else => false,
    };
}

pub fn targetClassForInfo(info: TypeInfo) ?[]const u8 {
    return switch (info.ty.tag) {
        .document => "DocumentObject",
        .page => "PageObject",
        .object => info.object_class,
        .selection => if (info.ty.param == .object or info.ty.param == .any) info.object_class else null,
        .code => switch (info.ty.param) {
            .document => "DocumentObject",
            .page => "PageObject",
            .object => info.object_class,
            else => null,
        },
        else => null,
    };
}

pub fn ensureSort(
    ir: ?*core.Ir,
    actual: core.SemanticSort,
    expected: core.SemanticSort,
    origin: []const u8,
    code: core.TypeMismatchCode,
) !void {
    if (actual != expected) {
        if (ir) |sink| {
            try sink.addValidationDiagnostic(.@"error", null, null, origin, .{
                .type_mismatch = .{ .code = code, .expected = expected, .actual = actual },
            });
        }
        return error.InvalidSemanticSort;
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
    const expected_sort = expected.toRuntimeSort() orelse actual.sort;
    if (expected_sort != actual.sort) return ensureSort(ir, actual.sort, expected_sort, origin, code);
    if (ir) |sink| {
        const actual_label = try typeLabelAlloc(allocator, actual.ty);
        defer allocator.free(actual_label);
        const expected_label = try typeLabelAlloc(allocator, expected);
        defer allocator.free(expected_label);
        const message = try std.fmt.allocPrint(sink.allocator, "TypeMismatch: expected {s}, got {s}", .{ expected_label, actual_label });
        const diagnostic_origin = try sink.allocator.dupe(u8, origin);
        try sink.addValidationDiagnostic(.@"error", null, null, diagnostic_origin, .{
            .user_report = .{ .message = message },
        });
    }
    return error.InvalidSemanticSort;
}
