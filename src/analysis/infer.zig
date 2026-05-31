const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const declarations = @import("../language/declarations.zig");
const semantic_env = @import("../language/env.zig");
const registry = @import("../language/registry.zig");
const contracts = @import("contracts.zig");
const semantic_types = @import("types.zig");

const Type = ast.Type;
const SemanticEnv = semantic_env.SemanticEnv;
const TypeEnv = semantic_types.TypeEnv;
const TypeInfo = semantic_types.TypeInfo;
const ensureSort = semantic_types.ensureSort;
const ensureType = semantic_types.ensureType;
const infoFromSort = semantic_types.infoFromSort;
const infoFromType = semantic_types.infoFromType;
const isPropertyTarget = semantic_types.isPropertyTarget;
const mergeObjectClass = semantic_types.mergeObjectClass;
const mergeTypeInfo = semantic_types.mergeTypeInfo;
const resolveStringLiteral = semantic_types.resolveStringLiteral;
const singleFunctionLabel = semantic_types.singleFunctionLabel;
const targetClassForInfo = semantic_types.targetClassForInfo;
const typeLabelAlloc = semantic_types.typeLabelAlloc;

threadlocal var active_return_visiting: ?*std.StringHashMap(void) = null;

const InferenceOptions = struct {
    validate_contracts: bool = true,
};

fn isConst(func: ast.FunctionDecl) bool {
    return func.kind == .constant;
}

fn addUserReport(ir: ?*core.Ir, origin: []const u8, comptime fmt: []const u8, args: anytype) !void {
    const sink = ir orelse return;
    const message = try std.fmt.allocPrint(sink.allocator, fmt, args);
    try sink.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = message },
    });
}

fn originPathForFunction(sema: *const SemanticEnv, func: ast.FunctionDecl) []const u8 {
    const ir = sema.ir orelse return "";
    const metadata = ir.function_metadata.get(func.name) orelse return "";
    const module = ir.moduleById(metadata.module_id) orelse return "";
    return module.path orelse module.spec;
}

fn statementOrigin(allocator: std.mem.Allocator, origin_path: []const u8, span: ast.Span) ![]const u8 {
    if (origin_path.len != 0) {
        return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ origin_path, span.start, span.end });
    }
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}

pub fn exprSort(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    expr: ast.Expr,
    origin: []const u8,
) anyerror!core.SemanticSort {
    return (try exprInfoWithOptions(allocator, ir, sema, env, expr, origin, .{})).sort;
}

pub fn exprInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    expr: ast.Expr,
    origin: []const u8,
) anyerror!TypeInfo {
    return exprInfoWithOptions(allocator, ir, sema, env, expr, origin, .{});
}

fn exprInfoWithOptions(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    expr: ast.Expr,
    origin: []const u8,
    options: InferenceOptions,
) anyerror!TypeInfo {
    return switch (expr) {
        .string => |text| blk: {
            var info = infoFromSort(.string);
            info.string_literal = text;
            break :blk info;
        },
        .number => infoFromSort(.number),
        .boolean => infoFromSort(.boolean),
        .ident => |name| blk: {
            if (env.get(name)) |info| break :blk info;
            if (sema.function(name)) |func| {
                if (isConst(func)) break :blk infoFromType(func.result_type);
                var info = infoFromType(try functionTypeForDecl(allocator, func));
                info.function_labels = try singleFunctionLabel(allocator, func.name);
                break :blk info;
            }
            try addUserReport(ir, origin, "UnknownIdentifier: unknown identifier: {s}", .{name});
            return error.UnknownIdentifier;
        },
        .call => |call| try inferCallInfo(allocator, ir, sema, env, call, origin, options),
        .apply => |apply| try inferApplyInfo(allocator, ir, sema, env, apply.callee.*, apply.args.items, origin, options),
        .lambda => |lambda| try inferLambdaInfo(allocator, ir, sema, env, lambda, origin, options),
    };
}

fn functionTypeForDecl(allocator: std.mem.Allocator, func: ast.FunctionDecl) !Type {
    const params = try allocator.alloc(Type, func.params.items.len);
    defer allocator.free(params);
    for (func.params.items, 0..) |param, index| params[index] = param.ty;
    return try Type.functionType(allocator, params, func.result_type);
}

fn lambdaLabel(allocator: std.mem.Allocator, lambda: ast.LambdaExpr) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "lambda:{d}-{d}", .{ lambda.span.start, lambda.span.end });
}

