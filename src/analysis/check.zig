const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const language_names = @import("../language/names.zig");
const semantic_env = @import("../language/env.zig");
const infer = @import("infer.zig");
const semantic_types = @import("types.zig");

const Type = ast.Type;
const SemanticEnv = semantic_env.SemanticEnv;
const TypeEnv = semantic_types.TypeEnv;
const ensureType = semantic_types.ensureType;
const infoFromType = semantic_types.infoFromType;
const inferExprInfo = infer.exprInfoWithContext;
const validatePropertySetStatement = infer.validatePropertySetStatement;
const StatementContext = enum {
    document,
    page,
};

pub fn originPathForModule(module: *const core.SourceModule) []const u8 {
    return module.path orelse module.spec;
}

const addUserReport = @import("diagnostics.zig").addUserReport;

pub fn continueAfterDiagnostic(state: *const core.DocumentState, diagnostic_count_before: usize, err: anyerror) !void {
    if (err == error.OutOfMemory or err == error.Canceled) return err;
    // A failed binding may refer to a later declaration that owns its diagnostic.
    if (err == error.ForwardBindingDiagnostic or err == error.AlreadyDiagnosed) return;
    if (err == error.DiagnosticsFailed and state.diagnostics.entries.items.len != 0) return;
    if (state.diagnostics.entries.items.len > diagnostic_count_before) return;
    return err;
}

fn retainFailedBinding(state: *core.DocumentState, sema: *const SemanticEnv, env: *TypeEnv, stmt: ast.Statement) !void {
    const binding = switch (stmt.kind) {
        .let_binding => |value| value,
        else => return,
    };
    if (language_names.isDiscardBindingName(binding.name) or env.contains(binding.name)) return;
    var info = infoFromType(binding.type_annotation orelse Type.any);
    info.failed = true;
    try env.put(binding.name, info);
    if (binding.type_annotation != null and sema.record_source_facts) try recordBindingType(state, sema.module_id, binding.name_span, info);
}

fn rejectDuplicateBinding(state: ?*core.DocumentState, env: *const TypeEnv, name: []const u8, origin: core.SourceOrigin) !void {
    if (!env.contains(name)) return;
    try addUserReport(state, origin, "DuplicateBinding", "binding '{s}' is already defined in this scope", .{name});
    return error.DuplicateBinding;
}

pub fn checkPageNamesUnique(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
) !void {
    var pages = std.StringHashMap(void).init(allocator);
    defer pages.deinit();

    for (state.modules.order.items) |module_id| {
        const module = state.moduleById(module_id) orelse continue;
        const origin_path = originPathForModule(module);
        for (module.syntax.pages.items) |page| {
            if (page.stage_index) |index| if (index != 0) continue;
            const name = page.source_name orelse page.name;
            if (pages.contains(name)) {
                const origin = core.SourceOrigin.at(origin_path, page.span);

                try addUserReport(state, origin, "DuplicatePage", "page '{s}' is already defined", .{name});
                return error.DuplicatePage;
            }
            try pages.put(name, {});
        }
    }
}

pub fn checkFunction(
    inference_context: *infer.Context,
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    func: ast.FunctionDecl,
) !void {
    var env = TypeEnv.init(allocator);
    defer env.deinit();

    const func_origin = core.SourceOrigin.at(origin_path, func.span);

    for (func.params.items) |param| {
        try rejectDuplicateBinding(state, &env, param.name, func_origin);
        if (param.default_value) |default_value| {
            const info = try inferExprInfo(inference_context, allocator, state, sema, &env, default_value.*, func_origin);
            try ensureType(state, allocator, info, param.ty, func_origin);
        }
        const param_info = infoFromType(param.ty);
        try env.put(param.name, param_info);
        if (sema.record_source_facts) try recordBindingType(state, sema.module_id, param.name_span, param_info);
    }

    var had_diagnostics = false;
    for (func.statements.items) |stmt| {
        const diagnostic_count = state.diagnostics.entries.items.len;
        checkStatement(inference_context, allocator, state, sema, origin_path, &env, func.result_type, stmt) catch |err| {
            try continueAfterDiagnostic(state, diagnostic_count, err);
            had_diagnostics = true;
        };
    }
    if (had_diagnostics) return error.DiagnosticsFailed;
}

