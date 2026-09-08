const std = @import("std");
const core = @import("core");
const builtin = @import("builtin.zig");
const eval_functions = @import("functions.zig");
const eval_value = @import("value.zig");
const utils = @import("utils");
const fs_utils = utils.fs;
const ast = @import("ast");
const names = @import("../language/names.zig");
const semantic_env = @import("../language/env.zig");
const declarations = @import("../language/declarations.zig");
const registry = @import("../language/registry.zig");
const analysis_cache = @import("../analysis/cache.zig");
const execution = @import("../analysis/execution.zig");
const value_contracts = @import("value_contracts.zig");

const FunctionDecl = ast.FunctionDecl;
const Statement = ast.Statement;
const Expr = ast.Expr;
const CallExpr = ast.CallExpr;
const AnchorRef = ast.AnchorRef;
const SemanticEnv = semantic_env.SemanticEnv;
const MAX_READLINES_BYTES = 1024 * 1024;

const ExecFlow = union(enum) {
    none,
    returned: core.Value,
};

const EvalScope = enum {
    document,
    page,
};

const Closure = struct {
    lambda: ast.LambdaExpr,
    env: std.StringHashMap(core.Value),

    fn deinit(self: *Closure, allocator: std.mem.Allocator) void {
        deinitValueEnv(allocator, &self.env);
    }
};

const ClosureStore = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Closure),

    fn init(allocator: std.mem.Allocator) ClosureStore {
        return .{ .allocator = allocator, .items = .empty };
    }

    fn deinit(self: *ClosureStore) void {
        for (self.items.items) |*closure| closure.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    fn add(self: *ClosureStore, lambda: ast.LambdaExpr, env: *const std.StringHashMap(core.Value)) !usize {
        const id = self.items.items.len;
        try self.items.append(self.allocator, .{
            .lambda = lambda,
            .env = try cloneValueEnv(self.allocator, env),
        });
        return id;
    }

    fn get(self: *ClosureStore, id: usize) ?*Closure {
        if (id >= self.items.items.len) return null;
        return &self.items.items[id];
    }
};

fn deinitValueEnv(allocator: std.mem.Allocator, env: *std.StringHashMap(core.Value)) void {
    var iterator = env.valueIterator();
    while (iterator.next()) |value| value.deinit(allocator);
    env.deinit();
}

fn cloneValueEnv(allocator: std.mem.Allocator, source: *const std.StringHashMap(core.Value)) !std.StringHashMap(core.Value) {
    var out = std.StringHashMap(core.Value).init(allocator);
    errdefer deinitValueEnv(allocator, &out);
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        try out.put(entry.key_ptr.*, try entry.value_ptr.clone(allocator));
    }
    return out;
}

fn putEnvValue(allocator: std.mem.Allocator, env: *std.StringHashMap(core.Value), name: []const u8, value: core.Value) !void {
    var owned = value;
    errdefer owned.deinit(allocator);
    const gop = try env.getOrPut(name);
    if (gop.found_existing) {
        gop.value_ptr.deinit(allocator);
    }
    gop.value_ptr.* = owned;
}

fn deinitValues(allocator: std.mem.Allocator, values: []core.Value) void {
    for (values) |*value| value.deinit(allocator);
}

const EvalContext = struct {
    io: std.Io,
    state: *core.DocumentState,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    module_id: core.SourceModuleId = 0,
    call_depth: u32 = 0,
    declarations: *const declarations.DeclarationIndex,
    name_resolution_cache: *analysis_cache.NameResolutionCache,
    cancellation: ?utils.Cancellation,
};

pub const ExecuteOptions = struct {
    io: std.Io,
    cancellation: ?utils.Cancellation = null,
};

fn checkCancellation(evaluation: *EvalContext) !void {
    if (evaluation.cancellation) |cancellation| try cancellation.check();
}

fn resolvedFunction(evaluation: *EvalContext, sema: *const SemanticEnv, callee: ast.CallableName) !?semantic_env.ResolvedFunction {
    return evaluation.name_resolution_cache.resolvedFunction(sema, callee);
}

fn resolvedConst(evaluation: *EvalContext, sema: *const SemanticEnv, callee: ast.CallableName) !?semantic_env.ResolvedConst {
    return evaluation.name_resolution_cache.resolvedConst(sema, callee);
}

fn callDescriptor(evaluation: *EvalContext, sema: *const SemanticEnv, callee: ast.CallableName) !?semantic_env.CallDescriptor {
    if (try resolvedFunction(evaluation, sema, callee)) |function| return .{ .function = function };
    if (!callee.isQualified()) {
        if (sema.primitive(callee.name)) |primitive| return .{ .primitive = primitive };
    }
    return null;
}

const LowerDiagnostic = struct {
    err: anyerror,
    origin: ?[]const u8,
    data: Data,

    const Data = union(enum) {
        unknown_name: struct {
            kind: []const u8,
            name: []const u8,
        },
        invalid_arity: struct {
            actual: usize,
            min: usize,
            max: usize,
        },
        invalid_value_tag: struct {
            expected: core.ValueTag,
            actual: core.ValueTag,
        },
        generic: void,
    };
};

fn reportUnknownFunction(state: *core.DocumentState, name: []const u8, origin: []const u8) !void {
    try reportNamedResolutionError(state, error.UnknownFunction, "function", name, origin);
}

fn reportUnknownCallable(state: *core.DocumentState, sema: *const SemanticEnv, callee: ast.CallableName, origin: []const u8) !void {
    switch (sema.resolveFunction(callee)) {
        .unknown_alias => |alias| try reportNamedResolutionError(state, error.UnknownFunction, "import alias", alias, origin),
        else => {
            const name = try callee.displayAlloc(state.allocator);
            defer state.allocator.free(name);
            try reportUnknownFunction(state, name, origin);
        },
    }
}

fn reportUnknownQuery(state: *core.DocumentState, name: []const u8, origin: []const u8) !void {
    try reportNamedResolutionError(state, error.UnknownQuery, "query", name, origin);
}

fn reportUnknownIdentifier(state: *core.DocumentState, name: []const u8, origin: []const u8) !void {
    try reportNamedResolutionError(state, error.UnknownIdentifier, "identifier", name, origin);
}

fn reportNamedResolutionError(state: *core.DocumentState, err: anyerror, kind: []const u8, name: []const u8, origin: []const u8) !void {
    try reportLowerDiagnostic(state, .{
        .err = err,
        .origin = origin,
        .data = .{ .unknown_name = .{ .kind = kind, .name = name } },
    });
}

fn reportLowerError(state: *core.DocumentState, err: anyerror, origin: ?[]const u8) !void {
    try reportLowerDiagnostic(state, .{
        .err = err,
        .origin = origin,
        .data = .generic,
    });
}

fn reportDuplicatePropertyDefinition(state: *core.DocumentState, origin: []const u8, key: []const u8) !void {
    try state.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{
            .message = try std.fmt.allocPrint(state.allocator, "DuplicatePropertyDefinition: property '{s}' is already defined on this target", .{key}),
        },
    });
}

fn reportDuplicateContentDefinition(state: *core.DocumentState, origin: []const u8) !void {
    try state.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = try state.allocator.dupe(u8, "DuplicateContentDefinition: object content is already defined") },
    });
}

fn reportDuplicateReprDefinition(state: *core.DocumentState, origin: []const u8) !void {
    try state.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = try state.allocator.dupe(u8, "DuplicateReprDefinition: object repr is already defined") },
    });
}

fn reportRecordUpdateError(state: *core.DocumentState, origin: []const u8, comptime fmt: []const u8, args: anytype) !void {
    try state.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{
            .message = try std.fmt.allocPrint(state.allocator, fmt, args),
        },
    });
}

fn reportInvalidRecordLiteral(state: *core.DocumentState, origin: []const u8, type_name: []const u8) !void {
    try state.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{
            .message = try std.fmt.allocPrint(state.allocator, "InvalidRecordLiteral: {s} is an enum type, not a record; use {s}.<case>", .{ type_name, type_name }),
        },
    });
}

fn reportLowerDiagnostic(state: *core.DocumentState, diagnostic: LowerDiagnostic) !void {
    var message_buf: [256]u8 = undefined;
    const message = formatLowerDiagnostic(&message_buf, diagnostic);
    try state.addValidationDiagnostic(.@"error", null, null, diagnostic.origin, .{
        .user_report = .{ .message = try state.allocator.dupe(u8, message) },
    });
}

fn formatLowerDiagnostic(buf: []u8, diagnostic: LowerDiagnostic) []const u8 {
    return switch (diagnostic.data) {
        .unknown_name => |data| std.fmt.bufPrint(buf, "{s}: unknown {s}: {s}", .{ unknownNameCode(data.kind), data.kind, data.name }) catch "UnknownName: unknown name",
        .invalid_arity => |data| blk: {
            if (data.min == data.max) {
                break :blk std.fmt.bufPrint(buf, "InvalidArity: expected {d}, got {d}", .{ data.min, data.actual }) catch formatGenericLowerDiagnostic(buf, diagnostic.err);
            }
            break :blk std.fmt.bufPrint(buf, "InvalidArity: expected {d}..{d}, got {d}", .{ data.min, data.max, data.actual }) catch formatGenericLowerDiagnostic(buf, diagnostic.err);
        },
        .invalid_value_tag => |data| std.fmt.bufPrint(buf, "InvalidValueTag: expected {s}, got {s}", .{ @tagName(data.expected), @tagName(data.actual) }) catch formatGenericLowerDiagnostic(buf, diagnostic.err),
        .generic => formatGenericLowerDiagnostic(buf, diagnostic.err),
    };
}

fn unknownNameCode(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "function")) return "UnknownFunction";
    if (std.mem.eql(u8, kind, "import alias")) return "UnknownModuleAlias";
    if (std.mem.eql(u8, kind, "query")) return "UnknownQuery";
    if (std.mem.eql(u8, kind, "identifier")) return "UnknownIdentifier";
    if (std.mem.eql(u8, kind, "record type")) return "UnknownRecordType";
    if (std.mem.eql(u8, kind, "anchor")) return "UnknownAnchor";
    if (std.mem.eql(u8, kind, "role")) return "UnknownRole";
    if (std.mem.eql(u8, kind, "payload kind")) return "UnknownPayloadKind";
    return "UnknownName";
}

fn formatGenericLowerDiagnostic(buf: []u8, err: anyerror) []const u8 {
    if (lowerErrorMessage(err)) |message| return message;
    var reason_buf: [256]u8 = undefined;
    return std.fmt.bufPrint(
        buf,
        "LoweringFailed: document evaluation could not finish: {s}",
        .{utils.err.formatErrorReason(&reason_buf, err)},
    ) catch "LoweringFailed: document evaluation could not finish; please report this as an ss bug";
}