fn inferLambdaInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    lambda: ast.LambdaExpr,
    origin: []const u8,
    options: InferenceOptions,
) !TypeInfo {
    var local_env = try env.clone();
    defer local_env.deinit();
    const param_types = try allocator.alloc(Type, lambda.params.items.len);
    defer allocator.free(param_types);
    for (lambda.params.items, 0..) |param, index| {
        param_types[index] = param.ty;
        var param_info = infoFromType(param.ty);
        param_info.sort = param.sort;
        try local_env.put(param.name, param_info);
    }
    const body_info = try exprInfoWithOptions(allocator, ir, sema, &local_env, lambda.body.*, origin, options);
    if (body_info.sort == .void) {
        try addUserReport(ir, origin, "VoidValue: lambda bodies must produce a value", .{});
        return error.InvalidSemanticSort;
    }
    var info = infoFromType(try Type.functionType(allocator, param_types, body_info.ty));
    info.function_labels = try singleFunctionLabel(allocator, try lambdaLabel(allocator, lambda));
    return info;
}

fn inferCallInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: []const u8,
    options: InferenceOptions,
) anyerror!TypeInfo {
    if (env.get(call.name)) |callee_info| {
        if (callee_info.ty.tag == .function and callee_info.ty.fn_result != null) {
            return try inferFunctionValueCallInfo(allocator, ir, sema, env, callee_info, call.args.items, origin, options);
        }
    }
    if (sema.function(call.name)) |func| {
        if (isConst(func) and func.result_type.tag == .function and func.result_type.fn_result != null) {
            const const_info = try inferUserFunctionReturnInfo(allocator, ir, sema, env, func, .{
                .name = call.name,
                .args = std.ArrayList(ast.Expr).empty,
            }, origin, options);
            return try inferFunctionValueCallInfo(allocator, ir, sema, env, const_info, call.args.items, origin, options);
        }
    }
    const descriptor = sema.call(call.name) orelse {
        try addUserReport(ir, origin, "UnknownFunction: unknown function: {s}", .{call.name});
        return error.UnknownFunction;
    };
    return switch (descriptor) {
        .function => |func| try inferUserCallInfo(allocator, ir, sema, env, call, origin, func, options),
        .primitive => |primitive| try inferPrimitiveCallInfo(allocator, ir, sema, env, call, origin, primitive, options),
    };
}

fn inferApplyInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    callee: ast.Expr,
    args: []const ast.Expr,
    origin: []const u8,
    options: InferenceOptions,
) !TypeInfo {
    const callee_info = try exprInfoWithOptions(allocator, ir, sema, env, callee, origin, options);
    return try inferFunctionValueCallInfo(allocator, ir, sema, env, callee_info, args, origin, options);
}

fn inferFunctionValueCallInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    callee_info: TypeInfo,
    args: []const ast.Expr,
    origin: []const u8,
    options: InferenceOptions,
) !TypeInfo {
    if (callee_info.ty.tag != .function or callee_info.ty.fn_result == null) {
        try ensureSort(ir, callee_info.sort, .function, origin, .UnmatchedArgumentType);
        return error.InvalidSemanticSort;
    }
    if (args.len != callee_info.ty.fn_params.len) {
        try addUserReport(ir, origin, "InvalidArity: expected {d}, got {d}", .{ callee_info.ty.fn_params.len, args.len });
        return error.InvalidArity;
    }
    for (args, 0..) |arg, index| {
        const actual = try exprInfoWithOptions(allocator, ir, sema, env, arg, origin, options);
        try ensureType(ir, allocator, actual, callee_info.ty.fn_params[index], origin, .UnmatchedArgumentType);
    }
    return infoFromType(callee_info.ty.fn_result.?.*);
}

