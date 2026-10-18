const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const declarations = @import("../language/declarations.zig");
const language_names = @import("../language/names.zig");
const semantic_env = @import("../language/env.zig");
const registry = @import("../language/registry.zig");
const contracts = @import("contracts.zig");
const semantic_types = @import("types.zig");
const utils = @import("utils");
const return_facts = @import("return_facts.zig");

const Type = ast.Type;
const SemanticEnv = semantic_env.SemanticEnv;
const TypeEnv = semantic_types.TypeEnv;
const TypeInfo = semantic_types.TypeInfo;
const ensureType = semantic_types.ensureType;
const infoFromHole = semantic_types.infoFromHole;
const infoFromType = semantic_types.infoFromType;
const isPropertyTarget = semantic_types.isPropertyTarget;
const joinTypeInfo = semantic_types.joinTypeInfo;
const resolveStringLiteral = semantic_types.resolveStringLiteral;
const singleFunctionLabel = semantic_types.singleFunctionLabel;
const targetClassForInfo = semantic_types.targetClassForInfo;
const typeInfoLabelAlloc = semantic_types.typeInfoLabelAlloc;
const typeLabelAlloc = semantic_types.typeLabelAlloc;
pub const Context = return_facts.Cache;

const InferenceOptions = struct {
    context: *Context,
    validate_contracts: bool = true,
};

const addUserReport = @import("diagnostics.zig").addUserReport;

fn preferredDiagnosticSpan(primary: ?ast.Span, fallback: ?ast.Span) ?ast.Span {
    return if (primary) |span| span else fallback;
}

fn addUserReportAtSpan(
    state: ?*core.DocumentState,
    origin: core.SourceOrigin,
    span: ?ast.Span,
    code: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    if (state == null or span == null) return addUserReport(state, origin, code, fmt, args);
    const precise_origin = if (origin.span != null) origin.withSpan(span.?) else origin;

    return addUserReport(state, precise_origin, code, fmt, args);
}

fn rejectDuplicateBinding(state: ?*core.DocumentState, env: *const TypeEnv, name: []const u8, origin: core.SourceOrigin) !void {
    if (!env.contains(name)) return;
    try addUserReport(state, origin, "DuplicateBinding", "binding '{s}' is already defined in this scope", .{name});
    return error.DuplicateBinding;
}

fn checkedLetBindingInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    binding: anytype,
    inferred: TypeInfo,
    origin: core.SourceOrigin,
) !TypeInfo {
    const annotation = binding.type_annotation orelse return inferred;
    try ensureType(state, allocator, inferred, annotation, origin, .UnmatchedReturnType);
    return infoFromType(annotation);
}

fn firstHoleInArgs(args: []const ast.Expr) ?ast.HoleId {
    for (args) |arg| {
        if (firstHoleInExpr(arg)) |hole_id| return hole_id;
    }
    return null;
}

fn firstHoleInExpr(expr: ast.Expr) ?ast.HoleId {
    return switch (expr) {
        .hole => |id| id,
        .call => |call| firstHoleInArgs(call.args.items),
        .apply => |apply| firstHoleInExpr(apply.callee.*) orelse firstHoleInArgs(apply.args.items),
        .lambda => |lambda| firstHoleInExpr(lambda.body.*),
        .record => |record| blk: {
            for (record.fields.items) |field| {
                if (firstHoleInExpr(field.value)) |hole_id| break :blk hole_id;
            }
            break :blk null;
        },
        .record_update => |update| blk: {
            if (firstHoleInExpr(update.target.*)) |hole_id| break :blk hole_id;
            for (update.fields.items) |field| {
                if (firstHoleInExpr(field.value)) |hole_id| break :blk hole_id;
            }
            break :blk null;
        },
        .member => |member| firstHoleInExpr(member.target.*),
        .optional_check => |check| firstHoleInExpr(check.target.*),
        .coalesce => |coalesce| firstHoleInExpr(coalesce.target.*) orelse firstHoleInExpr(coalesce.fallback.*),
        .ident, .string, .color, .number, .boolean, .none, .enum_case => null,
    };
}

fn originPathForModule(sema: *const SemanticEnv) []const u8 {
    const state = sema.state orelse return "";
    const module = state.moduleById(sema.module_id) orelse return "";
    return module.path orelse module.spec;
}

pub fn exprInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    expr: ast.Expr,
    origin: core.SourceOrigin,
) anyerror!TypeInfo {
    var context = Context.init(allocator);
    defer context.deinit();
    return exprInfoWithContext(&context, allocator, state, sema, env, expr, origin);
}

pub fn exprInfoWithContext(
    context: *Context,
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    expr: ast.Expr,
    origin: core.SourceOrigin,
) anyerror!TypeInfo {
    return exprInfoWithOptions(allocator, state, sema, env, expr, origin, .{ .context = context });
}

fn exprInfoWithOptions(
    caller_allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    expr: ast.Expr,
    origin: core.SourceOrigin,
    options: InferenceOptions,
) anyerror!TypeInfo {
    if (state) |owner| try owner.checkAnalysisCanceled();
    options.context.expression_visits += 1;
    const allocator = if (state) |owner| owner.inferenceAllocator() else caller_allocator;
    return switch (expr) {
        .hole => |id| infoFromHole(id),
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
            var info = infoFromType(Type.enumType(case.enum_name).inModule(case.module_id orelse sema.module_id));
            info.string_literal = case.case_name;
            break :blk info;
        },
        .ident => |ident| blk: {
            const name = ident.name;
            switch (try options.context.name_resolution.resolveValue(sema, TypeInfo, ast.CallableName.bare(name), env.get(name))) {
                .local => |info| {
                    if (info.failed) return error.AlreadyDiagnosed;
                    break :blk info;
                },
                .constant => |resolved| {
                    if (options.context.invalid_declarations.contains(resolved.key)) return error.AlreadyDiagnosed;
                    if (options.context.visiting.contains(resolved.key)) break :blk infoFromType(resolved.decl.value_type);
                    try options.context.visiting.put(resolved.key, {});
                    defer _ = options.context.visiting.remove(resolved.key);
                    var constant_env = TypeEnv.init(allocator);
                    defer constant_env.deinit();
                    const constant_sema = sema.forModule(resolved.module_id);
                    const constant_origin = core.SourceOrigin.at(originPathForModule(&constant_sema), resolved.decl.span);
                    const value = try exprInfoWithOptions(allocator, state, &constant_sema, &constant_env, resolved.decl.value, constant_origin, options);
                    break :blk semantic_types.refineTypeInfo(infoFromType(resolved.decl.value_type), value);
                },
                .function => |resolved| {
                    if (resolved.decl.type_params.items.len != 0 and resolved.decl.instance_id == null) {
                        try addUserReport(state, origin, "UninstantiatedFunction", "generic function '{s}' requires a concrete call", .{resolved.decl.name});
                        return error.InvalidType;
                    }
                    var info = infoFromType(try functionTypeForDecl(allocator, resolved.decl));
                    info.function_labels = try singleFunctionLabel(allocator, resolved.decl.name);
                    break :blk info;
                },
                .primitive, .unknown => {},
            }
            try addUserReportAtSpan(state, origin, ident.name_span, "UnknownIdentifier", "unknown identifier: {s}", .{name});
            return error.UnknownIdentifier;
        },
        .call => |call| try inferCallInfo(allocator, state, sema, env, call, origin, options),
        .apply => |apply| try inferApplyInfo(allocator, state, sema, env, apply.callee.*, apply.args.items, origin, options),
        .lambda => |lambda| try inferLambdaInfo(allocator, state, sema, env, lambda, origin, options),
        .record => |record| try inferRecordInfo(allocator, state, sema, env, record, origin, options),
        .record_update => |update| try inferRecordUpdateInfo(allocator, state, sema, env, update, origin, options),
        .member => |member| try inferMemberInfo(allocator, state, sema, env, member, origin, options),
        .optional_check => |check| try inferOptionalCheckInfo(allocator, state, sema, env, check.target.*, origin, options),
        .coalesce => |coalesce| try inferCoalesceInfo(allocator, state, sema, env, coalesce, origin, options),
    };
}

