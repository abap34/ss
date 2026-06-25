const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const declarations = @import("../language/declarations.zig");
const language_names = @import("../language/names.zig");
const semantic_env = @import("../language/env.zig");
const registry = @import("../language/registry.zig");
const contracts = @import("contracts.zig");
const semantic_types = @import("types.zig");

const Type = ast.Type;
const SemanticEnv = semantic_env.SemanticEnv;
const TypeEnv = semantic_types.TypeEnv;
const TypeInfo = semantic_types.TypeInfo;
const ensureType = semantic_types.ensureType;
const infoFromType = semantic_types.infoFromType;
const isPropertyTarget = semantic_types.isPropertyTarget;
const mergeObjectClass = semantic_types.mergeObjectClass;
const mergeTypeInfo = semantic_types.mergeTypeInfo;
const resolveStringLiteral = semantic_types.resolveStringLiteral;
const singleFunctionLabel = semantic_types.singleFunctionLabel;
const targetClassForInfo = semantic_types.targetClassForInfo;
const typeLabelAlloc = semantic_types.typeLabelAlloc;
const FunctionVisitSet = std.HashMap(core.FunctionKey, void, core.FunctionKeyContext, std.hash_map.default_max_load_percentage);

threadlocal var active_return_visiting: ?*FunctionVisitSet = null;

const InferenceOptions = struct {
    validate_contracts: bool = true,
};

fn addUserReport(ir: ?*core.Ir, origin: []const u8, comptime fmt: []const u8, args: anytype) !void {
    const sink = ir orelse return;
    const message = try std.fmt.allocPrint(sink.allocator, fmt, args);
    try sink.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = message },
    });
}

fn rejectDuplicateBinding(ir: ?*core.Ir, env: *const TypeEnv, name: []const u8, origin: []const u8) !void {
    if (!env.contains(name)) return;
    try addUserReport(ir, origin, "DuplicateBinding: binding '{s}' is already defined in this scope", .{name});
    return error.DuplicateBinding;
}

fn originPathForFunction(sema: *const SemanticEnv, func: ast.FunctionDecl) []const u8 {
    _ = func;
    const ir = sema.ir orelse return "";
    const module = ir.moduleById(sema.module_id) orelse return "";
    return module.path orelse module.spec;
}

fn statementOrigin(allocator: std.mem.Allocator, origin_path: []const u8, span: ast.Span) ![]const u8 {
    if (origin_path.len != 0) {
        return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ origin_path, span.start, span.end });
    }
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
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
        .string => |literal| blk: {
            var info = infoFromType(Type.string);
            info.string_literal = literal.text;
            break :blk info;
        },
        .color => |text| blk: {
            var info = infoFromType(Type.color);
            info.string_literal = text;
            break :blk info;
        },
        .number => infoFromType(Type.number),
        .boolean => infoFromType(Type.boolean),
        .none => infoFromType(Type.none),
        .enum_case => |case| blk: {
            var info = infoFromType(Type.enumType(case.enum_name));
            info.string_literal = case.case_name;
            break :blk info;
        },
        .ident => |name| blk: {
            if (env.get(name)) |info| break :blk info;
            if (sema.resolvedConst(ast.CallableName.bare(name))) |constant_decl| {
                break :blk infoFromType(constant_decl.decl.value_type);
            }
            if (sema.function(name)) |func| {
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
        .record => |record| try inferRecordInfo(allocator, ir, sema, env, record, origin, options),
        .record_update => |update| try inferRecordUpdateInfo(allocator, ir, sema, env, update, origin, options),
        .member => |member| try inferMemberInfo(allocator, ir, sema, env, member, origin, options),
        .optional_check => |check| try inferOptionalCheckInfo(allocator, ir, sema, env, check.target.*, origin, options),
        .coalesce => |coalesce| try inferCoalesceInfo(allocator, ir, sema, env, coalesce, origin, options),
    };
}

