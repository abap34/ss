const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const semantic_env = @import("../language/env.zig");
const infer = @import("infer.zig");
const semantic_types = @import("types.zig");

const Type = ast.Type;
const SemanticEnv = semantic_env.SemanticEnv;
const TypeEnv = semantic_types.TypeEnv;
const ensureType = semantic_types.ensureType;
const infoFromSort = semantic_types.infoFromSort;
const infoFromType = semantic_types.infoFromType;
const inferExprInfo = infer.exprInfo;
const validatePropertySetStatement = infer.validatePropertySetStatement;

const StatementContext = enum {
    document,
    page,
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

fn addUserReport(ir: ?*core.Ir, origin: []const u8, comptime fmt: []const u8, args: anytype) !void {
    const sink = ir orelse return;
    const message = try std.fmt.allocPrint(sink.allocator, fmt, args);
    try sink.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = message },
    });
}

pub fn checkPageNamesUnique(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
) !void {
    var pages = std.StringHashMap(void).init(allocator);
    defer pages.deinit();

    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        const origin_path = originPathForModule(module);
        for (module.program.pages.items) |page| {
            if (pages.contains(page.name)) {
                const origin = try statementOrigin(allocator, origin_path, page.span);
                defer allocator.free(origin);
                try addUserReport(ir, origin, "DuplicatePage: page '{s}' is already defined", .{page.name});
                return error.DuplicatePage;
            }
            try pages.put(page.name, {});
        }
    }
}

pub fn checkFunction(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    func: ast.FunctionDecl,
) !void {
    var env = TypeEnv.init(allocator);
    defer env.deinit();

    const func_origin = try statementOrigin(allocator, origin_path, func.span);
    defer allocator.free(func_origin);
    for (func.params.items) |param| {
        if (param.default_value) |default_value| {
            const info = try inferExprInfo(allocator, ir, sema, &env, default_value.*, func_origin);
            try ensureType(ir, allocator, info, param.ty, func_origin, .UnmatchedArgumentType);
        }
        var param_info = infoFromType(param.ty);
        param_info.sort = param.sort;
        try env.put(param.name, param_info);
    }

    for (func.statements.items) |stmt| {
        try checkStatement(allocator, ir, sema, origin_path, &env, func.result_type, stmt);
    }
}

pub fn checkPageStatements(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    program: ast.Program,
) !void {
    {
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        for (program.document_statements.items) |stmt| {
            try checkTopLevelStatement(allocator, ir, sema, origin_path, .document, &env, stmt);
        }
    }
    for (program.pages.items) |page| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();

        for (page.statements.items) |stmt| {
            try checkTopLevelStatement(allocator, ir, sema, origin_path, .page, &env, stmt);
        }
    }
}

fn checkTopLevelStatement(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    context: StatementContext,
    env: *TypeEnv,
    stmt: ast.Statement,
) !void {
    const origin = try statementOrigin(allocator, origin_path, stmt.span);
    defer allocator.free(origin);
    switch (stmt.kind) {
        .let_binding => |binding| {
            try rejectPageOnlyExpr(allocator, ir, context, origin, binding.expr);
            const info = try inferExprInfo(allocator, ir, sema, env, binding.expr, origin);
            try rejectVoidValue(ir, info, origin);
            try env.put(binding.name, info);
        },
        .return_expr => {
            try addUserReport(ir, origin, "ReturnOutsideFunction: return is only valid inside a function", .{});
            return error.ReturnOutsideFunction;
        },
        .return_void => {
            try addUserReport(ir, origin, "ReturnOutsideFunction: return is only valid inside a function", .{});
            return error.ReturnOutsideFunction;
        },
        .property_set => |property_set| {
            try rejectPageOnlyExpr(allocator, ir, context, origin, property_set.value);
            try validatePropertySetStatement(allocator, ir, sema, env, property_set.object_name, property_set.property_name, property_set.value, origin);
        },
        .if_stmt => |if_stmt| {
            try rejectPageOnlyExpr(allocator, ir, context, origin, if_stmt.condition);
            const condition = try inferExprInfo(allocator, ir, sema, env, if_stmt.condition, origin);
            try ensureType(ir, allocator, condition, Type.boolean, origin, .UnmatchedArgumentType);
            var then_env = try env.clone();
            defer then_env.deinit();
            for (if_stmt.then_statements.items) |nested| {
                try checkTopLevelStatement(allocator, ir, sema, origin_path, context, &then_env, nested);
            }
            var else_env = try env.clone();
            defer else_env.deinit();
            for (if_stmt.else_statements.items) |nested| {
                try checkTopLevelStatement(allocator, ir, sema, origin_path, context, &else_env, nested);
            }
        },
        .expr_stmt => |expr| {
            try rejectPageOnlyExpr(allocator, ir, context, origin, expr);
            _ = try inferExprInfo(allocator, ir, sema, env, expr, origin);
        },
        .constrain => |decl| {
            if (context != .page) {
                try addUserReport(ir, origin, "NoCurrentPage: constraints are only valid inside a page block", .{});
                return error.NoCurrentPage;
            }
            try validateAnchorRef(allocator, ir, env, origin, decl.target, true);
            try validateAnchorRef(allocator, ir, env, origin, decl.source, false);
            if (decl.offset) |expr| {
                try rejectPageOnlyExpr(allocator, ir, context, origin, expr);
                const actual = try inferExprInfo(allocator, ir, sema, env, expr, origin);
                try ensureType(ir, allocator, actual, Type.number, origin, .UnmatchedArgumentType);
            }
        },
    }
}