fn lowerErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ReturnOutsideFunction => "ReturnOutsideFunction: return is only valid inside a function",
        error.InvalidLibraryModule => "InvalidLibraryModule: imported modules must contain functions, constants, and imports only",
        error.FunctionDoesNotReturnValue => "FunctionDoesNotReturnValue: function used as a value does not return anything",
        error.InvalidArity => "InvalidArity: wrong number of arguments",
        error.InvalidValueTag => "InvalidValueTag: value has the wrong semantic kind",
        error.RecursiveFunction => "RecursiveFunction: recursive functions are not allowed",
        error.RecursiveConst => "RecursiveConst: recursive constants are not allowed",
        error.EmptySelection => "EmptySelection: selection is empty",
        error.InvalidSelectionItemType => "InvalidSelectionItemType: selection item kinds do not match",
        error.InvalidSelectionMutation => "InvalidSelectionMutation: primitive callbacks must not add objects or pages to the selection being iterated",
        error.LayoutDependencyCycle => "LayoutDependencyCycle: layout reads cannot feed object creation, content, properties, or constraints because layout is solved once",
        error.PostLayoutComputationUnsupported => "PostLayoutComputationUnsupported: layout-reading scheduled computations are not implemented yet",
        error.ExecutionDependencyCycle => "ExecutionDependencyCycle: document evaluation dependencies contain a cycle",
        error.DuplicateContentDefinition => "DuplicateContentDefinition: object content is already defined",
        error.DuplicatePropertyDefinition => "DuplicatePropertyDefinition: property is already defined on this target",
        error.DuplicateReprDefinition => "DuplicateReprDefinition: object repr is already defined",
        error.ExpectedSelection => "ExpectedSelection: expected a selection value",
        error.ExpectedConstraintSet => "ExpectedConstraintSet: expected a constraint set",
        error.ExpectedStringArgument => "ExpectedStringArgument: expected a string argument",
        error.ExpectedNumberArgument => "ExpectedNumberArgument: expected a number argument",
        error.ExpectedPathCommand => "ExpectedPathCommand: expected a PathCommand argument",
        error.InvalidPathArity => "InvalidPathArity: path expects between 1 and 255 commands",
        error.InvalidPathCommandOrder => "InvalidPathCommandOrder: drawing commands require an open subpath",
        error.InvalidPathVerb => "InvalidPathVerb: unknown path command verb",
        error.MissingPathCommandField => "MissingPathCommandField: path command field is missing",
        error.InvalidPathCommandField => "InvalidPathCommandField: path command field has the wrong type",
        error.NonFinitePathCoordinate => "NonFinitePathCoordinate: path coordinates must be finite",
        error.InvalidArcRadius => "InvalidArcRadius: arc radii must not be negative",
        error.ExpectedAnchor => "ExpectedAnchor: expected an anchor argument",
        error.ExpectedObject => "ExpectedObject: expected an object argument",
        error.NoCurrentPage => "NoCurrentPage: this operation is only valid inside a page block",
        error.NoPreviousPage => "NoPreviousPage: the current page is the first page and has no previous page",
        error.MissingParentPage => "MissingParentPage: the object is not attached to a page; place it before requesting its page",
        error.UnknownAnchor => "UnknownAnchor: unknown anchor",
        error.UnknownRole => "UnknownRole: unknown role",
        error.UnknownPayloadKind => "UnknownPayloadKind: unknown payload kind",
        error.PageCannotBeConstraintTarget => "PageCannotBeConstraintTarget: page anchors cannot be constraint targets",
        error.UnsupportedDocumentEvaluationPrimitive => "UnsupportedDocumentEvaluationPrimitive: this operation is not valid during document evaluation",
        error.FunctionDidNotReturnValue => "FunctionDidNotReturnValue: function did not return a value",
        else => null,
    };
}

pub fn executeGraph(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    graph: *const execution.ExecutionGraph,
    options: ExecuteOptions,
) !void {
    var name_resolution_cache = analysis_cache.NameResolutionCache.init(allocator);
    defer name_resolution_cache.deinit();
    var closures = ClosureStore.init(allocator);
    defer closures.deinit();
    var evaluation_context = EvalContext{
        .io = options.io,
        .state = state,
        .functions = &state.functions,
        .closures = &closures,
        .declarations = graph.declarations,
        .name_resolution_cache = &name_resolution_cache,
        .cancellation = options.cancellation,
    };
    const evaluation = &evaluation_context;
    try checkCancellation(evaluation);
    try name_resolution_cache.reserve(state);
    var document_states = std.AutoHashMap(core.SourceModuleId, DocumentExecutionState).init(allocator);
    defer {
        var iter = document_states.valueIterator();
        while (iter.next()) |execution_state| execution_state.deinit(allocator);
        document_states.deinit();
    }
    var page_states = std.AutoHashMap(core.NodeId, PageExecutionState).init(allocator);
    defer {
        var iter = page_states.valueIterator();
        while (iter.next()) |execution_state| execution_state.deinit(allocator);
        page_states.deinit();
    }
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordWysiwyg(.execute_units, measure_start);
        for (graph.order) |unit_index| try executeUnit(evaluation, &document_states, &page_states, graph.units.items[unit_index]);
    }
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordWysiwyg(.materialize_display, measure_start);
        try materializeDisplayContent(evaluation);
    }
}

fn materializeDisplayContent(evaluation: *EvalContext) !void {
    const state = evaluation.state;
    var env = std.StringHashMap(core.Value).init(state.allocator);
    defer env.deinit();

    var index: usize = 0;
    while (index < state.nodes.items.len) : (index += 1) {
        try checkCancellation(evaluation);
        const node_id = state.nodes.items[index].id;
        const node = state.getNode(node_id) orelse continue;
        if (node.kind != .object) continue;
        const function = if (node.repr_function) |repr_function|
            try repr_function.clone(state.allocator)
        else
            continue;
        var owned_function = function;
        defer owned_function.deinit(state.allocator);

        const page_id = state.parentPageOf(node_id) orelse state.document_id;
        const scope: EvalScope = if (page_id == state.document_id) .document else .page;
        const origin = node.origin orelse "";
        const text = evalNodeReprWithFunction(evaluation, page_id, scope, &env, origin, node_id, function) catch |err| {
            if (err == error.Canceled) return err;
            try reportLowerError(state, err, origin);
            return err;
        };
        try state.setNodeDisplayContent(node_id, text);
    }
}

const DocumentExecutionState = struct {
    env: std.StringHashMap(core.Value),
    last_code_like: ?core.NodeId = null,

    fn init(allocator: std.mem.Allocator) DocumentExecutionState {
        return .{ .env = std.StringHashMap(core.Value).init(allocator) };
    }

    fn deinit(self: *DocumentExecutionState, allocator: std.mem.Allocator) void {
        deinitValueEnv(allocator, &self.env);
    }
};

const PageExecutionState = DocumentExecutionState;

fn executeUnit(
    evaluation: *EvalContext,
    document_states: *std.AutoHashMap(core.SourceModuleId, DocumentExecutionState),
    page_states: *std.AutoHashMap(core.NodeId, PageExecutionState),
    unit: execution.ExecutionUnit,
) !void {
    const state = evaluation.state;
    try checkCancellation(evaluation);
    const previous_module_id = evaluation.module_id;
    const previous_call_depth = evaluation.call_depth;
    evaluation.module_id = unit.module_id;
    evaluation.call_depth = 0;
    defer evaluation.module_id = previous_module_id;
    defer evaluation.call_depth = previous_call_depth;
    switch (unit.kind) {
        .document_statement => |document_statement| {
            const entry = try document_states.getOrPut(unit.module_id);
            if (!entry.found_existing) entry.value_ptr.* = DocumentExecutionState.init(state.allocator);
            try executeDocumentStatement(evaluation, entry.value_ptr, document_statement.stmt);
        },
        .page_statement => |page_statement| {
            const entry = try page_states.getOrPut(page_statement.page_id);
            if (!entry.found_existing) entry.value_ptr.* = PageExecutionState.init(state.allocator);
            try executePageStatement(evaluation, entry.value_ptr, page_statement.page_id, page_statement.stmt);
        },
    }
}

fn executeDocumentStatement(
    evaluation: *EvalContext,
    execution_state: *DocumentExecutionState,
    stmt: Statement,
) !void {
    const state = evaluation.state;
    const error_count = diagnosticErrorCount(state);
    const flow = executeStatement(evaluation, state.document_id, .document, &execution_state.env, &execution_state.last_code_like, stmt, null) catch |err| {
        if (err == error.Canceled) return err;
        const origin = statementOrigin(evaluation, stmt.span) catch null;
        defer if (origin) |text| state.allocator.free(text);
        if (diagnosticErrorCount(state) == error_count) try reportLowerError(state, err, origin);
        return err;
    };
    switch (flow) {
        .none => {},
        .returned => |value| {
            var owned = value;
            owned.deinit(state.allocator);
            return error.ReturnOutsideFunction;
        },
    }
}

fn executePageStatement(
    evaluation: *EvalContext,
    execution_state: *PageExecutionState,
    page_id: core.NodeId,
    stmt: Statement,
) !void {
    const state = evaluation.state;
    const error_count = diagnosticErrorCount(state);
    const flow = executeStatement(evaluation, page_id, .page, &execution_state.env, &execution_state.last_code_like, stmt, null) catch |err| {
        if (err == error.Canceled) return err;
        const origin = statementOrigin(evaluation, stmt.span) catch null;
        defer if (origin) |text| state.allocator.free(text);
        if (diagnosticErrorCount(state) == error_count) try reportLowerError(state, err, origin);
        return err;
    };
    switch (flow) {
        .none => {},
        .returned => |value| {
            var owned = value;
            owned.deinit(state.allocator);
            return error.ReturnOutsideFunction;
        },
    }
}

fn diagnosticErrorCount(state: *const core.DocumentState) usize {
    var count: usize = 0;
    for (state.diagnostics.items) |diagnostic| {
        if (diagnostic.severity == .@"error") count += 1;
    }
    return count;
}