fn inferRecordInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    record: ast.RecordExpr,
    origin: []const u8,
    options: InferenceOptions,
) !TypeInfo {
    const record_decl = sema.record(record.type_name) orelse {
        try addUserReport(ir, origin, "UnknownRecordType: unknown record type: {s}", .{record.type_name});
        return error.InvalidType;
    };
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (record.fields.items) |field_expr| {
        if (seen.contains(field_expr.name)) {
            try addUserReport(ir, origin, "DuplicateRecordField: field '{s}' is already set in {s}", .{ field_expr.name, record.type_name });
            return error.InvalidType;
        }
        try seen.put(field_expr.name, {});
        const field = sema.recordField(record.type_name, field_expr.name) orelse {
            try addUserReport(ir, origin, "UnknownRecordField: record type '{s}' has no field '{s}'", .{ record.type_name, field_expr.name });
            return error.InvalidType;
        };
        var expected = (try sema.resolveTypeText(allocator, field.module_id, field.value_type)) orelse {
            try addUserReport(ir, origin, "InvalidFieldSchema: unknown field value type: {s}", .{field.value_type});
            return error.InvalidType;
        };
        defer expected.deinit(allocator);
        const actual = try exprInfoWithOptions(allocator, ir, sema, env, field_expr.value, origin, options);
        try ensureType(ir, allocator, actual, expected, origin, .UnmatchedArgumentType);
    }
    return infoFromType(Type.recordType(record_decl.name));
}

fn inferRecordUpdateInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    update: ast.RecordUpdateExpr,
    origin: []const u8,
    options: InferenceOptions,
) !TypeInfo {
    const target_info = try exprInfoWithOptions(allocator, ir, sema, env, update.target.*, origin, options);
    if (target_info.ty.kind != .record) {
        const actual = try typeLabelAlloc(allocator, target_info.ty);
        defer allocator.free(actual);
        try addUserReport(ir, origin, "InvalidRecordUpdate: with expects a record value, got {s}", .{actual});
        return error.InvalidType;
    }
    const record_name = target_info.ty.class_name orelse {
        try addUserReport(ir, origin, "InvalidRecordUpdate: record type has no name", .{});
        return error.InvalidType;
    };

    try rejectOverlappingRecordUpdateFields(allocator, ir, update.fields.items, origin);
    for (update.fields.items) |field| {
        try inferRecordUpdateField(allocator, ir, sema, env, record_name, field, origin, options);
    }
    return infoFromType(target_info.ty);
}

fn rejectOverlappingRecordUpdateFields(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    fields: []const ast.RecordUpdateFieldExpr,
    origin: []const u8,
) !void {
    for (fields, 0..) |left, left_index| {
        for (fields[left_index + 1 ..]) |right| {
            if (!recordUpdatePathsOverlap(left.path.items, right.path.items)) continue;
            const left_text = try formatRecordUpdatePath(allocator, left.path.items);
            defer allocator.free(left_text);
            const right_text = try formatRecordUpdatePath(allocator, right.path.items);
            defer allocator.free(right_text);
            try addUserReport(ir, origin, "OverlappingRecordUpdate: update path '{s}' overlaps '{s}'", .{ left_text, right_text });
            return error.InvalidType;
        }
    }
}

fn recordUpdatePathsOverlap(left: []const []const u8, right: []const []const u8) bool {
    const shared = @min(left.len, right.len);
    for (0..shared) |index| {
        if (!std.mem.eql(u8, left[index], right[index])) return false;
    }
    return true;
}

fn formatRecordUpdatePath(allocator: std.mem.Allocator, path: []const []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (path, 0..) |segment, index| {
        if (index > 0) try out.append(allocator, '.');
        try out.appendSlice(allocator, segment);
    }
    return try out.toOwnedSlice(allocator);
}

