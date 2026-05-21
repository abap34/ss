const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const semantic_env = @import("../language/env.zig");

const SemanticEnv = semantic_env.SemanticEnv;

pub fn checkObjectDeclarations(allocator: std.mem.Allocator, ir: *core.Ir, sema: *const SemanticEnv) !void {
    var roles = std.StringHashMap([]const u8).init(allocator);
    defer roles.deinit();

    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        const origin_path = originPathForModule(module);
        try checkObjectNamesUnique(allocator, ir, origin_path, module.program.objects.items);
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
            return error.InvalidSemanticSort;
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
            return error.InvalidSemanticSort;
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
        return error.InvalidSemanticSort;
    }
    if (extension.implements) |implements| {
        if (!sema.classExists(implements)) {
            try addUserReport(ir, origin, "InvalidObjectExtension: unknown protocol: {s}", .{implements});
            return error.InvalidSemanticSort;
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
        if (sema.valueDomain(module_id, field.value_type) != null) continue;
        const origin = try statementOrigin(allocator, origin_path, field.span);
        defer allocator.free(origin);
        try addUserReport(ir, origin, "InvalidFieldSchema: unknown field value type: {s}", .{field.value_type});
        return error.InvalidSemanticSort;
    }
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
            return error.InvalidSemanticSort;
        }
        try roles.put(role_name, class_name);
    }
}

fn addUserReport(ir: *core.Ir, origin: []const u8, comptime fmt: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(ir.allocator, fmt, args);
    const diagnostic_origin = try ir.allocator.dupe(u8, origin);
    try ir.addValidationDiagnostic(.@"error", null, null, diagnostic_origin, .{
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
