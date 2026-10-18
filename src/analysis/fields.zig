const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const infer = @import("infer.zig");
const semantic_env = @import("../language/env.zig");
const semantic_types = @import("types.zig");

const SemanticEnv = semantic_env.SemanticEnv;
const TypeEnv = semantic_types.TypeEnv;

pub fn checkTypeFields(allocator: std.mem.Allocator, state: *core.DocumentState, sema: *const SemanticEnv) !void {
    for (state.modules.order.items) |module_id| {
        const module = state.moduleById(module_id) orelse continue;
        const origin_path = originPathForModule(module);
        const module_sema = sema.forModule(module_id);
        for (module.syntax.records.items) |record_decl| {
            try checkRecordDeclaration(allocator, state, &module_sema, origin_path, record_decl);
        }
    }
}

fn checkRecordDeclaration(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    record_decl: ast.RecordDecl,
) !void {
    if (record_decl.type_params.items.len != 0) return;
    try checkFields(allocator, state, sema, origin_path, record_decl.fields.items);
}

fn checkFields(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    fields: []const ast.FieldDecl,
) !void {
    for (fields) |field| {
        const origin = core.SourceOrigin.at(origin_path, field.span);

        const field_type = field.value_type;
        if (field_type.kind == .hole) continue;
        if (field.default_value) |default_value| {
            try checkFieldDefault(allocator, state, sema, origin, field_type, default_value.*);
        }
    }
}

fn checkFieldDefault(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    origin: core.SourceOrigin,
    ty: ast.Type,
    default_value: ast.Expr,
) !void {
    var env = TypeEnv.init(allocator);
    defer env.deinit();
    const actual = infer.exprInfo(allocator, state, sema, &env, default_value, origin) catch |err| switch (err) {
        error.InvalidType, error.UnknownIdentifier => return error.InvalidType,
        else => return err,
    };
    if (actual.hole != null) return;
    if (ast.Type.accepts(ty, actual.ty)) return;
    const label = try fieldTypeLabel(allocator, ty);
    defer allocator.free(label);
    try addUserReport(state, origin, "InvalidFieldDefault", "default value does not match field type {s}", .{label});
    return error.InvalidType;
}

fn fieldTypeLabel(allocator: std.mem.Allocator, ty: ast.Type) ![]const u8 {
    return switch (ty.kind) {
        .enum_type => if (ty.enum_name) |name| try allocator.dupe(u8, name) else try ty.formatAlloc(allocator),
        else => try ty.formatAlloc(allocator),
    };
}

const addUserReport = @import("diagnostics.zig").addUserReport;

fn originPathForModule(module: *const core.SourceModule) []const u8 {
    return module.path orelse module.spec;
}