fn inferRecordUpdateField(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    base_record_name: []const u8,
    update_field: ast.RecordUpdateFieldExpr,
    origin: []const u8,
    options: InferenceOptions,
) !void {
    var current_record_name = base_record_name;
    for (update_field.path.items, 0..) |segment, index| {
        const field = sema.recordField(current_record_name, segment) orelse {
            try addUserReport(ir, origin, "UnknownRecordField: record type '{s}' has no field '{s}'", .{ current_record_name, segment });
            return error.InvalidType;
        };
        var field_type = (try sema.resolveTypeText(allocator, field.module_id, field.value_type)) orelse {
            try addUserReport(ir, origin, "InvalidFieldSchema: unknown field value type: {s}", .{field.value_type});
            return error.InvalidType;
        };
        defer field_type.deinit(allocator);

        if (index + 1 == update_field.path.items.len) {
            const actual = try exprInfoWithOptions(allocator, ir, sema, env, update_field.value, origin, options);
            try ensureType(ir, allocator, actual, field_type, origin, .UnmatchedArgumentType);
            return;
        }
        if (field_type.kind != .record) {
            const path = try formatRecordUpdatePath(allocator, update_field.path.items[0 .. index + 1]);
            defer allocator.free(path);
            const label = try typeLabelAlloc(allocator, field_type);
            defer allocator.free(label);
            try addUserReport(ir, origin, "InvalidRecordUpdatePath: field '{s}' is {s}, not a record", .{ path, label });
            return error.InvalidType;
        }
        current_record_name = field_type.class_name orelse {
            try addUserReport(ir, origin, "InvalidRecordUpdatePath: record type has no name", .{});
            return error.InvalidType;
        };
    }
}

fn inferMemberInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    member: ast.MemberExpr,
    origin: []const u8,
    options: InferenceOptions,
) !TypeInfo {
    if (member.target.* == .ident) {
        const enum_name = member.target.ident;
        if (env.get(enum_name) == null and sema.function(enum_name) == null) {
            if (sema.enumExistsAny(enum_name)) {
                try addUserReport(ir, origin, "UnknownEnumCase: enum '{s}' has no case '{s}'", .{ enum_name, member.name });
                return error.InvalidType;
            }
        }
    }

    const target_info = try exprInfoWithOptions(allocator, ir, sema, env, member.target.*, origin, options);
    if (target_info.ty.kind == .record) {
        const record_name = target_info.ty.class_name orelse {
            try addUserReport(ir, origin, "InvalidRecordType: record type has no name", .{});
            return error.InvalidType;
        };
        const field = sema.recordField(record_name, member.name) orelse {
            try addUserReport(ir, origin, "UnknownRecordField: record type '{s}' has no field '{s}'", .{ record_name, member.name });
            return error.InvalidType;
        };
        var field_type = (try sema.resolveTypeText(allocator, field.module_id, field.value_type)) orelse {
            try addUserReport(ir, origin, "InvalidFieldSchema: unknown field value type: {s}", .{field.value_type});
            return error.InvalidType;
        };
        defer field_type.deinit(allocator);
        var result_type = try field_type.clone(allocator);
        errdefer result_type.deinit(allocator);
        return infoFromType(result_type);
    }
    if (!isPropertyTarget(target_info)) {
        try addUserReport(ir, origin, "InvalidProperty: member target must be Document, Page, Object, or Selection<Object>", .{});
        return error.InvalidType;
    }
    if (std.mem.eql(u8, member.name, "content")) return infoFromType(Type.string);
    const field = lookupFieldForTarget(sema, target_info, member.name) orelse {
        try addUserReport(ir, origin, "UnknownField: unknown field: {s}", .{member.name});
        return error.InvalidType;
    };
    var field_type = (try sema.resolveTypeText(allocator, field.module_id, field.value_type)) orelse {
        try addUserReport(ir, origin, "InvalidFieldSchema: unknown field value type: {s}", .{field.value_type});
        return error.InvalidType;
    };
    defer field_type.deinit(allocator);
    var result_type = if (field_type.kind == .optional) try field_type.clone(allocator) else try Type.optional(allocator, field_type);
    errdefer result_type.deinit(allocator);
    return infoFromType(result_type);
}