fn inferRecordInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    record: ast.RecordExpr,
    origin: core.SourceOrigin,
    options: InferenceOptions,
) !TypeInfo {
    const record_decl = sema.record(record.module_id, record.type_name) orelse {
        if (sema.resolveTypeNameInContext(record.module_id orelse sema.module_id, record.type_name)) |ty| {
            if (ty.kind == .placed or ty.kind == .placement) {
                try addUserReportAtSpan(state, origin, record.type_name_span, "InvalidTypeConstruction", "{s} is a placement reference; use place! to register an input value", .{record.type_name});
                return error.InvalidType;
            }
        }
        if (sema.enumExists(record.module_id, record.type_name)) {
            try addUserReportAtSpan(state, origin, record.type_name_span, "InvalidTypeConstruction", "{s} is an enum type; use {s}.<case>", .{ record.type_name, record.type_name });
            return error.InvalidType;
        }
        try addUserReportAtSpan(state, origin, record.type_name_span, "UnknownType", "unknown type: {s}", .{record.type_name});
        return error.InvalidType;
    };
    const generic = record_decl.decl.type_params.items.len != 0;
    if (!generic or record.type_args.items.len != 0) {
        try semantic_types.ensureTypeArgumentCount(state, record_decl.decl.type_params.items.len, record.type_args.items.len, origin);
    }
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    const actuals = try allocator.alloc(TypeInfo, record.fields.items.len);
    defer allocator.free(actuals);
    for (record.fields.items, actuals) |field_expr, *actual| {
        if (seen.contains(field_expr.name)) {
            try addUserReportAtSpan(state, origin, field_expr.name_span, "DuplicateField", "field '{s}' is already set in {s}", .{ field_expr.name, record.type_name });
            return error.InvalidType;
        }
        try seen.put(field_expr.name, {});
        if (sema.recordField(.{ .module_id = record_decl.module_id, .name = record_decl.name }, field_expr.name) == null) {
            try addUserReportAtSpan(state, origin, field_expr.name_span, "UnknownField", "type '{s}' has no field '{s}'", .{ record.type_name, field_expr.name });
            return error.InvalidType;
        }
        actual.* = try exprInfoWithOptions(allocator, state, sema, env, field_expr.value, origin, options);
    }
    var ty = Type.recordType(record_decl.name).inModule(record_decl.module_id);
    if (generic) {
        const bindings = try allocator.alloc(Type.Substitution, record_decl.decl.type_params.items.len);
        defer allocator.free(bindings);
        const known = try allocator.alloc(bool, bindings.len);
        defer allocator.free(known);
        @memset(known, false);
        for (bindings, 0..) |*binding, index| binding.* = .{
            .parameter = .{ .module_id = record_decl.module_id, .declaration_start = record_decl.decl.span.start, .index = @intCast(index) },
            .replacement = Type.any,
        };
        const generic_arguments = @import("generic_arguments.zig");
        if (record.type_args.items.len != 0) {
            for (bindings, record.type_args.items, known) |*binding, argument, *is_known| {
                binding.replacement = argument;
                is_known.* = generic_arguments.isConcrete(argument);
            }
        } else {
            for (record.fields.items, actuals) |field_expr, actual| {
                const field = sema.recordField(ty.nominalId().?, field_expr.name).?;
                generic_arguments.infer(field.value_type, actual.ty, bindings, known) catch {
                    try addUserReport(state, origin, "ConflictingTypeArguments", "fields infer different types for a parameter of '{s}'", .{record.type_name});
                    return error.InvalidType;
                };
            }
        }
        for (known, record_decl.decl.type_params.items) |is_known, parameter| if (!is_known) {
            try addUserReport(state, origin, "CannotInferTypeArgument", "cannot determine concrete type argument '{s}' for '{s}'", .{ parameter.name, record.type_name });
            return error.InvalidType;
        };
        const arguments = try allocator.alloc(Type, bindings.len);
        defer allocator.free(arguments);
        for (arguments, bindings) |*argument, binding| argument.* = binding.replacement;
        ty = try ty.withArguments(allocator, arguments);
    }
    errdefer ty.deinit(allocator);
    for (record.fields.items, actuals) |field_expr, actual| {
        var expected = (try sema.recordFieldType(allocator, ty, field_expr.name)).?;
        defer expected.deinit(allocator);
        try ensureType(state, allocator, actual, expected, origin, .UnmatchedArgumentType);
    }
    for (record_decl.decl.fields.items) |field| {
        if (!seen.contains(field.name) and field.default_value == null) {
            try addUserReportAtSpan(state, origin, record.type_name_span, "MissingField", "value of type '{s}' requires field '{s}'; provide a value or declare a default", .{ record.type_name, field.name });
            return error.InvalidType;
        }
    }
    if (generic) try instantiateRecord(allocator, state orelse return error.InvalidType, sema, ty, record, record_decl, origin, options);
    return infoFromType(ty);
}

fn instantiateRecord(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    ty: Type,
    expression: ast.RecordExpr,
    definition: declarations.RecordDescriptor,
    origin: core.SourceOrigin,
    options: InferenceOptions,
) anyerror!void {
    try state.checkAnalysisCanceled();
    if (state.type_instances.isChecking(ty.nominalId().?)) {
        try addUserReport(state, origin, "RecursiveInstantiation", "cannot establish termination of defaults for type '{s}'", .{definition.name});
        return error.InvalidType;
    }
    const instance = state.type_instances.find(ty) orelse create: {
        const bindings = try core.type_instances.substitutions(allocator, ty, definition.decl.*);
        defer allocator.free(bindings);
        var declaration = try definition.decl.clone(state.allocator);
        var owned = true;
        errdefer if (owned) declaration.deinit(state.allocator);
        var transform = @import("instantiate.zig").Transform{
            .allocator = state.allocator,
            .next_expression_id = &state.next_expression_id,
            .substitutions = bindings,
        };
        try transform.record(&declaration);
        for (declaration.type_params.items) |*parameter| parameter.deinit(state.allocator);
        declaration.type_params.deinit(state.allocator);
        declaration.type_params = .empty;
        const entry = try state.type_instances.add(ty, declaration);
        owned = false;
        errdefer entry.status = .failed;
        var body_sema = sema.forModule(definition.module_id);
        body_sema.record_source_facts = false;
        checkRecordInstanceDefaults(allocator, state, &body_sema, entry.declaration, options) catch |err| {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            try addUserReport(state, origin, "InvalidInstantiation", "instantiation of '{s}' failed; see the field default diagnostic", .{definition.name});
            return err;
        };
        entry.status = .checked;
        break :create entry;
    };
    if (instance.status == .failed) return error.AlreadyDiagnosed;
    if (expression.analysis_id) |id| try state.type_instances.construction_targets.put(id, instance);
}

fn checkRecordInstanceDefaults(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    declaration: ast.RecordDecl,
    options: InferenceOptions,
) !void {
    var env = TypeEnv.init(allocator);
    defer env.deinit();
    for (declaration.fields.items) |field| {
        const default = field.default_value orelse continue;
        const origin = core.SourceOrigin.at(originPathForModule(sema), field.span);
        const actual = try exprInfoWithOptions(allocator, state, sema, &env, default.*, origin, options);
        try ensureType(state, allocator, actual, field.value_type, origin, .UnmatchedArgumentType);
    }
}

fn inferRecordUpdateInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    update: ast.RecordUpdateExpr,
    origin: core.SourceOrigin,
    options: InferenceOptions,
) !TypeInfo {
    const target_info = try exprInfoWithOptions(allocator, state, sema, env, update.target.*, origin, options);
    if (target_info.hole != null) return target_info;
    if (target_info.ty.kind != .record and target_info.ty.kind != .group) {
        const actual = try typeInfoLabelAlloc(allocator, target_info);
        defer allocator.free(actual);
        try addUserReport(state, origin, "InvalidValueUpdate", "with expects a value with fields, got {s}", .{actual});
        return error.InvalidType;
    }
    if (target_info.ty.kind == .record) _ = target_info.ty.nominalId() orelse {
        try addUserReport(state, origin, "InvalidValueUpdate", "ss produced a type without a resolved declaration while checking this update; report this as an ss bug with the source file", .{});
        return error.InvalidType;
    };

    try rejectOverlappingValueUpdateFields(allocator, state, update.fields.items, origin);
    for (update.fields.items) |field| {
        try inferRecordUpdateField(allocator, state, sema, env, target_info.ty, field, origin, options);
    }
    return infoFromType(target_info.ty);
}

fn rejectOverlappingValueUpdateFields(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    fields: []const ast.RecordUpdateFieldExpr,
    origin: core.SourceOrigin,
) !void {
    for (fields, 0..) |left, left_index| {
        for (fields[left_index + 1 ..]) |right| {
            if (!ast.recordPathsOverlap(left.path.items, right.path.items)) continue;
            const left_text = try ast.formatRecordPath(allocator, left.path.items);
            defer allocator.free(left_text);
            const right_text = try ast.formatRecordPath(allocator, right.path.items);
            defer allocator.free(right_text);
            try addUserReportAtSpan(state, origin, right.path_span, "OverlappingValueUpdate", "update path '{s}' overlaps '{s}'", .{ left_text, right_text });
            return error.InvalidType;
        }
    }
}

fn inferRecordUpdateField(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    base_type: Type,
    update_field: ast.RecordUpdateFieldExpr,
    origin: core.SourceOrigin,
    options: InferenceOptions,
) !void {
    var current_type = try base_type.clone(allocator);
    defer current_type.deinit(allocator);
    for (update_field.path.items, 0..) |segment, index| {
        if (segment.name_hole != null) return;
        var field_type = (try sema.recordFieldType(allocator, current_type, segment.name)) orelse {
            try addUserReportAtSpan(state, origin, segment.span, "UnknownField", "type '{s}' has no field '{s}'", .{ current_type.class_name orelse current_type.label(), segment.name });
            return error.InvalidType;
        };
        defer field_type.deinit(allocator);

        if (index + 1 == update_field.path.items.len) {
            const actual = try exprInfoWithOptions(allocator, state, sema, env, update_field.value, origin, options);
            try ensureType(state, allocator, actual, field_type, origin, .UnmatchedArgumentType);
            return;
        }
        if (field_type.kind != .record and field_type.kind != .group) {
            const path = try ast.formatRecordPath(allocator, update_field.path.items[0 .. index + 1]);
            defer allocator.free(path);
            const label = try typeLabelAlloc(allocator, field_type);
            defer allocator.free(label);
            try addUserReportAtSpan(state, origin, segment.span, "InvalidValueUpdatePath", "field '{s}' has type {s}, which has no fields", .{ path, label });
            return error.InvalidType;
        }
        const next_type = try field_type.clone(allocator);
        current_type.deinit(allocator);
        current_type = next_type;
    }
}

fn inferMemberInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    member: ast.MemberExpr,
    origin: core.SourceOrigin,
    options: InferenceOptions,
) !TypeInfo {
    if (member.name_hole) |hole_id| return infoFromHole(hole_id);
    if (member.target.* == .ident) {
        const enum_name = member.target.ident.name;
        if ((try options.context.name_resolution.resolveValue(sema, TypeInfo, ast.CallableName.bare(enum_name), env.get(enum_name))) == .unknown) {
            if (sema.enumExists(null, enum_name)) {
                if (member.optional) {
                    try addUserReportAtSpan(state, origin, member.name_span, "InvalidOptionalMember", "enum cases use '.'; '?.' requires a value receiver", .{});
                    return error.InvalidType;
                }
                try addUserReportAtSpan(state, origin, member.name_span, "UnknownEnumCase", "enum '{s}' has no case '{s}'", .{ enum_name, member.name });
                return error.InvalidType;
            }
        }
    }

    const target_info = try exprInfoWithOptions(allocator, state, sema, env, member.target.*, origin, options);
    if (target_info.hole != null) return target_info;
    if (member.optional) {
        const receiver = if (target_info.ty.kind == .optional)
            infoFromType((target_info.ty.optional_child orelse return error.InvalidType).*)
        else
            target_info;
        const field = try inferMemberInfoFromTargetInfo(allocator, state, sema, receiver, member.name, member.name_span, origin);
        if (target_info.ty.kind != .optional or field.hole != null or field.ty.kind == .optional) return field;
        return infoFromType(try Type.optional(allocator, field.ty));
    }
    return inferMemberInfoFromTargetInfo(allocator, state, sema, target_info, member.name, member.name_span, origin);
}