pub fn checkConst(
    inference_context: *infer.Context,
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    constant_decl: ast.ConstDecl,
) !void {
    const origin = core.SourceOrigin.at(origin_path, constant_decl.span);

    var env = TypeEnv.init(allocator);
    defer env.deinit();
    const before = state.diagnostics.entries.items.len;
    const actual = inferExprInfo(inference_context, allocator, state, sema, &env, constant_decl.value, origin) catch |err| {
        try continueAfterDiagnostic(state, before, err);
        return error.DiagnosticsFailed;
    };
    ensureType(state, allocator, actual, constant_decl.value_type, origin) catch |err| {
        try continueAfterDiagnostic(state, before, err);
        return error.DiagnosticsFailed;
    };
}

pub fn checkPageStatements(
    inference_context: *infer.Context,
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    program: ast.Module,
) !void {
    var had_diagnostics = false;

    {
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        try seedScheduledTypes(inference_context, &env, program.document_statements.items);
        for (program.document_statements.items) |stmt| {
            const diagnostic_count = state.diagnostics.entries.items.len;
            checkTopLevelStatement(inference_context, allocator, state, sema, origin_path, .document, &env, stmt) catch |err| {
                try continueAfterDiagnostic(state, diagnostic_count, err);
                had_diagnostics = true;
            };
        }
    }
    for (program.pages.items) |page| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        try seedScheduledTypes(inference_context, &env, page.statements.items);

        for (page.statements.items) |stmt| {
            const diagnostic_count = state.diagnostics.entries.items.len;
            checkTopLevelStatement(inference_context, allocator, state, sema, origin_path, .page, &env, stmt) catch |err| {
                try continueAfterDiagnostic(state, diagnostic_count, err);
                had_diagnostics = true;
            };
            if (page.stage_index != null) try state.labelDiagnostics(diagnostic_count, page.name);
        }
    }
    if (had_diagnostics) return error.DiagnosticsFailed;
}

fn seedScheduledTypes(context: *infer.Context, env: *TypeEnv, statements: []const ast.Statement) !void {
    for (statements) |stmt| if (stmt.kind == .let_binding) {
        const binding = stmt.kind.let_binding;
        if (binding.binding_id) |id| if (!env.contains(binding.name)) {
            try env.put(binding.name, context.binding_infos.get(id) orelse .{ .binding_id = id, .failed = true });
        };
    };
}

fn checkTopLevelStatement(
    inference_context: *infer.Context,
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    context: StatementContext,
    env: *TypeEnv,
    stmt: ast.Statement,
) anyerror!void {
    const before = state.diagnostics.entries.items.len;
    checkTopLevelStatementInner(inference_context, allocator, state, sema, origin_path, context, env, stmt) catch |err| {
        try continueAfterDiagnostic(state, before, err);
        try retainFailedBinding(state, sema, env, stmt);
        return err;
    };
}