fn inferOptionalCheckInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    target: ast.Expr,
    origin: []const u8,
    options: InferenceOptions,
) !TypeInfo {
    const target_info = try exprInfoWithOptions(allocator, ir, sema, env, target, origin, options);
    if (target_info.ty.kind != .optional) {
        try addUserReport(ir, origin, "TypeMismatch: '?' expects an optional value", .{});
        return error.InvalidType;
    }
    return infoFromType(Type.boolean);
}

fn inferCoalesceInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    coalesce: ast.CoalesceExpr,
    origin: []const u8,
    options: InferenceOptions,
) !TypeInfo {
    const target_info = try exprInfoWithOptions(allocator, ir, sema, env, coalesce.target.*, origin, options);
    if (target_info.ty.kind != .optional) {
        try addUserReport(ir, origin, "TypeMismatch: '??' expects an optional value", .{});
        return error.InvalidType;
    }
    const child = target_info.ty.optional_child orelse {
        try addUserReport(ir, origin, "TypeMismatch: invalid optional type", .{});
        return error.InvalidType;
    };
    const fallback_info = try exprInfoWithOptions(allocator, ir, sema, env, coalesce.fallback.*, origin, options);
    try ensureType(ir, allocator, fallback_info, child.*, origin, .UnmatchedArgumentType);
    return infoFromType(child.*);
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
        try rejectDuplicateBinding(ir, &local_env, param.name, origin);
        param_types[index] = param.ty;
        try local_env.put(param.name, infoFromType(param.ty));
    }
    const body_info = try exprInfoWithOptions(allocator, ir, sema, &local_env, lambda.body.*, origin, options);
    if (body_info.ty.kind == .void) {
        try addUserReport(ir, origin, "VoidValue: lambda bodies must produce a value", .{});
        return error.InvalidType;
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
    if (!call.callee.isQualified()) {
        if (env.get(call.callee.name)) |callee_info| {
            if (callee_info.ty.kind == .function and callee_info.ty.fn_result != null) {
                return try inferFunctionValueCallInfo(allocator, ir, sema, env, callee_info, call.args.items, origin, options);
            }
        }
    }
    if (sema.resolvedConst(call.callee)) |resolved| {
        const const_info = infoFromType(resolved.decl.value_type);
        if (const_info.ty.kind == .function and const_info.ty.fn_result != null) {
            return try inferFunctionValueCallInfo(allocator, ir, sema, env, const_info, call.args.items, origin, options);
        }
        try addUserReport(ir, origin, "UnknownFunction: constants are values; use '{s}' without parentheses", .{call.callee.name});
        return error.UnknownFunction;
    }
    const descriptor = sema.callCallee(call.callee) orelse {
        try reportCallResolutionFailure(allocator, ir, sema, call.callee, origin);
        return error.UnknownFunction;
    };
    return switch (descriptor) {
        .function => |resolved| blk: {
            const callee_sema = sema.forModule(resolved.module_id);
            break :blk try inferUserCallInfo(allocator, ir, sema, &callee_sema, env, call, origin, resolved.decl, options);
        },
        .primitive => |primitive| try inferPrimitiveCallInfo(allocator, ir, sema, env, call, origin, primitive, options),
    };
}