fn inferUserCallInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: []const u8,
    func: ast.FunctionDecl,
    options: InferenceOptions,
) !TypeInfo {
    if (isConst(func)) {
        try addUserReport(ir, origin, "UnknownFunction: constants are values; use '{s}' without parentheses", .{call.name});
        return error.UnknownFunction;
    }
    const min_arity = contracts.requiredParamCount(func);
    const max_arity = func.params.items.len;
    if (call.args.items.len < min_arity or call.args.items.len > max_arity) {
        if (min_arity == max_arity) {
            try addUserReport(ir, origin, "InvalidArity: expected {d}, got {d}", .{ max_arity, call.args.items.len });
        } else {
            try addUserReport(ir, origin, "InvalidArity: expected {d}..{d}, got {d}", .{ min_arity, max_arity, call.args.items.len });
        }
        return error.InvalidArity;
    }
    for (call.args.items, 0..) |arg, index| {
        const param = func.params.items[index];
        const actual = try exprInfoWithOptions(allocator, ir, sema, env, arg, origin, options);
        try ensureType(ir, allocator, actual, param.ty, origin, .UnmatchedArgumentType);
    }
    return try inferUserFunctionReturnInfo(allocator, ir, sema, env, func, call, origin, options);
}

fn inferPrimitiveCallInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: []const u8,
    descriptor: registry.PrimitiveDescriptor,
    options: InferenceOptions,
) !TypeInfo {
    if (call.args.items.len < descriptor.min_arity or call.args.items.len > descriptor.max_arity) {
        if (descriptor.min_arity == descriptor.max_arity) {
            try addUserReport(ir, origin, "InvalidArity: expected {d}, got {d}", .{ descriptor.min_arity, call.args.items.len });
        } else {
            try addUserReport(ir, origin, "InvalidArity: expected {d}..{d}, got {d}", .{ descriptor.min_arity, descriptor.max_arity, call.args.items.len });
        }
        return error.InvalidArity;
    }
    for (call.args.items, 0..) |arg, index| {
        if (isPrimitiveFunctionArgument(descriptor, index)) continue;
        const actual = try exprInfoWithOptions(allocator, ir, sema, env, arg, origin, options);
        if (registry.primitiveArgType(descriptor, index)) |expected| {
            try ensureType(ir, allocator, actual, expected, origin, .UnmatchedArgumentType);
        }
    }
    const info = try primitiveResultTypeInfo(allocator, ir, sema, env, call, descriptor, origin, options);
    if (ir != null and options.validate_contracts) {
        switch (descriptor.op) {
            .set_prop => try validateSetPropCall(ir.?, call, env, sema, origin),
            .extend_render_env => try validateExtendRenderEnvCall(ir.?, call, env, sema, origin),
            else => {},
        }
    }
    return info;
}

fn isPrimitiveFunctionArgument(descriptor: registry.PrimitiveDescriptor, index: usize) bool {
    const callback = descriptor.callback orelse return false;
    return index == callback.function_arg_index;
}

fn inferUserFunctionReturnInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    caller_env: *const TypeEnv,
    func: ast.FunctionDecl,
    call: ast.CallExpr,
    origin: []const u8,
    options: InferenceOptions,
) !TypeInfo {
    if (active_return_visiting) |visiting| {
        return inferUserFunctionReturnInfoInner(allocator, ir, sema, caller_env, func, call, origin, options, visiting);
    }
    var visiting = std.StringHashMap(void).init(allocator);
    defer visiting.deinit();
    active_return_visiting = &visiting;
    defer active_return_visiting = null;
    return inferUserFunctionReturnInfoInner(allocator, ir, sema, caller_env, func, call, origin, options, &visiting);
}

fn inferUserFunctionReturnInfoInner(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    caller_env: *const TypeEnv,
    func: ast.FunctionDecl,
    call: ast.CallExpr,
    origin: []const u8,
    options: InferenceOptions,
    visiting: *std.StringHashMap(void),
) !TypeInfo {
    if (visiting.contains(func.name)) {
        var info = infoFromType(func.result_type);
        info.object_class = func.result_type.class_name;
        return info;
    }
    try visiting.put(func.name, {});
    defer _ = visiting.remove(func.name);

    var env = TypeEnv.init(allocator);
    defer env.deinit();
    for (func.params.items, 0..) |param, index| {
        const info: TypeInfo = if (index < call.args.items.len)
            try exprInfoWithOptions(allocator, ir, sema, caller_env, call.args.items[index], origin, options)
        else if (param.default_value) |default_value|
            try exprInfoWithOptions(allocator, ir, sema, &env, default_value.*, origin, options)
        else blk: {
            var param_info = infoFromType(param.ty);
            param_info.sort = param.sort;
            break :blk param_info;
        };
        try env.put(param.name, info);
    }

    var result = infoFromType(func.result_type);
    try inferReturnInfoFromStatements(
        allocator,
        ir,
        sema,
        originPathForFunction(sema, func),
        .{ .validate_contracts = false },
        &env,
        func.statements.items,
        &result,
    );
    result.ty = func.result_type;
    result.sort = func.result_sort;
    if (func.result_type.class_name) |class_name| result.object_class = class_name;
    return result;
}