fn evalExpr(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    expr: Expr,
) anyerror!core.Value {
    const state = evaluation.state;
    const functions = evaluation.functions;
    try checkCancellation(evaluation);
    return switch (expr) {
        .hole => error.HoleExpression,
        .ident => |ident| blk: {
            const name = ident.name;
            if (env.get(name)) |value| break :blk try value.clone(state.allocator);
            const sema = SemanticEnv.init(state, evaluation.declarations, functions).forModule(evaluation.module_id);
            if (try resolvedConst(evaluation, &sema, ast.CallableName.bare(name))) |resolved| {
                break :blk try evalConstValue(evaluation, page_id, scope, current_origin, resolved);
            }
            if (try resolvedFunction(evaluation, &sema, ast.CallableName.bare(name))) |resolved| {
                const func = resolved.decl;
                break :blk .{ .function = try eval_functions.functionRefForInModule(state.allocator, resolved.module_id, func) };
            }
            try reportUnknownIdentifier(state, name, current_origin);
            break :blk error.UnknownIdentifier;
        },
        .string => |literal| blk: {
            try registerStringLiteralProvenance(evaluation, literal);
            break :blk .{ .string = literal.text };
        },
        .color => |text| .{ .string = text },
        .number => |value| .{ .number = value },
        .boolean => |value| .{ .boolean = value },
        .none => .{ .none = {} },
        .enum_case => |case| .{ .enum_case = .{
            .enum_name = case.enum_name,
            .module_id = case.module_id,
            .case_name = case.case_name,
        } },
        .call => |call| try evalCall(evaluation, page_id, scope, env, current_origin, call),
        .apply => |apply| try evalApply(evaluation, page_id, scope, env, current_origin, apply),
        .lambda => |lambda| try evalLambda(evaluation, env, lambda),
        .record => |record| try evalRecord(evaluation, page_id, scope, env, current_origin, record),
        .record_update => |update| try evalRecordUpdate(evaluation, page_id, scope, env, current_origin, update),
        .member => |member| try evalMember(evaluation, page_id, scope, env, current_origin, member),
        .optional_check => |check| blk: {
            var value = try evalExpr(evaluation, page_id, scope, env, current_origin, check.target.*);
            defer value.deinit(state.allocator);
            break :blk .{ .boolean = value_contracts.runtimeKind(value) != .none };
        },
        .coalesce => |coalesce| blk: {
            var value = try evalExpr(evaluation, page_id, scope, env, current_origin, coalesce.target.*);
            if (value_contracts.runtimeKind(value) != .none) break :blk value;
            value.deinit(state.allocator);
            break :blk try evalExpr(evaluation, page_id, scope, env, current_origin, coalesce.fallback.*);
        },
    };
}

fn registerStringLiteralProvenance(evaluation: *EvalContext, literal: ast.StringLiteral) !void {
    const state = evaluation.state;
    const source_span = literal.source_span orelse return;
    const origin = try originForModuleSpan(evaluation, source_span);
    defer state.allocator.free(origin);
    const provenance = [_]core.ContentProvenance{.{
        .content_start = 0,
        .content_end = literal.text.len,
        .origin = origin,
    }};
    try state.setStringProvenance(literal.text, &provenance);
}

fn evalConstValue(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    current_origin: []const u8,
    resolved: semantic_env.ResolvedConst,
) anyerror!core.Value {
    const state = evaluation.state;
    if (state.const_values.get(resolved.key)) |value| return try value.clone(state.allocator);
    if (state.const_eval_states.get(resolved.key)) |eval_state| {
        if (eval_state == 1) return error.RecursiveConst;
    }
    try state.const_eval_states.put(resolved.key, 1);
    var state_committed = false;
    errdefer {
        if (!state_committed) _ = state.const_eval_states.remove(resolved.key);
    }

    var local_env = std.StringHashMap(core.Value).init(state.allocator);
    defer deinitValueEnv(state.allocator, &local_env);

    const previous_module_id = evaluation.module_id;
    evaluation.module_id = resolved.module_id;
    defer evaluation.module_id = previous_module_id;

    const start_node_count = state.nodeCount();
    var value = try evalExpr(evaluation, page_id, scope, &local_env, current_origin, resolved.decl.value);
    var value_moved = false;
    errdefer if (!value_moved) value.deinit(state.allocator);
    try value_contracts.ensureValueConformsToType(state, page_id, value, resolved.decl.value_type, current_origin, .UnmatchedReturnType);
    try connectValueObjects(state, value, start_node_count, current_origin);
    try state.const_values.put(resolved.key, value);
    value_moved = true;
    try state.const_eval_states.put(resolved.key, 2);
    state_committed = true;
    return try state.const_values.get(resolved.key).?.clone(state.allocator);
}

fn evalMember(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    member: ast.MemberExpr,
) !core.Value {
    const state = evaluation.state;
    const functions = evaluation.functions;
    if (borrowLocalValue(env, member.target.*)) |target| {
        if (target == .record) {
            const value = target.record.field(member.name) orelse return .{ .none = {} };
            return try value.clone(state.allocator);
        }
    }
    var target = try evalExpr(evaluation, page_id, scope, env, current_origin, member.target.*);
    defer target.deinit(state.allocator);
    return evalMemberValue(state, functions, target, member.name);
}

fn borrowLocalValue(env: *const std.StringHashMap(core.Value), expr: Expr) ?core.Value {
    return switch (expr) {
        .ident => |ident| if (env.get(ident.name)) |value| value else null,
        .member => |member| blk: {
            const target = borrowLocalValue(env, member.target.*) orelse break :blk null;
            if (target != .record) break :blk null;
            break :blk target.record.field(member.name);
        },
        else => null,
    };
}

fn evalMemberValue(
    state: *core.DocumentState,
    functions: *const core.FunctionMap,
    target: core.Value,
    name: []const u8,
) !core.Value {
    if (target == .record) {
        const value = target.record.field(name) orelse return .{ .none = {} };
        return try value.clone(state.allocator);
    }
    if (std.mem.eql(u8, name, "content")) {
        const object_id = try resolveValueObjectId(target);
        return .{ .string = state.getNode(object_id).?.content orelse "" };
    }
    const node_id = switch (target) {
        .document => |id| id,
        .page => |id| id,
        .object => |id| id,
        else => return error.InvalidValueTag,
    };
    const node = state.getNode(node_id) orelse return error.UnknownNode;
    _ = functions;
    var value = (try core.fields.get(state.allocator, state, node, name)) orelse return .{ .none = {} };
    defer value.deinit(state.allocator);
    return try value.value.clone(state.allocator);
}

fn evalMemberPathPrefix(
    state: *core.DocumentState,
    functions: *const core.FunctionMap,
    base: core.Value,
    path: []const ast.RecordPathSegment,
) !core.Value {
    var current = try base.clone(state.allocator);
    errdefer current.deinit(state.allocator);
    for (path) |segment| {
        const next = try evalMemberValue(state, functions, current, segment.name);
        current.deinit(state.allocator);
        current = next;
    }
    return current;
}

fn evalRecord(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    record: ast.RecordExpr,
) !core.Value {
    const state = evaluation.state;
    const resolved = findRecordDecl(state, record.module_id, record.type_name) orelse {
        if (findEnumDecl(state, record.module_id, record.type_name) != null) {
            try reportInvalidRecordLiteral(state, current_origin, record.type_name);
            return error.InvalidType;
        }
        try reportNamedResolutionError(state, error.UnknownType, "record type", record.type_name, current_origin);
        return error.UnknownType;
    };
    const caller_module_id = evaluation.module_id;
    defer evaluation.module_id = caller_module_id;

    var value = core.RecordValue.init(resolved.decl.name);
    value.module_id = resolved.module_id;
    errdefer value.deinit(state.allocator);

    var default_env = std.StringHashMap(core.Value).init(state.allocator);
    defer deinitValueEnv(state.allocator, &default_env);
    evaluation.module_id = resolved.module_id;
    for (resolved.decl.fields.items) |field| {
        if (recordDefinesField(record, field.name)) continue;
        const default_expr = field.default_value orelse continue;
        const field_value = try evalExpr(evaluation, page_id, scope, &default_env, current_origin, default_expr.*);
        try putRecordFieldValue(state.allocator, &value, field.name, field_value, false);
    }

    evaluation.module_id = caller_module_id;
    for (record.fields.items) |field| {
        const field_value = try evalExpr(evaluation, page_id, scope, env, current_origin, field.value);
        try putRecordFieldValue(state.allocator, &value, field.name, field_value, true);
    }
    return .{ .record = value };
}

fn recordDefinesField(record: ast.RecordExpr, name: []const u8) bool {
    for (record.fields.items) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}

fn evalRecordDefaults(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    current_origin: []const u8,
    record_id: core.NominalId,
) !core.RecordValue {
    const state = evaluation.state;
    const resolved = findRecordDecl(state, record_id.module_id, record_id.name) orelse {
        try reportNamedResolutionError(state, error.UnknownType, "record type", record_id.name, current_origin);
        return error.UnknownType;
    };
    const caller_module_id = evaluation.module_id;
    defer evaluation.module_id = caller_module_id;

    var value = core.RecordValue.init(resolved.decl.name);
    value.module_id = resolved.module_id;
    errdefer value.deinit(state.allocator);

    var default_env = std.StringHashMap(core.Value).init(state.allocator);
    defer deinitValueEnv(state.allocator, &default_env);
    evaluation.module_id = resolved.module_id;
    for (resolved.decl.fields.items) |field| {
        const default_expr = field.default_value orelse continue;
        const field_value = try evalExpr(evaluation, page_id, scope, &default_env, current_origin, default_expr.*);
        try putRecordFieldValue(state.allocator, &value, field.name, field_value, false);
    }
    return value;
}

fn evalRecordUpdate(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    update: ast.RecordUpdateExpr,
) !core.Value {
    const state = evaluation.state;
    var target = try evalExpr(evaluation, page_id, scope, env, current_origin, update.target.*);
    errdefer target.deinit(state.allocator);
    if (target != .record) {
        try reportRecordUpdateError(state, current_origin, "InvalidRecordUpdate: with expects a record value", .{});
        return error.InvalidValueTag;
    }

    for (update.fields.items) |field| {
        var field_value = try evalExpr(evaluation, page_id, scope, env, current_origin, field.value);
        var field_value_moved = false;
        errdefer if (!field_value_moved) field_value.deinit(state.allocator);
        updateRecordFieldPath(state.allocator, &target.record, field.path.items, field_value) catch |err| switch (err) {
            error.InvalidValueTag => {
                const path = try ast.formatRecordPath(state.allocator, field.path.items);
                defer state.allocator.free(path);
                try reportRecordUpdateError(state, current_origin, "InvalidRecordUpdatePath: '{s}' does not resolve to a nested record", .{path});
                return err;
            },
            error.UnknownRecordField => {
                const path = try ast.formatRecordPath(state.allocator, field.path.items);
                defer state.allocator.free(path);
                try reportRecordUpdateError(state, current_origin, "MissingRecordField: record update path '{s}' is not present at runtime", .{path});
                return err;
            },
            else => return err,
        };
        field_value_moved = true;
    }
    return target;
}

