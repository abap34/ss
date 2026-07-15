const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const language_names = @import("../language/names.zig");
const semantic_env = @import("../language/env.zig");
const infer = @import("infer.zig");
const registry = @import("../language/registry.zig");
const semantic_types = @import("types.zig");
const analysis_env = @import("env.zig");

const Type = ast.Type;
const SemanticEnv = semantic_env.SemanticEnv;
const TypeEnv = semantic_types.TypeEnv;
const ensureType = semantic_types.ensureType;
const infoFromType = semantic_types.infoFromType;
const inferExprInfo = infer.exprInfo;
const validatePropertySetStatement = infer.validatePropertySetStatement;
const FunctionBoolMap = std.HashMap(core.FunctionKey, bool, core.FunctionKeyContext, std.hash_map.default_max_load_percentage);
const FunctionVisitSet = std.HashMap(core.FunctionKey, void, core.FunctionKeyContext, std.hash_map.default_max_load_percentage);

const StatementContext = enum {
    document,
    page,
};

const NameScope = analysis_env.NameEnv;

const PageContextRequirement = struct {
    const Requirement = union(enum) {
        primitive: registry.PrimitiveDescriptor,
        function: ast.FunctionDecl,
        constant: ast.ConstDecl,

        fn displayName(self: Requirement) []const u8 {
            return switch (self) {
                .primitive => |descriptor| descriptor.name,
                .function => |func| func.name,
                .constant => |constant_decl| constant_decl.name,
            };
        }
    };

    allocator: std.mem.Allocator,
    sema: *const SemanticEnv,
    memo: FunctionBoolMap,
    visiting: FunctionVisitSet,

    fn init(allocator: std.mem.Allocator, sema: *const SemanticEnv) PageContextRequirement {
        return .{
            .allocator = allocator,
            .sema = sema,
            .memo = FunctionBoolMap.init(allocator),
            .visiting = FunctionVisitSet.init(allocator),
        };
    }

    fn deinit(self: *PageContextRequirement) void {
        self.memo.deinit();
        self.visiting.deinit();
    }

    fn exprRequirement(self: *PageContextRequirement, scope: *const NameScope, expr: ast.Expr) anyerror!?Requirement {
        return switch (expr) {
            .hole => null,
            .ident => |ident| blk: {
                const name = ident.name;
                if (scope.contains(name)) break :blk null;
                if (self.sema.resolvedConst(ast.CallableName.bare(name))) |resolved| {
                    break :blk if (try self.constRequiresPage(resolved.key, resolved.decl)) .{ .constant = resolved.decl } else null;
                }
                const resolved = self.sema.resolvedFunction(ast.CallableName.bare(name)) orelse break :blk null;
                break :blk if (try self.functionRequiresPage(resolved.key, resolved.decl)) .{ .function = resolved.decl } else null;
            },
            .string, .color, .number, .boolean, .none, .enum_case => null,
            .record => |record| blk: {
                for (record.fields.items) |field| {
                    if (try self.exprRequirement(scope, field.value)) |requirement| break :blk requirement;
                }
                break :blk null;
            },
            .record_update => |update| blk: {
                if (try self.exprRequirement(scope, update.target.*)) |requirement| break :blk requirement;
                for (update.fields.items) |field| {
                    if (try self.exprRequirement(scope, field.value)) |requirement| break :blk requirement;
                }
                break :blk null;
            },
            .call => |call| blk: {
                if (!call.callee.isQualified()) {
                    if (registry.lookupPrimitiveCall(call.callee.name)) |descriptor| {
                        if (descriptor.context == .page) break :blk .{ .primitive = descriptor };
                    }
                }
                if (self.sema.resolvedFunction(call.callee)) |resolved| {
                    if (try self.functionRequiresPage(resolved.key, resolved.decl)) break :blk .{ .function = resolved.decl };
                }
                if (self.sema.resolvedConst(call.callee)) |resolved| {
                    if (try self.constRequiresPage(resolved.key, resolved.decl)) break :blk .{ .constant = resolved.decl };
                }
                for (call.args.items) |arg| {
                    if (try self.exprRequirement(scope, arg)) |requirement| break :blk requirement;
                }
                break :blk null;
            },
            .apply => |apply| blk: {
                if (try self.exprRequirement(scope, apply.callee.*)) |requirement| break :blk requirement;
                for (apply.args.items) |arg| {
                    if (try self.exprRequirement(scope, arg)) |requirement| break :blk requirement;
                }
                break :blk null;
            },
            .lambda => |lambda| try self.lambdaRequirement(scope, lambda),
            .member => |member| try self.exprRequirement(scope, member.target.*),
            .optional_check => |check| try self.exprRequirement(scope, check.target.*),
            .coalesce => |coalesce| blk: {
                if (try self.exprRequirement(scope, coalesce.target.*)) |requirement| break :blk requirement;
                break :blk try self.exprRequirement(scope, coalesce.fallback.*);
            },
        };
    }

    fn lambdaRequirement(self: *PageContextRequirement, scope: *const NameScope, lambda: ast.LambdaExpr) anyerror!?Requirement {
        var local_scope = try scope.clone();
        defer local_scope.deinit();
        for (lambda.params.items) |param| {
            if (param.default_value) |default_value| {
                if (try self.exprRequirement(&local_scope, default_value.*)) |requirement| return requirement;
            }
            try local_scope.put(param.name);
        }
        return try self.exprRequirement(&local_scope, lambda.body.*);
    }

    fn functionRequiresPage(self: *PageContextRequirement, key: core.FunctionKey, func: ast.FunctionDecl) anyerror!bool {
        if (self.memo.get(key)) |cached| return cached;
        if (self.visiting.contains(key)) return false;
        try self.visiting.put(key, {});
        defer _ = self.visiting.remove(key);

        const previous_sema = self.sema;
        var module_sema = previous_sema.forModule(key.module_id);
        self.sema = &module_sema;
        defer self.sema = previous_sema;

        const requires = try self.functionBodyRequiresPage(func);
        try self.memo.put(key, requires);
        return requires;
    }

    fn constRequiresPage(self: *PageContextRequirement, key: core.FunctionKey, constant_decl: ast.ConstDecl) anyerror!bool {
        if (self.memo.get(key)) |cached| return cached;
        if (self.visiting.contains(key)) return false;
        try self.visiting.put(key, {});
        defer _ = self.visiting.remove(key);

        const previous_sema = self.sema;
        var module_sema = previous_sema.forModule(key.module_id);
        self.sema = &module_sema;
        defer self.sema = previous_sema;

        var scope = NameScope.init(self.allocator);
        defer scope.deinit();
        const requires = (try self.exprRequirement(&scope, constant_decl.value)) != null;
        try self.memo.put(key, requires);
        return requires;
    }

    fn functionBodyRequiresPage(self: *PageContextRequirement, func: ast.FunctionDecl) anyerror!bool {
        var scope = NameScope.init(self.allocator);
        defer scope.deinit();
        for (func.params.items) |param| {
            if (param.default_value) |default_value| {
                if ((try self.exprRequirement(&scope, default_value.*)) != null) return true;
            }
            try scope.put(param.name);
        }
        for (func.statements.items) |stmt| {
            if (try self.statementRequiresPage(&scope, stmt)) return true;
        }
        return false;
    }

    fn statementRequiresPage(self: *PageContextRequirement, scope: *NameScope, stmt: ast.Statement) anyerror!bool {
        return switch (stmt.kind) {
            .hole => false,
            .let_binding => |binding| blk: {
                if ((try self.exprRequirement(scope, binding.expr)) != null) break :blk true;
                if (language_names.isDiscardBindingName(binding.name)) break :blk false;
                try scope.put(binding.name);
                break :blk false;
            },
            .return_expr => |expr| (try self.exprRequirement(scope, expr)) != null,
            .return_void => false,
            .property_set => |property_set| blk: {
                if ((try self.exprRequirement(scope, property_set.target)) != null) break :blk true;
                break :blk (try self.exprRequirement(scope, property_set.value)) != null;
            },
            .constrain => |constraint| if (constraint.offset) |offset| (try self.exprRequirement(scope, offset)) != null else false,
            .expr_stmt => |expr| (try self.exprRequirement(scope, expr)) != null,
            .if_stmt => |if_stmt| blk: {
                if ((try self.exprRequirement(scope, if_stmt.condition)) != null) break :blk true;
                var then_scope = try scope.clone();
                defer then_scope.deinit();
                for (if_stmt.then_statements.items) |nested| {
                    if (try self.statementRequiresPage(&then_scope, nested)) break :blk true;
                }
                var else_scope = try scope.clone();
                defer else_scope.deinit();
                for (if_stmt.else_statements.items) |nested| {
                    if (try self.statementRequiresPage(&else_scope, nested)) break :blk true;
                }
                break :blk false;
            },
        };
    }
};