fn checkTopLevelStatementInner(
    inference_context: *infer.Context,
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    context: StatementContext,
    env: *TypeEnv,
    stmt: ast.Statement,
) !void {
    const origin = core.SourceOrigin.at(origin_path, stmt.span);

    switch (stmt.kind) {
        .hole => return,
        .let_binding => |binding| {
            const binds_name = !language_names.isDiscardBindingName(binding.name);
            if (binds_name) {
                const existing = env.get(binding.name);
                if (binding.binding_id == null or existing == null or existing.?.binding_id != binding.binding_id)
                    try rejectDuplicateBinding(state, env, binding.name, origin);
            }
            const inferred = try inferExprInfo(inference_context, allocator, state, sema, env, binding.expr, origin);
            var info = try semantic_types.checkedAnnotation(allocator, state, inferred, binding.type_annotation, origin);
            try rejectVoidValue(state, info, origin);
            if (!binds_name) return;
            info.binding_id = binding.binding_id;
            if (binding.binding_id) |id| {
                if (state.scheduled_bindings.items[id].referenced and info.hole == null and info.ty.kind != .placed) {
                    try addUserReport(state, origin, "InvalidReferenceTarget", "'{s}' is referenced with '&' and must be bound to a placement", .{binding.name});
                    return error.InvalidType;
                }
                const slot = &state.scheduled_bindings.items[id].ty;
                if (slot.*) |resolved| {
                    if (info.hole == null) try ensureType(state, allocator, info, resolved, origin);
                } else slot.* = info.ty;
            }
            try env.put(binding.name, info);
            if (sema.record_source_facts) try recordBindingType(state, sema.module_id, binding.name_span, info);
        },
        .return_expr => {
            try addUserReport(state, origin, "ReturnOutsideFunction", "return is only valid inside a function", .{});
            return error.ReturnOutsideFunction;
        },
        .return_void => {
            try addUserReport(state, origin, "ReturnOutsideFunction", "return is only valid inside a function", .{});
            return error.ReturnOutsideFunction;
        },
        .property_set => |property_set| {
            try validatePropertySetStatement(inference_context, allocator, state, sema, env, property_set.target, property_set.path.items, property_set.value, origin);
        },
        .if_stmt => |if_stmt| {
            const condition = try inferExprInfo(inference_context, allocator, state, sema, env, if_stmt.condition, origin);
            try ensureType(state, allocator, condition, Type.boolean, origin);
            var then_env = try env.clone();
            defer then_env.deinit();
            for (if_stmt.then_statements.items) |nested| {
                try checkTopLevelStatement(inference_context, allocator, state, sema, origin_path, context, &then_env, nested);
            }
            var else_env = try env.clone();
            defer else_env.deinit();
            for (if_stmt.else_statements.items) |nested| {
                try checkTopLevelStatement(inference_context, allocator, state, sema, origin_path, context, &else_env, nested);
            }
        },
        .expr_stmt => |expr| {
            _ = try inferExprInfo(inference_context, allocator, state, sema, env, expr, origin);
        },
        .constrain => |decl| {
            if (context != .page) {
                try addUserReport(state, origin, "NoCurrentPage", "constraints are only valid inside a page block", .{});
                return error.NoCurrentPage;
            }
            try validateAnchorRef(allocator, state, sema, env, origin, decl.target, true);
            if (decl.source) |source| try validateAnchorRef(allocator, state, sema, env, origin, source, false);
            if (decl.offset) |expr| {
                const actual = try inferExprInfo(inference_context, allocator, state, sema, env, expr, origin);
                try ensureType(state, allocator, actual, Type.number, origin);
            }
        },
    }
}

fn recordBindingType(state: *core.DocumentState, module_id: core.SourceModuleId, span: ?ast.Span, info: semantic_types.TypeInfo) !void {
    try state.recordBindingType(module_id, span, .{
        .ty = if (info.hole) |hole| Type.hole(hole.hole_id) else info.ty,
    });
}

fn rejectVoidValue(state: *core.DocumentState, info: semantic_types.TypeInfo, origin: core.SourceOrigin) !void {
    if (info.hole != null) return;
    if (info.ty.kind != .void) return;
    try addUserReport(state, origin, "VoidValue", "void results can only be used as statements", .{});
    return error.InvalidType;
}

fn validateAnchorRef(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    env: *TypeEnv,
    origin: core.SourceOrigin,
    anchor_ref: ast.AnchorRef,
    is_target: bool,
) !void {
    switch (anchor_ref.kind) {
        .page => if (is_target) {
            try addUserReport(state, origin, "PageCannotBeConstraintTarget", "page anchors cannot be constraint targets", .{});
            return error.PageCannotBeConstraintTarget;
        },
        .node => {
            const path = anchorObjectPath(anchor_ref) orelse return;
            const info = try resolveAnchorPathInfo(state, sema, env, origin, path);
            if (info.hole != null) return;
            if (!isPlacementReference(info) and (is_target or info.ty.kind != .page)) {
                try semantic_types.ensurePlaced(state, allocator, info, origin);
            }
        },
    }
}

fn anchorObjectPath(anchor_ref: ast.AnchorRef) ?[]const u8 {
    return anchor_ref.node_path orelse anchor_ref.node_name;
}