fn updateRecordFieldPath(
    allocator: std.mem.Allocator,
    record: *core.RecordValue,
    path: []const ast.RecordPathSegment,
    value: core.Value,
) !void {
    if (path.len == 0) return error.UnknownRecordField;
    if (path.len == 1) {
        try putRecordFieldValue(allocator, record, path[0].name, value, true);
        return;
    }
    for (record.fields.items) |*field| {
        if (!std.mem.eql(u8, field.name, path[0].name)) continue;
        if (field.value != .record) return error.InvalidValueTag;
        try updateRecordFieldPath(allocator, &field.value.record, path[1..], value);
        return;
    }
    return error.UnknownRecordField;
}

fn findRecordDecl(state: *const core.DocumentState, module_id: ?core.SourceModuleId, type_name: []const u8) ?declarations.RecordDescriptor {
    return state.declaration_index.record(.{ .module_id = module_id orelse return null, .name = type_name });
}

fn findEnumDecl(state: *const core.DocumentState, module_id: ?core.SourceModuleId, type_name: []const u8) ?declarations.TypeDescriptor {
    return state.declaration_index.typeInModule(module_id orelse return null, type_name);
}

fn putRecordFieldValue(allocator: std.mem.Allocator, record: *core.RecordValue, name: []const u8, value: core.Value, explicit: bool) !void {
    var owned = value;
    errdefer owned.deinit(allocator);
    for (record.fields.items) |*field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        field.value.deinit(allocator);
        field.value = owned;
        field.explicit = explicit;
        return;
    }
    try record.fields.append(allocator, .{
        .name = name,
        .value = owned,
        .explicit = explicit,
    });
}

fn materializePropertyRecord(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    origin: []const u8,
    node: *const core.Node,
    key: []const u8,
    ty: ast.Type,
) !core.RecordValue {
    const state = evaluation.state;
    if (try core.fields.get(state.allocator, state, node, key)) |slot_value| {
        var slot = slot_value;
        defer slot.deinit(state.allocator);
        if (slot.value != .record) return error.InvalidValueTag;
        if (slot.owns_tagged_text) return try cloneTaggedRecordForRuntime(state, slot.value.record);
        return try slot.value.record.clone(state.allocator);
    }
    const record_id = ty.nominalId() orelse {
        try reportRecordUpdateError(state, origin, "InvalidRecordUpdatePath: ss produced a record type without a resolved declaration while evaluating this update; report this as an ss bug with the source file", .{});
        return error.InvalidType;
    };
    return evalRecordDefaults(evaluation, page_id, scope, origin, record_id);
}

fn cloneTaggedRecordForRuntime(state: *core.DocumentState, record: core.RecordValue) anyerror!core.RecordValue {
    var cloned = core.RecordValue.init(try state.copyString(record.type_name));
    cloned.module_id = record.module_id;
    errdefer cloned.deinit(state.allocator);
    for (record.fields.items) |field| {
        try cloned.fields.append(state.allocator, .{
            .name = try state.copyString(field.name),
            .value = try cloneTaggedValueForRuntime(state, field.value),
            .explicit = field.explicit,
        });
    }
    return cloned;
}

fn cloneTaggedValueForRuntime(state: *core.DocumentState, value: core.Value) anyerror!core.Value {
    return switch (value) {
        .string => |text| .{ .string = try state.copyString(text) },
        .enum_case => |case| .{ .enum_case = .{
            .enum_name = try state.copyString(case.enum_name),
            .module_id = case.module_id,
            .case_name = try state.copyString(case.case_name),
        } },
        .record => |record| .{ .record = try cloneTaggedRecordForRuntime(state, record) },
        .none => .{ .none = {} },
        .number => |number| .{ .number = number },
        .boolean => |boolean| .{ .boolean = boolean },
        else => try value.clone(state.allocator),
    };
}

fn evalCall(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    const state = evaluation.state;
    const functions = evaluation.functions;
    if (!call.callee.isQualified()) {
        if (env.get(call.callee.name)) |value| {
            switch (value) {
                .function => |func_ref| {
                    if (!func_ref.returns_value) return error.FunctionDoesNotReturnValue;
                    try validateFixedArity(state, call.args.items.len, func_ref.param_count, current_origin);
                    var args = try evalCallArgs(evaluation, page_id, scope, env, current_origin, call.args.items);
                    defer args.deinit(state.allocator);
                    defer deinitValues(state.allocator, args.items);
                    return try invokeFunctionRef(evaluation, page_id, scope, env, func_ref, current_origin, args.items);
                },
                else => {},
            }
        }
    }
    const sema = SemanticEnv.init(state, evaluation.declarations, functions).forModule(evaluation.module_id);
    if (try resolvedConst(evaluation, &sema, call.callee)) |resolved| {
        var const_value = try evalConstValue(evaluation, page_id, scope, current_origin, resolved);
        defer const_value.deinit(state.allocator);
        const function = switch (const_value) {
            .function => |function| function,
            else => {
                try reportUnknownFunction(state, call.callee.name, current_origin);
                return error.UnknownFunction;
            },
        };
        var args = try evalCallArgs(evaluation, page_id, scope, env, current_origin, call.args.items);
        defer args.deinit(state.allocator);
        defer deinitValues(state.allocator, args.items);
        return try invokeFunctionRef(evaluation, page_id, scope, env, function, current_origin, args.items);
    }
    const descriptor = (try callDescriptor(evaluation, &sema, call.callee)) orelse {
        try reportUnknownCallable(state, &sema, call.callee, current_origin);
        return error.UnknownFunction;
    };
    return switch (descriptor) {
        .function => |resolved| blk: {
            const func = resolved.decl;
            try eval_functions.requireReturnsValue(func);
            break :blk try invokeUserFunctionValueInModule(evaluation, page_id, scope, env, resolved.module_id, func, current_origin, call);
        },
        .primitive => |primitive| try evalPrimitiveCall(evaluation, page_id, scope, env, current_origin, call, primitive),
    };
}

fn evalLambda(
    evaluation: *EvalContext,
    env: *std.StringHashMap(core.Value),
    lambda: ast.LambdaExpr,
) !core.Value {
    const closures = evaluation.closures;
    const id = try closures.add(lambda, env);
    return .{ .function = .{
        .name = "#lambda",
        .module_id = evaluation.module_id,
        .closure_id = id,
        .param_count = lambda.params.items.len,
        .returns_value = true,
    } };
}

fn evalApply(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    apply: ast.ApplyExpr,
) anyerror!core.Value {
    const state = evaluation.state;
    var callee = try evalExpr(evaluation, page_id, scope, env, current_origin, apply.callee.*);
    defer callee.deinit(state.allocator);
    const function = switch (callee) {
        .function => |function| function,
        else => return error.InvalidValueTag,
    };
    var args = try evalCallArgs(evaluation, page_id, scope, env, current_origin, apply.args.items);
    defer args.deinit(state.allocator);
    defer deinitValues(state.allocator, args.items);
    return try invokeFunctionRef(evaluation, page_id, scope, env, function, current_origin, args.items);
}

fn evalCallArgs(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    args: []const Expr,
) !std.ArrayList(core.Value) {
    const state = evaluation.state;
    var values = std.ArrayList(core.Value).empty;
    errdefer {
        deinitValues(state.allocator, values.items);
        values.deinit(state.allocator);
    }
    for (args) |arg| {
        try values.append(state.allocator, try evalExpr(evaluation, page_id, scope, env, current_origin, arg));
    }
    return values;
}

fn evalNodeRepr(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    object_id: core.NodeId,
) ![]const u8 {
    const state = evaluation.state;
    const node = state.getNode(object_id) orelse return error.UnknownNode;
    const function = node.repr_function orelse return node.content orelse "";
    return evalNodeReprWithFunction(evaluation, page_id, scope, env, current_origin, object_id, function);
}

fn evalNodeReprWithFunction(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    object_id: core.NodeId,
    function: core.FunctionRef,
) ![]const u8 {
    const state = evaluation.state;
    const args = [_]core.Value{.{ .object = object_id }};
    var result = try invokeFunctionRef(evaluation, page_id, scope, env, function, current_origin, &args);
    defer result.deinit(state.allocator);
    return switch (result) {
        .string => |text| text,
        else => error.ExpectedStringArgument,
    };
}