fn rejectVoidValue(ir: *core.Ir, info: semantic_types.TypeInfo, origin: []const u8) !void {
    if (info.sort != .void) return;
    try addUserReport(ir, origin, "VoidValue: void results can only be used as statements", .{});
    return error.InvalidSemanticSort;
}

fn rejectPageOnlyExpr(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    context: StatementContext,
    origin: []const u8,
    expr: ast.Expr,
) !void {
    if (context == .page) return;
    switch (expr) {
        .call => |call| {
            if (isPageOnlyCall(call.name)) {
                try addUserReport(ir, origin, "NoCurrentPage: '{s}' is only valid inside a page block", .{call.name});
                return error.NoCurrentPage;
            }
            for (call.args.items) |arg| try rejectPageOnlyExpr(allocator, ir, context, origin, arg);
        },
        .apply => |apply| {
            try rejectPageOnlyExpr(allocator, ir, context, origin, apply.callee.*);
            for (apply.args.items) |arg| try rejectPageOnlyExpr(allocator, ir, context, origin, arg);
        },
        .lambda => |lambda| try rejectPageOnlyExpr(allocator, ir, context, origin, lambda.body.*),
        else => {},
    }
}

fn isPageOnlyCall(name: []const u8) bool {
    return std.mem.eql(u8, name, "pagectx") or
        std.mem.eql(u8, name, "object") or
        std.mem.eql(u8, name, "group");
}

fn validateAnchorRef(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    env: *TypeEnv,
    origin: []const u8,
    anchor_ref: ast.AnchorRef,
    is_target: bool,
) !void {
    switch (anchor_ref.kind) {
        .page => if (is_target) {
            try addUserReport(ir, origin, "PageCannotBeConstraintTarget: page anchors cannot be constraint targets", .{});
            return error.PageCannotBeConstraintTarget;
        },
        .node => {
            const name = anchor_ref.node_name orelse return;
            const info = env.get(name) orelse {
                try addUserReport(ir, origin, "UnknownIdentifier: unknown constraint object '{s}'", .{name});
                return error.UnknownIdentifier;
            };
            if (!isObjectLike(info)) {
                try ensureType(ir, allocator, info, Type.object, origin, .UnmatchedArgumentType);
            }
        },
    }
}

fn isObjectLike(info: semantic_types.TypeInfo) bool {
    return switch (info.ty.tag) {
        .object => true,
        .code => info.ty.param == .object,
        else => info.sort == .object,
    };
}

fn checkStatement(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    env: *TypeEnv,
    result_type: Type,
    stmt: ast.Statement,
) !void {
    const origin = try statementOrigin(allocator, origin_path, stmt.span);
    defer allocator.free(origin);
    switch (stmt.kind) {
        .let_binding => |binding| {
            const info = try inferExprInfo(allocator, ir, sema, env, binding.expr, origin);
            try rejectVoidValue(ir, info, origin);
            try env.put(binding.name, info);
        },
        .return_expr => |expr| {
            const actual = try inferExprInfo(allocator, ir, sema, env, expr, origin);
            try ensureType(ir, allocator, actual, result_type, origin, .UnmatchedReturnType);
        },
        .return_void => {
            if (result_type.tag != .void) {
                try ensureType(ir, allocator, infoFromType(.{ .tag = .void }), result_type, origin, .UnmatchedReturnType);
            }
        },
        .property_set => |property_set| {
            try validatePropertySetStatement(allocator, ir, sema, env, property_set.object_name, property_set.property_name, property_set.value, origin);
        },
        .if_stmt => |if_stmt| {
            const condition = try inferExprInfo(allocator, ir, sema, env, if_stmt.condition, origin);
            try ensureType(ir, allocator, condition, Type.boolean, origin, .UnmatchedArgumentType);
            var then_env = try env.clone();
            defer then_env.deinit();
            for (if_stmt.then_statements.items) |nested| {
                try checkStatement(allocator, ir, sema, origin_path, &then_env, result_type, nested);
            }
            var else_env = try env.clone();
            defer else_env.deinit();
            for (if_stmt.else_statements.items) |nested| {
                try checkStatement(allocator, ir, sema, origin_path, &else_env, result_type, nested);
            }
        },
        .expr_stmt => |expr| {
            _ = try inferExprInfo(allocator, ir, sema, env, expr, origin);
        },
        .constrain => |decl| {
            if (decl.offset) |expr| {
                const actual = try inferExprInfo(allocator, ir, sema, env, expr, origin);
                try ensureType(ir, allocator, actual, Type.number, origin, .UnmatchedArgumentType);
            }
        },
    }
}