fn resolveAnchorPathInfo(
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    env: *TypeEnv,
    origin: core.SourceOrigin,
    path: []const u8,
) !semantic_types.TypeInfo {
    var iter = std.mem.splitScalar(u8, path, '.');
    const first = iter.next() orelse return error.UnknownIdentifier;
    var info = env.get(first) orelse {
        try addUserReport(state, origin, "UnknownIdentifier", "unknown constraint object '{s}'", .{first});
        return error.UnknownIdentifier;
    };
    try info.requireValid();
    while (iter.next()) |field_name| {
        if (info.hole != null) return info;
        if (info.ty.kind == .placed) {
            const field_type = @import("../language/placement.zig").memberType(info.ty, field_name) orelse {
                const label = try semantic_types.typeLabelAlloc(state.inferenceAllocator(), info.ty);
                defer state.inferenceAllocator().free(label);
                try addUserReport(state, origin, "UnknownField", "type '{s}' has no field '{s}'", .{ label, field_name });
                return error.InvalidType;
            };
            info = infoFromType(field_type);
            continue;
        }
        if (info.ty.kind != .record) {
            try addUserReport(state, origin, "InvalidConstraintObject", "anchor path '{s}' does not resolve through a value with fields", .{path});
            return error.InvalidType;
        }
        const record_id = info.ty.nominalId() orelse {
            try addUserReport(state, origin, "InvalidType", "ss produced a type without a resolved declaration; report this as an ss bug with the source file", .{});
            return error.InvalidType;
        };
        const field_type = (try sema.recordFieldType(state.inferenceAllocator(), info.ty, field_name)) orelse {
            try addUserReport(state, origin, "UnknownField", "type '{s}' has no field '{s}'", .{ record_id.name, field_name });
            return error.InvalidType;
        };
        info = infoFromType(field_type);
    }
    return info;
}

fn isPlacementReference(info: semantic_types.TypeInfo) bool {
    return switch (info.ty.kind) {
        .placed => true,
        else => false,
    };
}

fn checkStatement(
    inference_context: *infer.Context,
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    env: *TypeEnv,
    result_type: Type,
    stmt: ast.Statement,
) anyerror!void {
    const before = state.diagnostics.entries.items.len;
    checkStatementInner(inference_context, allocator, state, sema, origin_path, env, result_type, stmt) catch |err| {
        try continueAfterDiagnostic(state, before, err);
        try retainFailedBinding(state, sema, env, stmt);
        return err;
    };
}

fn checkStatementInner(
    inference_context: *infer.Context,
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    env: *TypeEnv,
    result_type: Type,
    stmt: ast.Statement,
) !void {
    const origin = core.SourceOrigin.at(origin_path, stmt.span);

    switch (stmt.kind) {
        .hole => return,
        .let_binding => |binding| {
            const binds_name = !language_names.isDiscardBindingName(binding.name);
            if (binds_name) try rejectDuplicateBinding(state, env, binding.name, origin);
            const inferred = try inferExprInfo(inference_context, allocator, state, sema, env, binding.expr, origin);
            const info = try semantic_types.checkedAnnotation(allocator, state, inferred, binding.type_annotation, origin);
            try rejectVoidValue(state, info, origin);
            if (!binds_name) return;
            try env.put(binding.name, info);
            if (sema.record_source_facts) try recordBindingType(state, sema.module_id, binding.name_span, info);
        },
        .return_expr => |expr| {
            if (result_type.kind == .void) {
                try addUserReport(state, origin, "VoidReturnValue", "Void functions must use return without an expression", .{});
                return error.InvalidType;
            }
            const actual = try inferExprInfo(inference_context, allocator, state, sema, env, expr, origin);
            try ensureType(state, allocator, actual, result_type, origin);
        },
        .return_void => {
            if (result_type.kind != .void) {
                try ensureType(state, allocator, infoFromType(.{ .kind = .void }), result_type, origin);
            }
        },
        .property_set => |property_set| {
            try validatePropertySetStatement(inference_context, allocator, state, sema, env, property_set.target, property_set.path.items, property_set.value, origin);
        },
        .if_stmt => |if_stmt| {
            const condition = try inferExprInfo(inference_context, allocator, state, sema, env, if_stmt.condition, origin);
            try ensureType(state, allocator, condition, Type.boolean, origin);
            var then_env = try env.clone();
            defer then_env.deinit();
            for (if_stmt.then_statements.items) |nested| {
                try checkStatement(inference_context, allocator, state, sema, origin_path, &then_env, result_type, nested);
            }
            var else_env = try env.clone();
            defer else_env.deinit();
            for (if_stmt.else_statements.items) |nested| {
                try checkStatement(inference_context, allocator, state, sema, origin_path, &else_env, result_type, nested);
            }
        },
        .expr_stmt => |expr| {
            _ = try inferExprInfo(inference_context, allocator, state, sema, env, expr, origin);
        },
        .constrain => |decl| {
            try validateAnchorRef(allocator, state, sema, env, origin, decl.target, true);
            if (decl.source) |source| try validateAnchorRef(allocator, state, sema, env, origin, source, false);
            if (decl.offset) |expr| {
                const actual = try inferExprInfo(inference_context, allocator, state, sema, env, expr, origin);
                try ensureType(state, allocator, actual, Type.number, origin);
            }
        },
    }
}