const BuiltinContext = struct {
    evaluation: *EvalContext,
    state: *core.DocumentState,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,

    pub fn checkArityRange(self: *const BuiltinContext, actual: usize, min: usize, max: usize) !void {
        try validateArityRange(self.state, actual, min, max, self.current_origin);
    }

    pub fn currentPageValue(self: *const BuiltinContext) !core.Value {
        if (self.scope != .page) return error.NoCurrentPage;
        return .{ .page = self.page_id };
    }

    pub fn currentDocumentValue(self: *const BuiltinContext) core.Value {
        return .{ .document = self.state.document_id };
    }

    pub fn runSelectCall(self: *BuiltinContext, call: CallExpr) anyerror!core.Value {
        return try evalSelectCall(self.evaluation, self.page_id, self.scope, self.env, self.current_origin, call);
    }

    pub fn evalExprValue(self: *BuiltinContext, expr: Expr) anyerror!core.Value {
        return try evalExpr(self.evaluation, self.page_id, self.scope, self.env, self.current_origin, expr);
    }

    pub fn evalStringArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror![]const u8 {
        return try evalCallStringArg(self.evaluation, self.page_id, self.scope, self.env, self.current_origin, call, index);
    }

    pub fn evalPropertyStringArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror![]const u8 {
        return try resolveValuePropertyString(self.state.allocator, try self.evalExprValue(call.args.items[index]));
    }

    pub fn evalNumberArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!f32 {
        return try evalCallNumberArg(self.evaluation, self.page_id, self.scope, self.env, self.current_origin, call, index);
    }

    pub fn evalObjectArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.NodeId {
        return try evalCallObjectArg(self.evaluation, self.page_id, self.scope, self.env, self.current_origin, call, index);
    }

    pub fn evalAnchorArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.AnchorValue {
        return try evalCallAnchorArg(self.evaluation, self.page_id, self.scope, self.env, self.current_origin, call, index);
    }

    pub fn evalRoleArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.Role {
        return try evalCallRoleArg(self.evaluation, self.page_id, self.scope, self.env, self.current_origin, call, index);
    }

    pub fn evalPayloadArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!names.ParsedPayload {
        return try evalCallPayloadArg(self.evaluation, self.page_id, self.scope, self.env, self.current_origin, call, index);
    }

    pub fn ownString(self: *BuiltinContext, text: []u8) ![]const u8 {
        return try self.state.ownString(text);
    }

    pub fn ownStringWithProvenance(self: *BuiltinContext, text: []u8, entries: []const core.ContentProvenance) ![]const u8 {
        return try self.state.ownStringWithProvenance(text, entries);
    }

    pub fn readlines(self: *BuiltinContext, requested: []const u8) ![]const u8 {
        self.state.has_external_evaluation_inputs = true;
        if (self.state.file_inputs) |inputs| try inputs.record(self.state.asset_base_dir, requested, .file);
        const resolved = try resolveAssetPath(self.state.allocator, self.state.asset_base_dir, requested);
        defer self.state.allocator.free(resolved);

        const bytes = utils.fs.readFileAllocWithOptions(self.evaluation.io, self.state.allocator, resolved, .{
            // Reader limits exclude the boundary; readlines allows this exact size.
            .limit = .limited(MAX_READLINES_BYTES + 1),
            .cancellation = self.evaluation.cancellation,
        }) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            var reason_buf: [320]u8 = undefined;
            const reason = switch (err) {
                error.StreamTooLong => std.fmt.bufPrint(
                    &reason_buf,
                    "the file exceeds the {d}-byte readlines limit",
                    .{MAX_READLINES_BYTES},
                ) catch "the file exceeds the readlines size limit",
                else => utils.err.formatErrorReason(&reason_buf, err),
            };
            const message = try std.fmt.allocPrint(
                self.state.allocator,
                "ReadlinesFailed: could not read {s} (resolved to {s}): {s}",
                .{ requested, resolved, reason },
            );
            defer self.state.allocator.free(message);
            try self.emitDiagnosticReport(.@"error", message);
            return try self.state.copyString("");
        };
        return try self.state.ownString(bytes);
    }

    pub fn anchorValueForObject(self: *BuiltinContext, node_id: core.NodeId, anchor_name: []const u8) !core.Value {
        const anchor = names.parseAnchorName(anchor_name) orelse {
            try reportNamedResolutionError(self.state, error.UnknownAnchor, "anchor", anchor_name, self.current_origin);
            return error.UnknownAnchor;
        };
        return .{ .anchor = .{ .node = .{ .node_id = node_id, .anchor = anchor } } };
    }

    pub fn pageAnchorValue(self: *BuiltinContext, anchor_name: []const u8) !core.Value {
        const anchor = names.parseAnchorName(anchor_name) orelse {
            try reportNamedResolutionError(self.state, error.UnknownAnchor, "anchor", anchor_name, self.current_origin);
            return error.UnknownAnchor;
        };
        return .{ .anchor = .{ .page = anchor } };
    }

    pub fn makeObject(
        self: *BuiltinContext,
        role_name: []const u8,
        role: core.Role,
        object_kind: core.ObjectKind,
        payload_kind: core.PayloadKind,
        content: []const u8,
    ) !core.NodeId {
        return try self.state.createObjectWithOrigin(role_name, role, object_kind, payload_kind, content, self.current_origin);
    }

    pub fn makeGroup(self: *BuiltinContext, child_ids: []const core.NodeId) !core.NodeId {
        return try self.state.createGroupWithOrigin(child_ids, self.current_origin);
    }

    pub fn makePage(self: *BuiltinContext, title: []const u8) !core.NodeId {
        return try self.state.addPage(title);
    }

    pub fn placeObjectOnPage(self: *BuiltinContext, page_id: core.NodeId, object_id: core.NodeId) !void {
        try self.state.placeObjectOnPage(page_id, object_id);
    }

    pub fn placeOverlayObjectOnPage(self: *BuiltinContext, page_id: core.NodeId, object_id: core.NodeId) !void {
        try self.state.placeOverlayObjectOnPage(page_id, object_id);
    }

    pub fn setNodeFieldValue(self: *BuiltinContext, object_id: core.NodeId, key: []const u8, value: core.Value) !void {
        self.state.setNodeFieldValue(object_id, key, value) catch |err| switch (err) {
            error.DuplicatePropertyDefinition => {
                try reportDuplicatePropertyDefinition(self.state, self.current_origin, key);
                return err;
            },
            else => return err,
        };
    }

    pub fn setNodeReprFunction(self: *BuiltinContext, object_id: core.NodeId, function: core.FunctionRef) !void {
        self.state.setNodeReprFunction(object_id, function) catch |err| switch (err) {
            error.DuplicateReprDefinition => {
                try reportDuplicateReprDefinition(self.state, self.current_origin);
                return err;
            },
            else => return err,
        };
    }

    pub fn unsetNodeField(self: *BuiltinContext, object_id: core.NodeId, key: []const u8) !void {
        try self.state.unsetNodeField(object_id, key);
    }

    pub fn extendRenderEnv(self: *BuiltinContext, node_id: core.NodeId, op: []const u8, key: []const u8, value: []const u8) !void {
        try self.state.extendRenderEnv(node_id, op, key, value);
    }

    pub fn invokeCallback(self: *BuiltinContext, function: core.FunctionRef, args: []const core.Value) !core.Value {
        return try invokeFunctionRef(self.evaluation, self.page_id, self.scope, self.env, function, self.current_origin, args);
    }

    pub fn pageIndex(self: *BuiltinContext, page_id: core.NodeId) usize {
        return self.state.pageIndexOf(page_id);
    }

    pub fn pageCount(self: *BuiltinContext) usize {
        return self.state.pageCount();
    }

    pub fn frameX(self: *BuiltinContext, object_id: core.NodeId) !f32 {
        _ = self;
        _ = object_id;
        return error.UnsupportedDocumentEvaluationPrimitive;
    }

    pub fn frameY(self: *BuiltinContext, object_id: core.NodeId) !f32 {
        _ = self;
        _ = object_id;
        return error.UnsupportedDocumentEvaluationPrimitive;
    }

    pub fn frameWidth(self: *BuiltinContext, object_id: core.NodeId) !f32 {
        _ = self;
        _ = object_id;
        return error.UnsupportedDocumentEvaluationPrimitive;
    }

    pub fn frameHeight(self: *BuiltinContext, object_id: core.NodeId) !f32 {
        _ = self;
        _ = object_id;
        return error.UnsupportedDocumentEvaluationPrimitive;
    }

    pub fn nodeContent(self: *BuiltinContext, object_id: core.NodeId) ?[]const u8 {
        const node = self.state.getNode(object_id) orelse return null;
        return node.content;
    }

    pub fn reprNode(self: *BuiltinContext, object_id: core.NodeId) ![]const u8 {
        return try evalNodeRepr(self.evaluation, self.page_id, self.scope, self.env, self.current_origin, object_id);
    }

    pub fn nodeField(self: *BuiltinContext, target: core.Value, key: []const u8) ?core.Value {
        const node_id = switch (target) {
            .document => |id| id,
            .page => |id| id,
            .object => |id| id,
            else => return null,
        };
        const node = self.state.getNode(node_id) orelse return null;
        return core.nodeField(node, key);
    }

    pub fn setNodeContent(self: *BuiltinContext, object_id: core.NodeId, text: []const u8) !void {
        self.state.setNodeContent(object_id, text) catch |err| switch (err) {
            error.DuplicateContentDefinition => {
                try reportDuplicateContentDefinition(self.state, self.current_origin);
                return err;
            },
            else => return err,
        };
    }

    pub fn equalAnchorConstraintSet(
        self: *BuiltinContext,
        target: core.AnchorValue,
        source: core.AnchorValue,
        offset: f32,
    ) !core.ConstraintSet {
        return try anchorEqualityConstraintSet(self.evaluation, target, source, offset, self.current_origin);
    }

    pub fn emitDiagnosticReport(self: *BuiltinContext, severity: core.DiagnosticSeverity, message: []const u8) !void {
        try emitUserReport(self.state, self.page_id, self.current_origin, severity, message);
    }

    pub fn ensurePrimitiveArgType(self: *BuiltinContext, descriptor: registry.PrimitiveDescriptor, index: usize, value: core.Value) !void {
        const sema = SemanticEnv.init(self.state, self.evaluation.declarations, self.evaluation.functions).forModule(self.evaluation.module_id);
        const expected = sema.primitiveArgType(descriptor, index) orelse return;
        try value_contracts.ensureValueConformsToType(self.state, self.page_id, value, expected, self.current_origin, .UnmatchedArgumentType);
    }

    pub fn checkAssetExists(self: *BuiltinContext, object_id: core.NodeId) !void {
        try validateAssetExists(self.state, self.page_id, object_id, self.current_origin);
    }
};

fn evalPrimitiveCall(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    call: CallExpr,
    descriptor: registry.PrimitiveDescriptor,
) anyerror!core.Value {
    const state = evaluation.state;
    var ctx = BuiltinContext{
        .evaluation = evaluation,
        .state = state,
        .page_id = page_id,
        .scope = scope,
        .env = env,
        .current_origin = current_origin,
    };
    return try builtin.evalCall(&ctx, call, descriptor);
}

fn emitUserReport(
    state: *core.DocumentState,
    page_id: core.NodeId,
    origin: []const u8,
    severity: core.DiagnosticSeverity,
    message: []const u8,
) !void {
    try state.addValidationDiagnostic(
        severity,
        page_id,
        null,
        origin,
        .{ .user_report = .{ .message = try state.allocator.dupe(u8, message) } },
    );
}

fn validateAssetExists(state: *core.DocumentState, page_id: core.NodeId, object_id: core.NodeId, origin: []const u8) !void {
    state.has_external_evaluation_inputs = true;
    const node = state.getNode(object_id) orelse return error.UnknownNode;
    var diagnostic_origin = try assetContentDiagnosticOrigin(state, node, origin);
    defer diagnostic_origin.deinit(state.allocator);
    if (node.object_kind == null or node.object_kind.? != .asset or node.content == null) {
        try state.addValidationDiagnostic(.@"error", page_id, object_id, diagnostic_origin.text, .{
            .asset_invalid = .{
                .reason = try state.allocator.dupe(u8, "expected an asset object with a path"),
                .payload_kind = node.payload_kind,
            },
        });
        return;
    }

    const requested = node.content.?;
    if (state.file_inputs) |inputs| try inputs.record(state.asset_base_dir, requested, .file);
    const resolved = try resolveAssetPath(state.allocator, state.asset_base_dir, requested);
    var resolved_owned = true;
    defer if (resolved_owned) state.allocator.free(resolved);
    if (!try fs_utils.fileExists(state.allocator, resolved)) {
        const requested_path = try state.allocator.dupe(u8, requested);
        resolved_owned = false;
        try state.addValidationDiagnostic(.@"error", page_id, object_id, diagnostic_origin.text, .{
            .asset_not_found = .{
                .requested_path = requested_path,
                .resolved_path = resolved,
                .payload_kind = node.payload_kind,
            },
        });
        return;
    }
}