fn inferMemberInfoFromTargetInfo(
    caller_allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    target_info: TypeInfo,
    member_name: []const u8,
    member_span: ?ast.Span,
    origin: core.SourceOrigin,
) !TypeInfo {
    const allocator = if (state) |owner| owner.inferenceAllocator() else caller_allocator;
    if (target_info.ty.kind == .optional) {
        try addUserReportAtSpan(state, origin, member_span, "InvalidOptionalMember", "optional receivers require ?. or an explicit fallback with ?? before member access", .{});
        return error.InvalidType;
    }
    if (target_info.ty.kind == .placed or target_info.ty.kind == .placement) {
        const field_type = @import("../language/placement.zig").memberType(target_info.ty, member_name) orelse {
            try addUserReportAtSpan(state, origin, member_span, "UnknownField", "type '{s}' has no field '{s}'", .{ target_info.ty.label(), member_name });
            return error.InvalidType;
        };
        return infoFromType(field_type);
    }
    if (target_info.ty.kind == .group) {
        const field_type = Type.groupMemberType(member_name) orelse {
            try addUserReportAtSpan(state, origin, member_span, "UnknownField", "type 'Group' has no field '{s}'", .{member_name});
            return error.InvalidType;
        };
        return infoFromType(field_type);
    }
    if (target_info.ty.kind == .record) {
        const record_id = target_info.ty.nominalId() orelse {
            try addUserReportAtSpan(state, origin, member_span, "InvalidType", "ss produced a type without a resolved declaration; report this as an ss bug with the source file", .{});
            return error.InvalidType;
        };
        const field_type = (try sema.recordFieldType(allocator, target_info.ty, member_name)) orelse {
            try addUserReportAtSpan(state, origin, member_span, "UnknownField", "type '{s}' has no field '{s}'", .{ record_id.name, member_name });
            return error.InvalidType;
        };
        return infoFromType(field_type);
    }
    if (!semantic_types.isPropertyReadTarget(target_info)) {
        const message = if (target_info.ty.kind == .selection)
            "selection fields cannot be read directly; select an object with first(...) before reading its fields"
        else
            "member reads require a value with fields, Document, Page, or Object";
        try addUserReportAtSpan(state, origin, member_span, "InvalidProperty", "{s}", .{message});
        return error.InvalidType;
    }
    if ((target_info.ty.kind == .object or target_info.ty.kind == .page) and language_names.parseAnchorName(member_name) != null) {
        return infoFromType(Type.anchor);
    }
    if (std.mem.eql(u8, member_name, "content")) {
        if (target_info.ty.kind != .object) {
            try addUserReportAtSpan(state, origin, member_span, "InvalidProperty", "content is available only on Object", .{});
            return error.InvalidType;
        }
        return infoFromType(Type.string);
    }
    const field = lookupFieldForTarget(sema, target_info, member_name) orelse {
        try addUserReportAtSpan(state, origin, member_span, "UnknownField", "unknown field: {s}", .{member_name});
        return error.InvalidType;
    };
    const field_type = field.value_type;
    var result_type = if (field_type.kind == .optional) try field_type.clone(allocator) else try Type.optional(allocator, field_type);
    errdefer result_type.deinit(allocator);
    return infoFromType(result_type);
}

fn inferOptionalCheckInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    target: ast.Expr,
    origin: core.SourceOrigin,
    options: InferenceOptions,
) !TypeInfo {
    const target_info = try exprInfoWithOptions(allocator, state, sema, env, target, origin, options);
    if (target_info.hole != null) return target_info;
    if (target_info.ty.kind != .optional) {
        try addUserReport(state, origin, "TypeMismatch", "'?' expects an optional value", .{});
        return error.InvalidType;
    }
    return infoFromType(Type.boolean);
}

fn inferCoalesceInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    coalesce: ast.CoalesceExpr,
    origin: core.SourceOrigin,
    options: InferenceOptions,
) !TypeInfo {
    const target_info = try exprInfoWithOptions(allocator, state, sema, env, coalesce.target.*, origin, options);
    if (target_info.hole != null) return target_info;
    if (target_info.ty.kind != .optional) {
        try addUserReport(state, origin, "TypeMismatch", "'??' expects an optional value", .{});
        return error.InvalidType;
    }
    const child = target_info.ty.optional_child orelse {
        try addUserReport(state, origin, "TypeMismatch", "invalid optional type", .{});
        return error.InvalidType;
    };
    const fallback_info = try exprInfoWithOptions(allocator, state, sema, env, coalesce.fallback.*, origin, options);
    if (fallback_info.hole != null) return fallback_info;
    const result_type = if (fallback_info.ty.kind == .optional or fallback_info.ty.kind == .none) target_info.ty else child.*;
    try ensureType(state, allocator, fallback_info, result_type, origin, .UnmatchedArgumentType);
    return infoFromType(result_type);
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
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    lambda: ast.LambdaExpr,
    origin: core.SourceOrigin,
    options: InferenceOptions,
) !TypeInfo {
    var local_env = try env.clone();
    defer local_env.deinit();
    var parameter_names = @import("env.zig").NameEnv.init(allocator);
    defer parameter_names.deinit();
    const param_types = try allocator.alloc(Type, lambda.params.items.len);
    defer allocator.free(param_types);
    for (lambda.params.items, 0..) |param, index| {
        if (parameter_names.contains(param.name)) {
            try addUserReport(state, origin, "DuplicateBinding", "binding '{s}' is already defined in this scope", .{param.name});
            return error.DuplicateBinding;
        }
        try parameter_names.put(param.name);
        param_types[index] = param.ty;
        try local_env.put(param.name, infoFromType(param.ty));
    }
    const body_info = try exprInfoWithOptions(allocator, state, sema, &local_env, lambda.body.*, origin, options);
    if (body_info.hole != null) return body_info;
    var info = infoFromType(try Type.functionType(allocator, param_types, body_info.ty));
    info.function_labels = try singleFunctionLabel(allocator, try lambdaLabel(allocator, lambda));
    return info;
}

fn inferCallInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: core.SourceOrigin,
    options: InferenceOptions,
) anyerror!TypeInfo {
    if (call.callee.name_hole) |hole_id| return infoFromHole(hole_id);
    const binding = try options.context.name_resolution.resolveValue(sema, TypeInfo, call.callee, env.get(call.callee.name));
    if (call.type_args.items.len != 0) {
        const expected_count = switch (binding) {
            .function => |resolved| resolved.decl.type_params.items.len,
            .primitive => |primitive| primitive.type_parameter_count,
            .unknown => call.type_args.items.len,
            else => 0,
        };
        try semantic_types.ensureTypeArgumentCount(state, expected_count, call.type_args.items.len, origin);
    }
    return switch (binding) {
        .local => |callee_info| blk: {
            if (callee_info.failed) return error.AlreadyDiagnosed;
            if (callee_info.hole != null) break :blk callee_info;
            if (callee_info.ty.kind == .function and callee_info.ty.fn_result != null) {
                break :blk try inferFunctionValueCallInfo(allocator, state, sema, env, callee_info, call.args.items, origin, options);
            }
            try addUserReportAtSpan(state, origin, preferredDiagnosticSpan(call.callee.name_span, call.callee.span), "UnknownFunction", "local binding '{s}' is not callable", .{call.callee.name});
            return error.UnknownFunction;
        },
        .constant => |resolved| blk: {
            const const_info = infoFromType(resolved.decl.value_type);
            if (const_info.ty.kind == .function and const_info.ty.fn_result != null) {
                break :blk try inferFunctionValueCallInfo(allocator, state, sema, env, const_info, call.args.items, origin, options);
            }
            try addUserReportAtSpan(state, origin, preferredDiagnosticSpan(call.callee.name_span, call.callee.span), "UnknownFunction", "constants are values; use '{s}' without parentheses", .{call.callee.name});
            return error.UnknownFunction;
        },
        .function => |resolved| blk: {
            if (resolved.decl.type_params.items.len != 0 and resolved.decl.instance_id == null) {
                if (firstHoleInArgs(call.args.items)) |id| break :blk infoFromHole(id);
            }
            const concrete = if (resolved.decl.type_params.items.len != 0 and resolved.decl.instance_id == null)
                try instantiateFunction(allocator, state, sema, env, call, origin, resolved, options)
            else
                resolved;
            const callee_sema = sema.forModule(concrete.module_id);
            break :blk try inferUserCallInfo(allocator, state, sema, &callee_sema, env, call, origin, concrete.decl, options);
        },
        .primitive => |primitive| try inferPrimitiveCallInfo(allocator, state, sema, env, call, origin, primitive, options),
        .unknown => {
            try reportCallResolutionFailure(allocator, state, sema, call.callee, origin);
            return error.UnknownFunction;
        },
    };
}