fn reportCallResolutionFailure(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    callee: ast.CallableName,
    origin: []const u8,
) !void {
    switch (sema.resolveFunction(callee)) {
        .unknown_alias => |alias| try addUserReport(ir, origin, "UnknownModuleAlias: unknown import alias: {s}", .{alias}),
        else => {
            const name = try callee.displayAlloc(allocator);
            defer allocator.free(name);
            try addUserReport(ir, origin, "UnknownFunction: unknown function: {s}", .{name});
        },
    }
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
    if (callee_info.ty.kind != .function or callee_info.ty.fn_result == null) {
        const actual_label = try typeLabelAlloc(allocator, callee_info.ty);
        defer allocator.free(actual_label);
        try addUserReport(ir, origin, "TypeMismatch: expected Function, got {s}", .{actual_label});
        return error.InvalidType;
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
    caller_sema: *const SemanticEnv,
    callee_sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: []const u8,
    func: ast.FunctionDecl,
    options: InferenceOptions,
) !TypeInfo {
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
        const actual = try exprInfoWithOptions(allocator, ir, caller_sema, env, arg, origin, options);
        try ensureType(ir, allocator, actual, param.ty, origin, .UnmatchedArgumentType);
    }
    return try inferUserFunctionReturnInfo(allocator, ir, callee_sema, env, func, call, caller_sema, origin, options);
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
            .prop, .has_prop, .prop_eq => try validateKnownPropertyKeyCall(ir.?, call, env, sema, origin),
            .set_prop => try validateSetPropCall(ir.?, call, env, sema, origin),
            .set_repr => try validateSetReprCall(allocator, ir.?, call, env, sema, origin, options),
            .extend_render_env => try validateExtendRenderEnvCall(ir.?, call, env, sema, origin),
            else => {},
        }
    }
    return info;
}

fn validateKnownPropertyKeyCall(
    ir: *core.Ir,
    call: ast.CallExpr,
    env: *const TypeEnv,
    sema: *const SemanticEnv,
    origin: []const u8,
) !void {
    if (call.args.items.len < 2) return;
    const key = switch (call.args.items[1]) {
        .string => |literal| literal.text,
        else => {
            try addUserReport(ir, origin, "InvalidProperty: property key must be a known field literal", .{});
            return error.InvalidType;
        },
    };
    const target_info = try exprInfo(ir.allocator, ir, sema, env, call.args.items[0], origin);
    if (lookupFieldForTarget(sema, target_info, key) == null) {
        try addUserReport(ir, origin, "UnknownField: unknown field: {s}", .{key});
        return error.InvalidType;
    }
}

fn validateSetReprCall(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    call: ast.CallExpr,
    env: *const TypeEnv,
    sema: *const SemanticEnv,
    origin: []const u8,
    options: InferenceOptions,
) !void {
    if (call.args.items.len < 2) return;
    const object_info = try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[0], origin, options);
    const callback_info = try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[1], origin, options);
    if (callback_info.ty.kind != .function or callback_info.ty.fn_result == null) {
        try addUserReport(ir, origin, "InvalidCallback: set_repr expects Object -> String", .{});
        return error.InvalidType;
    }
    if (callback_info.ty.fn_params.len != 1) {
        try addUserReport(ir, origin, "InvalidCallback: set_repr callback receives 1 argument, but its function type has {d}", .{callback_info.ty.fn_params.len});
        return error.InvalidArity;
    }
    const object_arg_type = if (object_info.ty.kind == .object and object_info.object_class != null)
        Type.objectClass(object_info.object_class.?)
    else
        Type.object;
    try ensureType(ir, allocator, infoFromType(object_arg_type), callback_info.ty.fn_params[0], origin, .UnmatchedArgumentType);
    try ensureType(ir, allocator, infoFromType(callback_info.ty.fn_result.?.*), Type.string, origin, .UnmatchedReturnType);
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
    caller_sema: *const SemanticEnv,
    origin: []const u8,
    options: InferenceOptions,
) !TypeInfo {
    if (active_return_visiting) |visiting| {
        return inferUserFunctionReturnInfoInner(allocator, ir, sema, caller_env, func, call, caller_sema, origin, options, visiting);
    }
    var visiting = FunctionVisitSet.init(allocator);
    defer visiting.deinit();
    active_return_visiting = &visiting;
    defer active_return_visiting = null;
    return inferUserFunctionReturnInfoInner(allocator, ir, sema, caller_env, func, call, caller_sema, origin, options, &visiting);
}