pub fn originPathForModule(module: *const core.SourceModule) []const u8 {
    return module.path orelse module.spec;
}

fn statementOrigin(allocator: std.mem.Allocator, origin_path: []const u8, span: ast.Span) ![]const u8 {
    if (origin_path.len != 0) {
        return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ origin_path, span.start, span.end });
    }
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}

fn addUserReport(state: ?*core.DocumentState, origin: []const u8, comptime fmt: []const u8, args: anytype) !void {
    const sink = state orelse return;
    const message = try std.fmt.allocPrint(sink.allocator, fmt, args);
    try sink.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = message },
    });
}

fn continueAfterDiagnostic(state: *const core.DocumentState, diagnostic_count_before: usize, err: anyerror) !void {
    if (state.diagnostics.items.len > diagnostic_count_before) return;
    return err;
}

fn rejectDuplicateBinding(state: ?*core.DocumentState, env: *const TypeEnv, name: []const u8, origin: []const u8) !void {
    if (!env.contains(name)) return;
    try addUserReport(state, origin, "DuplicateBinding: binding '{s}' is already defined in this scope", .{name});
    return error.DuplicateBinding;
}

pub fn checkPageNamesUnique(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
) !void {
    var pages = std.StringHashMap(void).init(allocator);
    defer pages.deinit();

    for (state.module_order.items) |module_id| {
        const module = state.moduleById(module_id) orelse continue;
        const origin_path = originPathForModule(module);
        for (module.syntax.pages.items) |page| {
            if (pages.contains(page.name)) {
                const origin = try statementOrigin(allocator, origin_path, page.span);
                defer allocator.free(origin);
                try addUserReport(state, origin, "DuplicatePage: page '{s}' is already defined", .{page.name});
                return error.DuplicatePage;
            }
            try pages.put(page.name, {});
        }
    }
}

