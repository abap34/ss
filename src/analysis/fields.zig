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
            return error.InvalidValueTag;
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
            return error.InvalidValueTag;
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
        return error.InvalidValueTag;
    }
    if (extension.implements) |implements| {
        if (!sema.classExists(implements)) {
            try addUserReport(ir, origin, "InvalidObjectExtension: unknown protocol: {s}", .{implements});
            return error.InvalidValueTag;
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
            return error.InvalidValueTag;
        };
        defer field_type.deinit(allocator);
        if (field.default_value) |default_value| {
            try checkFieldDefault(allocator, ir, sema, module_id, origin, field_type, default_value);
        }
    }
}

fn checkFieldDefault(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    origin: []const u8,
    ty: ast.Type,
    default_value: []const u8,
) !void {
    const value = std.mem.trim(u8, default_value, " \t\r\n");
    if (ty.tag == .optional) {
        if (std.mem.eql(u8, value, "none")) return;
        const child = ty.optional_child orelse return;
        return checkFieldDefault(allocator, ir, sema, module_id, origin, child.*, value);
    }
    switch (ty.tag) {
        .string => if (isStringDefault(value)) return,
        .color => if (isColorDefault(value)) return,
        .number => if (std.fmt.parseFloat(f32, value) catch null) |_| return,
        .boolean => if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) return,
        .style => if (isStringDefault(value)) return,
        .enum_type => if (ty.enum_name) |name| {
            if (enumDefaultMatches(sema, module_id, name, value)) return;
        },
        .none => if (std.mem.eql(u8, value, "none")) return,
        else => return,
    }
    try addUserReport(ir, origin, "InvalidFieldDefault: default value does not match field type {s}", .{fieldTypeLabel(ty)});
    return error.InvalidValueTag;
}

fn isStringDefault(value: []const u8) bool {
    return value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"';
}

fn isColorDefault(value: []const u8) bool {
    return value.len >= 3 and value[0] == 'c' and value[1] == '"' and value[value.len - 1] == '"';
}

fn enumDefaultMatches(sema: *const SemanticEnv, module_id: core.SourceModuleId, enum_name: []const u8, value: []const u8) bool {
    if (!std.mem.startsWith(u8, value, enum_name)) return false;
    if (value.len <= enum_name.len + 1 or value[enum_name.len] != '.') return false;
    return sema.enumHasCase(module_id, enum_name, value[enum_name.len + 1 ..]);
}

fn fieldTypeLabel(ty: ast.Type) []const u8 {
    return switch (ty.tag) {
        .string => "String",
        .color => "Color",
        .number => "Number",
        .boolean => "Bool",
        .style => "Style",
        .enum_type => ty.enum_name orelse "enum",
        .optional => "optional",
        .none => "None",
        else => "type",
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
            return error.InvalidValueTag;
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