fn inferUserFunctionReturnInfoInner(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    caller_env: *const TypeEnv,
    func: ast.FunctionDecl,
    call: ast.CallExpr,
    caller_sema: *const SemanticEnv,
    origin: []const u8,
    options: InferenceOptions,
    visiting: *FunctionVisitSet,
) !TypeInfo {
    const visit_key = core.functionKey(sema.module_id, func.name);
    if (visiting.contains(visit_key)) {
        var info = infoFromType(func.result_type);
        info.object_class = func.result_type.class_name;
        return info;
    }
    try visiting.put(visit_key, {});
    defer _ = visiting.remove(visit_key);

    var env = TypeEnv.init(allocator);
    defer env.deinit();
    for (func.params.items, 0..) |param, index| {
        var param_info = infoFromType(param.ty);
        if (index >= call.args.items.len) {
            if (param.default_value) |default_value| {
                const default_info = try exprInfoWithOptions(allocator, ir, sema, &env, default_value.*, origin, options);
                try ensureType(ir, allocator, default_info, param.ty, origin, .UnmatchedArgumentType);
                param_info = try mergeTypeInfo(allocator, param_info, default_info);
            }
        } else {
            const actual_info = try exprInfoWithOptions(allocator, ir, caller_sema, caller_env, call.args.items[index], origin, options);
            param_info = try mergeTypeInfo(allocator, param_info, actual_info);
        }
        try env.put(param.name, param_info);
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
                const binds_name = !language_names.isDiscardBindingName(binding.name);
                if (binds_name) try rejectDuplicateBinding(ir, env, binding.name, origin);
                const info = try exprInfoWithOptions(allocator, ir, sema, env, binding.expr, origin, options);
                if (!binds_name) continue;
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
                descriptor,
                callback.function_arg_index,
                selection_info,
                callback.supplied_arg_count,
                callback.expected_result_type,
                options,
            );
        }
    }

    switch (descriptor.result_policy) {
        .first_selection_item => {
            if (call.args.items.len == 0) return infoFromType(Type.object);
            const selection_info = try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[0], origin, options);
            var info = switch (selection_info.ty.param) {
                .page => infoFromType(Type.page),
                .object, .any, .none => infoFromType(Type.object),
                else => infoFromType(Type.object),
            };
            if (info.ty.kind == .object) {
                info.object_class = selection_info.object_class;
                info.ty.class_name = selection_info.object_class;
            }
            return info;
        },
        .first_arg => {
            if (call.args.items.len <= descriptor.result_arg_index) return infoFromType(registry.primitiveResultType(descriptor) orelse Type.object);
            return try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[descriptor.result_arg_index], origin, options);
        },
        .selection_algebra => return try inferSelectionAlgebraInfo(allocator, ir, sema, env, call, origin, options),
        .select_query => return try inferSelectCallInfo(allocator, ir, sema, env, call, origin, options),
        .target_arg => {
            if (call.args.items.len <= descriptor.result_arg_index) return infoFromType(Type.object);
            const target_info = try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[descriptor.result_arg_index], origin, options);
            return .{
                .ty = switch (target_info.ty.kind) {
                    .document, .page, .object, .selection => target_info.ty,
                    else => Type.object,
                },
                .object_class = target_info.object_class,
            };
        },
        .declared, .group_object, .object_from_role_arg => {},
    }

    const result_type = registry.primitiveResultType(descriptor) orelse Type.object;
    if (result_type.kind != .object) return infoFromType(result_type);

    var info = infoFromType(result_type);
    info.object_class = switch (descriptor.result_policy) {
        .group_object => "Group",
        .object_from_role_arg => inferObjectConstructorClass(sema, env, call, if (descriptor.op == .new) 1 else 2),
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
    descriptor: registry.PrimitiveDescriptor,
    function_arg_index: usize,
    selection_info: TypeInfo,
    supplied_arg_count: usize,
    expected_result_type: ?Type,
    options: InferenceOptions,
) !void {
    if (call.args.items.len <= function_arg_index) return;
    const callback_info = try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[function_arg_index], origin, options);
    if (callback_info.ty.kind != .function or callback_info.ty.fn_result == null) {
        try addUserReport(ir, origin, "InvalidCallback: callback must have a function type", .{});
        return error.InvalidType;
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
        .object => if (selection_info.object_class orelse selection_info.ty.param_class_name) |class_name| Type.objectClass(class_name) else Type.object,
        .any, .none => Type.object,
        else => Type.any,
    };
    if (supplied_arg_count == 1) {
        try ensureType(ir, allocator, infoFromType(callback_info.ty.fn_params[0]), item_type, origin, .UnmatchedArgumentType);
    } else if (supplied_arg_count == 2) {
        switch (descriptor.op) {
            .fold => {
                try ensureType(ir, allocator, infoFromType(callback_info.ty.fn_params[0]), Type.string, origin, .UnmatchedArgumentType);
                try ensureType(ir, allocator, infoFromType(callback_info.ty.fn_params[1]), item_type, origin, .UnmatchedArgumentType);
            },
            .foreach_enumerate => {
                try ensureType(ir, allocator, infoFromType(callback_info.ty.fn_params[0]), item_type, origin, .UnmatchedArgumentType);
                try ensureType(ir, allocator, infoFromType(callback_info.ty.fn_params[1]), Type.number, origin, .UnmatchedArgumentType);
            },
            else => {},
        }
    }
    var extra_index: usize = 0;
    while (extra_index < extra_count) : (extra_index += 1) {
        const actual = try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[function_arg_index + 1 + extra_index], origin, options);
        const param_index = supplied_arg_count + extra_index;
        try ensureType(ir, allocator, actual, callback_info.ty.fn_params[param_index], origin, .UnmatchedArgumentType);
    }
    if (expected_result_type) |result_type| {
        try ensureType(ir, allocator, infoFromType(callback_info.ty.fn_result.?.*), result_type, origin, .UnmatchedReturnType);
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
        return error.InvalidType;
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
    for (query.extra_arg_types, 0..) |expected, extra_index| {
        const arg_index = 2 + extra_index;
        if (arg_index >= call.args.items.len) break;
        const actual = try exprInfoWithOptions(allocator, ir, sema, env, call.args.items[arg_index], origin, options);
        try ensureType(ir, allocator, actual, expected, origin, .UnmatchedArgumentType);
    }
    var info = infoFromType(registry.queryOutputType(query));
    info.object_class = inferQueryOutputClass(sema, env, query, call, base);
    if (info.ty.kind == .selection and info.ty.param == .object) info.ty.param_class_name = info.object_class;
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
        .string => |literal| literal.text,
        else => {
            try addUserReport(ir, origin, "InvalidProperty: property key must be a known field literal", .{});
            return error.InvalidType;
        },
    };
    const target_info = try exprInfo(ir.allocator, ir, sema, env, call.args.items[0], origin);
    if (!isPropertyTarget(target_info)) {
        const actual_label = try typeLabelAlloc(ir.allocator, target_info.ty);
        defer ir.allocator.free(actual_label);
        try addUserReport(
            ir,
            origin,
            "InvalidProperty: set_prop target must be Document, Page, Object, or Selection<Object>; got {s}",
            .{actual_label},
        );
        return error.InvalidType;
    }

    const value_info = try exprInfo(ir.allocator, ir, sema, env, call.args.items[2], origin);
    if (value_info.ty.kind == .function) {
        try addUserReport(ir, origin, "InvalidProperty: function values cannot be stored as properties", .{});
        return error.InvalidType;
    }
    if (lookupFieldForTarget(sema, target_info, key)) |field| {
        try validateFieldValue(ir, sema, field, key, value_info, origin);
        return;
    }

    try addUserReport(ir, origin, "UnknownField: unknown field: {s}", .{key});
    return error.InvalidType;
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
        const actual_label = try typeLabelAlloc(ir.allocator, target_info.ty);
        defer ir.allocator.free(actual_label);
        try addUserReport(
            ir,
            origin,
            "InvalidRenderEnv: extend_render_env target must be Document, Page, Object, or Selection<Object>; got {s}",
            .{actual_label},
        );
        return error.InvalidType;
    }

    const op = resolveStringLiteral(env, call.args.items[1]);
    const key = resolveStringLiteral(env, call.args.items[2]);
    if (op) |literal| {
        if (!std.mem.eql(u8, literal, core.render_env.OpAdd)) {
            try addUserReport(ir, origin, "InvalidRenderEnv: unsupported render environment op: {s}", .{literal});
            return error.InvalidType;
        }
    }
    if (key) |literal| {
        if (!std.mem.eql(u8, literal, core.render_env.KeyMathTexPreamble) and
            !std.mem.eql(u8, literal, core.render_env.KeyMathTexPreambleFile))
        {
            try addUserReport(ir, origin, "InvalidRenderEnv: unsupported render environment key: {s}", .{literal});
            return error.InvalidType;
        }
    }
    if (op != null and key != null and !core.render_env.isSupported(op.?, key.?)) {
        try addUserReport(ir, origin, "InvalidRenderEnv: unsupported render environment operation", .{});
        return error.InvalidType;
    }
    if (key != null and core.render_env.isTexPreambleFileKey(key.?)) {
        if (resolveStringLiteral(env, call.args.items[3])) |path| {
            if (!core.render_env.isValidTexPreambleFilePath(path)) {
                try addUserReport(ir, origin, "InvalidRenderEnv: empty TeX preamble file path", .{});
                return error.InvalidType;
            }
        }
    }
}