pub fn checkFunction(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    func: ast.FunctionDecl,
) !void {
    var env = TypeEnv.init(allocator);
    defer env.deinit();

    const func_origin = try statementOrigin(allocator, origin_path, func.span);
    defer allocator.free(func_origin);
    for (func.params.items) |param| {
        try rejectDuplicateBinding(state, &env, param.name, func_origin);
        if (param.default_value) |default_value| {
            const info = try inferExprInfo(allocator, state, sema, &env, default_value.*, func_origin);
            try ensureType(state, allocator, info, param.ty, func_origin, .UnmatchedArgumentType);
        }
        try env.put(param.name, infoFromType(param.ty));
    }

    var had_diagnostics = false;
    for (func.statements.items) |stmt| {
        const diagnostic_count = state.diagnostics.items.len;
        checkStatement(allocator, state, sema, origin_path, &env, func.result_type, stmt) catch |err| {
            try continueAfterDiagnostic(state, diagnostic_count, err);
            had_diagnostics = true;
        };
    }
    if (had_diagnostics) return error.DiagnosticsFailed;
}

pub fn checkConst(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    constant_decl: ast.ConstDecl,
) !void {
    const origin = try statementOrigin(allocator, origin_path, constant_decl.span);
    defer allocator.free(origin);

    var env = TypeEnv.init(allocator);
    defer env.deinit();
    var scope = NameScope.init(allocator);
    defer scope.deinit();
    var page_context = PageContextRequirement.init(allocator, sema);
    defer page_context.deinit();

    var had_diagnostics = false;
    {
        const diagnostic_count = state.diagnostics.items.len;
        rejectPageOnlyExpr(state, .document, origin, &page_context, &scope, constant_decl.value) catch |err| {
            try continueAfterDiagnostic(state, diagnostic_count, err);
            had_diagnostics = true;
        };
    }
    {
        const diagnostic_count = state.diagnostics.items.len;
        const actual = inferExprInfo(allocator, state, sema, &env, constant_decl.value, origin) catch |err| {
            try continueAfterDiagnostic(state, diagnostic_count, err);
            had_diagnostics = true;
            return error.DiagnosticsFailed;
        };
        ensureType(state, allocator, actual, constant_decl.value_type, origin, .UnmatchedReturnType) catch |err| {
            try continueAfterDiagnostic(state, diagnostic_count, err);
            had_diagnostics = true;
        };
    }
    if (had_diagnostics) return error.DiagnosticsFailed;
}