fn inferReturnInfoFromStatements(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    options: InferenceOptions,
    env: *TypeEnv,
    statements: []const ast.Statement,
    result: *TypeInfo,
) !void {
    for (statements) |stmt| {
        const origin = try statementOrigin(allocator, origin_path, stmt.span);
        defer allocator.free(origin);
        switch (stmt.kind) {
            .let_binding => |binding| {
                const info = try exprInfoWithOptions(allocator, ir, sema, env, binding.expr, origin, options);
                try env.put(binding.name, info);
            },
            .return_expr => |expr| {
                const info = try exprInfoWithOptions(allocator, ir, sema, env, expr, origin, options);
                result.* = try mergeTypeInfo(allocator, result.*, info);
            },
            .return_void => {},
            .property_set => |property_set| {
                try validatePropertySetStatementWithOptions(allocator, ir, sema, env, property_set.object_name, property_set.property_name, property_set.value, origin, options);
            },
            .if_stmt => |if_stmt| {
                _ = try exprInfoWithOptions(allocator, ir, sema, env, if_stmt.condition, origin, options);
                var then_env = try env.clone();
                defer then_env.deinit();
                try inferReturnInfoFromStatements(allocator, ir, sema, origin_path, options, &then_env, if_stmt.then_statements.items, result);
                var else_env = try env.clone();
                defer else_env.deinit();
                try inferReturnInfoFromStatements(allocator, ir, sema, origin_path, options, &else_env, if_stmt.else_statements.items, result);
            },
            .expr_stmt => |expr| {
                _ = try exprInfoWithOptions(allocator, ir, sema, env, expr, origin, options);
            },
            .constrain => |decl| {
                if (decl.offset) |expr| _ = try exprInfoWithOptions(allocator, ir, sema, env, expr, origin, options);
            },
        }
    }
}

fn primitiveResultTypeInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    descriptor: registry.PrimitiveDescriptor,
    origin: []const u8,
    options: InferenceOptions,
) !TypeInfo {
    if (descriptor.callback) |callback| {
        const selection_info = if (call.args.items.len > 0)
            try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[0], origin, options)
        else
            infoFromType(Type.selection(.any));
        if (call.args.items.len > callback.function_arg_index) {
            try validateCallbackShape(
                allocator,
                ir,
                sema,
                env,
                call,
                origin,
                callback.function_arg_index,
                selection_info,
                callback.supplied_arg_count,
                callback.expected_result_sort,
                options,
            );
        }
    }

    switch (descriptor.result_policy) {
        .first_selection_item => {
            if (call.args.items.len == 0) return infoFromSort(.object);
            const selection_info = try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[0], origin, options);
            var info = switch (selection_info.ty.param) {
                .page => infoFromSort(.page),
                .metadata => infoFromSort(.metadata),
                .object, .any, .none => infoFromSort(.object),
                else => infoFromSort(selection_info.sort),
            };
            if (info.sort == .object) {
                info.object_class = selection_info.object_class;
                info.ty.class_name = selection_info.object_class;
            }
            return info;
        },
        .first_arg => {
            if (call.args.items.len == 0) return infoFromType(registry.primitiveResultType(descriptor) orelse Type.object);
            return try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[0], origin, options);
        },
        .selection_algebra => return try inferSelectionAlgebraInfo(allocator, ir, sema, env, call, origin, options),
        .select_query => return try inferSelectCallInfo(allocator, ir, sema, env, call, origin, options),
        .target_arg => {
            if (call.args.items.len == 0) return infoFromSort(.object);
            const target_info = try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[0], origin, options);
            if (target_info.ty.tag == .code) return target_info;
            return .{
                .ty = switch (target_info.ty.tag) {
                    .document, .page, .object, .selection => target_info.ty,
                    else => Type.object,
                },
                .sort = switch (target_info.sort) {
                    .document, .page, .object, .selection => target_info.sort,
                    else => .object,
                },
                .object_class = target_info.object_class,
            };
        },
        .metadata_selection => return infoFromType(Type.selection(.metadata)),
        .declared, .group_object, .object_from_role_arg => {},
    }

    const result_type = registry.primitiveResultType(descriptor) orelse Type.object;
    if (result_type.tag != .object) return infoFromType(result_type);

    var info = infoFromType(result_type);
    info.object_class = switch (descriptor.result_policy) {
        .group_object => "Group",
        .object_from_role_arg => inferObjectConstructorClass(sema, env, call, 2),
        else => null,
    };
    if (info.object_class) |class_name| info.ty.class_name = class_name;
    return info;
}