fn instantiateFunction(
    allocator: std.mem.Allocator,
    maybe_state: ?*core.DocumentState,
    caller_sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: core.SourceOrigin,
    definition: semantic_env.ResolvedFunction,
    options: InferenceOptions,
) anyerror!semantic_env.ResolvedFunction {
    const state = maybe_state orelse return error.InvalidType;
    try state.checkAnalysisCanceled();
    const func = definition.decl;
    if (call.args.items.len < contracts.requiredParamCount(func) or call.args.items.len > func.params.items.len) {
        try addUserReport(state, origin, "InvalidArity", "expected {d}..{d} arguments, got {d}", .{ contracts.requiredParamCount(func), func.params.items.len, call.args.items.len });
        return error.InvalidArity;
    }
    const bindings = try allocator.alloc(Type.Substitution, func.type_params.items.len);
    defer allocator.free(bindings);
    const known = try allocator.alloc(bool, bindings.len);
    defer allocator.free(known);
    @memset(known, false);
    for (bindings, 0..) |*binding, index| {
        binding.* = .{
            .parameter = .{ .module_id = definition.module_id, .declaration_start = func.span.start, .index = @intCast(index) },
            .replacement = Type.any,
        };
    }
    const generic_arguments = @import("generic_arguments.zig");
    if (call.type_args.items.len != 0) {
        for (bindings, call.type_args.items, known) |*binding, argument, *is_known| {
            binding.replacement = argument;
            is_known.* = generic_arguments.isConcrete(argument);
        }
    } else {
        for (call.args.items, func.params.items[0..call.args.items.len]) |arg, parameter| {
            const actual = try exprInfoWithOptions(allocator, state, caller_sema, env, arg, origin, options);
            generic_arguments.infer(parameter.ty, actual.ty, bindings, known) catch {
                try addUserReport(state, origin, "ConflictingTypeArguments", "arguments infer different types for a parameter of '{s}'", .{func.name});
                return error.InvalidType;
            };
        }
    }
    for (known, func.type_params.items) |is_known, parameter| if (!is_known) {
        try addUserReport(state, origin, "CannotInferTypeArgument", "cannot determine concrete type argument '{s}' for '{s}'", .{ parameter.name, func.name });
        return error.InvalidType;
    };
    const concrete = try instantiateBoundFunction(allocator, state, caller_sema, definition, bindings, origin, options.context);
    if (call.callee.call_id) |id| try state.instantiations.call_targets.put(id, concrete.key);
    return concrete;
}

fn instantiateBoundFunction(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    caller_sema: *const SemanticEnv,
    definition: semantic_env.ResolvedFunction,
    bindings: []const Type.Substitution,
    origin: core.SourceOrigin,
    context: *Context,
) anyerror!semantic_env.ResolvedFunction {
    const func = definition.decl;
    const arguments = try allocator.alloc(Type, bindings.len);
    defer allocator.free(arguments);
    for (arguments, bindings) |*argument, binding| argument.* = binding.replacement;
    const instance_key = core.function_instances.Key{ .definition = definition.key, .arguments = arguments };
    if (state.instantiations.isChecking(definition.key)) {
        try addUserReport(state, origin, "RecursiveInstantiation", "cannot establish termination of generic function '{s}'", .{func.name});
        return error.InvalidType;
    }
    const instance = state.instantiations.find(instance_key) orelse create: {
        var declaration = try func.clone(state.allocator);
        var owned = true;
        errdefer if (owned) declaration.deinit(state.allocator);
        var transform = @import("instantiate.zig").Transform{
            .allocator = state.allocator,
            .next_expression_id = &state.next_expression_id,
            .substitutions = bindings,
        };
        try transform.function(&declaration);
        const entry = try state.instantiations.add(instance_key, declaration);
        owned = false;
        errdefer entry.status = .failed;
        const key = core.functionDeclarationKey(definition.module_id, entry.declaration);
        try state.functions.put(key, entry.declaration);
        var body_sema = caller_sema.forModule(definition.module_id);
        body_sema.record_source_facts = false;
        const checker = @import("check.zig");
        const path = originPathForModule(&body_sema);
        checker.checkFunction(context, allocator, state, &body_sema, path, entry.declaration) catch |err| {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            try addUserReport(state, origin, "InvalidInstantiation", "instantiation of '{s}' failed; see the function body diagnostic", .{func.name});
            return err;
        };
        entry.status = .checked;
        break :create entry;
    };
    if (instance.status == .failed) return error.AlreadyDiagnosed;
    const key = core.functionDeclarationKey(definition.module_id, instance.declaration);
    return .{ .key = key, .module_id = definition.module_id, .decl = instance.declaration };
}

/// Prepares a display call from a concrete placement input, without synthesizing
/// a source-level call or erasing the receiver's type arguments.
pub fn prepareDisplay(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    input: Type,
    origin: core.SourceOrigin,
    context: *Context,
) anyerror!core.native_display.Target {
    try state.checkAnalysisCanceled();
    if (input.kind == .group) return .group;
    if (core.native_display.kindForType(state, input)) |kind| {
        core.native_display.validateType(state, input, kind) catch |err| {
            try addUserReport(state, origin, "InvalidNativeDisplay", "native display type '{s}' does not satisfy its rendering contract", .{input.label()});
            return err;
        };
        return .{ .native = kind };
    }
    return .{ .function = (try prepareDisplayFunction(allocator, state, sema, input, origin, context)).key };
}

fn prepareDisplayFunction(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    input: Type,
    origin: core.SourceOrigin,
    context: *Context,
) anyerror!semantic_env.ResolvedFunction {
    try state.checkAnalysisCanceled();
    const generic_arguments = @import("generic_arguments.zig");
    if (!generic_arguments.isConcrete(input)) {
        try addUserReport(state, origin, "UnresolvedDisplayType", "display requires a fully concrete input type", .{});
        return error.InvalidType;
    }
    const definition = sema.displayForType(input) orelse {
        try addUserReport(state, origin, "MissingDisplay", "type '{s}' has no display declaration", .{input.label()});
        return error.InvalidType;
    };
    var receiver = try Type.placedOf(allocator, input);
    defer receiver.deinit(allocator);
    const concrete = if (definition.decl.type_params.items.len == 0) definition else instantiate: {
        const parameters = definition.decl.type_params.items;
        const bindings = try allocator.alloc(Type.Substitution, parameters.len);
        defer allocator.free(bindings);
        const known = try allocator.alloc(bool, parameters.len);
        defer allocator.free(known);
        @memset(known, false);
        for (bindings, 0..) |*binding, index| binding.* = .{
            .parameter = .{ .module_id = definition.module_id, .declaration_start = definition.decl.span.start, .index = @intCast(index) },
            .replacement = Type.any,
        };
        try generic_arguments.infer(definition.decl.params.items[0].ty, receiver, bindings, known);
        for (known) |is_known| if (!is_known) {
            try addUserReport(state, origin, "UnresolvedDisplayType", "cannot infer every type argument of display", .{});
            return error.InvalidType;
        };
        break :instantiate try instantiateBoundFunction(allocator, state, sema, definition, bindings, origin, context);
    };
    try ensureType(state, allocator, infoFromType(receiver), concrete.decl.params.items[0].ty, origin, .UnmatchedArgumentType);
    if (concrete.decl.result_type.kind != .record and concrete.decl.result_type.kind != .group) {
        try addUserReport(state, origin, "InvalidDisplayResult", "display must return an unplaced presentation value after instantiation", .{});
        return error.InvalidType;
    }
    return concrete;
}

fn reportCallResolutionFailure(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    callee: ast.CallableName,
    origin: core.SourceOrigin,
) !void {
    switch (sema.resolveFunction(callee)) {
        .unknown_alias => |alias| try addUserReportAtSpan(state, origin, preferredDiagnosticSpan(callee.qualifier_span, callee.span), "UnknownModuleAlias", "unknown import alias: {s}", .{alias}),
        else => {
            const name = try callee.displayAlloc(allocator);
            defer allocator.free(name);
            try addUserReportAtSpan(state, origin, preferredDiagnosticSpan(callee.name_span, callee.span), "UnknownFunction", "unknown function: {s}", .{name});
        },
    }
}

fn inferApplyInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    callee: ast.Expr,
    args: []const ast.Expr,
    origin: core.SourceOrigin,
    options: InferenceOptions,
) !TypeInfo {
    const callee_info = try exprInfoWithOptions(allocator, state, sema, env, callee, origin, options);
    return try inferFunctionValueCallInfo(allocator, state, sema, env, callee_info, args, origin, options);
}

fn inferFunctionValueCallInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    callee_info: TypeInfo,
    args: []const ast.Expr,
    origin: core.SourceOrigin,
    options: InferenceOptions,
) !TypeInfo {
    if (callee_info.hole != null) return callee_info;
    if (callee_info.ty.kind != .function or callee_info.ty.fn_result == null) {
        const actual_label = try typeInfoLabelAlloc(allocator, callee_info);
        defer allocator.free(actual_label);
        try addUserReport(state, origin, "TypeMismatch", "expected Function, got {s}", .{actual_label});
        return error.InvalidType;
    }
    if (args.len != callee_info.ty.fn_params.len) {
        if (firstHoleInArgs(args)) |hole_id| return infoFromHole(hole_id);
        try addUserReport(state, origin, "InvalidArity", "expected {d}, got {d}", .{ callee_info.ty.fn_params.len, args.len });
        return error.InvalidArity;
    }
    for (args, 0..) |arg, index| {
        const actual = try exprInfoWithOptions(allocator, state, sema, env, arg, origin, options);
        try ensureType(state, allocator, actual, callee_info.ty.fn_params[index], origin, .UnmatchedArgumentType);
    }
    return infoFromType(callee_info.ty.fn_result.?.*);
}