pub fn checkPageStatements(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    program: ast.Module,
) !void {
    var page_context = PageContextRequirement.init(allocator, sema);
    defer page_context.deinit();
    var had_diagnostics = false;

    {
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        var scope = NameScope.init(allocator);
        defer scope.deinit();
        for (program.document_statements.items) |stmt| {
            const diagnostic_count = state.diagnostics.items.len;
            checkTopLevelStatement(allocator, state, sema, origin_path, .document, &env, &scope, &page_context, stmt) catch |err| {
                try continueAfterDiagnostic(state, diagnostic_count, err);
                had_diagnostics = true;
            };
        }
    }
    for (program.pages.items) |page| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        var scope = NameScope.init(allocator);
        defer scope.deinit();

        for (page.statements.items) |stmt| {
            const diagnostic_count = state.diagnostics.items.len;
            checkTopLevelStatement(allocator, state, sema, origin_path, .page, &env, &scope, &page_context, stmt) catch |err| {
                try continueAfterDiagnostic(state, diagnostic_count, err);
                had_diagnostics = true;
            };
        }
    }
    if (had_diagnostics) return error.DiagnosticsFailed;
}

fn checkTopLevelStatement(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    context: StatementContext,
    env: *TypeEnv,
    scope: *NameScope,
    page_context: *PageContextRequirement,
    stmt: ast.Statement,
) !void {
    const origin = try statementOrigin(allocator, origin_path, stmt.span);
    defer allocator.free(origin);
    switch (stmt.kind) {
        .hole => return,
        .let_binding => |binding| {
            const binds_name = !language_names.isDiscardBindingName(binding.name);
            if (binds_name) try rejectDuplicateBinding(state, env, binding.name, origin);
            try rejectPageOnlyExpr(state, context, origin, page_context, scope, binding.expr);
            const inferred = try inferExprInfo(allocator, state, sema, env, binding.expr, origin);
            const info = try checkedLetBindingInfo(allocator, state, binding, inferred, origin);
            try rejectVoidValue(state, info, origin);
            if (!binds_name) return;
            try env.put(binding.name, info);
            try scope.put(binding.name);
        },
        .return_expr => {
            try addUserReport(state, origin, "ReturnOutsideFunction: return is only valid inside a function", .{});
            return error.ReturnOutsideFunction;
        },
        .return_void => {
            try addUserReport(state, origin, "ReturnOutsideFunction: return is only valid inside a function", .{});
            return error.ReturnOutsideFunction;
        },
        .property_set => |property_set| {
            try rejectPageOnlyExpr(state, context, origin, page_context, scope, property_set.target);
            try rejectPageOnlyExpr(state, context, origin, page_context, scope, property_set.value);
            try validatePropertySetStatement(allocator, state, sema, env, property_set.target, property_set.path.items, property_set.value, origin);
        },
        .if_stmt => |if_stmt| {
            try rejectPageOnlyExpr(state, context, origin, page_context, scope, if_stmt.condition);
            const condition = try inferExprInfo(allocator, state, sema, env, if_stmt.condition, origin);
            try ensureType(state, allocator, condition, Type.boolean, origin, .UnmatchedArgumentType);
            var then_env = try env.clone();
            defer then_env.deinit();
            var then_scope = try scope.clone();
            defer then_scope.deinit();
            for (if_stmt.then_statements.items) |nested| {
                try checkTopLevelStatement(allocator, state, sema, origin_path, context, &then_env, &then_scope, page_context, nested);
            }
            var else_env = try env.clone();
            defer else_env.deinit();
            var else_scope = try scope.clone();
            defer else_scope.deinit();
            for (if_stmt.else_statements.items) |nested| {
                try checkTopLevelStatement(allocator, state, sema, origin_path, context, &else_env, &else_scope, page_context, nested);
            }
        },
        .expr_stmt => |expr| {
            try rejectPageOnlyExpr(state, context, origin, page_context, scope, expr);
            _ = try inferExprInfo(allocator, state, sema, env, expr, origin);
        },
        .constrain => |decl| {
            if (context != .page) {
                try addUserReport(state, origin, "NoCurrentPage: constraints are only valid inside a page block", .{});
                return error.NoCurrentPage;
            }
            try validateAnchorRef(allocator, state, sema, env, origin, decl.target, true);
            if (decl.source) |source| try validateAnchorRef(allocator, state, sema, env, origin, source, false);
            if (decl.offset) |expr| {
                try rejectPageOnlyExpr(state, context, origin, page_context, scope, expr);
                const actual = try inferExprInfo(allocator, state, sema, env, expr, origin);
                try ensureType(state, allocator, actual, Type.number, origin, .UnmatchedArgumentType);
            }
        },
    }
}