fn lookupFieldForTarget(sema: *const SemanticEnv, target_info: TypeInfo, key: []const u8) ?declarations.FieldDescriptor {
    if (targetClassForInfo(target_info)) |class_name| {
        return sema.field(class_name, key);
    }
    if (target_info.ty.kind == .object or (target_info.ty.kind == .selection and (target_info.ty.param == .object or target_info.ty.param == .any))) {
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
    var expected = (try sema.resolveTypeText(ir.allocator, field.module_id, field.value_type)) orelse {
        try addUserReport(ir, origin, "InvalidFieldSchema: unknown field value type: {s}", .{field.value_type});
        return error.InvalidType;
    };
    defer expected.deinit(ir.allocator);
    if (!Type.accepts(expected, value_info.ty)) {
        const expected_label = try expected.formatAlloc(ir.allocator);
        defer ir.allocator.free(expected_label);
        const actual_label = try value_info.ty.formatAlloc(ir.allocator);
        defer ir.allocator.free(actual_label);
        try addUserReport(
            ir,
            origin,
            "InvalidFieldValue: field '{s}' expects {s}, got {s}",
            .{ key, expected_label, actual_label },
        );
        return error.InvalidType;
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
    if (!isPropertyTarget(object_info)) {
        const actual_label = try typeLabelAlloc(allocator, object_info.ty);
        defer allocator.free(actual_label);
        try addUserReport(ir, origin, "InvalidProperty: property target must be Document, Page, Object, or Selection<Object>; got {s}", .{actual_label});
        return error.InvalidType;
    }
    const value_info = try exprInfoWithOptions(allocator, ir, sema, env, value, origin, options);
    if (!options.validate_contracts) return;
    if (ir) |sink| {
        if (lookupFieldForTarget(sema, object_info, property_name)) |field| {
            try validateFieldValue(sink, sema, field, property_name, value_info, origin);
            return;
        }
        try addUserReport(ir, origin, "UnknownField: unknown field: {s}", .{property_name});
        return error.InvalidType;
    }
}

pub fn expectedPrimitiveArgType(descriptor: registry.PrimitiveDescriptor, index: usize) ?Type {
    return registry.primitiveArgType(descriptor, index);
}