fn inferUserCallInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    caller_sema: *const SemanticEnv,
    callee_sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: core.SourceOrigin,
    func: ast.FunctionDecl,
    options: InferenceOptions,
) !TypeInfo {
    const min_arity = contracts.requiredParamCount(func);
    const max_arity = func.params.items.len;
    if (call.args.items.len < min_arity or call.args.items.len > max_arity) {
        if (firstHoleInArgs(call.args.items)) |hole_id| return infoFromHole(hole_id);
        if (min_arity == max_arity) {
            try addUserReport(state, origin, "InvalidArity", "expected {d}, got {d}", .{ max_arity, call.args.items.len });
        } else {
            try addUserReport(state, origin, "InvalidArity", "expected {d}..{d}, got {d}", .{ min_arity, max_arity, call.args.items.len });
        }
        return error.InvalidArity;
    }
    const needs_facts = returnTypeNeedsInferredFacts(func.result_type);
    const actual_arguments = try allocator.alloc(TypeInfo, if (needs_facts) call.args.items.len else 0);
    defer allocator.free(actual_arguments);
    for (call.args.items, 0..) |arg, index| {
        const param = func.params.items[index];
        const arg_origin = if (call.callee.qualifier != null and
            std.mem.startsWith(u8, call.callee.qualifier.?, "std:") and
            origin.span != null and index < call.arg_spans.items.len)
            origin.withSpan(call.arg_spans.items[index])
        else
            origin;
        const actual = try exprInfoWithOptions(allocator, state, caller_sema, env, arg, arg_origin, options);
        if (needs_facts) actual_arguments[index] = actual;
        try ensureType(state, allocator, actual, param.ty, arg_origin, .UnmatchedArgumentType);
    }
    if (options.context.invalid_declarations.contains(core.functionDeclarationKey(callee_sema.module_id, func))) return error.AlreadyDiagnosed;
    if (!needs_facts) return infoFromType(func.result_type);
    return try inferUserFunctionReturnInfo(allocator, state, callee_sema, func, actual_arguments, options);
}

fn callArgumentOrigin(call: ast.CallExpr, index: usize, origin: core.SourceOrigin) core.SourceOrigin {
    return if (origin.span != null and index < call.arg_spans.items.len) origin.withSpan(call.arg_spans.items[index]) else origin;
}

fn inferPrimitiveCallInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: core.SourceOrigin,
    descriptor: registry.PrimitiveDescriptor,
    options: InferenceOptions,
) !TypeInfo {
    if (call.args.items.len < descriptor.min_arity or call.args.items.len > descriptor.max_arity) {
        if (firstHoleInArgs(call.args.items)) |hole_id| return infoFromHole(hole_id);
        if (descriptor.min_arity == descriptor.max_arity) {
            try addUserReport(state, origin, "InvalidArity", "expected {d}, got {d}", .{ descriptor.min_arity, call.args.items.len });
        } else {
            try addUserReport(state, origin, "InvalidArity", "expected {d}..{d}, got {d}", .{ descriptor.min_arity, descriptor.max_arity, call.args.items.len });
        }
        return error.InvalidArity;
    }
    const argument_infos = try allocator.alloc(TypeInfo, call.args.items.len);
    defer allocator.free(argument_infos);
    for (call.args.items, 0..) |arg, index| {
        const arg_origin = if (call.callee.composition != null) callArgumentOrigin(call, index, origin) else origin;
        const actual = try exprInfoWithOptions(allocator, state, sema, env, arg, arg_origin, options);
        argument_infos[index] = actual;
        if (isPrimitiveFunctionArgument(descriptor, index)) continue;
        if (actual.hole == null and actual.ty.kind == .void) {
            try addUserReport(state, origin, "VoidValue", "Void calls do not produce argument values", .{});
            return error.InvalidType;
        }
    }
    if (argument_infos.len == 2 and argument_infos[0].hole == null and argument_infos[1].hole == null) {
        const left = argument_infos[0].ty.kind;
        const right = argument_infos[1].ty.kind;
        if (descriptor.op == .sub and left == .selection and right == .selection) {
            return inferSelectionAlgebraInfo(allocator, state, call, .selection_difference, origin, argument_infos);
        }
        if (descriptor.op == .num_eq and left == .anchor and right == .anchor) return infoFromType(Type.constraints);
        if ((descriptor.op == .add or descriptor.op == .sub) and left == .anchor and right == .number) return infoFromType(Type.anchor);
        if (descriptor.op == .add and left == .number and right == .anchor) return infoFromType(Type.anchor);
    }
    if (descriptor.op == .group and argument_infos.len > 0 and
        (argument_infos[0].ty.kind == .record or argument_infos[0].ty.kind == .group))
    {
        const children = try allocator.alloc(Type, argument_infos.len);
        defer allocator.free(children);
        for (argument_infos, children, 0..) |info, *child, index| {
            if (info.hole != null) return info;
            if (info.ty.kind != .record and info.ty.kind != .group) {
                try addUserReport(state, callArgumentOrigin(call, index, origin), "InvalidGroupInput", "group requires unplaced presentation values", .{});
                return error.InvalidType;
            }
            child.* = info.ty;
        }
        if (state) |owner| if (call.callee.call_id) |id| try owner.displays.typed_group_calls.put(id, {});
        return infoFromType(try (Type{ .kind = .group }).withArguments(allocator, children));
    }
    if (descriptor.op == .group and call.callee.composition != null) {
        // A composition operand is one input, never an implicit selection spread.
        for (argument_infos, 0..) |actual, index| try ensureType(state, allocator, actual, Type.object, callArgumentOrigin(call, index, origin), .UnmatchedArgumentType);
    }
    for (argument_infos, 0..) |actual, index| {
        if (isPrimitiveFunctionArgument(descriptor, index)) continue;
        if (sema.primitiveArgType(descriptor, index)) |expected| {
            const argument_type = if (descriptor.op == .group and actual.ty.kind == .selection) Type.selection(.object) else expected;
            try ensureType(state, allocator, actual, argument_type, origin, .UnmatchedArgumentType);
        }
    }
    if (descriptor.result_policy == .placement) {
        const input = argument_infos[descriptor.result_arg_index];
        if (input.hole != null) return input;
        // Legacy object constructors are removed as stdlib migrates. Their
        // attachment path must not be used for immutable typed inputs.
        if (input.ty.kind == .object) return input;
        if (input.ty.kind != .record and input.ty.kind != .group) {
            try addUserReport(state, origin, "InvalidPlacementInput", "placement requires an unplaced presentation value", .{});
            return error.InvalidType;
        }
        if (state) |owner| {
            if (options.validate_contracts) {
                const plan_index = owner.displays.find(input.ty) orelse create: {
                    var plan = try @import("display.zig").prepare(owner.allocator, owner, sema, input.ty, origin, options.context);
                    errdefer plan.deinit();
                    const index = owner.displays.plans.items.len;
                    try owner.displays.plans.append(owner.allocator, plan);
                    break :create index;
                };
                if (call.callee.call_id) |id| try owner.displays.call_targets.put(id, plan_index);
            }
        }
        return infoFromType(try Type.placedOf(allocator, input.ty));
    }
    const info = try primitiveResultTypeInfo(allocator, state, sema, env, call, descriptor, origin, argument_infos);
    if (state != null and options.validate_contracts) {
        switch (descriptor.op) {
            .prop, .has_prop, .prop_eq => try validateKnownPropertyKeyCall(state.?, call, sema, origin, argument_infos),
            .set_prop => try validateSetPropCall(state.?, call, sema, origin, argument_infos),
            .set_repr => try validateSetReprCall(allocator, state.?, call, origin, argument_infos),
            .extend_render_env => try validateExtendRenderEnvCall(state.?, call, env, origin, argument_infos),
            else => {},
        }
    }
    return info;
}

fn validateKnownPropertyKeyCall(
    state: *core.DocumentState,
    call: ast.CallExpr,
    sema: *const SemanticEnv,
    origin: core.SourceOrigin,
    argument_infos: []const TypeInfo,
) !void {
    if (call.args.items.len < 2) return;
    const key = switch (call.args.items[1]) {
        .string => |literal| literal.text,
        .hole => return,
        else => {
            try addUserReport(state, origin, "InvalidProperty", "property key must be a known field literal", .{});
            return error.InvalidType;
        },
    };
    const target_info = argument_infos[0];
    if (target_info.hole != null) return;
    if (!semantic_types.isPropertyReadTarget(target_info)) {
        try addUserReport(state, origin, "InvalidProperty", "property reads require Document, Page, or Object", .{});
        return error.InvalidType;
    }
    if (lookupFieldForTarget(sema, target_info, key) == null) {
        try addUserReport(state, origin, "UnknownField", "unknown field: {s}", .{key});
        return error.InvalidType;
    }
}

fn validateSetReprCall(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    call: ast.CallExpr,
    origin: core.SourceOrigin,
    argument_infos: []const TypeInfo,
) !void {
    if (call.args.items.len < 2) return;
    const object_info = argument_infos[0];
    const callback_info = argument_infos[1];
    if (object_info.hole != null) return;
    if (callback_info.hole != null) return;
    if (callback_info.ty.kind != .function or callback_info.ty.fn_result == null) {
        try addUserReport(state, origin, "InvalidCallback", "set_repr expects Object -> String", .{});
        return error.InvalidType;
    }
    if (callback_info.ty.fn_params.len != 1) {
        try addUserReport(state, origin, "InvalidCallback", "set_repr callback receives 1 argument, but its function type has {d}", .{callback_info.ty.fn_params.len});
        return error.InvalidArity;
    }
    const object_arg_type = if (object_info.ty.kind == .object and object_info.object_class != null)
        Type.objectId(object_info.object_class.?)
    else
        Type.object;
    try ensureType(state, allocator, infoFromType(object_arg_type), callback_info.ty.fn_params[0], origin, .UnmatchedArgumentType);
    try ensureType(state, allocator, infoFromType(callback_info.ty.fn_result.?.*), Type.string, origin, .UnmatchedReturnType);
}

fn isPrimitiveFunctionArgument(descriptor: registry.PrimitiveDescriptor, index: usize) bool {
    const callback = descriptor.callback orelse return false;
    return index == callback.function_arg_index;
}

fn returnTypeNeedsInferredFacts(ty: Type) bool {
    return switch (ty.kind) {
        .any,
        .function,
        .string,
        .enum_type,
        .hole,
        => true,
        .object => ty.class_name == null,
        .selection => (ty.selectionItem().kind == .object or ty.selectionItem().kind == .any) and ty.selectionItem().class_name == null,
        .optional => if (ty.optional_child) |child| returnTypeNeedsInferredFacts(child.*) else true,
        .none,
        .document,
        .page,
        .anchor,
        .color,
        .number,
        .boolean,
        .constraints,
        .record,
        .placed,
        .group,
        .placement,
        .path,
        .parameter,
        .void,
        => false,
    };
}