fn validateCallbackShape(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: []const u8,
    function_arg_index: usize,
    selection_info: TypeInfo,
    supplied_arg_count: usize,
    expected_result_sort: ?core.SemanticSort,
    options: InferenceOptions,
) !void {
    if (call.args.items.len <= function_arg_index) return;
    const callback_info = try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[function_arg_index], origin, options);
    if (callback_info.ty.tag != .function or callback_info.ty.fn_result == null) {
        try addUserReport(ir, origin, "InvalidCallback: callback must have a function type", .{});
        return error.InvalidSemanticSort;
    }
    const extra_count = if (call.args.items.len > function_arg_index + 1) call.args.items.len - function_arg_index - 1 else 0;
    const expected_arg_count = supplied_arg_count + extra_count;
    if (expected_arg_count != callback_info.ty.fn_params.len) {
        try addUserReport(ir, origin, "InvalidCallback: callback receives {d} arguments here, but its function type has {d}", .{
            expected_arg_count,
            callback_info.ty.fn_params.len,
        });
        return error.InvalidArity;
    }
    const item_type = switch (selection_info.ty.param) {
        .page => Type.page,
        .metadata => Type.metadata,
        .object, .any, .none => Type.object,
        else => Type.any,
    };
    if (supplied_arg_count == 1) {
        try ensureType(ir, allocator, infoFromType(callback_info.ty.fn_params[0]), item_type, origin, .UnmatchedArgumentType);
    } else if (supplied_arg_count == 2) {
        try ensureType(ir, allocator, infoFromType(callback_info.ty.fn_params[0]), Type.string, origin, .UnmatchedArgumentType);
        try ensureType(ir, allocator, infoFromType(callback_info.ty.fn_params[1]), item_type, origin, .UnmatchedArgumentType);
    }
    var extra_index: usize = 0;
    while (extra_index < extra_count) : (extra_index += 1) {
        const actual = try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[function_arg_index + 1 + extra_index], origin, options);
        const param_index = supplied_arg_count + extra_index;
        try ensureType(ir, allocator, actual, callback_info.ty.fn_params[param_index], origin, .UnmatchedArgumentType);
    }
    if (expected_result_sort) |result_sort| {
        const actual_sort = callback_info.ty.fn_result.?.toRuntimeSort() orelse .fragment;
        try ensureSort(ir, actual_sort, result_sort, origin, .UnmatchedReturnType);
    }
}

fn inferSelectionAlgebraInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: []const u8,
    options: InferenceOptions,
) !TypeInfo {
    if (call.args.items.len < 2) return infoFromType(Type.selection(.any));
    const left = try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[0], origin, options);
    const right = try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[1], origin, options);
    try ensureType(ir, allocator, left, Type.selection(.any), origin, .UnmatchedArgumentType);
    try ensureType(ir, allocator, right, Type.selection(.any), origin, .UnmatchedArgumentType);

    if (left.ty.param != .any and right.ty.param != .any and left.ty.param != right.ty.param) {
        const left_label = try typeLabelAlloc(allocator, left.ty);
        defer allocator.free(left_label);
        const right_label = try typeLabelAlloc(allocator, right.ty);
        defer allocator.free(right_label);
        try addUserReport(
            ir,
            origin,
            "InvalidSelectionAlgebra: cannot combine {s} and {s}",
            .{ left_label, right_label },
        );
        return error.InvalidSemanticSort;
    }

    const item_tag = if (left.ty.param != .any) left.ty.param else right.ty.param;
    var info = infoFromType(Type.selection(item_tag));
    info.object_class = mergeObjectClass(left.object_class, right.object_class);
    if (info.ty.param == .object) info.ty.param_class_name = info.object_class;
    return info;
}

