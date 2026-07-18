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
const registry = @import("../language/registry.zig");
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

const EvalMode = enum {
    attached,
};

const EvalContext = enum {
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

var diagnostic_path: []const u8 = "";
threadlocal var active_module_id: core.SourceModuleId = 0;
threadlocal var active_call_depth: u32 = 0;

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
    return lowerErrorMessage(err) orelse
        std.fmt.bufPrint(buf, "LoweringFailed: {s}", .{@errorName(err)}) catch "LoweringFailed: internal lowering error";
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
        error.ExpectedAnchor => "ExpectedAnchor: expected an anchor argument",
        error.ExpectedObject => "ExpectedObject: expected an object argument",
        error.NoCurrentPage => "NoCurrentPage: this operation is only valid inside a page block",
        error.UnknownAnchor => "UnknownAnchor: unknown anchor",
        error.UnknownRole => "UnknownRole: unknown role",
        error.UnknownPayloadKind => "UnknownPayloadKind: unknown payload kind",
        error.PageCannotBeConstraintTarget => "PageCannotBeConstraintTarget: page anchors cannot be constraint targets",
        error.UnsupportedDocumentEvaluationPrimitive => "UnsupportedDocumentEvaluationPrimitive: this operation is not valid during document evaluation",
        error.FunctionDidNotReturnValue => "FunctionDidNotReturnValue: function did not return a value",
        else => null,
    };
}

pub fn executeGraph(allocator: std.mem.Allocator, state: *core.DocumentState, graph: *const execution.ExecutionGraph) !void {
    var closures = ClosureStore.init(allocator);
    defer closures.deinit();
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
    for (graph.order) |unit_index| try executeUnit(state, &state.functions, &closures, &document_states, &page_states, graph.units.items[unit_index]);
    try materializeDisplayContent(state, &state.functions, &closures);
}