fn inferUserFunctionReturnInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    func: ast.FunctionDecl,
    actual_arguments: []const TypeInfo,
    options: InferenceOptions,
) !TypeInfo {
    const context = options.context;
    const visit_key = core.functionDeclarationKey(sema.module_id, func);
    if (context.visiting.contains(visit_key)) {
        context.recursive_calls += 1;
        return infoFromType(func.result_type);
    }
    try context.visiting.put(visit_key, {});
    defer _ = context.visiting.remove(visit_key);
    const recursive_calls_before = context.recursive_calls;

    var env = TypeEnv.init(allocator);
    defer env.deinit();
    const arguments = try allocator.alloc(TypeInfo, func.params.items.len);
    defer allocator.free(arguments);
    for (func.params.items, 0..) |param, index| {
        var param_info = infoFromType(param.ty);
        if (index >= actual_arguments.len) {
            if (param.default_value) |default_value| {
                const default_origin = core.SourceOrigin.at(originPathForModule(sema), param.name_span orelse func.span);
                const default_info = try exprInfoWithOptions(allocator, state, sema, &env, default_value.*, default_origin, options);
                try ensureType(state, allocator, default_info, param.ty, default_origin, .UnmatchedArgumentType);
                param_info = semantic_types.refineTypeInfo(param_info, default_info);
            }
        } else {
            param_info = semantic_types.refineTypeInfo(param_info, actual_arguments[index]);
        }
        arguments[index] = param_info;
        try env.put(param.name, param_info);
    }

    const key = return_facts.Key{ .function = visit_key, .arguments = arguments };
    if (context.get(key)) |cached| return cached;
    context.body_analyses += 1;
    var returns: ?TypeInfo = null;
    _ = try inferReturnInfoFromStatements(
        allocator,
        state,
        sema,
        originPathForModule(sema),
        .{ .context = context, .validate_contracts = false },
        &env,
        func.statements.items,
        &returns,
    );
    var result = returns orelse infoFromType(func.result_type);
    result.ty = func.result_type;
    if (func.result_type.kind == .object) {
        if (func.result_type.nominalId()) |class_id| result.object_class = class_id;
    }
    // A result that used a recursive fallback depends on the active call chain.
    if (context.recursive_calls == recursive_calls_before) try context.put(key, result);
    return result;
}

fn inferReturnInfoFromStatements(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    origin_path: []const u8,
    options: InferenceOptions,
    env: *TypeEnv,
    statements: []const ast.Statement,
    result: *?TypeInfo,
) anyerror!bool {
    for (statements) |stmt| {
        const origin = core.SourceOrigin.at(origin_path, stmt.span);

        switch (stmt.kind) {
            .hole => {},
            .let_binding => |binding| {
                const binds_name = !language_names.isDiscardBindingName(binding.name);
                if (binds_name) try rejectDuplicateBinding(state, env, binding.name, origin);
                const inferred = try exprInfoWithOptions(allocator, state, sema, env, binding.expr, origin, options);
                const info = try checkedLetBindingInfo(allocator, state, binding, inferred, origin);
                if (!binds_name) continue;
                try env.put(binding.name, info);
            },
            .return_expr => |expr| {
                const info = try exprInfoWithOptions(allocator, state, sema, env, expr, origin, options);
                result.* = if (result.*) |previous| try joinTypeInfo(allocator, previous, info) else info;
                return false;
            },
            .return_void => return false,
            .property_set => |property_set| {
                try validatePropertySetStatementWithOptions(allocator, state, sema, env, property_set.target, property_set.path.items, property_set.value, origin, options);
            },
            .if_stmt => |if_stmt| {
                _ = try exprInfoWithOptions(allocator, state, sema, env, if_stmt.condition, origin, options);
                var then_env = try env.clone();
                defer then_env.deinit();
                const then_continues = try inferReturnInfoFromStatements(allocator, state, sema, origin_path, options, &then_env, if_stmt.then_statements.items, result);
                var else_env = try env.clone();
                defer else_env.deinit();
                const else_continues = try inferReturnInfoFromStatements(allocator, state, sema, origin_path, options, &else_env, if_stmt.else_statements.items, result);
                if (!then_continues and !else_continues) return false;
            },
            .expr_stmt => |expr| {
                _ = try exprInfoWithOptions(allocator, state, sema, env, expr, origin, options);
            },
            .constrain => |decl| {
                if (decl.offset) |expr| _ = try exprInfoWithOptions(allocator, state, sema, env, expr, origin, options);
            },
        }
    }
    return true;
}

fn primitiveResultTypeInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    descriptor: registry.PrimitiveDescriptor,
    origin: core.SourceOrigin,
    argument_infos: []const TypeInfo,
) !TypeInfo {
    if (descriptor.callback) |callback| {
        const selection_info = if (call.args.items.len > 0)
            argument_infos[0]
        else
            infoFromType(Type.selection(.any));
        if (call.args.items.len > callback.function_arg_index) {
            try validateCallbackShape(
                allocator,
                state,
                call,
                origin,
                descriptor,
                callback.function_arg_index,
                selection_info,
                callback.supplied_arg_count,
                callback.expected_result_type,
                argument_infos,
            );
        }
    }

    switch (descriptor.result_policy) {
        .first_selection_item => {
            if (call.args.items.len == 0) return error.InvalidArity;
            const selection_info = argument_infos[0];
            if (selection_info.hole != null) return selection_info;
            return infoFromType(try selectionItemType(state, selection_info, origin));
        },
        .first_arg, .argument_type => {
            if (call.args.items.len <= descriptor.result_arg_index) return infoFromType(registry.primitiveResultType(descriptor) orelse Type.object);
            const result = argument_infos[descriptor.result_arg_index];
            if (descriptor.result_policy == .argument_type and result.hole == null) return infoFromType(result.ty);
            return result;
        },
        .selection_algebra => return try inferSelectionAlgebraInfo(allocator, state, call, descriptor.op, origin, argument_infos),
        .select_query => return try inferSelectCallInfo(allocator, state, sema, env, call, origin, argument_infos),
        .target_arg => {
            if (call.args.items.len <= descriptor.result_arg_index) return infoFromType(Type.object);
            const target_info = argument_infos[descriptor.result_arg_index];
            if (target_info.hole != null) return target_info;
            return .{
                .ty = switch (target_info.ty.kind) {
                    .document, .page, .object, .selection => target_info.ty,
                    else => Type.object,
                },
                .object_class = target_info.object_class,
            };
        },
        .declared, .group_object, .object_from_role_arg => {},
        .placement => unreachable,
    }

    if (descriptor.op == .concat and call.args.items.len == 2) {
        const left = argument_infos[0];
        const right = argument_infos[1];
        return .{ .ty = Type.string, .string_literal = try semantic_types.concatStringLiterals(allocator, left.string_literal, right.string_literal) };
    }
    const result_type = registry.primitiveResultType(descriptor) orelse Type.object;
    if (result_type.kind != .object) return infoFromType(result_type);

    var info = infoFromType(result_type);
    info.object_class = switch (descriptor.result_policy) {
        .group_object => sema.builtinClass("ObjectGroup"),
        .object_from_role_arg => inferObjectConstructorClass(sema, env, call, if (descriptor.op == .new) 1 else 2),
        else => null,
    };
    if (info.object_class) |id| info.ty = Type.objectId(id);
    return info;
}

fn selectionItemType(state: ?*core.DocumentState, info: TypeInfo, origin: core.SourceOrigin) !Type {
    return switch (info.ty.selectionItem().kind) {
        .page => Type.page,
        .placed, .placement => info.ty.selectionItem(),
        .object => if (info.object_class orelse info.ty.selectionItemId()) |id| Type.objectId(id) else Type.object,
        else => {
            try addUserReport(state, origin, "UnknownSelectionItemType", "this operation requires a Selection of pages or placements; specify the element type in the Selection annotation", .{});
            return error.InvalidType;
        },
    };
}

fn validateCallbackShape(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    call: ast.CallExpr,
    origin: core.SourceOrigin,
    descriptor: registry.PrimitiveDescriptor,
    function_arg_index: usize,
    selection_info: TypeInfo,
    supplied_arg_count: usize,
    expected_result_type: ?Type,
    argument_infos: []const TypeInfo,
) !void {
    if (call.args.items.len <= function_arg_index) return;
    const callback_info = argument_infos[function_arg_index];
    if (callback_info.hole != null) return;
    if (selection_info.hole != null) return;
    if (callback_info.ty.kind != .function or callback_info.ty.fn_result == null) {
        try addUserReport(state, origin, "InvalidCallback", "callback must have a function type", .{});
        return error.InvalidType;
    }
    const extra_count = if (call.args.items.len > function_arg_index + 1) call.args.items.len - function_arg_index - 1 else 0;
    const expected_arg_count = supplied_arg_count + extra_count;
    if (expected_arg_count != callback_info.ty.fn_params.len) {
        try addUserReport(state, origin, "InvalidCallback", "callback receives {d} arguments here, but its function type has {d}", .{
            expected_arg_count,
            callback_info.ty.fn_params.len,
        });
        return error.InvalidArity;
    }
    if (supplied_arg_count == 1) {
        const item_type = try selectionItemType(state, selection_info, origin);
        try ensureType(state, allocator, infoFromType(item_type), callback_info.ty.fn_params[0], origin, .UnmatchedArgumentType);
    } else if (supplied_arg_count == 2) {
        const item_type = try selectionItemType(state, selection_info, origin);
        switch (descriptor.op) {
            .fold => {
                try ensureType(state, allocator, argument_infos[1], callback_info.ty.fn_params[0], origin, .UnmatchedArgumentType);
                try ensureType(state, allocator, infoFromType(callback_info.ty.fn_result.?.*), argument_infos[1].ty, origin, .UnmatchedReturnType);
                try ensureType(state, allocator, infoFromType(item_type), callback_info.ty.fn_params[1], origin, .UnmatchedArgumentType);
            },
            .foreach_enumerate => {
                try ensureType(state, allocator, infoFromType(item_type), callback_info.ty.fn_params[0], origin, .UnmatchedArgumentType);
                try ensureType(state, allocator, infoFromType(Type.number), callback_info.ty.fn_params[1], origin, .UnmatchedArgumentType);
            },
            else => {},
        }
    }
    var extra_index: usize = 0;
    while (extra_index < extra_count) : (extra_index += 1) {
        const actual = argument_infos[function_arg_index + 1 + extra_index];
        const param_index = supplied_arg_count + extra_index;
        try ensureType(state, allocator, actual, callback_info.ty.fn_params[param_index], origin, .UnmatchedArgumentType);
    }
    if (expected_result_type) |result_type| {
        try ensureType(state, allocator, infoFromType(callback_info.ty.fn_result.?.*), result_type, origin, .UnmatchedReturnType);
    }
}