const DiagnosticOrigin = struct {
    text: ?[]const u8,
    owned: bool = false,

    fn deinit(self: *DiagnosticOrigin, allocator: std.mem.Allocator) void {
        if (self.owned) {
            if (self.text) |text| allocator.free(text);
        }
    }
};

fn assetContentDiagnosticOrigin(state: *core.DocumentState, node: *const core.Node, fallback: []const u8) !DiagnosticOrigin {
    const content = node.content orelse return .{ .text = fallback };
    if (try originForContentSpan(state.allocator, node.content_provenance.items, 0, content.len)) |origin| {
        return .{ .text = origin, .owned = true };
    }
    return .{ .text = fallback };
}

fn originForContentSpan(
    allocator: std.mem.Allocator,
    entries: []const core.ContentProvenance,
    content_start: usize,
    content_end: usize,
) !?[]const u8 {
    const normalized_end = @max(content_end, content_start);
    for (entries) |entry| {
        if (content_start < entry.content_start or normalized_end > entry.content_end) continue;
        const located = utils.err.parseLocatedOrigin(entry.origin) orelse continue;
        const start = located.span.start + (content_start - entry.content_start);
        const end = located.span.start + (normalized_end - entry.content_start);
        if (located.path) |path| {
            return try std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ path, start, end });
        }
        return try std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ start, end });
    }
    return null;
}

fn resolveAssetPath(allocator: std.mem.Allocator, base_dir: []const u8, requested: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(requested)) return allocator.dupe(u8, requested);
    return std.fs.path.join(allocator, &.{ base_dir, requested });
}

fn evalSelectCall(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    const state = evaluation.state;
    const functions = evaluation.functions;
    const base = try evalExpr(evaluation, page_id, scope, env, current_origin, call.args.items[0]);
    const op_name = try evalCallStringArg(evaluation, page_id, scope, env, current_origin, call, 1);
    const sema = SemanticEnv.init(null, null, functions);
    const descriptor = sema.query(op_name) orelse {
        try reportUnknownQuery(state, op_name, current_origin);
        return error.UnknownQuery;
    };
    registry.validateQueryArity(descriptor, call.args.items.len) catch |err| {
        if (err == error.InvalidArity) try validateFixedArity(state, call.args.items.len, descriptor.arity, current_origin);
        return err;
    };
    try value_contracts.ensureValueConformsToType(state, null, base, descriptor.input_type, current_origin, .UnmatchedInputType);
    switch (descriptor.op) {
        .self_object => {
            return try state.select(state.allocator, base, core.Query.selfObject());
        },
        .previous_page => {
            return try state.select(state.allocator, base, core.Query.previousPage());
        },
        .parent_page => {
            return try state.select(state.allocator, base, core.Query.parentPage());
        },
        .children => {
            return try state.select(state.allocator, base, core.Query.children());
        },
        .descendants => {
            return try state.select(state.allocator, base, core.Query.descendants());
        },
        .document_pages => {
            return try state.select(state.allocator, base, core.Query.documentPages());
        },
        .page_objects_by_role => {
            const role = try evalCallRoleArg(evaluation, page_id, scope, env, current_origin, call, 2);
            return try state.select(state.allocator, base, core.Query.pageObjectsByRole(role));
        },
        .document_objects_by_role => {
            const role = try evalCallRoleArg(evaluation, page_id, scope, env, current_origin, call, 2);
            return try state.select(state.allocator, base, core.Query.documentObjectsByRole(role));
        },
    }
}

fn validateFixedArity(state: *core.DocumentState, actual: usize, expected: usize, origin: []const u8) !void {
    if (actual != expected) {
        try reportLowerDiagnostic(state, .{
            .err = error.InvalidArity,
            .origin = origin,
            .data = .{ .invalid_arity = .{ .actual = actual, .min = expected, .max = expected } },
        });
        return error.InvalidArity;
    }
}

fn validateUserFunctionArity(state: *core.DocumentState, actual: usize, func: FunctionDecl, origin: []const u8) !void {
    const range = eval_functions.arity(func);
    if (actual < range.min or actual > range.max) {
        try reportLowerDiagnostic(state, .{
            .err = error.InvalidArity,
            .origin = origin,
            .data = .{ .invalid_arity = .{ .actual = actual, .min = range.min, .max = range.max } },
        });
        return error.InvalidArity;
    }
}

fn validateArityRange(state: *core.DocumentState, actual: usize, min: usize, max: usize, origin: []const u8) !void {
    if (actual < min or actual > max) {
        try reportLowerDiagnostic(state, .{
            .err = error.InvalidArity,
            .origin = origin,
            .data = .{ .invalid_arity = .{ .actual = actual, .min = min, .max = max } },
        });
        return error.InvalidArity;
    }
}

fn bindUserFunctionArgs(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    caller_env: *std.StringHashMap(core.Value),
    local_env: *std.StringHashMap(core.Value),
    module_id: core.SourceModuleId,
    func: FunctionDecl,
    current_origin: []const u8,
    call: CallExpr,
) !void {
    const state = evaluation.state;
    for (func.params.items, 0..) |param, index| {
        const value = if (index < call.args.items.len) blk: {
            break :blk try evalExpr(evaluation, page_id, scope, caller_env, current_origin, call.args.items[index]);
        } else blk: {
            const previous_module_id = evaluation.module_id;
            evaluation.module_id = module_id;
            defer evaluation.module_id = previous_module_id;
            break :blk try evalExpr(evaluation, page_id, scope, local_env, current_origin, (param.default_value orelse return error.InvalidArity).*);
        };
        value_contracts.ensureValueConformsToType(state, page_id, value, param.ty, current_origin, .UnmatchedArgumentType) catch |err| {
            var owned = value;
            owned.deinit(state.allocator);
            return err;
        };
        try putEnvValue(state.allocator, local_env, param.name, value);
    }
}

fn bindUserFunctionValueArgs(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    caller_env: *std.StringHashMap(core.Value),
    local_env: *std.StringHashMap(core.Value),
    module_id: core.SourceModuleId,
    func: FunctionDecl,
    current_origin: []const u8,
    args: []const core.Value,
) !void {
    const state = evaluation.state;
    try validateUserFunctionArity(state, args.len, func, current_origin);
    for (func.params.items, 0..) |param, index| {
        const value = if (index < args.len) blk: {
            break :blk try args[index].clone(state.allocator);
        } else blk: {
            const previous_module_id = evaluation.module_id;
            evaluation.module_id = module_id;
            defer evaluation.module_id = previous_module_id;
            break :blk try evalExpr(evaluation, page_id, scope, local_env, current_origin, (param.default_value orelse return error.InvalidArity).*);
        };
        value_contracts.ensureValueConformsToType(state, page_id, value, param.ty, current_origin, .UnmatchedArgumentType) catch |err| {
            var owned = value;
            owned.deinit(state.allocator);
            return err;
        };
        try putEnvValue(state.allocator, local_env, param.name, value);
    }
    _ = caller_env;
}

fn resolveValueString(value: core.Value) ![]const u8 {
    return eval_value.string(value);
}

pub fn resolveValuePropertyString(allocator: std.mem.Allocator, value: core.Value) ![]const u8 {
    return eval_value.propertyString(allocator, value);
}

fn resolveValueNumber(value: core.Value) !f32 {
    return eval_value.number(value);
}

fn resolveValueBoolean(value: core.Value) !bool {
    return eval_value.boolean(value);
}

fn resolveValueAnchor(value: core.Value) !core.AnchorValue {
    return switch (value) {
        .anchor => |anchor| anchor,
        else => return error.ExpectedAnchor,
    };
}

fn resolveValueObjectId(value: core.Value) !core.NodeId {
    return switch (value) {
        .object => |id| id,
        else => return error.ExpectedObject,
    };
}