fn rejectVoidValue(state: *core.DocumentState, info: semantic_types.TypeInfo, origin: []const u8) !void {
    if (info.hole != null) return;
    if (info.ty.kind != .void) return;
    try addUserReport(state, origin, "VoidValue: void results can only be used as statements", .{});
    return error.InvalidType;
}

fn checkedLetBindingInfo(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    binding: anytype,
    inferred: semantic_types.TypeInfo,
    origin: []const u8,
) !semantic_types.TypeInfo {
    const annotation = binding.type_annotation orelse return inferred;
    try ensureType(state, allocator, inferred, annotation, origin, .UnmatchedReturnType);
    return infoFromType(annotation);
}

fn rejectPageOnlyExpr(
    state: *core.DocumentState,
    context: StatementContext,
    origin: []const u8,
    page_context: *PageContextRequirement,
    scope: *const NameScope,
    expr: ast.Expr,
) !void {
    if (context == .page) return;
    if (try page_context.exprRequirement(scope, expr)) |requirement| {
        try addUserReport(state, origin, "NoCurrentPage: '{s}' is only valid inside a page block", .{requirement.displayName()});
        return error.NoCurrentPage;
    }
}

fn validateAnchorRef(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    env: *TypeEnv,
    origin: []const u8,
    anchor_ref: ast.AnchorRef,
    is_target: bool,
) !void {
    switch (anchor_ref.kind) {
        .page => if (is_target) {
            try addUserReport(state, origin, "PageCannotBeConstraintTarget: page anchors cannot be constraint targets", .{});
            return error.PageCannotBeConstraintTarget;
        },
        .node => {
            const path = anchorObjectPath(anchor_ref) orelse return;
            const info = try resolveAnchorPathInfo(state, sema, env, origin, path);
            if (info.hole != null) return;
            if (!isObjectLike(info)) {
                try ensureType(state, allocator, info, Type.object, origin, .UnmatchedArgumentType);
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
    origin: []const u8,
    path: []const u8,
) !semantic_types.TypeInfo {
    var iter = std.mem.splitScalar(u8, path, '.');
    const first = iter.next() orelse return error.UnknownIdentifier;
    var info = env.get(first) orelse {
        try addUserReport(state, origin, "UnknownIdentifier: unknown constraint object '{s}'", .{first});
        return error.UnknownIdentifier;
    };
    while (iter.next()) |field_name| {
        if (info.hole != null) return info;
        if (info.ty.kind != .record) {
            try addUserReport(state, origin, "InvalidConstraintObject: anchor path '{s}' does not resolve through a record", .{path});
            return error.InvalidType;
        }
        const record_name = info.ty.class_name orelse {
            try addUserReport(state, origin, "InvalidRecordType: record type has no name", .{});
            return error.InvalidType;
        };
        const field = sema.recordField(record_name, field_name) orelse {
            try addUserReport(state, origin, "UnknownRecordField: record type '{s}' has no field '{s}'", .{ record_name, field_name });
            return error.InvalidType;
        };
        info = infoFromType(field.value_type);
    }
    return info;
}

fn isObjectLike(info: semantic_types.TypeInfo) bool {
    return switch (info.ty.kind) {
        .object => true,
        else => false,
    };
}

fn checkStatement(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    env: *TypeEnv,
    result_type: Type,
    stmt: ast.Statement,
) !void {
    const origin = try statementOrigin(allocator, origin_path, stmt.span);
    defer allocator.free(origin);
    switch (stmt.kind) {
        .hole => return,
        .let_binding => |binding| {
            const binds_name = !language_names.isDiscardBindingName(binding.name);
            if (binds_name) try rejectDuplicateBinding(state, env, binding.name, origin);
            const inferred = try inferExprInfo(allocator, state, sema, env, binding.expr, origin);
            const info = try checkedLetBindingInfo(allocator, state, binding, inferred, origin);
            try rejectVoidValue(state, info, origin);
            if (!binds_name) return;
            try env.put(binding.name, info);
        },
        .return_expr => |expr| {
            const actual = try inferExprInfo(allocator, state, sema, env, expr, origin);
            try ensureType(state, allocator, actual, result_type, origin, .UnmatchedReturnType);
        },
        .return_void => {
            if (result_type.kind != .void) {
                try ensureType(state, allocator, infoFromType(.{ .kind = .void }), result_type, origin, .UnmatchedReturnType);
            }
        },
        .property_set => |property_set| {
            try validatePropertySetStatement(allocator, state, sema, env, property_set.target, property_set.path.items, property_set.value, origin);
        },
        .if_stmt => |if_stmt| {
            const condition = try inferExprInfo(allocator, state, sema, env, if_stmt.condition, origin);
            try ensureType(state, allocator, condition, Type.boolean, origin, .UnmatchedArgumentType);
            var then_env = try env.clone();
            defer then_env.deinit();
            for (if_stmt.then_statements.items) |nested| {
                try checkStatement(allocator, state, sema, origin_path, &then_env, result_type, nested);
            }
            var else_env = try env.clone();
            defer else_env.deinit();
            for (if_stmt.else_statements.items) |nested| {
                try checkStatement(allocator, state, sema, origin_path, &else_env, result_type, nested);
            }
        },
        .expr_stmt => |expr| {
            _ = try inferExprInfo(allocator, state, sema, env, expr, origin);
        },
        .constrain => |decl| {
            if (decl.offset) |expr| {
                const actual = try inferExprInfo(allocator, state, sema, env, expr, origin);
                try ensureType(state, allocator, actual, Type.number, origin, .UnmatchedArgumentType);
            }
        },
    }
}