fn inferSelectionAlgebraInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    call: ast.CallExpr,
    op: registry.PrimitiveCall,
    origin: core.SourceOrigin,
    argument_infos: []const TypeInfo,
) !TypeInfo {
    if (call.args.items.len < 2) return infoFromType(Type.selection(.any));
    const left = argument_infos[0];
    const right = argument_infos[1];
    try ensureType(state, allocator, left, Type.selection(.any), origin, .UnmatchedArgumentType);
    try ensureType(state, allocator, right, Type.selection(.any), origin, .UnmatchedArgumentType);
    if (left.hole != null) return left;
    if (right.hole != null) return right;
    _ = try selectionItemType(state, left, origin);
    _ = try selectionItemType(state, right, origin);

    const left_item = left.ty.selectionItem();
    const right_item = right.ty.selectionItem();
    if (registry.selectionPlacementItem(op, left_item, right_item)) |item| {
        return infoFromType(try Type.selectionOf(allocator, item));
    }

    if (left.ty.selectionItem().kind != right.ty.selectionItem().kind) {
        const left_label = try typeLabelAlloc(allocator, left.ty);
        defer allocator.free(left_label);
        const right_label = try typeLabelAlloc(allocator, right.ty);
        defer allocator.free(right_label);
        try addUserReport(
            state,
            origin,
            "InvalidSelectionAlgebra",
            "cannot combine {s} and {s}",
            .{ left_label, right_label },
        );
        return error.InvalidType;
    }

    var info = infoFromType(if (left.ty.selectionItem().kind == .page) Type.selection(.page) else Type.selection(.object));
    info.object_class = switch (op) {
        .selection_union => semantic_types.joinObjectClass(left.object_class, right.object_class),
        .selection_intersection => semantic_types.meetObjectClass(left.object_class, right.object_class),
        .selection_difference => left.object_class,
        else => unreachable,
    };
    if (info.ty.selectionItem().kind == .object) if (info.object_class) |id| {
        info.ty = try Type.selectionOf(allocator, Type.objectId(id));
    };
    return info;
}

fn inferSelectCallInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: core.SourceOrigin,
    argument_infos: []const TypeInfo,
) !TypeInfo {
    if (call.type_args.items.len != 0) {
        if (call.args.items.len != 1) {
            try addUserReport(state, origin, "InvalidArity", "select<T> expects one scope argument, got {d}", .{call.args.items.len});
            return error.InvalidArity;
        }
        const input = call.type_args.items[0];
        if (input.kind != .record and input.kind != .group) {
            try addUserReport(state, origin, "InvalidSelectionType", "select<T> requires an ordinary input type", .{});
            return error.InvalidType;
        }
        const scope = argument_infos[0];
        if (scope.hole != null) return scope;
        switch (scope.ty.kind) {
            .document, .page, .placed, .placement => {},
            else => {
                try addUserReport(state, origin, "InvalidSelectionScope", "select<T> requires a Document, Page, or placement scope", .{});
                return error.InvalidType;
            },
        }
        var item = try Type.placedOf(allocator, input);
        defer item.deinit(allocator);
        return infoFromType(try Type.selectionOf(allocator, item));
    }
    if (call.args.items.len < 2) {
        try addUserReport(state, origin, "MissingTypeArguments", "select<T>(scope) requires an explicit input type", .{});
        return error.InvalidType;
    }
    const query_info = argument_infos[1];
    if (query_info.hole != null) return query_info;
    const query_name = query_info.string_literal orelse {
        try addUserReport(state, origin, "UnknownQuery", "select query must be a statically known string", .{});
        return error.UnknownQuery;
    };
    const query = sema.query(query_name) orelse {
        try addUserReport(state, origin, "UnknownQuery", "unknown query: {s}", .{query_name});
        return error.UnknownQuery;
    };
    if (call.args.items.len != query.arity) {
        try addUserReport(state, origin, "InvalidArity", "query {s} expects {d} arguments, got {d}", .{ query_name, query.arity, call.args.items.len });
        return error.InvalidArity;
    }
    const base = argument_infos[0];
    try ensureType(state, allocator, base, registry.queryInputType(query), origin, .UnmatchedInputType);
    for (query.extra_arg_types, 0..) |expected, extra_index| {
        const arg_index = 2 + extra_index;
        if (arg_index >= call.args.items.len) break;
        const actual = argument_infos[arg_index];
        try ensureType(state, allocator, actual, expected, origin, .UnmatchedArgumentType);
    }
    if (query.preserves_input_type) return infoFromType(try Type.selectionOf(allocator, base.ty));
    var info = infoFromType(registry.queryOutputType(query));
    info.object_class = inferQueryOutputClass(sema, env, query, call, base);
    if (info.ty.kind == .selection and info.ty.selectionItem().kind == .object) if (info.object_class) |id| {
        info.ty = try Type.selectionOf(allocator, Type.objectId(id));
    };
    return info;
}

fn inferQueryOutputClass(
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    query: registry.QueryDescriptor,
    call: ast.CallExpr,
    base: TypeInfo,
) ?core.NominalId {
    return switch (query.op) {
        .self_object => base.object_class,
        .page_objects_by_role, .document_objects_by_role => blk: {
            if (call.args.items.len < 3) break :blk null;
            const role_name = resolveStringLiteral(env, call.args.items[2]) orelse break :blk null;
            if (sema.roleClass(role_name)) |class_name| break :blk class_name;
            break :blk null;
        },
        .self_placement, .children, .descendants, .document_pages, .previous_page, .parent_page => null,
    };
}

fn inferObjectConstructorClass(sema: *const SemanticEnv, env: *const TypeEnv, call: ast.CallExpr, role_index: usize) ?core.NominalId {
    if (call.args.items.len <= role_index) return null;
    const role_name = resolveStringLiteral(env, call.args.items[role_index]) orelse return null;
    return sema.roleClass(role_name);
}

fn validateSetPropCall(
    state: *core.DocumentState,
    call: ast.CallExpr,
    sema: *const SemanticEnv,
    origin: core.SourceOrigin,
    argument_infos: []const TypeInfo,
) !void {
    if (call.args.items.len < 3) return;
    const key = switch (call.args.items[1]) {
        .string => |literal| literal.text,
        .hole => return,
        else => {
            try addUserReport(state, origin, "InvalidProperty", "property key must be a known field literal", .{});
            return error.InvalidType;
        },
    };
    const target_info = argument_infos[0];
    if (target_info.hole != null) return;
    if (!isPropertyTarget(target_info)) {
        const actual_label = try typeInfoLabelAlloc(state.allocator, target_info);
        defer state.allocator.free(actual_label);
        try addUserReport(
            state,
            origin,
            "InvalidProperty",
            "set_prop target must be Document, Page, Object, or Selection<Object>; got {s}",
            .{actual_label},
        );
        return error.InvalidType;
    }

    const value_info = argument_infos[2];
    if (value_info.hole != null) return;
    if (!try semantic_types.isPropertyStorable(state.allocator, sema, value_info.ty)) {
        try addUserReport(state, origin, "InvalidProperty", "properties cannot contain functions or unconstrained Any values", .{});
        return error.InvalidType;
    }
    if (lookupFieldForTarget(sema, target_info, key)) |field| {
        try validateFieldValue(state, field, key, value_info, origin);
        return;
    }

    try addUserReport(state, origin, "UnknownField", "unknown field: {s}", .{key});
    return error.InvalidType;
}

fn validateExtendRenderEnvCall(
    state: *core.DocumentState,
    call: ast.CallExpr,
    env: *const TypeEnv,
    origin: core.SourceOrigin,
    argument_infos: []const TypeInfo,
) !void {
    if (call.args.items.len < 4) return;
    const target_info = argument_infos[0];
    if (target_info.hole != null) return;
    if (!isPropertyTarget(target_info)) {
        const actual_label = try typeInfoLabelAlloc(state.allocator, target_info);
        defer state.allocator.free(actual_label);
        try addUserReport(
            state,
            origin,
            "InvalidRenderEnv",
            "extend_render_env target must be Document, Page, Object, or Selection<Object>; got {s}",
            .{actual_label},
        );
        return error.InvalidType;
    }

    const op = resolveStringLiteral(env, call.args.items[1]);
    const key = resolveStringLiteral(env, call.args.items[2]);
    if (op) |literal| {
        if (!std.mem.eql(u8, literal, core.render_env.OpAdd) and
            !std.mem.eql(u8, literal, core.render_env.OpSet))
        {
            try addUserReport(state, origin, "InvalidRenderEnv", "unsupported render environment op: {s}", .{literal});
            return error.InvalidType;
        }
    }
    if (key) |literal| {
        if (!std.mem.eql(u8, literal, core.render_env.KeyLatexPreamble) and
            !std.mem.eql(u8, literal, core.render_env.KeyLatexPreambleFile) and
            !std.mem.eql(u8, literal, core.render_env.KeyLatexEngine))
        {
            try addUserReport(state, origin, "InvalidRenderEnv", "unsupported render environment key: {s}", .{literal});
            return error.InvalidType;
        }
    }
    if (op != null and key != null and !core.render_env.isSupported(op.?, key.?)) {
        try addUserReport(state, origin, "InvalidRenderEnv", "unsupported render environment operation", .{});
        return error.InvalidType;
    }
    if (key != null and core.render_env.isLatexPreambleFileKey(key.?)) {
        if (resolveStringLiteral(env, call.args.items[3])) |path| {
            if (!core.render_env.isValidLatexPreambleFilePath(path)) {
                try addUserReport(state, origin, "InvalidRenderEnv", "empty LaTeX preamble file path", .{});
                return error.InvalidType;
            }
        }
    }
    if (key != null and core.render_env.isLatexEngineKey(key.?)) {
        if (resolveStringLiteral(env, call.args.items[3])) |engine| {
            if (!core.render_env.isValidLatexEngine(engine)) {
                try addUserReport(state, origin, "InvalidRenderEnv", "LaTeX engine must be pdflatex or lualatex", .{});
                return error.InvalidType;
            }
        }
    }
}