fn inferSelectCallInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: []const u8,
    options: InferenceOptions,
) !TypeInfo {
    if (call.args.items.len < 2) return infoFromType(Type.selection(.any));
    const query_name = resolveStringLiteral(env, call.args.items[1]) orelse return infoFromType(Type.selection(.any));
    const query = sema.query(query_name) orelse {
        try addUserReport(ir, origin, "UnknownQuery: unknown query: {s}", .{query_name});
        return error.UnknownQuery;
    };
    if (call.args.items.len != query.arity) {
        try addUserReport(ir, origin, "InvalidArity: query {s} expects {d} arguments, got {d}", .{ query_name, query.arity, call.args.items.len });
        return error.InvalidArity;
    }
    const base = try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[0], origin, options);
    try ensureType(ir, allocator, base, registry.queryInputType(query), origin, .UnmatchedInputType);
    for (query.extra_arg_sorts, 0..) |_, extra_index| {
        const arg_index = 2 + extra_index;
        if (arg_index >= call.args.items.len) break;
        const actual = try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[arg_index], origin, options);
        if (registry.argSortType(query.extra_arg_sorts[extra_index])) |expected| {
            try ensureType(ir, allocator, actual, expected, origin, .UnmatchedArgumentType);
        }
    }
    var info = infoFromType(registry.queryOutputType(query));
    info.object_class = inferQueryOutputClass(sema, env, query, call, base);
    if (info.ty.tag == .selection and info.ty.param == .object) info.ty.param_class_name = info.object_class;
    return info;
}

fn inferQueryOutputClass(
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    query: registry.QueryDescriptor,
    call: ast.CallExpr,
    base: TypeInfo,
) ?[]const u8 {
    return switch (query.op) {
        .self_object => base.object_class,
        .page_objects_by_role, .document_objects_by_role => blk: {
            if (call.args.items.len < 3) break :blk null;
            const role_name = resolveStringLiteral(env, call.args.items[2]) orelse break :blk null;
            if (sema.roleClass(role_name)) |class_name| break :blk class_name;
            break :blk null;
        },
        .children, .descendants, .document_pages, .previous_page, .parent_page => null,
    };
}

fn inferObjectConstructorClass(sema: *const SemanticEnv, env: *const TypeEnv, call: ast.CallExpr, role_index: usize) ?[]const u8 {
    if (call.args.items.len <= role_index) return null;
    const role_name = resolveStringLiteral(env, call.args.items[role_index]) orelse return null;
    return sema.roleClass(role_name);
}

fn validateSetPropCall(
    ir: *core.Ir,
    call: ast.CallExpr,
    env: *const TypeEnv,
    sema: *const SemanticEnv,
    origin: []const u8,
) !void {
    if (call.args.items.len < 3) return;
    const key = switch (call.args.items[1]) {
        .string => |text| text,
        else => return,
    };
    const target_info = try exprInfo(ir.allocator, ir, sema, env, call.args.items[0], origin);
    if (!isPropertyTarget(target_info)) {
        try addUserReport(
            ir,
            origin,
            "InvalidProperty: set_prop target must be Document, Page, Object, or Selection<Object>; got {s}",
            .{@tagName(target_info.sort)},
        );
        return error.InvalidSemanticSort;
    }

    const value_info = try exprInfo(ir.allocator, ir, sema, env, call.args.items[2], origin);
    if (value_info.ty.tag == .function) {
        try addUserReport(ir, origin, "InvalidProperty: function values cannot be stored as properties", .{});
        return error.InvalidSemanticSort;
    }
    if (lookupFieldForTarget(sema, target_info, key)) |field| {
        try validateFieldValue(ir, sema, field, key, value_info, origin);
        return;
    }

    try addUserReport(ir, origin, "UnknownField: unknown field: {s}", .{key});
    return error.InvalidSemanticSort;
}