fn evalCallArg(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.Value {
    return try evalExpr(evaluation, page_id, scope, env, current_origin, call.args.items[index]);
}

fn evalCallStringArg(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror![]const u8 {
    return try resolveValueString(try evalCallArg(evaluation, page_id, scope, env, current_origin, call, index));
}

fn evalCallNumberArg(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!f32 {
    return try resolveValueNumber(try evalCallArg(evaluation, page_id, scope, env, current_origin, call, index));
}

fn evalCallObjectArg(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.NodeId {
    return try resolveValueObjectId(try evalCallArg(evaluation, page_id, scope, env, current_origin, call, index));
}

fn evalCallAnchorArg(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.AnchorValue {
    return try resolveValueAnchor(try evalCallArg(evaluation, page_id, scope, env, current_origin, call, index));
}

fn evalCallRoleArg(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.Role {
    const state = evaluation.state;
    const role_name = try evalCallStringArg(evaluation, page_id, scope, env, current_origin, call, index);
    return names.parseRoleName(role_name) orelse {
        try reportNamedResolutionError(state, error.UnknownRole, "role", role_name, current_origin);
        return error.UnknownRole;
    };
}

fn evalCallPayloadArg(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!names.ParsedPayload {
    const state = evaluation.state;
    const payload_name = try evalCallStringArg(evaluation, page_id, scope, env, current_origin, call, index);
    return names.parsePayloadName(payload_name) orelse {
        try reportNamedResolutionError(state, error.UnknownPayloadKind, "payload kind", payload_name, current_origin);
        return error.UnknownPayloadKind;
    };
}

fn singleConstraintSet(state: *core.DocumentState, constraint: core.Constraint) !core.ConstraintSet {
    var bundle = core.ConstraintSet.init();
    errdefer bundle.deinit(state.allocator);
    try bundle.items.append(state.allocator, constraint);
    return bundle;
}

fn anchorEqualityConstraintSet(
    evaluation: *EvalContext,
    target: core.AnchorValue,
    source: core.AnchorValue,
    offset: f32,
    origin: []const u8,
) !core.ConstraintSet {
    const state = evaluation.state;
    return switch (target) {
        .page => error.PageCannotBeConstraintTarget,
        .node => |node| try singleConstraintSet(state, .{
            .target_node = node.node_id,
            .target_anchor = node.anchor,
            .source = source.toConstraintSource(),
            .offset = offset,
            .origin = origin,
            .role = core.constraintRoleForRelation(node.node_id, node.anchor, source.toConstraintSource()),
            .scope_depth = evaluation.call_depth,
        }),
    };
}

const ResolvedTarget = struct {
    node_id: core.NodeId,
    anchor: core.Anchor,
};

fn writeNodeFieldValue(
    state: *core.DocumentState,
    node_id: core.NodeId,
    field_name: []const u8,
    value: core.Value,
    origin: []const u8,
    replace_existing: bool,
) !void {
    if (value == .none) {
        try state.unsetNodeField(node_id, field_name);
        return;
    }
    if (std.mem.eql(u8, field_name, "content")) {
        const text = try resolveValuePropertyString(state.allocator, value);
        defer if (eval_value.propertyStringNeedsFree(value)) state.allocator.free(text);
        state.setNodeContent(node_id, text) catch |err| switch (err) {
            error.DuplicateContentDefinition => {
                try reportDuplicateContentDefinition(state, origin);
                return err;
            },
            else => return err,
        };
        return;
    }
    if (replace_existing) try state.unsetNodeField(node_id, field_name);
    state.setNodeFieldValue(node_id, field_name, value) catch |err| switch (err) {
        error.DuplicatePropertyDefinition => {
            try reportDuplicatePropertyDefinition(state, origin, field_name);
            return err;
        },
        else => return err,
    };
}

fn isPropertyTargetValue(value: core.Value) bool {
    return switch (value) {
        .document, .page, .object, .selection => true,
        else => false,
    };
}

fn writePropertyPath(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    origin: []const u8,
    base: core.Value,
    path: []const ast.RecordPathSegment,
    value: core.Value,
) !void {
    const state = evaluation.state;
    const functions = evaluation.functions;
    if (path.len == 0) return;
    var current = try base.clone(state.allocator);
    defer current.deinit(state.allocator);

    var path_index: usize = 0;
    while (!isPropertyTargetValue(current)) {
        if (path_index >= path.len) return error.ExpectedObject;
        const next = try evalMemberValue(state, functions, current, path[path_index].name);
        current.deinit(state.allocator);
        current = next;
        path_index += 1;
    }

    try writePropertyPathToTarget(evaluation, page_id, scope, origin, current, path[path_index..], value);
}

fn writePropertyPathToTarget(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    origin: []const u8,
    target: core.Value,
    path: []const ast.RecordPathSegment,
    value: core.Value,
) !void {
    if (path.len == 0) return error.ExpectedObject;
    switch (target) {
        .document => |id| try writePropertyPathToNode(evaluation, page_id, scope, origin, id, path, value),
        .page => |id| try writePropertyPathToNode(evaluation, page_id, scope, origin, id, path, value),
        .object => |id| try writePropertyPathToNode(evaluation, page_id, scope, origin, id, path, value),
        .selection => |selection| {
            if (selection.item_tag != .object) return error.InvalidSelectionItemType;
            for (selection.ids.items) |id| {
                try writePropertyPathToNode(evaluation, page_id, scope, origin, id, path, value);
            }
        },
        else => return error.ExpectedObject,
    }
}

fn writePropertyPathToNode(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    origin: []const u8,
    node_id: core.NodeId,
    path: []const ast.RecordPathSegment,
    value: core.Value,
) !void {
    const state = evaluation.state;
    const functions = evaluation.functions;
    if (path.len == 0) return error.ExpectedObject;
    const property_name = path[0].name;
    if (path.len == 1) {
        try writeNodeFieldValue(state, node_id, property_name, value, origin, false);
        return;
    }

    const node = state.getNode(node_id) orelse return error.UnknownNode;
    const sema = SemanticEnv.init(state, evaluation.declarations, functions).forModule(evaluation.module_id);
    const maybe_field = if (core.fields.classId(state, node)) |class_name|
        sema.field(class_name, property_name)
    else
        sema.fieldByName(property_name);
    const field = maybe_field orelse return error.InvalidType;
    if (field.value_type.kind != .record) return error.InvalidValueTag;
    var record = try materializePropertyRecord(evaluation, page_id, scope, origin, node, property_name, field.value_type);
    defer record.deinit(state.allocator);

    var value_copy = try value.clone(state.allocator);
    var value_moved = false;
    defer if (!value_moved) value_copy.deinit(state.allocator);
    updateRecordFieldPath(state.allocator, &record, path[1..], value_copy) catch |err| switch (err) {
        error.InvalidValueTag => {
            const path_text = try ast.formatRecordPath(state.allocator, path);
            defer state.allocator.free(path_text);
            try reportRecordUpdateError(state, origin, "InvalidRecordUpdatePath: '{s}' does not resolve to a nested record", .{path_text});
            return err;
        },
        error.UnknownRecordField => {
            const path_text = try ast.formatRecordPath(state.allocator, path);
            defer state.allocator.free(path_text);
            try reportRecordUpdateError(state, origin, "MissingRecordField: record update path '{s}' is not present at runtime", .{path_text});
            return err;
        },
        else => return err,
    };
    value_moved = true;
    try writeNodeFieldValue(state, node_id, property_name, .{ .record = record }, origin, true);
}

fn executeStatement(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    last_code_like: *?core.NodeId,
    stmt: Statement,
    origin_override: ?[]const u8,
) anyerror!ExecFlow {
    const state = evaluation.state;
    const functions = evaluation.functions;
    try checkCancellation(evaluation);
    const origin = if (origin_override) |override| override else try state.ownString(try statementOrigin(evaluation, stmt.span));
    switch (stmt.kind) {
        .hole => return error.HoleStatement,
        .let_binding => |binding| {
            const value = try evalExpr(evaluation, page_id, scope, env, origin, binding.expr);
            if (names.isDiscardBindingName(binding.name)) {
                defer {
                    var owned = value;
                    owned.deinit(state.allocator);
                }
                try discardStatementValue(state, value);
                return .none;
            }
            if (scope == .page and evaluation.call_depth == 0) {
                try addValueObjectSources(state, page_id, evaluation.module_id, binding.name, null, stmt.span, value);
            }
            try putEnvValue(state.allocator, env, binding.name, value);
        },
        .return_expr => |expr| {
            const value = try evalExpr(evaluation, page_id, scope, env, origin, expr);
            return .{ .returned = value };
        },
        .return_void => return .{ .returned = .{ .void = {} } },
        .property_set => |property_set| {
            if (property_set.path.items.len == 0) return .none;
            var base = try evalExpr(evaluation, page_id, scope, env, origin, property_set.target);
            defer base.deinit(state.allocator);
            var value = try evalExpr(evaluation, page_id, scope, env, origin, property_set.value);
            defer value.deinit(state.allocator);
            try writePropertyPath(evaluation, page_id, scope, origin, base, property_set.path.items, value);
        },
        .if_stmt => |if_stmt| {
            const value = try evalExpr(evaluation, page_id, scope, env, origin, if_stmt.condition);
            const condition = try resolveValueBoolean(value);
            const branch = if (condition) if_stmt.then_statements.items else if_stmt.else_statements.items;
            var branch_env = try cloneValueEnv(state.allocator, env);
            defer deinitValueEnv(state.allocator, &branch_env);
            for (branch) |nested| {
                const flow = try executeStatement(evaluation, page_id, scope, &branch_env, last_code_like, nested, null);
                switch (flow) {
                    .none => {},
                    .returned => return flow,
                }
            }
        },
        .constrain => |decl| {
            const target = try resolveAnchorRef(state, env, origin, decl.target, true);
            const resolved_source: ?core.ConstraintSource = if (decl.source) |source_ref|
                try resolveAnchorRef(state, env, origin, source_ref, false)
            else
                null;
            const offset: f32 = if (decl.offset) |expr| blk: {
                const value = try evalExpr(evaluation, page_id, scope, env, origin, expr);
                break :blk try resolveValueNumber(value);
            } else 0;
            const role: core.ConstraintRole = if (decl.target_kind == .dimension)
                .size
            else if (resolved_source) |source|
                core.constraintRoleForRelation(target.node_id, target.anchor, source)
            else
                .position;
            switch (decl.action) {
                .add => try state.addAnchorConstraintAtScope(
                    target.node_id,
                    target.anchor,
                    resolved_source orelse return error.InvalidConstraint,
                    offset,
                    origin,
                    evaluation.call_depth,
                ),
                .update => try state.addConstraintUpdate(
                    target.node_id,
                    target.anchor,
                    role,
                    evaluation.call_depth,
                    resolved_source,
                    offset,
                    origin,
                ),
            }
        },
        .expr_stmt => |expr| {
            var value = switch (expr) {
                .call => |call| blk: {
                    const sema = SemanticEnv.init(state, evaluation.declarations, functions).forModule(evaluation.module_id);
                    if ((try resolvedFunction(evaluation, &sema, call.callee)) != null) {
                        break :blk try executeCallStatement(evaluation, page_id, scope, env, last_code_like, origin, call);
                    }
                    break :blk try evalExpr(evaluation, page_id, scope, env, origin, expr);
                },
                else => try evalExpr(evaluation, page_id, scope, env, origin, expr),
            };
            defer value.deinit(state.allocator);
            try materializeStatementValue(state, last_code_like, value);
            if (scope == .page and evaluation.call_depth == 0) {
                const binding_base = switch (expr) {
                    .call => |call| call.callee.name,
                    else => "",
                };
                try addValueObjectSources(state, page_id, evaluation.module_id, "", binding_base, stmt.span, value);
            }
        },
    }
    return .none;
}

fn materializeStatementValue(state: *core.DocumentState, last_code_like: *?core.NodeId, value: core.Value) !void {
    switch (value) {
        .constraints => |constraints| try state.addConstraintSet(constraints),
        .object => |id| last_code_like.* = id,
        else => {},
    }
}

fn addValueObjectSources(
    state: *core.DocumentState,
    page_id: core.NodeId,
    module_id: core.SourceModuleId,
    path: []const u8,
    binding_base: ?[]const u8,
    span: ast.Span,
    value: core.Value,
) !void {
    switch (value) {
        .object => |node_id| try state.addObjectSource(node_id, page_id, module_id, path, binding_base, span),
        .record => |record| {
            for (record.fields.items) |field| {
                const field_path = if (path.len == 0)
                    try std.fmt.allocPrint(state.allocator, ".{s}", .{field.name})
                else
                    try std.fmt.allocPrint(state.allocator, "{s}.{s}", .{ path, field.name });
                defer state.allocator.free(field_path);
                try addValueObjectSources(state, page_id, module_id, field_path, binding_base, span, field.value);
            }
        },
        else => {},
    }
}

fn connectReturnedObject(state: *core.DocumentState, value: core.Value, start_node_count: usize, origin: []const u8) !void {
    switch (value) {
        .object => |id| try state.connectGeneratedReturnObjects(id, start_node_count, origin),
        else => {},
    }
}

fn connectValueObjects(state: *core.DocumentState, value: core.Value, start_node_count: usize, origin: []const u8) !void {
    switch (value) {
        .object => |id| try state.connectGeneratedReturnObjects(id, start_node_count, origin),
        .record => |record| {
            for (record.fields.items) |field| try connectValueObjects(state, field.value, start_node_count, origin);
        },
        else => {},
    }
}

fn discardStatementValue(state: *core.DocumentState, value: core.Value) !void {
    switch (value) {
        .object => |id| try state.discardObjectSubtree(id),
        .selection => |selection| {
            if (selection.item_tag != .object) return;
            for (selection.ids.items) |id| try state.discardObjectSubtree(id);
        },
        else => {},
    }
}

fn executeCallStatement(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    last_code_like: *?core.NodeId,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    const state = evaluation.state;
    const functions = evaluation.functions;
    const sema = SemanticEnv.init(state, evaluation.declarations, functions).forModule(evaluation.module_id);
    const resolved = (try resolvedFunction(evaluation, &sema, call.callee)) orelse {
        return try evalCall(evaluation, page_id, scope, env, current_origin, call);
    };
    const func = resolved.decl;
    try validateUserFunctionArity(state, call.args.items.len, func, current_origin);

    const previous_call_depth = evaluation.call_depth;
    evaluation.call_depth += 1;
    defer evaluation.call_depth = previous_call_depth;

    var local_env = std.StringHashMap(core.Value).init(state.allocator);
    defer deinitValueEnv(state.allocator, &local_env);
    try bindUserFunctionArgs(evaluation, page_id, scope, env, &local_env, resolved.module_id, func, current_origin, call);
    const start_node_count = state.nodeCount();
    const previous_module_id = evaluation.module_id;
    evaluation.module_id = resolved.module_id;
    defer evaluation.module_id = previous_module_id;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(evaluation, page_id, scope, &local_env, last_code_like, inner, null);
        switch (flow) {
            .none => {},
            .returned => |value| {
                if (func.result_type.kind == .void) {
                    value_contracts.ensureValueTypeWithCode(state, page_id, value, .void, current_origin, .UnmatchedReturnType) catch |err| {
                        var owned = value;
                        owned.deinit(state.allocator);
                        return err;
                    };
                } else {
                    value_contracts.ensureValueConformsToType(state, page_id, value, func.result_type, current_origin, .UnmatchedReturnType) catch |err| {
                        var owned = value;
                        owned.deinit(state.allocator);
                        return err;
                    };
                    connectValueObjects(state, value, start_node_count, current_origin) catch |err| {
                        var owned = value;
                        owned.deinit(state.allocator);
                        return err;
                    };
                }
                return value;
            },
        }
    }
    if (func.result_type.kind != .void) return error.FunctionDidNotReturnValue;
    return .{ .void = {} };
}

fn invokeFunctionRef(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    function: core.FunctionRef,
    current_origin: []const u8,
    args: []const core.Value,
) anyerror!core.Value {
    const state = evaluation.state;
    const functions = evaluation.functions;
    if (function.closure_id) |closure_id| {
        return try invokeClosureValues(evaluation, page_id, scope, env, function.module_id, closure_id, current_origin, args);
    }
    const sema = SemanticEnv.init(state, evaluation.declarations, functions).forModule(function.module_id);
    const resolved = (try resolvedFunction(evaluation, &sema, ast.CallableName.bare(function.name))) orelse {
        try reportUnknownFunction(state, function.name, current_origin);
        return error.UnknownFunction;
    };
    return try invokeUserFunctionValues(evaluation, page_id, scope, env, resolved.module_id, resolved.decl, current_origin, args);
}

fn invokeClosureValues(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    caller_env: *std.StringHashMap(core.Value),
    module_id: core.SourceModuleId,
    closure_id: usize,
    current_origin: []const u8,
    args: []const core.Value,
) anyerror!core.Value {
    const state = evaluation.state;
    const closures = evaluation.closures;
    _ = caller_env;
    const closure = closures.get(closure_id) orelse {
        try reportUnknownFunction(state, "#lambda", current_origin);
        return error.UnknownFunction;
    };
    try validateFixedArity(state, args.len, closure.lambda.params.items.len, current_origin);

    const previous_call_depth = evaluation.call_depth;
    evaluation.call_depth += 1;
    defer evaluation.call_depth = previous_call_depth;

    var local_env = try cloneValueEnv(state.allocator, &closure.env);
    defer deinitValueEnv(state.allocator, &local_env);
    for (closure.lambda.params.items, 0..) |param, index| {
        const value = try args[index].clone(state.allocator);
        value_contracts.ensureValueConformsToType(state, page_id, value, param.ty, current_origin, .UnmatchedArgumentType) catch |err| {
            var owned = value;
            owned.deinit(state.allocator);
            return err;
        };
        try putEnvValue(state.allocator, &local_env, param.name, value);
    }
    const start_node_count = state.nodeCount();
    const previous_module_id = evaluation.module_id;
    evaluation.module_id = module_id;
    defer evaluation.module_id = previous_module_id;
    const value = try evalExpr(evaluation, page_id, scope, &local_env, current_origin, closure.lambda.body.*);
    try connectReturnedObject(state, value, start_node_count, current_origin);
    return value;
}

fn invokeUserFunctionValue(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    func: FunctionDecl,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    return invokeUserFunctionValueInModule(evaluation, page_id, scope, env, evaluation.module_id, func, current_origin, call);
}

fn invokeUserFunctionValueInModule(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    module_id: core.SourceModuleId,
    func: FunctionDecl,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    const state = evaluation.state;
    var func_ref = try eval_functions.functionRefForInModule(state.allocator, module_id, func);
    defer func_ref.deinit(state.allocator);
    if (!func_ref.returns_value) return error.FunctionDoesNotReturnValue;
    try validateUserFunctionArity(state, call.args.items.len, func, current_origin);

    const previous_call_depth = evaluation.call_depth;
    evaluation.call_depth += 1;
    defer evaluation.call_depth = previous_call_depth;

    var local_env = std.StringHashMap(core.Value).init(state.allocator);
    defer deinitValueEnv(state.allocator, &local_env);
    try bindUserFunctionArgs(evaluation, page_id, scope, env, &local_env, module_id, func, current_origin, call);

    var last_code_like: ?core.NodeId = null;
    const start_node_count = state.nodeCount();
    const previous_module_id = evaluation.module_id;
    evaluation.module_id = module_id;
    defer evaluation.module_id = previous_module_id;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(evaluation, page_id, scope, &local_env, &last_code_like, inner, null);
        switch (flow) {
            .none => {},
            .returned => |value| {
                try value_contracts.ensureValueConformsToType(state, page_id, value, func.result_type, current_origin, .UnmatchedReturnType);
                try connectReturnedObject(state, value, start_node_count, current_origin);
                return value;
            },
        }
    }

    return error.FunctionDidNotReturnValue;
}

fn invokeUserFunctionValues(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *std.StringHashMap(core.Value),
    module_id: core.SourceModuleId,
    func: FunctionDecl,
    current_origin: []const u8,
    args: []const core.Value,
) anyerror!core.Value {
    const state = evaluation.state;
    const previous_call_depth = evaluation.call_depth;
    evaluation.call_depth += 1;
    defer evaluation.call_depth = previous_call_depth;

    var local_env = std.StringHashMap(core.Value).init(state.allocator);
    defer deinitValueEnv(state.allocator, &local_env);
    try bindUserFunctionValueArgs(evaluation, page_id, scope, env, &local_env, module_id, func, current_origin, args);

    var last_code_like: ?core.NodeId = null;
    const start_node_count = state.nodeCount();
    const previous_module_id = evaluation.module_id;
    evaluation.module_id = module_id;
    defer evaluation.module_id = previous_module_id;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(evaluation, page_id, scope, &local_env, &last_code_like, inner, null);
        switch (flow) {
            .none => {},
            .returned => |value| {
                try value_contracts.ensureValueConformsToType(state, page_id, value, func.result_type, current_origin, .UnmatchedReturnType);
                try connectReturnedObject(state, value, start_node_count, current_origin);
                return value;
            },
        }
    }

    if (func.result_type.kind == .void) return .{ .void = {} };
    return error.FunctionDidNotReturnValue;
}

fn statementOrigin(evaluation: *EvalContext, span: ast.Span) ![]u8 {
    const state = evaluation.state;
    const path: []const u8 = if (state.moduleById(evaluation.module_id)) |module|
        module.path orelse module.spec
    else
        "";
    if (path.len != 0) {
        return std.fmt.allocPrint(state.allocator, "path:{s}:bytes:{d}-{d}", .{ path, span.start, span.end });
    }
    return std.fmt.allocPrint(state.allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}

fn originForModuleSpan(evaluation: *EvalContext, span: ast.Span) ![]const u8 {
    return statementOrigin(evaluation, span);
}

fn resolveAnchorRef(
    state: *core.DocumentState,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    anchor_ref: AnchorRef,
    comptime is_target: bool,
) !if (is_target) ResolvedTarget else core.ConstraintSource {
    switch (anchor_ref.kind) {
        .page => {
            if (is_target) return error.PageCannotBeConstraintTarget;
            return .{ .page = anchor_ref.anchor };
        },
        .node => {
            var value = try resolveAnchorPathValue(state, env, current_origin, anchor_ref.node_path orelse anchor_ref.node_name.?);
            defer value.deinit(state.allocator);
            const node_id = try resolveValueObjectId(value);
            if (is_target) {
                return .{ .node_id = node_id, .anchor = anchor_ref.anchor };
            }
            return .{ .node = .{ .node_id = node_id, .anchor = anchor_ref.anchor } };
        },
    }
}

fn resolveAnchorPathValue(
    state: *core.DocumentState,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    path: []const u8,
) !core.Value {
    var iter = std.mem.splitScalar(u8, path, '.');
    const first = iter.next() orelse return error.UnknownIdentifier;
    const base = env.get(first) orelse {
        try reportUnknownIdentifier(state, first, current_origin);
        return error.UnknownIdentifier;
    };
    var current = try base.clone(state.allocator);
    while (iter.next()) |field_name| {
        if (current != .record) {
            current.deinit(state.allocator);
            return error.InvalidValueTag;
        }
        const field_value = current.record.field(field_name) orelse {
            current.deinit(state.allocator);
            try reportUnknownIdentifier(state, field_name, current_origin);
            return error.UnknownIdentifier;
        };
        const next = try field_value.clone(state.allocator);
        current.deinit(state.allocator);
        current = next;
    }
    return current;
}
