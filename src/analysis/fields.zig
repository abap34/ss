const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const infer = @import("infer.zig");
const semantic_env = @import("../language/env.zig");
const semantic_types = @import("types.zig");

const SemanticEnv = semantic_env.SemanticEnv;
const TypeEnv = semantic_types.TypeEnv;

pub fn checkObjectDeclarations(allocator: std.mem.Allocator, ir: *core.Ir, sema: *const SemanticEnv) !void {
    var roles = std.StringHashMap([]const u8).init(allocator);
    defer roles.deinit();

    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        const origin_path = originPathForModule(module);
        try checkObjectNamesUnique(allocator, ir, origin_path, module.program.objects.items);
        try checkRecordNamesUnique(allocator, ir, origin_path, module.program.records.items);
        for (module.program.records.items) |record_decl| {
            try checkRecordDeclaration(allocator, ir, sema, module.id, origin_path, record_decl);
        }
        for (module.program.objects.items) |object_decl| {
            try checkObjectDeclaration(allocator, ir, sema, module.id, origin_path, object_decl);
            try checkRolesUnique(allocator, ir, origin_path, &roles, object_decl.name, object_decl.roles.items, object_decl.span);
        }
        for (module.program.object_extensions.items) |extension| {
            try checkObjectExtension(allocator, ir, sema, module.id, origin_path, extension);
            try checkRolesUnique(allocator, ir, origin_path, &roles, extension.target, extension.roles.items, extension.span);
        }
    }
}

fn checkRecordNamesUnique(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    origin_path: []const u8,
    records: []const ast.RecordDecl,
) !void {
    var names = std.StringHashMap(void).init(allocator);
    defer names.deinit();
    for (records) |record_decl| {
        if (names.contains(record_decl.name)) {
            const origin = try statementOrigin(allocator, origin_path, record_decl.span);
            defer allocator.free(origin);
            try addUserReport(ir, origin, "DuplicateRecordType: record type '{s}' is already defined in this module", .{record_decl.name});
            return error.InvalidType;
        }
        try names.put(record_decl.name, {});
    }
}

fn checkRecordDeclaration(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    origin_path: []const u8,
    record_decl: ast.RecordDecl,
) !void {
    try checkObjectFields(allocator, ir, sema, module_id, origin_path, record_decl.fields.items);
}

fn checkObjectNamesUnique(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    origin_path: []const u8,
    objects: []const ast.ObjectDecl,
) !void {
    var names = std.StringHashMap(void).init(allocator);
    defer names.deinit();
    for (objects) |object_decl| {
        if (names.contains(object_decl.name)) {
            const origin = try statementOrigin(allocator, origin_path, object_decl.span);
            defer allocator.free(origin);
            try addUserReport(ir, origin, "DuplicateObjectClass: object class '{s}' is already defined in this module", .{object_decl.name});
            return error.InvalidType;
        }
        try names.put(object_decl.name, {});
    }
}

fn checkObjectDeclaration(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    origin_path: []const u8,
    object_decl: ast.ObjectDecl,
) !void {
    const origin = try statementOrigin(allocator, origin_path, object_decl.span);
    defer allocator.free(origin);
    if (object_decl.base) |base| {
        if (!sema.classExists(base)) {
            try addUserReport(ir, origin, "InvalidObjectDeclaration: unknown base object class: {s}", .{base});
            return error.InvalidType;
        }
    }
    try checkObjectFields(allocator, ir, sema, module_id, origin_path, object_decl.fields.items);
}

fn checkObjectExtension(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    origin_path: []const u8,
    extension: ast.ObjectExtensionDecl,
) !void {
    const origin = try statementOrigin(allocator, origin_path, extension.span);
    defer allocator.free(origin);
    if (!sema.classExists(extension.target)) {
        try addUserReport(ir, origin, "InvalidObjectExtension: unknown object class: {s}", .{extension.target});
        return error.InvalidType;
    }
    if (extension.implements) |implements| {
        if (!sema.classExists(implements)) {
            try addUserReport(ir, origin, "InvalidObjectExtension: unknown protocol: {s}", .{implements});
            return error.InvalidType;
        }
    }
    try checkObjectFields(allocator, ir, sema, module_id, origin_path, extension.fields.items);
}

fn checkObjectFields(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    origin_path: []const u8,
    fields: []const ast.ObjectFieldDecl,
) !void {
    for (fields) |field| {
        const origin = try statementOrigin(allocator, origin_path, field.span);
        defer allocator.free(origin);
        var field_type = (try sema.resolveTypeText(allocator, module_id, field.value_type)) orelse {
            try addUserReport(ir, origin, "InvalidFieldSchema: unknown field value type: {s}", .{field.value_type});
            return error.InvalidType;
        };
        defer field_type.deinit(allocator);
        if (field.default_value) |default_value| {
            try checkFieldDefault(allocator, ir, sema, origin, field_type, default_value.*, field.default_property_value);
        }
    }
}

fn checkFieldDefault(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    origin: []const u8,
    ty: ast.Type,
    default_value: ast.Expr,
    default_property_value: ?[]const u8,
) !void {
    var env = TypeEnv.init(allocator);
    defer env.deinit();
    const actual = infer.exprInfo(allocator, ir, sema, &env, default_value, origin) catch |err| switch (err) {
        error.InvalidType, error.UnknownIdentifier => return error.InvalidType,
        else => return err,
    };
    if (fieldDefaultHasStaticPropertyValue(default_value, default_property_value) and fieldDefaultTypeAccepts(ty, actual.ty, default_value)) return;
    const label = try fieldTypeLabel(allocator, ty);
    defer allocator.free(label);
    try addUserReport(ir, origin, "InvalidFieldDefault: default value does not match field type {s}", .{label});
    return error.InvalidType;
}

fn fieldDefaultHasStaticPropertyValue(default_value: ast.Expr, default_property_value: ?[]const u8) bool {
    if (default_value == .none) return true;
    return default_property_value != null;
}

fn fieldDefaultTypeAccepts(expected: ast.Type, actual: ast.Type, default_value: ast.Expr) bool {
    _ = default_value;
    if (ast.Type.accepts(expected, actual)) return true;
    return false;
}

fn fieldTypeLabel(allocator: std.mem.Allocator, ty: ast.Type) ![]const u8 {
    return switch (ty.kind) {
        .enum_type => if (ty.enum_name) |name| try allocator.dupe(u8, name) else try ty.formatAlloc(allocator),
        else => try ty.formatAlloc(allocator),
    };
}

fn checkRolesUnique(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    origin_path: []const u8,
    roles: *std.StringHashMap([]const u8),
    class_name: []const u8,
    role_names: []const []const u8,
    span: ast.Span,
) !void {
    for (role_names) |role_name| {
        if (roles.get(role_name)) |existing_class| {
            const origin = try statementOrigin(allocator, origin_path, span);
            defer allocator.free(origin);
            try addUserReport(
                ir,
                origin,
                "DuplicateRole: role '{s}' is already provided by {s}",
                .{ role_name, existing_class },
            );
            return error.InvalidType;
        }
        try roles.put(role_name, class_name);
    }
}

fn addUserReport(ir: *core.Ir, origin: []const u8, comptime fmt: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(ir.allocator, fmt, args);
    try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = message },
    });
}

fn originPathForModule(module: *const core.SourceModule) []const u8 {
    return module.path orelse module.spec;
}

fn statementOrigin(allocator: std.mem.Allocator, origin_path: []const u8, span: ast.Span) ![]const u8 {
    if (origin_path.len != 0) {
        return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ origin_path, span.start, span.end });
    }
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}