fn validateExtendRenderEnvCall(
    ir: *core.Ir,
    call: ast.CallExpr,
    env: *const TypeEnv,
    sema: *const SemanticEnv,
    origin: []const u8,
) !void {
    if (call.args.items.len < 4) return;
    const target_info = try exprInfo(ir.allocator, ir, sema, env, call.args.items[0], origin);
    if (!isPropertyTarget(target_info)) {
        try addUserReport(
            ir,
            origin,
            "InvalidRenderEnv: extend_render_env target must be Document, Page, Object, or Selection<Object>; got {s}",
            .{@tagName(target_info.sort)},
        );
        return error.InvalidSemanticSort;
    }

    const op = resolveStringLiteral(env, call.args.items[1]);
    const key = resolveStringLiteral(env, call.args.items[2]);
    if (op) |literal| {
        if (!std.mem.eql(u8, literal, core.render_env.OpAdd)) {
            try addUserReport(ir, origin, "InvalidRenderEnv: unsupported render environment op: {s}", .{literal});
            return error.InvalidSemanticSort;
        }
    }
    if (key) |literal| {
        if (!std.mem.eql(u8, literal, core.render_env.KeyMathLatexPackages)) {
            try addUserReport(ir, origin, "InvalidRenderEnv: unsupported render environment key: {s}", .{literal});
            return error.InvalidSemanticSort;
        }
    }
    if (op != null and key != null and !core.render_env.isSupported(op.?, key.?)) {
        try addUserReport(ir, origin, "InvalidRenderEnv: unsupported render environment operation", .{});
        return error.InvalidSemanticSort;
    }
    if (key != null and std.mem.eql(u8, key.?, core.render_env.KeyMathLatexPackages)) {
        if (resolveStringLiteral(env, call.args.items[3])) |package| {
            if (!core.render_env.isValidLatexPackageName(package)) {
                try addUserReport(ir, origin, "InvalidRenderEnv: invalid LaTeX package name: {s}", .{package});
                return error.InvalidSemanticSort;
            }
        }
    }
}

fn lookupFieldForTarget(sema: *const SemanticEnv, target_info: TypeInfo, key: []const u8) ?declarations.FieldDescriptor {
    if (targetClassForInfo(target_info)) |class_name| {
        return sema.field(class_name, key);
    }
    if (target_info.ty.tag == .object or (target_info.ty.tag == .selection and (target_info.ty.param == .object or target_info.ty.param == .any))) {
        return sema.fieldByName(key);
    }
    return null;
}

fn validateFieldValue(
    ir: *core.Ir,
    sema: *const SemanticEnv,
    field: declarations.FieldDescriptor,
    key: []const u8,
    value_info: TypeInfo,
    origin: []const u8,
) !void {
    if (!sema.valueMatches(field.module_id, field.value_type, value_info.string_literal, value_info.sort)) {
        try addUserReport(
            ir,
            origin,
            "InvalidFieldValue: field '{s}' expects {s}, got {s}",
            .{ key, sema.valueLabel(field.module_id, field.value_type), @tagName(value_info.sort) },
        );
        return error.InvalidSemanticSort;
    }
}

pub fn validatePropertySetStatement(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    object_name: []const u8,
    property_name: []const u8,
    value: ast.Expr,
    origin: []const u8,
) !void {
    return validatePropertySetStatementWithOptions(allocator, ir, sema, env, object_name, property_name, value, origin, .{});
}

fn validatePropertySetStatementWithOptions(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    object_name: []const u8,
    property_name: []const u8,
    value: ast.Expr,
    origin: []const u8,
    options: InferenceOptions,
) !void {
    const object_info = env.get(object_name) orelse {
        try addUserReport(ir, origin, "UnknownIdentifier: unknown identifier: {s}", .{object_name});
        return error.UnknownIdentifier;
    };
    try ensureSort(ir, object_info.sort, .object, origin, .UnmatchedArgumentType);
    const value_info = try exprInfoWithOptions(allocator, ir, sema, env, value, origin, options);
    if (!options.validate_contracts) return;
    if (ir) |sink| {
        if (lookupFieldForTarget(sema, object_info, property_name)) |field| {
            try validateFieldValue(sink, sema, field, property_name, value_info, origin);
            return;
        }
        try addUserReport(ir, origin, "UnknownField: unknown field: {s}", .{property_name});
        return error.InvalidSemanticSort;
    }
}

pub fn expectedPrimitiveArgSort(descriptor: registry.PrimitiveDescriptor, index: usize) ?core.SemanticSort {
    const arg_sort = if (descriptor.arg_sorts.len == 0)
        return null
    else if (index < descriptor.arg_sorts.len)
        descriptor.arg_sorts[index]
    else
        descriptor.arg_sorts[descriptor.arg_sorts.len - 1];

    return switch (arg_sort) {
        .any => null,
        .document => .document,
        .page => .page,
        .object => .object,
        .metadata => .metadata,
        .selection => .selection,
        .anchor => .anchor,
        .function => .function,
        .style => .style,
        .string => .string,
        .number => .number,
        .boolean => .boolean,
        .constraints => .constraints,
    };
}