fn materializeDisplayContent(state: *core.DocumentState, functions: *const core.FunctionMap, closures: *ClosureStore) !void {
    var env = std.StringHashMap(core.Value).init(state.allocator);
    defer env.deinit();

    var index: usize = 0;
    while (index < state.nodes.items.len) : (index += 1) {
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
        const context: EvalContext = if (page_id == state.document_id) .document else .page;
        const origin = node.origin orelse "";
        const text = evalNodeReprWithFunction(state, page_id, context, .attached, &env, functions, closures, origin, node_id, function) catch |err| {
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
    state: *core.DocumentState,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    document_states: *std.AutoHashMap(core.SourceModuleId, DocumentExecutionState),
    page_states: *std.AutoHashMap(core.NodeId, PageExecutionState),
    unit: execution.ExecutionUnit,
) !void {
    const previous_module_id = active_module_id;
    const previous_call_depth = active_call_depth;
    active_module_id = unit.module_id;
    active_call_depth = 0;
    defer active_module_id = previous_module_id;
    defer active_call_depth = previous_call_depth;
    setLowerDiagnosticOrigin(unit.source, unit.path);
    switch (unit.kind) {
        .document_statement => |document_statement| {
            const entry = try document_states.getOrPut(unit.module_id);
            if (!entry.found_existing) entry.value_ptr.* = DocumentExecutionState.init(state.allocator);
            try executeDocumentStatement(state, functions, closures, entry.value_ptr, document_statement.stmt);
        },
        .page_statement => |page_statement| {
            const entry = try page_states.getOrPut(page_statement.page_id);
            if (!entry.found_existing) entry.value_ptr.* = PageExecutionState.init(state.allocator);
            try executePageStatement(state, functions, closures, entry.value_ptr, page_statement.page_id, page_statement.stmt);
        },
    }
}

fn executeDocumentStatement(
    state: *core.DocumentState,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    execution_state: *DocumentExecutionState,
    stmt: Statement,
) !void {
    const error_count = diagnosticErrorCount(state);
    const flow = executeStatement(state, state.document_id, .document, .attached, &execution_state.env, functions, closures, &execution_state.last_code_like, stmt, null) catch |err| {
        const origin = statementOrigin(state, stmt.span) catch null;
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
    state: *core.DocumentState,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    execution_state: *PageExecutionState,
    page_id: core.NodeId,
    stmt: Statement,
) !void {
    const error_count = diagnosticErrorCount(state);
    const flow = executeStatement(state, page_id, .page, .attached, &execution_state.env, functions, closures, &execution_state.last_code_like, stmt, null) catch |err| {
        const origin = statementOrigin(state, stmt.span) catch null;
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

fn setLowerDiagnosticOrigin(source: []const u8, path: []const u8) void {
    _ = source;
    diagnostic_path = path;
}

fn evalExpr(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    expr: Expr,
) anyerror!core.Value {
    return switch (expr) {
        .hole => error.HoleExpression,
        .ident => |ident| blk: {
            const name = ident.name;
            if (env.get(name)) |value| break :blk try value.clone(state.allocator);
            const sema = SemanticEnv.init(state, null, functions).forModule(active_module_id);
            if (sema.resolvedConst(ast.CallableName.bare(name))) |resolved| {
                break :blk try evalConstValue(state, page_id, context, mode, functions, closures, current_origin, resolved);
            }
            if (sema.resolvedFunction(ast.CallableName.bare(name))) |resolved| {
                const func = resolved.decl;
                break :blk .{ .function = try eval_functions.functionRefForInModule(state.allocator, resolved.module_id, func) };
            }
            try reportUnknownIdentifier(state, name, current_origin);
            break :blk error.UnknownIdentifier;
        },
        .string => |literal| blk: {
            try registerStringLiteralProvenance(state, literal);
            break :blk .{ .string = literal.text };
        },
        .color => |text| .{ .string = text },
        .number => |value| .{ .number = value },
        .boolean => |value| .{ .boolean = value },
        .none => .{ .none = {} },
        .enum_case => |case| .{ .enum_case = .{
            .enum_name = case.enum_name,
            .case_name = case.case_name,
        } },
        .call => |call| try evalCall(state, page_id, context, mode, env, functions, closures, current_origin, call),
        .apply => |apply| try evalApply(state, page_id, context, mode, env, functions, closures, current_origin, apply),
        .lambda => |lambda| try evalLambda(env, closures, lambda),
        .record => |record| try evalRecord(state, page_id, context, mode, env, functions, closures, current_origin, record),
        .record_update => |update| try evalRecordUpdate(state, page_id, context, mode, env, functions, closures, current_origin, update),
        .member => |member| try evalMember(state, page_id, context, mode, env, functions, closures, current_origin, member),
        .optional_check => |check| blk: {
            var value = try evalExpr(state, page_id, context, mode, env, functions, closures, current_origin, check.target.*);
            defer value.deinit(state.allocator);
            break :blk .{ .boolean = value_contracts.runtimeKind(value) != .none };
        },
        .coalesce => |coalesce| blk: {
            var value = try evalExpr(state, page_id, context, mode, env, functions, closures, current_origin, coalesce.target.*);
            if (value_contracts.runtimeKind(value) != .none) break :blk value;
            value.deinit(state.allocator);
            break :blk try evalExpr(state, page_id, context, mode, env, functions, closures, current_origin, coalesce.fallback.*);
        },
    };
}

fn registerStringLiteralProvenance(state: *core.DocumentState, literal: ast.StringLiteral) !void {
    const source_span = literal.source_span orelse return;
    const origin = try originForActiveModuleSpan(state, source_span);
    defer state.allocator.free(origin);
    const provenance = [_]core.ContentProvenance{.{
        .content_start = 0,
        .content_end = literal.text.len,
        .origin = origin,
    }};
    try state.setStringProvenance(literal.text, &provenance);
}

fn evalConstValue(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    resolved: semantic_env.ResolvedConst,
) anyerror!core.Value {
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

    const previous_module_id = active_module_id;
    active_module_id = resolved.module_id;
    defer active_module_id = previous_module_id;

    const start_node_count = state.nodeCount();
    var value = try evalExpr(state, page_id, context, mode, &local_env, functions, closures, current_origin, resolved.decl.value);
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
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    member: ast.MemberExpr,
) !core.Value {
    var target = try evalExpr(state, page_id, context, mode, env, functions, closures, current_origin, member.target.*);
    defer target.deinit(state.allocator);
    return evalMemberValue(state, mode, functions, target, member.name);
}

fn evalMemberValue(
    state: *core.DocumentState,
    mode: EvalMode,
    functions: *const core.FunctionMap,
    target: core.Value,
    name: []const u8,
) !core.Value {
    if (target == .record) {
        const value = target.record.field(name) orelse return .{ .none = {} };
        return try value.clone(state.allocator);
    }
    if (std.mem.eql(u8, name, "content")) {
        const object_id = try resolveValueObjectId(state, mode, target);
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
    mode: EvalMode,
    functions: *const core.FunctionMap,
    base: core.Value,
    path: []const ast.RecordPathSegment,
) !core.Value {
    var current = try base.clone(state.allocator);
    errdefer current.deinit(state.allocator);
    for (path) |segment| {
        const next = try evalMemberValue(state, mode, functions, current, segment.name);
        current.deinit(state.allocator);
        current = next;
    }
    return current;
}

fn evalRecord(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    record: ast.RecordExpr,
) !core.Value {
    const resolved = findRecordDecl(state, record.type_name) orelse {
        if (findEnumDecl(state, record.type_name) != null) {
            try reportInvalidRecordLiteral(state, current_origin, record.type_name);
            return error.InvalidType;
        }
        try reportNamedResolutionError(state, error.UnknownType, "record type", record.type_name, current_origin);
        return error.UnknownType;
    };
    const caller_module_id = active_module_id;
    defer active_module_id = caller_module_id;

    var value = core.RecordValue.init(resolved.decl.name);
    errdefer value.deinit(state.allocator);

    var default_env = std.StringHashMap(core.Value).init(state.allocator);
    defer deinitValueEnv(state.allocator, &default_env);
    active_module_id = resolved.module_id;
    for (resolved.decl.fields.items) |field| {
        const default_expr = field.default_value orelse continue;
        const field_value = try evalExpr(state, page_id, context, mode, &default_env, functions, closures, current_origin, default_expr.*);
        try putRecordFieldValue(state.allocator, &value, field.name, field_value, false);
    }

    active_module_id = caller_module_id;
    for (record.fields.items) |field| {
        const field_value = try evalExpr(state, page_id, context, mode, env, functions, closures, current_origin, field.value);
        try putRecordFieldValue(state.allocator, &value, field.name, field_value, true);
    }
    return .{ .record = value };
}

fn evalRecordDefaults(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    record_name: []const u8,
) !core.RecordValue {
    const resolved = findRecordDecl(state, record_name) orelse {
        try reportNamedResolutionError(state, error.UnknownType, "record type", record_name, current_origin);
        return error.UnknownType;
    };
    const caller_module_id = active_module_id;
    defer active_module_id = caller_module_id;

    var value = core.RecordValue.init(resolved.decl.name);
    errdefer value.deinit(state.allocator);

    var default_env = std.StringHashMap(core.Value).init(state.allocator);
    defer deinitValueEnv(state.allocator, &default_env);
    active_module_id = resolved.module_id;
    for (resolved.decl.fields.items) |field| {
        const default_expr = field.default_value orelse continue;
        const field_value = try evalExpr(state, page_id, context, mode, &default_env, functions, closures, current_origin, default_expr.*);
        try putRecordFieldValue(state.allocator, &value, field.name, field_value, false);
    }
    return value;
}

fn evalRecordUpdate(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    update: ast.RecordUpdateExpr,
) !core.Value {
    var target = try evalExpr(state, page_id, context, mode, env, functions, closures, current_origin, update.target.*);
    errdefer target.deinit(state.allocator);
    if (target != .record) {
        try reportRecordUpdateError(state, current_origin, "InvalidRecordUpdate: with expects a record value", .{});
        return error.InvalidValueTag;
    }

    for (update.fields.items) |field| {
        var field_value = try evalExpr(state, page_id, context, mode, env, functions, closures, current_origin, field.value);
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

const ResolvedRecordDecl = struct {
    decl: *const ast.RecordDecl,
    module_id: core.SourceModuleId,
};

fn findRecordDecl(state: *const core.DocumentState, type_name: []const u8) ?ResolvedRecordDecl {
    var index = state.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = state.moduleById(state.module_order.items[index]) orelse continue;
        for (module.syntax.records.items) |*decl| {
            if (std.mem.eql(u8, decl.name, type_name)) return .{
                .decl = decl,
                .module_id = module.id,
            };
        }
    }
    return null;
}

fn findEnumDecl(state: *const core.DocumentState, type_name: []const u8) ?*const ast.TypeDecl {
    var index = state.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = state.moduleById(state.module_order.items[index]) orelse continue;
        for (module.syntax.types.items) |*decl| {
            if (std.mem.eql(u8, decl.name, type_name)) return decl;
        }
    }
    return null;
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
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    origin: []const u8,
    node: *const core.Node,
    sema: *const SemanticEnv,
    key: []const u8,
    ty: ast.Type,
) !core.RecordValue {
    if (try core.fields.getWithEnv(state.allocator, node, key, sema)) |slot_value| {
        var slot = slot_value;
        defer slot.deinit(state.allocator);
        if (slot.value != .record) return error.InvalidValueTag;
        if (slot.owns_tagged_text) return try cloneTaggedRecordForRuntime(state, slot.value.record);
        return try slot.value.record.clone(state.allocator);
    }
    const record_name = ty.class_name orelse {
        try reportRecordUpdateError(state, origin, "InvalidRecordUpdatePath: record type has no name", .{});
        return error.InvalidType;
    };
    return evalRecordDefaults(state, page_id, context, mode, functions, closures, origin, record_name);
}

fn cloneTaggedRecordForRuntime(state: *core.DocumentState, record: core.RecordValue) anyerror!core.RecordValue {
    var cloned = core.RecordValue.init(try state.copyString(record.type_name));
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
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    if (!call.callee.isQualified()) {
        if (env.get(call.callee.name)) |value| {
            switch (value) {
                .function => |func_ref| {
                    if (!func_ref.returns_value) return error.FunctionDoesNotReturnValue;
                    try validateFixedArity(state, call.args.items.len, func_ref.param_count, current_origin);
                    var args = try evalCallArgs(state, page_id, context, mode, env, functions, closures, current_origin, call.args.items);
                    defer args.deinit(state.allocator);
                    defer deinitValues(state.allocator, args.items);
                    return try invokeFunctionRef(state, page_id, context, mode, env, functions, closures, func_ref, current_origin, args.items);
                },
                else => {},
            }
        }
    }
    const sema = SemanticEnv.init(state, null, functions).forModule(active_module_id);
    if (sema.resolvedConst(call.callee)) |resolved| {
        var const_value = try evalConstValue(state, page_id, context, mode, functions, closures, current_origin, resolved);
        defer const_value.deinit(state.allocator);
        const function = switch (const_value) {
            .function => |function| function,
            else => {
                try reportUnknownFunction(state, call.callee.name, current_origin);
                return error.UnknownFunction;
            },
        };
        var args = try evalCallArgs(state, page_id, context, mode, env, functions, closures, current_origin, call.args.items);
        defer args.deinit(state.allocator);
        defer deinitValues(state.allocator, args.items);
        return try invokeFunctionRef(state, page_id, context, mode, env, functions, closures, function, current_origin, args.items);
    }
    const descriptor = sema.callCallee(call.callee) orelse {
        try reportUnknownCallable(state, &sema, call.callee, current_origin);
        return error.UnknownFunction;
    };
    return switch (descriptor) {
        .function => |resolved| blk: {
            const func = resolved.decl;
            try eval_functions.requireReturnsValue(func);
            break :blk try invokeUserFunctionValueInModule(state, page_id, context, mode, env, functions, closures, resolved.module_id, func, current_origin, call);
        },
        .primitive => |primitive| try evalPrimitiveCall(state, page_id, context, mode, env, functions, closures, current_origin, call, primitive),
    };
}

fn evalLambda(
    env: *std.StringHashMap(core.Value),
    closures: *ClosureStore,
    lambda: ast.LambdaExpr,
) !core.Value {
    const id = try closures.add(lambda, env);
    return .{ .function = .{
        .name = "#lambda",
        .module_id = active_module_id,
        .closure_id = id,
        .param_count = lambda.params.items.len,
        .returns_value = true,
    } };
}

fn evalApply(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    apply: ast.ApplyExpr,
) anyerror!core.Value {
    var callee = try evalExpr(state, page_id, context, mode, env, functions, closures, current_origin, apply.callee.*);
    defer callee.deinit(state.allocator);
    const function = switch (callee) {
        .function => |function| function,
        else => return error.InvalidValueTag,
    };
    var args = try evalCallArgs(state, page_id, context, mode, env, functions, closures, current_origin, apply.args.items);
    defer args.deinit(state.allocator);
    defer deinitValues(state.allocator, args.items);
    return try invokeFunctionRef(state, page_id, context, mode, env, functions, closures, function, current_origin, args.items);
}

fn evalCallArgs(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    args: []const Expr,
) !std.ArrayList(core.Value) {
    var values = std.ArrayList(core.Value).empty;
    errdefer {
        deinitValues(state.allocator, values.items);
        values.deinit(state.allocator);
    }
    for (args) |arg| {
        try values.append(state.allocator, try evalExpr(state, page_id, context, mode, env, functions, closures, current_origin, arg));
    }
    return values;
}

fn evalNodeRepr(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    object_id: core.NodeId,
) ![]const u8 {
    const node = state.getNode(object_id) orelse return error.UnknownNode;
    const function = node.repr_function orelse return node.content orelse "";
    return evalNodeReprWithFunction(state, page_id, context, mode, env, functions, closures, current_origin, object_id, function);
}

fn evalNodeReprWithFunction(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    object_id: core.NodeId,
    function: core.FunctionRef,
) ![]const u8 {
    const args = [_]core.Value{.{ .object = object_id }};
    var result = try invokeFunctionRef(state, page_id, context, mode, env, functions, closures, function, current_origin, &args);
    defer result.deinit(state.allocator);
    return switch (result) {
        .string => |text| text,
        else => error.ExpectedStringArgument,
    };
}

const BuiltinContext = struct {
    state: *core.DocumentState,
    page_id: core.NodeId,
    eval_context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,

    pub fn checkArityRange(self: *const BuiltinContext, actual: usize, min: usize, max: usize) !void {
        try validateArityRange(self.state, actual, min, max, self.current_origin);
    }

    pub fn currentPageValue(self: *const BuiltinContext) !core.Value {
        if (self.eval_context != .page) return error.NoCurrentPage;
        return .{ .page = self.page_id };
    }

    pub fn currentDocumentValue(self: *const BuiltinContext) core.Value {
        return .{ .document = self.state.document_id };
    }

    pub fn runSelectCall(self: *BuiltinContext, call: CallExpr) anyerror!core.Value {
        return try evalSelectCall(self.state, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, call);
    }

    pub fn evalExprValue(self: *BuiltinContext, expr: Expr) anyerror!core.Value {
        return try evalExpr(self.state, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, expr);
    }

    pub fn evalStringArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror![]const u8 {
        return try evalCallStringArg(self.state, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, call, index);
    }

    pub fn evalPropertyStringArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror![]const u8 {
        return try resolveValuePropertyString(self.state.allocator, try self.evalExprValue(call.args.items[index]));
    }

    pub fn evalNumberArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!f32 {
        return try evalCallNumberArg(self.state, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, call, index);
    }

    pub fn evalObjectArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.NodeId {
        return try evalCallObjectArg(self.state, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, call, index);
    }

    pub fn evalAnchorArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.AnchorValue {
        return try evalCallAnchorArg(self.state, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, call, index);
    }

    pub fn evalRoleArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.Role {
        return try evalCallRoleArg(self.state, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, call, index);
    }

    pub fn evalPayloadArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!names.ParsedPayload {
        return try evalCallPayloadArg(self.state, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, call, index);
    }

    pub fn ownString(self: *BuiltinContext, text: []u8) ![]const u8 {
        return try self.state.ownString(text);
    }

    pub fn ownStringWithProvenance(self: *BuiltinContext, text: []u8, entries: []const core.ContentProvenance) ![]const u8 {
        return try self.state.ownStringWithProvenance(text, entries);
    }

    pub fn readlines(self: *BuiltinContext, requested: []const u8) ![]const u8 {
        const resolved = try resolveAssetPath(self.state.allocator, self.state.asset_base_dir, requested);
        defer self.state.allocator.free(resolved);

        const bytes = readTextFileAlloc(self.state.allocator, resolved) catch |err| {
            const message = try std.fmt.allocPrint(
                self.state.allocator,
                "ReadlinesFailed: could not read {s} (resolved to {s}): {s}",
                .{ requested, resolved, @errorName(err) },
            );
            defer self.state.allocator.free(message);
            try self.emitDiagnosticReport(.@"error", message);
            return try self.state.copyString("");
        };
        return try self.state.ownString(bytes);
    }

    pub fn materializeForUse(self: *BuiltinContext, value: core.Value) !core.Value {
        return try normalizeForUse(self.state, self.mode, value);
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

    pub fn setNodeFieldValue(self: *BuiltinContext, object_id: core.NodeId, key: []const u8, value: core.Value) !void {
        try self.state.replaceNodeFieldValue(object_id, key, value);
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
        return try invokeFunctionRef(self.state, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, function, self.current_origin, args);
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
        return try evalNodeRepr(self.state, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, object_id);
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
        return try anchorEqualityConstraintSet(self.state, target, source, offset, self.current_origin);
    }

    pub fn emitDiagnosticReport(self: *BuiltinContext, severity: core.DiagnosticSeverity, message: []const u8) !void {
        try emitUserReport(self.state, self.page_id, self.current_origin, severity, message);
    }

    pub fn checkAssetExists(self: *BuiltinContext, object_id: core.NodeId) !void {
        try validateAssetExists(self.state, self.page_id, object_id, self.current_origin);
    }
};

fn evalPrimitiveCall(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
    descriptor: registry.PrimitiveDescriptor,
) anyerror!core.Value {
    var ctx = BuiltinContext{
        .state = state,
        .page_id = page_id,
        .eval_context = context,
        .mode = mode,
        .env = env,
        .functions = functions,
        .closures = closures,
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
    const resolved = try resolveAssetPath(state.allocator, state.asset_base_dir, requested);
    if (!fs_utils.fileExists(state.allocator, resolved)) {
        try state.addValidationDiagnostic(.@"error", page_id, object_id, diagnostic_origin.text, .{
            .asset_not_found = .{
                .requested_path = try state.allocator.dupe(u8, requested),
                .resolved_path = resolved,
                .payload_kind = node.payload_kind,
            },
        });
        return;
    }

    if (node.payload_kind == .image_ref) {
        try attachIntrinsicImageSize(state, object_id, resolved);
    } else if (node.payload_kind == .pdf_ref) {
        try attachIntrinsicPdfSize(state, object_id, resolved);
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

fn attachIntrinsicImageSize(state: *core.DocumentState, object_id: core.NodeId, resolved_path: []const u8) !void {
    const dimensions = fs_utils.readImageDimensions(state.allocator, resolved_path) catch return;
    try attachIntrinsicAssetSize(state, object_id, dimensions);
}

fn attachIntrinsicPdfSize(state: *core.DocumentState, object_id: core.NodeId, resolved_path: []const u8) !void {
    const dimensions = fs_utils.readPdfDimensions(state.allocator, resolved_path) catch return;
    try attachIntrinsicAssetSize(state, object_id, dimensions);
}

fn attachIntrinsicAssetSize(state: *core.DocumentState, object_id: core.NodeId, dimensions: fs_utils.ImageDimensions) !void {
    try state.setNodeFieldValue(object_id, "asset_width", .{ .number = dimensions.width });
    try state.setNodeFieldValue(object_id, "asset_height", .{ .number = dimensions.height });
}

fn resolveAssetPath(allocator: std.mem.Allocator, base_dir: []const u8, requested: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(requested)) return allocator.dupe(u8, requested);
    return std.fs.path.join(allocator, &.{ base_dir, requested });
}

fn readTextFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const zpath = try allocator.dupeZ(u8, path);
    defer allocator.free(zpath);

    const fd = std.c.open(zpath.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const read_len = std.c.read(fd, &buf, buf.len);
        if (read_len < 0) return error.FileReadFailed;
        if (read_len == 0) break;
        const count: usize = @intCast(read_len);
        if (out.items.len + count > MAX_READLINES_BYTES) return error.FileTooLarge;
        try out.appendSlice(allocator, buf[0..count]);
    }

    return try out.toOwnedSlice(allocator);
}

fn evalSelectCall(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    const base = try normalizeForUse(state, mode, try evalExpr(state, page_id, context, mode, env, functions, closures, current_origin, call.args.items[0]));
    const op_name = try evalCallStringArg(state, page_id, context, mode, env, functions, closures, current_origin, call, 1);
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
            const role = try evalCallRoleArg(state, page_id, context, mode, env, functions, closures, current_origin, call, 2);
            return try state.select(state.allocator, base, core.Query.pageObjectsByRole(role));
        },
        .document_objects_by_role => {
            const role = try evalCallRoleArg(state, page_id, context, mode, env, functions, closures, current_origin, call, 2);
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
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    caller_env: *std.StringHashMap(core.Value),
    local_env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    module_id: core.SourceModuleId,
    func: FunctionDecl,
    current_origin: []const u8,
    call: CallExpr,
) !void {
    for (func.params.items, 0..) |param, index| {
        const value = if (index < call.args.items.len) blk: {
            break :blk try evalExpr(state, page_id, context, mode, caller_env, functions, closures, current_origin, call.args.items[index]);
        } else blk: {
            const previous_module_id = active_module_id;
            active_module_id = module_id;
            defer active_module_id = previous_module_id;
            break :blk try evalExpr(state, page_id, context, mode, local_env, functions, closures, current_origin, (param.default_value orelse return error.InvalidArity).*);
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
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    caller_env: *std.StringHashMap(core.Value),
    local_env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    module_id: core.SourceModuleId,
    func: FunctionDecl,
    current_origin: []const u8,
    args: []const core.Value,
) !void {
    try validateUserFunctionArity(state, args.len, func, current_origin);
    for (func.params.items, 0..) |param, index| {
        const value = if (index < args.len) blk: {
            break :blk try args[index].clone(state.allocator);
        } else blk: {
            const previous_module_id = active_module_id;
            active_module_id = module_id;
            defer active_module_id = previous_module_id;
            break :blk try evalExpr(state, page_id, context, mode, local_env, functions, closures, current_origin, (param.default_value orelse return error.InvalidArity).*);
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

fn normalizeForUse(state: *core.DocumentState, mode: EvalMode, value: core.Value) !core.Value {
    _ = state;
    _ = mode;
    return value;
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

fn resolveValueObjectId(state: *core.DocumentState, mode: EvalMode, value: core.Value) !core.NodeId {
    return switch (try normalizeForUse(state, mode, value)) {
        .object => |id| id,
        else => return error.ExpectedObject,
    };
}

fn evalCallArg(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.Value {
    return try evalExpr(state, page_id, context, mode, env, functions, closures, current_origin, call.args.items[index]);
}

fn evalCallStringArg(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror![]const u8 {
    return try resolveValueString(try evalCallArg(state, page_id, context, mode, env, functions, closures, current_origin, call, index));
}

fn evalCallNumberArg(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!f32 {
    return try resolveValueNumber(try evalCallArg(state, page_id, context, mode, env, functions, closures, current_origin, call, index));
}

fn evalCallObjectArg(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.NodeId {
    return try resolveValueObjectId(state, mode, try evalCallArg(state, page_id, context, mode, env, functions, closures, current_origin, call, index));
}

fn evalCallAnchorArg(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.AnchorValue {
    return try resolveValueAnchor(try evalCallArg(state, page_id, context, mode, env, functions, closures, current_origin, call, index));
}

fn evalCallRoleArg(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.Role {
    const role_name = try evalCallStringArg(state, page_id, context, mode, env, functions, closures, current_origin, call, index);
    return names.parseRoleName(role_name) orelse {
        try reportNamedResolutionError(state, error.UnknownRole, "role", role_name, current_origin);
        return error.UnknownRole;
    };
}

fn evalCallPayloadArg(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!names.ParsedPayload {
    const payload_name = try evalCallStringArg(state, page_id, context, mode, env, functions, closures, current_origin, call, index);
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
    state: *core.DocumentState,
    target: core.AnchorValue,
    source: core.AnchorValue,
    offset: f32,
    origin: []const u8,
) !core.ConstraintSet {
    return switch (target) {
        .page => error.PageCannotBeConstraintTarget,
        .node => |node| try singleConstraintSet(state, .{
            .target_node = node.node_id,
            .target_anchor = node.anchor,
            .source = source.toConstraintSource(),
            .offset = offset,
            .origin = origin,
            .role = core.constraintRoleForRelation(node.node_id, node.anchor, source.toConstraintSource()),
            .scope_depth = active_call_depth,
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
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    origin: []const u8,
    base: core.Value,
    path: []const ast.RecordPathSegment,
    value: core.Value,
) !void {
    if (path.len == 0) return;
    var current = try base.clone(state.allocator);
    defer current.deinit(state.allocator);

    var path_index: usize = 0;
    while (!isPropertyTargetValue(current)) {
        if (path_index >= path.len) return error.ExpectedObject;
        const next = try evalMemberValue(state, mode, functions, current, path[path_index].name);
        current.deinit(state.allocator);
        current = next;
        path_index += 1;
    }

    try writePropertyPathToTarget(state, page_id, context, mode, functions, closures, origin, current, path[path_index..], value);
}

fn writePropertyPathToTarget(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    origin: []const u8,
    target: core.Value,
    path: []const ast.RecordPathSegment,
    value: core.Value,
) !void {
    if (path.len == 0) return error.ExpectedObject;
    switch (target) {
        .document => |id| try writePropertyPathToNode(state, page_id, context, mode, functions, closures, origin, id, path, value),
        .page => |id| try writePropertyPathToNode(state, page_id, context, mode, functions, closures, origin, id, path, value),
        .object => |id| try writePropertyPathToNode(state, page_id, context, mode, functions, closures, origin, id, path, value),
        .selection => |selection| {
            if (selection.item_tag != .object) return error.InvalidSelectionItemType;
            for (selection.ids.items) |id| {
                try writePropertyPathToNode(state, page_id, context, mode, functions, closures, origin, id, path, value);
            }
        },
        else => return error.ExpectedObject,
    }
}

fn writePropertyPathToNode(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    origin: []const u8,
    node_id: core.NodeId,
    path: []const ast.RecordPathSegment,
    value: core.Value,
) !void {
    if (path.len == 0) return error.ExpectedObject;
    const property_name = path[0].name;
    if (path.len == 1) {
        try writeNodeFieldValue(state, node_id, property_name, value, origin, false);
        return;
    }

    const node = state.getNode(node_id) orelse return error.UnknownNode;
    const sema = SemanticEnv.init(state, null, functions).forModule(active_module_id);
    const maybe_field = if (core.fields.classNameWithEnv(node, &sema)) |class_name|
        sema.field(class_name, property_name)
    else
        sema.fieldByName(property_name);
    const field = maybe_field orelse return error.InvalidType;
    if (field.value_type.kind != .record) return error.InvalidValueTag;
    var record = try materializePropertyRecord(state, page_id, context, mode, functions, closures, origin, node, &sema, property_name, field.value_type);
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
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    last_code_like: *?core.NodeId,
    stmt: Statement,
    origin_override: ?[]const u8,
) anyerror!ExecFlow {
    const origin = if (origin_override) |override| override else try statementOrigin(state, stmt.span);
    switch (stmt.kind) {
        .hole => return error.HoleStatement,
        .let_binding => |binding| {
            const value = try evalExpr(state, page_id, context, mode, env, functions, closures, origin, binding.expr);
            if (names.isDiscardBindingName(binding.name)) {
                defer {
                    var owned = value;
                    owned.deinit(state.allocator);
                }
                try discardStatementValue(state, value);
                return .none;
            }
            if (context == .page and active_call_depth == 0) {
                try addValueObjectSources(state, page_id, active_module_id, binding.name, null, stmt.span, value);
            }
            try putEnvValue(state.allocator, env, binding.name, value);
        },
        .return_expr => |expr| {
            const value = try evalExpr(state, page_id, context, mode, env, functions, closures, origin, expr);
            return .{ .returned = value };
        },
        .return_void => return .{ .returned = .{ .void = {} } },
        .property_set => |property_set| {
            if (property_set.path.items.len == 0) return .none;
            var base = try evalExpr(state, page_id, context, mode, env, functions, closures, origin, property_set.target);
            defer base.deinit(state.allocator);
            var value = try evalExpr(state, page_id, context, mode, env, functions, closures, origin, property_set.value);
            defer value.deinit(state.allocator);
            try writePropertyPath(state, page_id, context, mode, functions, closures, origin, base, property_set.path.items, value);
        },
        .if_stmt => |if_stmt| {
            const value = try evalExpr(state, page_id, context, mode, env, functions, closures, origin, if_stmt.condition);
            const condition = try resolveValueBoolean(value);
            const branch = if (condition) if_stmt.then_statements.items else if_stmt.else_statements.items;
            var branch_env = try cloneValueEnv(state.allocator, env);
            defer deinitValueEnv(state.allocator, &branch_env);
            for (branch) |nested| {
                const flow = try executeStatement(state, page_id, context, mode, &branch_env, functions, closures, last_code_like, nested, null);
                switch (flow) {
                    .none => {},
                    .returned => return flow,
                }
            }
        },
        .constrain => |decl| {
            const target = try resolveAnchorRef(state, mode, env, origin, decl.target, true);
            const resolved_source: ?core.ConstraintSource = if (decl.source) |source_ref|
                try resolveAnchorRef(state, mode, env, origin, source_ref, false)
            else
                null;
            const offset: f32 = if (decl.offset) |expr| blk: {
                const value = try evalExpr(state, page_id, context, mode, env, functions, closures, origin, expr);
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
                    active_call_depth,
                ),
                .update => try state.addConstraintUpdate(
                    target.node_id,
                    target.anchor,
                    role,
                    active_call_depth,
                    resolved_source,
                    offset,
                    origin,
                ),
            }
        },
        .expr_stmt => |expr| {
            var value = switch (expr) {
                .call => |call| blk: {
                    const sema = SemanticEnv.init(state, null, functions).forModule(active_module_id);
                    if (sema.resolvedFunction(call.callee) != null) {
                        break :blk try executeCallStatement(state, page_id, context, mode, env, functions, closures, last_code_like, origin, call);
                    }
                    break :blk try evalExpr(state, page_id, context, mode, env, functions, closures, origin, expr);
                },
                else => try evalExpr(state, page_id, context, mode, env, functions, closures, origin, expr),
            };
            defer value.deinit(state.allocator);
            try materializeStatementValue(state, mode, last_code_like, value);
            if (context == .page and active_call_depth == 0) {
                const binding_base = switch (expr) {
                    .call => |call| call.callee.name,
                    else => "",
                };
                try addValueObjectSources(state, page_id, active_module_id, "", binding_base, stmt.span, value);
            }
        },
    }
    return .none;
}

fn materializeStatementValue(state: *core.DocumentState, mode: EvalMode, last_code_like: *?core.NodeId, value: core.Value) !void {
    _ = mode;
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
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    last_code_like: *?core.NodeId,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    const sema = SemanticEnv.init(state, null, functions).forModule(active_module_id);
    const resolved = sema.resolvedFunction(call.callee) orelse {
        return try evalCall(state, page_id, context, mode, env, functions, closures, current_origin, call);
    };
    const func = resolved.decl;
    try validateUserFunctionArity(state, call.args.items.len, func, current_origin);

    const previous_call_depth = active_call_depth;
    active_call_depth += 1;
    defer active_call_depth = previous_call_depth;

    var local_env = try cloneValueEnv(state.allocator, env);
    defer deinitValueEnv(state.allocator, &local_env);
    try bindUserFunctionArgs(state, page_id, context, mode, env, &local_env, functions, closures, resolved.module_id, func, current_origin, call);
    const start_node_count = state.nodeCount();
    const previous_module_id = active_module_id;
    active_module_id = resolved.module_id;
    defer active_module_id = previous_module_id;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(state, page_id, context, mode, &local_env, functions, closures, last_code_like, inner, null);
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
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    function: core.FunctionRef,
    current_origin: []const u8,
    args: []const core.Value,
) anyerror!core.Value {
    if (function.closure_id) |closure_id| {
        return try invokeClosureValues(state, page_id, context, mode, env, functions, closures, closure_id, current_origin, args);
    }
    const sema = SemanticEnv.init(state, null, functions).forModule(function.module_id);
    const resolved = sema.resolvedFunction(ast.CallableName.bare(function.name)) orelse {
        try reportUnknownFunction(state, function.name, current_origin);
        return error.UnknownFunction;
    };
    return try invokeUserFunctionValues(state, page_id, context, mode, env, functions, closures, resolved.module_id, resolved.decl, current_origin, args);
}

fn invokeClosureValues(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    caller_env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    closure_id: usize,
    current_origin: []const u8,
    args: []const core.Value,
) anyerror!core.Value {
    _ = caller_env;
    const closure = closures.get(closure_id) orelse {
        try reportUnknownFunction(state, "#lambda", current_origin);
        return error.UnknownFunction;
    };
    try validateFixedArity(state, args.len, closure.lambda.params.items.len, current_origin);

    const previous_call_depth = active_call_depth;
    active_call_depth += 1;
    defer active_call_depth = previous_call_depth;

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
    const value = try evalExpr(state, page_id, context, mode, &local_env, functions, closures, current_origin, closure.lambda.body.*);
    try connectReturnedObject(state, value, start_node_count, current_origin);
    return value;
}

fn invokeUserFunctionValue(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    func: FunctionDecl,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    return invokeUserFunctionValueInModule(state, page_id, context, mode, env, functions, closures, active_module_id, func, current_origin, call);
}

fn invokeUserFunctionValueInModule(
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    module_id: core.SourceModuleId,
    func: FunctionDecl,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    var func_ref = try eval_functions.functionRefForInModule(state.allocator, module_id, func);
    defer func_ref.deinit(state.allocator);
    if (!func_ref.returns_value) return error.FunctionDoesNotReturnValue;
    try validateUserFunctionArity(state, call.args.items.len, func, current_origin);

    const previous_call_depth = active_call_depth;
    active_call_depth += 1;
    defer active_call_depth = previous_call_depth;

    var local_env = try cloneValueEnv(state.allocator, env);
    defer deinitValueEnv(state.allocator, &local_env);
    try bindUserFunctionArgs(state, page_id, context, mode, env, &local_env, functions, closures, module_id, func, current_origin, call);

    var last_code_like: ?core.NodeId = null;
    const start_node_count = state.nodeCount();
    const previous_module_id = active_module_id;
    active_module_id = module_id;
    defer active_module_id = previous_module_id;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(state, page_id, context, mode, &local_env, functions, closures, &last_code_like, inner, null);
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
    state: *core.DocumentState,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    module_id: core.SourceModuleId,
    func: FunctionDecl,
    current_origin: []const u8,
    args: []const core.Value,
) anyerror!core.Value {
    const previous_call_depth = active_call_depth;
    active_call_depth += 1;
    defer active_call_depth = previous_call_depth;

    var local_env = try cloneValueEnv(state.allocator, env);
    defer deinitValueEnv(state.allocator, &local_env);
    try bindUserFunctionValueArgs(state, page_id, context, mode, env, &local_env, functions, closures, module_id, func, current_origin, args);

    var last_code_like: ?core.NodeId = null;
    const start_node_count = state.nodeCount();
    const previous_module_id = active_module_id;
    active_module_id = module_id;
    defer active_module_id = previous_module_id;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(state, page_id, context, mode, &local_env, functions, closures, &last_code_like, inner, null);
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

fn statementOrigin(state: *core.DocumentState, span: ast.Span) ![]const u8 {
    if (state.modulePath(active_module_id)) |path| {
        return std.fmt.allocPrint(state.allocator, "path:{s}:bytes:{d}-{d}", .{ path, span.start, span.end });
    }
    if (diagnostic_path.len != 0) {
        return std.fmt.allocPrint(state.allocator, "path:{s}:bytes:{d}-{d}", .{ diagnostic_path, span.start, span.end });
    }
    return std.fmt.allocPrint(state.allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}

fn originForActiveModuleSpan(state: *core.DocumentState, span: ast.Span) ![]const u8 {
    return statementOrigin(state, span);
}

fn resolveAnchorRef(
    state: *core.DocumentState,
    mode: EvalMode,
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
            const node_id = try resolveValueObjectId(state, mode, value);
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