fn lookupFieldForTarget(sema: *const SemanticEnv, target_info: TypeInfo, key: []const u8) ?declarations.FieldDescriptor {
    if (targetClassForInfo(target_info, sema)) |class_name| {
        return sema.field(class_name, key);
    }
    if (target_info.ty.kind == .object or (target_info.ty.kind == .selection and target_info.ty.selectionItem().kind == .object)) {
        return sema.fieldByName(key);
    }
    return null;
}

fn validateFieldValue(
    state: *core.DocumentState,
    field: declarations.FieldDescriptor,
    key: []const u8,
    value_info: TypeInfo,
    origin: core.SourceOrigin,
) !void {
    return validateExpectedFieldValue(state, field.value_type, key, value_info, origin);
}

fn validateExpectedFieldValue(
    state: *core.DocumentState,
    expected: Type,
    key: []const u8,
    value_info: TypeInfo,
    origin: core.SourceOrigin,
) !void {
    return validateExpectedFieldValueAtSpan(state, expected, key, value_info, origin, null);
}

fn validateExpectedFieldValueAtSpan(
    state: *core.DocumentState,
    expected: Type,
    key: []const u8,
    value_info: TypeInfo,
    origin: core.SourceOrigin,
    span: ?ast.Span,
) !void {
    switch (semantic_types.assignability(value_info, expected)) {
        .assignable => return,
        .blocked_by_hole => return,
        .mismatch => {},
    }
    {
        const expected_label = try expected.formatAlloc(state.allocator);
        defer state.allocator.free(expected_label);
        const actual_label = try typeInfoLabelAlloc(state.allocator, value_info);
        defer state.allocator.free(actual_label);
        try addUserReportAtSpan(
            state,
            origin,
            span,
            "InvalidFieldValue",
            "field '{s}' expects {s}, got {s}",
            .{ key, expected_label, actual_label },
        );
        return error.InvalidType;
    }
}

pub fn validatePropertySetStatement(
    context: *Context,
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    target: ast.Expr,
    path: []const ast.RecordPathSegment,
    value: ast.Expr,
    origin: core.SourceOrigin,
) !void {
    return validatePropertySetStatementWithOptions(allocator, state, sema, env, target, path, value, origin, .{ .context = context });
}

fn validatePropertySetStatementWithOptions(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    target: ast.Expr,
    path: []const ast.RecordPathSegment,
    value: ast.Expr,
    origin: core.SourceOrigin,
    options: InferenceOptions,
) !void {
    if (path.len == 0) return;
    var receiver = target;
    while (receiver == .member) {
        if (receiver.member.optional) {
            try addUserReport(state, origin, "InvalidProperty", "optional member access cannot be an assignment target", .{});
            return error.InvalidType;
        }
        receiver = receiver.member.target.*;
    }
    const object_info = try exprInfoWithOptions(allocator, state, sema, env, target, origin, options);
    if (object_info.hole != null) return;
    const value_info = try exprInfoWithOptions(allocator, state, sema, env, value, origin, options);
    if (!options.validate_contracts) return;
    if (!isPropertyTarget(object_info)) {
        try validateMemberTargetPropertySetPath(allocator, state, sema, object_info, path, value_info, origin);
        return;
    }
    try validatePropertySetPath(allocator, state, sema, object_info, path, value_info, origin);
}

fn validatePropertySetPath(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    target_info: TypeInfo,
    path: []const ast.RecordPathSegment,
    value_info: TypeInfo,
    origin: core.SourceOrigin,
) !void {
    if (path.len == 0) return;
    if (value_info.hole == null and !try semantic_types.isPropertyStorable(allocator, sema, value_info.ty)) {
        try addUserReport(state, origin, "InvalidProperty", "properties cannot contain functions or unconstrained Any values", .{});
        return error.InvalidType;
    }
    if (state) |sink| {
        const first = path[0];
        if (path.len == 1 and std.mem.eql(u8, first.name, "content")) {
            try ensureType(sink, allocator, value_info, Type.string, origin, .UnmatchedArgumentType);
            return;
        }
        if (lookupFieldForTarget(sema, target_info, first.name)) |field| {
            if (path.len == 1) {
                try validateExpectedFieldValueAtSpan(sink, field.value_type, first.name, value_info, origin, first.span);
                return;
            }
            try validateNestedPropertySetPath(allocator, sink, sema, path, field.value_type, value_info, origin);
            return;
        }
        try addUserReportAtSpan(state, origin, first.span, "UnknownField", "unknown field: {s}", .{first.name});
        return error.InvalidType;
    }
}

fn memberPathPrefixInfo(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    initial_info: TypeInfo,
    path_prefix: []const ast.RecordPathSegment,
    origin: core.SourceOrigin,
) !TypeInfo {
    var current_info = initial_info;
    for (path_prefix) |segment| {
        if (segment.name_hole != null) return infoFromHole(segment.name_hole.?);
        if (current_info.hole != null) return current_info;
        current_info = try inferMemberInfoFromTargetInfo(allocator, state, sema, current_info, segment.name, segment.span, origin);
    }
    return current_info;
}

fn validateMemberTargetPropertySetPath(
    allocator: std.mem.Allocator,
    state: ?*core.DocumentState,
    sema: *const SemanticEnv,
    object_info: TypeInfo,
    path: []const ast.RecordPathSegment,
    value_info: TypeInfo,
    origin: core.SourceOrigin,
) !void {
    var current_info = object_info;
    for (path, 0..) |segment, index| {
        if (current_info.hole != null) return;
        if (isPropertyTarget(current_info)) {
            try validatePropertySetPath(allocator, state, sema, current_info, path[index..], value_info, origin);
            return;
        }
        if (segment.name_hole != null) return;
        const owner_type = current_info.ty;
        current_info = try inferMemberInfoFromTargetInfo(allocator, state, sema, current_info, segment.name, segment.span, origin);
        if (index == path.len - 1 and (owner_type.kind == .placed or owner_type.kind == .placement) and current_info.hole == null) {
            try addUserReportAtSpan(state, origin, segment.span, "ImmutablePlacement", "placement member '{s}' is read-only", .{segment.name});
            return error.InvalidType;
        }
        if (index == path.len - 1 and (owner_type.kind == .record or owner_type.kind == .group) and current_info.hole == null) {
            try addUserReportAtSpan(state, origin, segment.span, "ImmutableValue", "field '{s}' belongs to an immutable value; use with to construct an updated value", .{segment.name});
            return error.InvalidType;
        }
    }
    if (current_info.hole != null) return;
    const actual_label = try typeInfoLabelAlloc(allocator, current_info);
    defer allocator.free(actual_label);
    try addUserReportAtSpan(state, origin, path[path.len - 1].span, "InvalidProperty", "property target must be Document, Page, Object, or Selection<Object>; got {s}", .{actual_label});
    return error.InvalidType;
}

fn validateNestedPropertySetPath(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    path: []const ast.RecordPathSegment,
    root_type: Type,
    value_info: TypeInfo,
    origin: core.SourceOrigin,
) !void {
    if (root_type.kind != .record) {
        const path_text = try ast.formatRecordPath(allocator, path[0..1]);
        defer allocator.free(path_text);
        const label = try typeLabelAlloc(allocator, root_type);
        defer allocator.free(label);
        try addUserReportAtSpan(state, origin, path[0].span, "InvalidValueUpdatePath", "field '{s}' has type {s}, which has no fields", .{ path_text, label });
        return error.InvalidType;
    }
    _ = root_type.nominalId() orelse {
        try addUserReportAtSpan(state, origin, path[0].span, "InvalidValueUpdatePath", "ss produced a type without a resolved declaration while checking this update; report this as an ss bug with the source file", .{});
        return error.InvalidType;
    };
    var current_type = try root_type.clone(allocator);
    defer current_type.deinit(allocator);
    for (path[1..], 1..) |segment, index| {
        if (segment.name_hole != null) return;
        var field_type = (try sema.recordFieldType(allocator, current_type, segment.name)) orelse {
            try addUserReportAtSpan(state, origin, segment.span, "UnknownField", "type '{s}' has no field '{s}'", .{ current_type.class_name.?, segment.name });
            return error.InvalidType;
        };
        defer field_type.deinit(allocator);
        if (index + 1 == path.len) {
            const path_text = try ast.formatRecordPath(allocator, path[0 .. index + 1]);
            defer allocator.free(path_text);
            try validateExpectedFieldValueAtSpan(state, field_type, path_text, value_info, origin, segment.span);
            return;
        }
        if (field_type.kind != .record) {
            const path_text = try ast.formatRecordPath(allocator, path[0 .. index + 1]);
            defer allocator.free(path_text);
            const label = try typeLabelAlloc(allocator, field_type);
            defer allocator.free(label);
            try addUserReportAtSpan(state, origin, segment.span, "InvalidValueUpdatePath", "field '{s}' has type {s}, which has no fields", .{ path_text, label });
            return error.InvalidType;
        }
        const next_type = try field_type.clone(allocator);
        current_type.deinit(allocator);
        current_type = next_type;
    }
}

pub fn expectedPrimitiveArgType(descriptor: registry.PrimitiveDescriptor, index: usize) ?Type {
    return registry.primitiveArgType(descriptor, index);
}
