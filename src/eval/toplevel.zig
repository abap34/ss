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
const schedule = @import("../analysis/schedule.zig");
const value_contracts = @import("value_contracts.zig");
const analysis = @import("../analysis.zig");

const Program = ast.Program;
const FunctionDecl = ast.FunctionDecl;
const PageDecl = ast.PageDecl;
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

fn reportUnknownFunction(ir: *core.Ir, name: []const u8, origin: []const u8) !void {
    try reportNamedResolutionError(ir, error.UnknownFunction, "function", name, origin);
}

fn reportUnknownCallable(ir: *core.Ir, sema: *const SemanticEnv, callee: ast.CallableName, origin: []const u8) !void {
    switch (sema.resolveFunction(callee)) {
        .unknown_alias => |alias| try reportNamedResolutionError(ir, error.UnknownFunction, "import alias", alias, origin),
        else => {
            const name = try callee.displayAlloc(ir.allocator);
            defer ir.allocator.free(name);
            try reportUnknownFunction(ir, name, origin);
        },
    }
}

fn reportUnknownQuery(ir: *core.Ir, name: []const u8, origin: []const u8) !void {
    try reportNamedResolutionError(ir, error.UnknownQuery, "query", name, origin);
}

fn reportUnknownIdentifier(ir: *core.Ir, name: []const u8, origin: []const u8) !void {
    try reportNamedResolutionError(ir, error.UnknownIdentifier, "identifier", name, origin);
}

fn reportNamedResolutionError(ir: *core.Ir, err: anyerror, kind: []const u8, name: []const u8, origin: []const u8) !void {
    try reportLowerDiagnostic(ir, .{
        .err = err,
        .origin = origin,
        .data = .{ .unknown_name = .{ .kind = kind, .name = name } },
    });
}

fn reportLowerError(ir: *core.Ir, err: anyerror, origin: []const u8) !void {
    try reportLowerDiagnostic(ir, .{
        .err = err,
        .origin = origin,
        .data = .generic,
    });
}

fn reportDuplicatePropertyDefinition(ir: *core.Ir, origin: []const u8, key: []const u8) !void {
    try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{
            .message = try std.fmt.allocPrint(ir.allocator, "DuplicatePropertyDefinition: property '{s}' is already defined on this target", .{key}),
        },
    });
}

fn reportDuplicateContentDefinition(ir: *core.Ir, origin: []const u8) !void {
    try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = try ir.allocator.dupe(u8, "DuplicateContentDefinition: object content is already defined") },
    });
}

fn reportDuplicateReprDefinition(ir: *core.Ir, origin: []const u8) !void {
    try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = try ir.allocator.dupe(u8, "DuplicateReprDefinition: object repr is already defined") },
    });
}

fn reportLowerDiagnostic(ir: *core.Ir, diagnostic: LowerDiagnostic) !void {
    var message_buf: [256]u8 = undefined;
    const message = formatLowerDiagnostic(&message_buf, diagnostic);
    try ir.addValidationDiagnostic(.@"error", null, null, diagnostic.origin, .{
        .user_report = .{ .message = try ir.allocator.dupe(u8, message) },
    });
}

fn formatLowerDiagnostic(buf: []u8, diagnostic: LowerDiagnostic) []const u8 {
    return switch (diagnostic.data) {
        .unknown_name => |data| std.fmt.bufPrint(buf, "{s}: unknown {s}: {s}", .{ unknownNameCode(data.kind), data.kind, data.name }) catch "UnknownName: unknown name",
        .invalid_arity => |data| blk: {
            if (data.min == data.max) {
                break :blk std.fmt.bufPrint(buf, "InvalidArity: expected {d}, got {d}", .{ data.min, data.actual }) catch lowerErrorMessage(diagnostic.err);
            }
            break :blk std.fmt.bufPrint(buf, "InvalidArity: expected {d}..{d}, got {d}", .{ data.min, data.max, data.actual }) catch lowerErrorMessage(diagnostic.err);
        },
        .invalid_value_tag => |data| std.fmt.bufPrint(buf, "InvalidValueTag: expected {s}, got {s}", .{ @tagName(data.expected), @tagName(data.actual) }) catch lowerErrorMessage(diagnostic.err),
        .generic => lowerErrorMessage(diagnostic.err),
    };
}

fn unknownNameCode(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "function")) return "UnknownFunction";
    if (std.mem.eql(u8, kind, "query")) return "UnknownQuery";
    if (std.mem.eql(u8, kind, "identifier")) return "UnknownIdentifier";
    if (std.mem.eql(u8, kind, "anchor")) return "UnknownAnchor";
    if (std.mem.eql(u8, kind, "role")) return "UnknownRole";
    return "UnknownName";
}

fn lowerErrorMessage(err: anyerror) []const u8 {
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
        error.ScheduledDependencyCycle => "ScheduledDependencyCycle: document evaluation dependencies contain a cycle",
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
        error.UnsupportedScheduledPrimitive => "UnsupportedScheduledPrimitive: this operation is not valid during document evaluation",
        error.FunctionDidNotReturnValue => "FunctionDidNotReturnValue: function did not return a value",
        else => @errorName(err),
    };
}

pub fn evalIr(allocator: std.mem.Allocator, ir: *core.Ir) !void {
    var graph = try schedule.ScheduleGraph.build(allocator, ir, ir, .{ .page_id_mode = .create });
    defer graph.deinit();
    try evalIrWithSchedule(allocator, ir, &graph);
}

pub fn evalIrWithSchedule(allocator: std.mem.Allocator, ir: *core.Ir, graph: *const schedule.ScheduleGraph) !void {
    var closures = ClosureStore.init(allocator);
    defer closures.deinit();
    var document_states = std.AutoHashMap(core.SourceModuleId, DocumentExecutionState).init(allocator);
    defer {
        var iter = document_states.valueIterator();
        while (iter.next()) |state| state.deinit(allocator);
        document_states.deinit();
    }
    var page_states = std.AutoHashMap(core.NodeId, PageExecutionState).init(allocator);
    defer {
        var iter = page_states.valueIterator();
        while (iter.next()) |state| state.deinit(allocator);
        page_states.deinit();
    }
    for (graph.order) |unit_index| try executeScheduledUnit(ir, &ir.functions, &closures, &document_states, &page_states, graph.units.items[unit_index]);
    try materializeDisplayContent(ir, &ir.functions, &closures);
}

fn materializeDisplayContent(ir: *core.Ir, functions: *const core.FunctionMap, closures: *ClosureStore) !void {
    var env = std.StringHashMap(core.Value).init(ir.allocator);
    defer env.deinit();

    var index: usize = 0;
    while (index < ir.nodes.items.len) : (index += 1) {
        const node_id = ir.nodes.items[index].id;
        const node = ir.getNode(node_id) orelse continue;
        if (node.kind != .object) continue;
        const function = if (node.repr_function) |repr_function|
            try repr_function.clone(ir.allocator)
        else
            continue;
        var owned_function = function;
        defer owned_function.deinit(ir.allocator);

        const page_id = ir.parentPageOf(node_id) orelse ir.document_id;
        const context: EvalContext = if (page_id == ir.document_id) .document else .page;
        const origin = node.origin orelse "";
        const text = evalNodeReprWithFunction(ir, page_id, context, .attached, &env, functions, closures, origin, node_id, function) catch |err| {
            try reportLowerError(ir, err, origin);
            return err;
        };
        try ir.setNodeDisplayContent(node_id, text);
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

fn executeScheduledUnit(
    ir: *core.Ir,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    document_states: *std.AutoHashMap(core.SourceModuleId, DocumentExecutionState),
    page_states: *std.AutoHashMap(core.NodeId, PageExecutionState),
    unit: schedule.ScheduledUnit,
) !void {
    const previous_module_id = active_module_id;
    active_module_id = unit.module_id;
    defer active_module_id = previous_module_id;
    setLowerDiagnosticOrigin(unit.source, unit.path);
    switch (unit.kind) {
        .document_statement => |document_statement| {
            const entry = try document_states.getOrPut(unit.module_id);
            if (!entry.found_existing) entry.value_ptr.* = DocumentExecutionState.init(ir.allocator);
            try executeScheduledDocumentStatement(ir, functions, closures, entry.value_ptr, document_statement.stmt);
        },
        .page_statement => |page_statement| {
            const entry = try page_states.getOrPut(page_statement.page_id);
            if (!entry.found_existing) entry.value_ptr.* = PageExecutionState.init(ir.allocator);
            try executeScheduledPageStatement(ir, functions, closures, entry.value_ptr, page_statement.page_id, page_statement.stmt);
        },
    }
}

fn executeScheduledDocumentStatement(
    ir: *core.Ir,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    state: *DocumentExecutionState,
    stmt: Statement,
) !void {
    const error_count = diagnosticErrorCount(ir);
    const flow = executeStatement(ir, ir.document_id, .document, .attached, &state.env, functions, closures, &state.last_code_like, stmt, null) catch |err| {
        var owns_origin = true;
        const origin = statementOrigin(ir.allocator, stmt.span) catch blk: {
            owns_origin = false;
            break :blk "bytes:0-1";
        };
        defer if (owns_origin) ir.allocator.free(origin);
        if (diagnosticErrorCount(ir) == error_count) try reportLowerError(ir, err, origin);
        return err;
    };
    switch (flow) {
        .none => {},
        .returned => |value| {
            var owned = value;
            owned.deinit(ir.allocator);
            return error.ReturnOutsideFunction;
        },
    }
}

fn executeScheduledPageStatement(
    ir: *core.Ir,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    state: *PageExecutionState,
    page_id: core.NodeId,
    stmt: Statement,
) !void {
    const error_count = diagnosticErrorCount(ir);
    const flow = executeStatement(ir, page_id, .page, .attached, &state.env, functions, closures, &state.last_code_like, stmt, null) catch |err| {
        var owns_origin = true;
        const origin = statementOrigin(ir.allocator, stmt.span) catch blk: {
            owns_origin = false;
            break :blk "bytes:0-1";
        };
        defer if (owns_origin) ir.allocator.free(origin);
        if (diagnosticErrorCount(ir) == error_count) try reportLowerError(ir, err, origin);
        return err;
    };
    switch (flow) {
        .none => {},
        .returned => |value| {
            var owned = value;
            owned.deinit(ir.allocator);
            return error.ReturnOutsideFunction;
        },
    }
}

fn diagnosticErrorCount(ir: *const core.Ir) usize {
    var count: usize = 0;
    for (ir.diagnostics.items) |diagnostic| {
        if (diagnostic.severity == .@"error") count += 1;
    }
    return count;
}

fn executeModuleProgramInSourceOrder(
    core_ir: *const core.Ir,
    module: *const core.SourceModule,
    ir: *core.Ir,
    functions: *const core.FunctionMap,
    executed_modules: *std.AutoHashMap(core.SourceModuleId, void),
) !void {
    var closures = ClosureStore.init(ir.allocator);
    defer closures.deinit();
    try executeModuleProgramInSourceOrderWithClosures(core_ir, module, ir, functions, executed_modules, &closures);
}

fn executeModuleProgramInSourceOrderWithClosures(
    core_ir: *const core.Ir,
    module: *const core.SourceModule,
    ir: *core.Ir,
    functions: *const core.FunctionMap,
    executed_modules: *std.AutoHashMap(core.SourceModuleId, void),
    closures: *ClosureStore,
) !void {
    const previous_module_id = active_module_id;
    active_module_id = module.id;
    defer active_module_id = previous_module_id;

    if (module.kind == .library) {
        if (executed_modules.contains(module.id)) return;
        try executed_modules.put(module.id, {});
    }

    var document_state = DocumentExecutionState.init(ir.allocator);
    defer document_state.deinit(ir.allocator);

    if (module.program.top_level_items.items.len == 0) {
        setLowerDiagnosticOrigin(module.source, module.path orelse module.spec);
        try executeDocumentStatementsWithState(module.program, ir, functions, closures, &document_state);
        for (module.program.pages.items) |page| {
            setLowerDiagnosticOrigin(module.source, module.path orelse module.spec);
            try executePage(page, ir, functions, closures);
        }
        return;
    }

    for (module.program.top_level_items.items) |item| {
        switch (item) {
            .import => |import_index| {
                if (import_index >= module.resolved_import_ids.items.len) continue;
                const import_id = module.resolved_import_ids.items[import_index];
                const imported = core_ir.moduleById(import_id) orelse continue;
                try executeModuleProgramInSourceOrderWithClosures(core_ir, imported, ir, functions, executed_modules, closures);
            },
            .document => |document_index| {
                if (document_index >= module.program.document_blocks.items.len) continue;
                setLowerDiagnosticOrigin(module.source, module.path orelse module.spec);
                try executeDocumentBlockWithState(module.program, module.program.document_blocks.items[document_index], ir, functions, closures, &document_state);
            },
            .page => |page_index| {
                if (page_index >= module.program.pages.items.len) continue;
                setLowerDiagnosticOrigin(module.source, module.path orelse module.spec);
                try executePage(module.program.pages.items[page_index], ir, functions, closures);
            },
        }
    }
}

pub fn executeProgramWithLegacyIndex(program: Program, source: []const u8, ir: *core.Ir, io: std.Io) !void {
    return executeProgramWithPath(program, source, "", ir, io);
}

pub fn executeProgramWithPath(program: Program, source: []const u8, path: []const u8, ir: *core.Ir, io: std.Io) !void {
    var index = try analysis.loadProgramIndex(ir.allocator, io, ir.asset_base_dir, program);
    defer index.deinit();
    return executeProgramWithIndex(program, source, path, ir, &index);
}

pub fn executeProgramWithIndex(
    program: Program,
    source: []const u8,
    path: []const u8,
    ir: *core.Ir,
    index: *const analysis.ProgramIndex,
) !void {
    return executeProgram(program, source, path, ir, &index.functions);
}

pub fn executeProgram(
    program: Program,
    source: []const u8,
    path: []const u8,
    ir: *core.Ir,
    functions: *const core.FunctionMap,
) !void {
    setLowerDiagnosticOrigin(source, path);

    var closures = ClosureStore.init(ir.allocator);
    defer closures.deinit();
    try executeDocumentStatements(program, ir, functions, &closures);
    for (program.pages.items) |page| try executePage(page, ir, functions, &closures);
}

fn setLowerDiagnosticOrigin(source: []const u8, path: []const u8) void {
    _ = source;
    diagnostic_path = path;
}

fn executeDocumentStatements(
    program: Program,
    ir: *core.Ir,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
) !void {
    try executeDocumentStatementSlice(ir, functions, closures, program.document_statements.items);
}

fn executeDocumentStatementsWithState(
    program: Program,
    ir: *core.Ir,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    state: *DocumentExecutionState,
) !void {
    try executeDocumentStatementSliceWithState(ir, functions, closures, state, program.document_statements.items);
}

fn executeDocumentBlockWithState(
    program: Program,
    block: ast.DocumentBlockDecl,
    ir: *core.Ir,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    state: *DocumentExecutionState,
) !void {
    const statement_end = @min(block.statement_start + block.statement_count, program.document_statements.items.len);
    try executeDocumentStatementSliceWithState(ir, functions, closures, state, program.document_statements.items[block.statement_start..statement_end]);
}

fn executeDocumentStatementSliceWithState(
    ir: *core.Ir,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    state: *DocumentExecutionState,
    statements: []const Statement,
) !void {
    for (statements) |stmt| try executeScheduledDocumentStatement(ir, functions, closures, state, stmt);
}

fn executeDocumentStatementSlice(
    ir: *core.Ir,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    statements: []const Statement,
) !void {
    var document_env = std.StringHashMap(core.Value).init(ir.allocator);
    defer deinitValueEnv(ir.allocator, &document_env);
    var document_last_code_like: ?core.NodeId = null;
    for (statements) |stmt| {
        const error_count = diagnosticErrorCount(ir);
        const flow = executeStatement(ir, ir.document_id, .document, .attached, &document_env, functions, closures, &document_last_code_like, stmt, null) catch |err| {
            var owns_origin = true;
            const origin = statementOrigin(ir.allocator, stmt.span) catch blk: {
                owns_origin = false;
                break :blk "bytes:0-1";
            };
            defer if (owns_origin) ir.allocator.free(origin);
            if (diagnosticErrorCount(ir) == error_count) try reportLowerError(ir, err, origin);
            return err;
        };
        switch (flow) {
            .none => {},
            .returned => |value| {
                var owned = value;
                owned.deinit(ir.allocator);
                return error.ReturnOutsideFunction;
            },
        }
    }
}

fn executePage(
    page: PageDecl,
    ir: *core.Ir,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
) !void {
    const page_id = try ir.addPage(page.name);
    try executePageBody(page, page_id, ir, functions, closures);
}

fn executePageBody(
    page: PageDecl,
    page_id: core.NodeId,
    ir: *core.Ir,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
) !void {
    var last_code_like: ?core.NodeId = null;
    var env = std.StringHashMap(core.Value).init(ir.allocator);
    defer deinitValueEnv(ir.allocator, &env);

    for (page.statements.items) |stmt| {
        const error_count = diagnosticErrorCount(ir);
        const flow = executeStatement(ir, page_id, .page, .attached, &env, functions, closures, &last_code_like, stmt, null) catch |err| {
            var owns_origin = true;
            const origin = statementOrigin(ir.allocator, stmt.span) catch blk: {
                owns_origin = false;
                break :blk "bytes:0-1";
            };
            defer if (owns_origin) ir.allocator.free(origin);
            if (diagnosticErrorCount(ir) == error_count) try reportLowerError(ir, err, origin);
            return err;
        };
        switch (flow) {
            .none => {},
            .returned => |value| {
                var owned = value;
                owned.deinit(ir.allocator);
                return error.ReturnOutsideFunction;
            },
        }
    }
}

fn evalExpr(
    ir: *core.Ir,
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
        .ident => |name| blk: {
            if (env.get(name)) |value| break :blk try value.clone(ir.allocator);
            const sema = SemanticEnv.init(ir, null, functions).forModule(active_module_id);
            if (sema.resolvedConst(ast.CallableName.bare(name))) |resolved| {
                break :blk try evalConstValue(ir, page_id, context, mode, functions, closures, current_origin, resolved);
            }
            if (sema.resolvedFunction(ast.CallableName.bare(name))) |resolved| {
                const func = resolved.decl;
                break :blk .{ .function = try eval_functions.functionRefForInModule(ir.allocator, resolved.module_id, func) };
            }
            try reportUnknownIdentifier(ir, name, current_origin);
            break :blk error.UnknownIdentifier;
        },
        .string => |literal| blk: {
            try registerStringLiteralProvenance(ir, literal);
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
        .call => |call| try evalCall(ir, page_id, context, mode, env, functions, closures, current_origin, call),
        .apply => |apply| try evalApply(ir, page_id, context, mode, env, functions, closures, current_origin, apply),
        .lambda => |lambda| try evalLambda(env, closures, lambda),
        .record => |record| try evalRecord(ir, page_id, context, mode, env, functions, closures, current_origin, record),
        .member => |member| try evalMember(ir, page_id, context, mode, env, functions, closures, current_origin, member),
        .optional_check => |check| blk: {
            var value = try evalExpr(ir, page_id, context, mode, env, functions, closures, current_origin, check.target.*);
            defer value.deinit(ir.allocator);
            break :blk .{ .boolean = value_contracts.runtimeKind(value) != .none };
        },
        .coalesce => |coalesce| blk: {
            var value = try evalExpr(ir, page_id, context, mode, env, functions, closures, current_origin, coalesce.target.*);
            if (value_contracts.runtimeKind(value) != .none) break :blk value;
            value.deinit(ir.allocator);
            break :blk try evalExpr(ir, page_id, context, mode, env, functions, closures, current_origin, coalesce.fallback.*);
        },
    };
}

fn registerStringLiteralProvenance(ir: *core.Ir, literal: ast.StringLiteral) !void {
    const source_span = literal.source_span orelse return;
    const origin = try originForActiveModuleSpan(ir, source_span);
    defer ir.allocator.free(origin);
    const provenance = [_]core.ContentProvenance{.{
        .content_start = 0,
        .content_end = literal.text.len,
        .origin = origin,
    }};
    try ir.setStringProvenance(literal.text, &provenance);
}

fn evalConstValue(
    ir: *core.Ir,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    resolved: semantic_env.ResolvedConst,
) anyerror!core.Value {
    if (ir.const_values.get(resolved.key)) |value| return try value.clone(ir.allocator);
    if (ir.const_eval_states.get(resolved.key)) |state| {
        if (state == 1) return error.RecursiveConst;
    }
    try ir.const_eval_states.put(resolved.key, 1);
    var state_committed = false;
    errdefer {
        if (!state_committed) _ = ir.const_eval_states.remove(resolved.key);
    }

    var local_env = std.StringHashMap(core.Value).init(ir.allocator);
    defer deinitValueEnv(ir.allocator, &local_env);

    const previous_module_id = active_module_id;
    active_module_id = resolved.module_id;
    defer active_module_id = previous_module_id;

    const start_node_count = ir.nodeCount();
    var value = try evalExpr(ir, page_id, context, mode, &local_env, functions, closures, current_origin, resolved.decl.value);
    var value_moved = false;
    errdefer if (!value_moved) value.deinit(ir.allocator);
    try value_contracts.ensureValueConformsToType(ir, page_id, value, resolved.decl.value_type, current_origin, .UnmatchedReturnType);
    try connectValueObjects(ir, value, start_node_count);
    try ir.const_values.put(resolved.key, value);
    value_moved = true;
    try ir.const_eval_states.put(resolved.key, 2);
    state_committed = true;
    return try ir.const_values.get(resolved.key).?.clone(ir.allocator);
}

fn evalMember(
    ir: *core.Ir,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    member: ast.MemberExpr,
) !core.Value {
    var target = try evalExpr(ir, page_id, context, mode, env, functions, closures, current_origin, member.target.*);
    defer target.deinit(ir.allocator);
    if (target == .record) {
        const value = target.record.field(member.name) orelse return .{ .none = {} };
        return try value.clone(ir.allocator);
    }
    if (std.mem.eql(u8, member.name, "content")) {
        const object_id = try resolveValueObjectId(ir, mode, target);
        return .{ .string = ir.getNode(object_id).?.content orelse "" };
    }
    const node_id = switch (target) {
        .document => |id| id,
        .page => |id| id,
        .object => |id| id,
        else => return error.InvalidValueTag,
    };
    const node = ir.getNode(node_id) orelse return error.UnknownNode;
    const value = core.nodeProperty(node, member.name) orelse return .{ .none = {} };
    const sema = SemanticEnv.init(ir, null, functions).forModule(active_module_id);
    const class_name = core.class_fields.classNameForNodeWithEnv(node, &sema) orelse return .{ .string = value };
    const field = sema.field(class_name, member.name) orelse return .{ .string = value };
    var field_type = (try sema.resolveTypeText(ir.allocator, field.module_id, field.value_type)) orelse return .{ .string = value };
    defer field_type.deinit(ir.allocator);
    return typedPropertyValue(ir.allocator, value, field_type);
}

fn evalRecord(
    ir: *core.Ir,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    record: ast.RecordExpr,
) !core.Value {
    const resolved = findRecordDecl(ir, record.type_name) orelse {
        try reportNamedResolutionError(ir, error.UnknownType, "record type", record.type_name, current_origin);
        return error.UnknownType;
    };
    const caller_module_id = active_module_id;
    defer active_module_id = caller_module_id;

    var value = core.RecordValue.init(resolved.decl.name);
    errdefer value.deinit(ir.allocator);

    var default_env = std.StringHashMap(core.Value).init(ir.allocator);
    defer deinitValueEnv(ir.allocator, &default_env);
    active_module_id = resolved.module_id;
    for (resolved.decl.fields.items) |field| {
        const default_expr = field.default_value orelse continue;
        const field_value = try evalExpr(ir, page_id, context, mode, &default_env, functions, closures, current_origin, default_expr.*);
        try putRecordFieldValue(ir.allocator, &value, field.name, field_value, false);
    }

    active_module_id = caller_module_id;
    for (record.fields.items) |field| {
        const field_value = try evalExpr(ir, page_id, context, mode, env, functions, closures, current_origin, field.value);
        try putRecordFieldValue(ir.allocator, &value, field.name, field_value, true);
    }
    return .{ .record = value };
}

const ResolvedRecordDecl = struct {
    decl: *const ast.RecordDecl,
    module_id: core.SourceModuleId,
};

fn findRecordDecl(ir: *const core.Ir, type_name: []const u8) ?ResolvedRecordDecl {
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
        for (module.program.records.items) |*decl| {
            if (std.mem.eql(u8, decl.name, type_name)) return .{
                .decl = decl,
                .module_id = module.id,
            };
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

fn typedPropertyValue(allocator: std.mem.Allocator, value: []const u8, ty: ast.Type) !core.Value {
    if (ty.kind == .optional) {
        const child = ty.optional_child orelse return .{ .string = value };
        return typedPropertyValue(allocator, value, child.*);
    }
    return switch (ty.kind) {
        .none => .{ .none = {} },
        .string, .color => .{ .string = value },
        .enum_type => .{ .enum_case = .{
            .enum_name = ty.enum_name orelse "",
            .case_name = value,
        } },
        .record => blk: {
            var parsed = try eval_value.parsePropertyValue(allocator, value);
            if (parsed != .record) {
                parsed.deinit(allocator);
                return error.InvalidValueTag;
            }
            if (ty.class_name) |expected| {
                if (!std.mem.eql(u8, parsed.record.type_name, expected)) {
                    parsed.deinit(allocator);
                    return error.InvalidValueTag;
                }
            }
            break :blk parsed;
        },
        .number => .{ .number = std.fmt.parseFloat(f32, value) catch return error.InvalidValueTag },
        .boolean => blk: {
            if (std.mem.eql(u8, value, "true")) break :blk .{ .boolean = true };
            if (std.mem.eql(u8, value, "false")) break :blk .{ .boolean = false };
            return error.InvalidValueTag;
        },
        else => .{ .string = value },
    };
}

fn evalCall(
    ir: *core.Ir,
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
                    try validateFixedArity(ir, call.args.items.len, func_ref.param_count, current_origin);
                    var args = try evalCallArgs(ir, page_id, context, mode, env, functions, closures, current_origin, call.args.items);
                    defer args.deinit(ir.allocator);
                    defer deinitValues(ir.allocator, args.items);
                    return try invokeFunctionRef(ir, page_id, context, mode, env, functions, closures, func_ref, current_origin, args.items);
                },
                else => {},
            }
        }
    }
    const sema = SemanticEnv.init(ir, null, functions).forModule(active_module_id);
    if (sema.resolvedConst(call.callee)) |resolved| {
        var const_value = try evalConstValue(ir, page_id, context, mode, functions, closures, current_origin, resolved);
        defer const_value.deinit(ir.allocator);
        const function = switch (const_value) {
            .function => |function| function,
            else => {
                try reportUnknownFunction(ir, call.callee.name, current_origin);
                return error.UnknownFunction;
            },
        };
        var args = try evalCallArgs(ir, page_id, context, mode, env, functions, closures, current_origin, call.args.items);
        defer args.deinit(ir.allocator);
        defer deinitValues(ir.allocator, args.items);
        return try invokeFunctionRef(ir, page_id, context, mode, env, functions, closures, function, current_origin, args.items);
    }
    const descriptor = sema.callCallee(call.callee) orelse {
        try reportUnknownCallable(ir, &sema, call.callee, current_origin);
        return error.UnknownFunction;
    };
    return switch (descriptor) {
        .function => |resolved| blk: {
            const func = resolved.decl;
            try eval_functions.requireReturnsValue(func);
            break :blk try invokeUserFunctionValueInModule(ir, page_id, context, mode, env, functions, closures, resolved.module_id, func, current_origin, call);
        },
        .primitive => |primitive| try evalPrimitiveCall(ir, page_id, context, mode, env, functions, closures, current_origin, call, primitive),
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
    ir: *core.Ir,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    apply: ast.ApplyExpr,
) anyerror!core.Value {
    var callee = try evalExpr(ir, page_id, context, mode, env, functions, closures, current_origin, apply.callee.*);
    defer callee.deinit(ir.allocator);
    const function = switch (callee) {
        .function => |function| function,
        else => return error.InvalidValueTag,
    };
    var args = try evalCallArgs(ir, page_id, context, mode, env, functions, closures, current_origin, apply.args.items);
    defer args.deinit(ir.allocator);
    defer deinitValues(ir.allocator, args.items);
    return try invokeFunctionRef(ir, page_id, context, mode, env, functions, closures, function, current_origin, args.items);
}

fn evalCallArgs(
    ir: *core.Ir,
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
        deinitValues(ir.allocator, values.items);
        values.deinit(ir.allocator);
    }
    for (args) |arg| {
        try values.append(ir.allocator, try evalExpr(ir, page_id, context, mode, env, functions, closures, current_origin, arg));
    }
    return values;
}

fn evalNodeRepr(
    ir: *core.Ir,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    object_id: core.NodeId,
) ![]const u8 {
    const node = ir.getNode(object_id) orelse return error.UnknownNode;
    const function = node.repr_function orelse return node.content orelse "";
    return evalNodeReprWithFunction(ir, page_id, context, mode, env, functions, closures, current_origin, object_id, function);
}

fn evalNodeReprWithFunction(
    ir: *core.Ir,
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
    var result = try invokeFunctionRef(ir, page_id, context, mode, env, functions, closures, function, current_origin, &args);
    defer result.deinit(ir.allocator);
    return switch (result) {
        .string => |text| text,
        else => error.ExpectedStringArgument,
    };
}

const BuiltinContext = struct {
    ir: *core.Ir,
    page_id: core.NodeId,
    eval_context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,

    pub fn checkArityRange(self: *const BuiltinContext, actual: usize, min: usize, max: usize) !void {
        try validateArityRange(self.ir, actual, min, max, self.current_origin);
    }

    pub fn currentPageValue(self: *const BuiltinContext) !core.Value {
        if (self.eval_context != .page) return error.NoCurrentPage;
        return .{ .page = self.page_id };
    }

    pub fn currentDocumentValue(self: *const BuiltinContext) core.Value {
        return .{ .document = self.ir.document_id };
    }

    pub fn runSelectCall(self: *BuiltinContext, call: CallExpr) anyerror!core.Value {
        return try evalSelectCall(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, call);
    }

    pub fn evalExprValue(self: *BuiltinContext, expr: Expr) anyerror!core.Value {
        return try evalExpr(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, expr);
    }

    pub fn evalStringArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror![]const u8 {
        return try evalCallStringArg(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, call, index);
    }

    pub fn evalPropertyStringArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror![]const u8 {
        return try resolveValuePropertyString(self.ir.allocator, try self.evalExprValue(call.args.items[index]));
    }

    pub fn evalNumberArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!f32 {
        return try evalCallNumberArg(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, call, index);
    }

    pub fn evalObjectArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.NodeId {
        return try evalCallObjectArg(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, call, index);
    }

    pub fn evalAnchorArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.AnchorValue {
        return try evalCallAnchorArg(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, call, index);
    }

    pub fn evalRoleArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.Role {
        return try evalCallRoleArg(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, call, index);
    }

    pub fn evalPayloadArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!names.ParsedPayload {
        return try evalCallPayloadArg(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, call, index);
    }

    pub fn ownString(self: *BuiltinContext, text: []u8) ![]const u8 {
        return try self.ir.ownString(text);
    }

    pub fn ownStringWithProvenance(self: *BuiltinContext, text: []u8, entries: []const core.ContentProvenance) ![]const u8 {
        return try self.ir.ownStringWithProvenance(text, entries);
    }

    pub fn readlines(self: *BuiltinContext, requested: []const u8) ![]const u8 {
        const resolved = try resolveAssetPath(self.ir.allocator, self.ir.asset_base_dir, requested);
        defer self.ir.allocator.free(resolved);

        const bytes = readTextFileAlloc(self.ir.allocator, resolved) catch |err| {
            const message = try std.fmt.allocPrint(
                self.ir.allocator,
                "ReadlinesFailed: could not read {s} (resolved to {s}): {s}",
                .{ requested, resolved, @errorName(err) },
            );
            defer self.ir.allocator.free(message);
            try self.emitDiagnosticReport(.@"error", message);
            return try self.ir.copyString("");
        };
        return try self.ir.ownString(bytes);
    }

    pub fn materializeForUse(self: *BuiltinContext, value: core.Value) !core.Value {
        return try normalizeForUse(self.ir, self.mode, value);
    }

    pub fn anchorValueForObject(self: *BuiltinContext, node_id: core.NodeId, anchor_name: []const u8) !core.Value {
        const anchor = names.parseAnchorName(anchor_name) orelse {
            try reportNamedResolutionError(self.ir, error.UnknownAnchor, "anchor", anchor_name, self.current_origin);
            return error.UnknownAnchor;
        };
        return .{ .anchor = .{ .node = .{ .node_id = node_id, .anchor = anchor } } };
    }

    pub fn pageAnchorValue(self: *BuiltinContext, anchor_name: []const u8) !core.Value {
        const anchor = names.parseAnchorName(anchor_name) orelse {
            try reportNamedResolutionError(self.ir, error.UnknownAnchor, "anchor", anchor_name, self.current_origin);
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
        return try self.ir.createObjectWithOrigin(role_name, role, object_kind, payload_kind, content, self.current_origin);
    }

    pub fn makeGroup(self: *BuiltinContext, child_ids: []const core.NodeId) !core.NodeId {
        return try self.ir.createGroupWithOrigin(child_ids, self.current_origin);
    }

    pub fn makePage(self: *BuiltinContext, title: []const u8) !core.NodeId {
        return try self.ir.addPage(title);
    }

    pub fn placeObjectOnPage(self: *BuiltinContext, page_id: core.NodeId, object_id: core.NodeId) !void {
        try self.ir.placeObjectOnPage(page_id, object_id);
    }

    pub fn setNodeProperty(self: *BuiltinContext, object_id: core.NodeId, key: []const u8, value: []const u8) !void {
        self.ir.setNodeProperty(object_id, key, value) catch |err| switch (err) {
            error.DuplicatePropertyDefinition => {
                try reportDuplicatePropertyDefinition(self.ir, self.current_origin, key);
                return err;
            },
            else => return err,
        };
    }

    pub fn setNodeReprFunction(self: *BuiltinContext, object_id: core.NodeId, function: core.FunctionRef) !void {
        self.ir.setNodeReprFunction(object_id, function) catch |err| switch (err) {
            error.DuplicateReprDefinition => {
                try reportDuplicateReprDefinition(self.ir, self.current_origin);
                return err;
            },
            else => return err,
        };
    }

    pub fn unsetNodeProperty(self: *BuiltinContext, object_id: core.NodeId, key: []const u8) !void {
        try self.ir.unsetNodeProperty(object_id, key);
    }

    pub fn extendRenderEnv(self: *BuiltinContext, node_id: core.NodeId, op: []const u8, key: []const u8, value: []const u8) !void {
        try self.ir.extendRenderEnv(node_id, op, key, value);
    }

    pub fn invokeCallback(self: *BuiltinContext, function: core.FunctionRef, args: []const core.Value) !core.Value {
        return try invokeFunctionRef(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, function, self.current_origin, args);
    }

    pub fn pageIndex(self: *BuiltinContext, page_id: core.NodeId) usize {
        return self.ir.pageIndexOf(page_id);
    }

    pub fn pageCount(self: *BuiltinContext) usize {
        return self.ir.pageCount();
    }

    pub fn frameX(self: *BuiltinContext, object_id: core.NodeId) !f32 {
        _ = self;
        _ = object_id;
        return error.UnsupportedScheduledPrimitive;
    }

    pub fn frameY(self: *BuiltinContext, object_id: core.NodeId) !f32 {
        _ = self;
        _ = object_id;
        return error.UnsupportedScheduledPrimitive;
    }

    pub fn frameWidth(self: *BuiltinContext, object_id: core.NodeId) !f32 {
        _ = self;
        _ = object_id;
        return error.UnsupportedScheduledPrimitive;
    }

    pub fn frameHeight(self: *BuiltinContext, object_id: core.NodeId) !f32 {
        _ = self;
        _ = object_id;
        return error.UnsupportedScheduledPrimitive;
    }

    pub fn nodeContent(self: *BuiltinContext, object_id: core.NodeId) ?[]const u8 {
        const node = self.ir.getNode(object_id) orelse return null;
        return node.content;
    }

    pub fn reprNode(self: *BuiltinContext, object_id: core.NodeId) ![]const u8 {
        return try evalNodeRepr(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.closures, self.current_origin, object_id);
    }

    pub fn nodeProperty(self: *BuiltinContext, target: core.Value, key: []const u8) ?[]const u8 {
        const node_id = switch (target) {
            .document => |id| id,
            .page => |id| id,
            .object => |id| id,
            else => return null,
        };
        const node = self.ir.getNode(node_id) orelse return null;
        return core.nodeProperty(node, key);
    }

    pub fn setNodeContent(self: *BuiltinContext, object_id: core.NodeId, text: []const u8) !void {
        self.ir.setNodeContent(object_id, text) catch |err| switch (err) {
            error.DuplicateContentDefinition => {
                try reportDuplicateContentDefinition(self.ir, self.current_origin);
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
        return try anchorEqualityConstraintSet(self.ir, target, source, offset, self.current_origin);
    }

    pub fn emitDiagnosticReport(self: *BuiltinContext, severity: core.DiagnosticSeverity, message: []const u8) !void {
        try emitUserReport(self.ir, self.page_id, self.current_origin, severity, message);
    }

    pub fn checkAssetExists(self: *BuiltinContext, object_id: core.NodeId) !void {
        try validateAssetExists(self.ir, self.page_id, object_id, self.current_origin);
    }
};

fn evalPrimitiveCall(
    ir: *core.Ir,
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
        .ir = ir,
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
    ir: *core.Ir,
    page_id: core.NodeId,
    origin: []const u8,
    severity: core.DiagnosticSeverity,
    message: []const u8,
) !void {
    try ir.addValidationDiagnostic(
        severity,
        page_id,
        null,
        origin,
        .{ .user_report = .{ .message = try ir.allocator.dupe(u8, message) } },
    );
}

fn validateAssetExists(ir: *core.Ir, page_id: core.NodeId, object_id: core.NodeId, origin: []const u8) !void {
    const node = ir.getNode(object_id) orelse return error.UnknownNode;
    if (node.object_kind == null or node.object_kind.? != .asset or node.content == null) {
        try ir.addValidationDiagnostic(.@"error", page_id, object_id, origin, .{
            .asset_invalid = .{
                .reason = try ir.allocator.dupe(u8, "expected an asset object with a path"),
                .payload_kind = node.payload_kind,
            },
        });
        return;
    }

    const requested = node.content.?;
    const resolved = try resolveAssetPath(ir.allocator, ir.asset_base_dir, requested);
    if (!fs_utils.fileExists(ir.allocator, resolved)) {
        try ir.addValidationDiagnostic(.@"error", page_id, object_id, origin, .{
            .asset_not_found = .{
                .requested_path = try ir.allocator.dupe(u8, requested),
                .resolved_path = resolved,
                .payload_kind = node.payload_kind,
            },
        });
        return;
    }

    if (node.payload_kind == .image_ref) {
        try attachIntrinsicImageSize(ir, object_id, resolved);
    } else if (node.payload_kind == .pdf_ref) {
        try attachIntrinsicPdfSize(ir, object_id, resolved);
    }
}

fn attachIntrinsicImageSize(ir: *core.Ir, object_id: core.NodeId, resolved_path: []const u8) !void {
    const dimensions = fs_utils.readImageDimensions(ir.allocator, resolved_path) catch return;
    try attachIntrinsicAssetSize(ir, object_id, dimensions);
}

fn attachIntrinsicPdfSize(ir: *core.Ir, object_id: core.NodeId, resolved_path: []const u8) !void {
    const dimensions = fs_utils.readPdfDimensions(ir.allocator, resolved_path) catch return;
    try attachIntrinsicAssetSize(ir, object_id, dimensions);
}

fn attachIntrinsicAssetSize(ir: *core.Ir, object_id: core.NodeId, dimensions: fs_utils.ImageDimensions) !void {
    const fitted = fitSize(
        dimensions.width,
        dimensions.height,
        core.PageLayout.default_asset_width,
        core.PageLayout.max_figure_height,
    );
    var width_buf: [32]u8 = undefined;
    var height_buf: [32]u8 = undefined;
    const width_text = try std.fmt.bufPrint(&width_buf, "{d}", .{fitted.width});
    const height_text = try std.fmt.bufPrint(&height_buf, "{d}", .{fitted.height});
    try ir.setNodeProperty(object_id, "asset_width", width_text);
    try ir.setNodeProperty(object_id, "asset_height", height_text);
}

fn fitSize(width: f32, height: f32, max_width: f32, max_height: f32) struct { width: f32, height: f32 } {
    if (width <= 0 or height <= 0) return .{ .width = max_width, .height = max_height };
    const scale = @min(max_width / width, max_height / height);
    return .{ .width = width * scale, .height = height * scale };
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
    ir: *core.Ir,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    const base = try normalizeForUse(ir, mode, try evalExpr(ir, page_id, context, mode, env, functions, closures, current_origin, call.args.items[0]));
    const op_name = try evalCallStringArg(ir, page_id, context, mode, env, functions, closures, current_origin, call, 1);
    const sema = SemanticEnv.init(null, null, functions);
    const descriptor = sema.query(op_name) orelse {
        try reportUnknownQuery(ir, op_name, current_origin);
        return error.UnknownQuery;
    };
    registry.validateQueryArity(descriptor, call.args.items.len) catch |err| {
        if (err == error.InvalidArity) try validateFixedArity(ir, call.args.items.len, descriptor.arity, current_origin);
        return err;
    };
    try value_contracts.ensureValueConformsToType(ir, null, base, descriptor.input_type, current_origin, .UnmatchedInputType);
    switch (descriptor.op) {
        .self_object => {
            return try ir.select(ir.allocator, base, core.Query.selfObject());
        },
        .previous_page => {
            return try ir.select(ir.allocator, base, core.Query.previousPage());
        },
        .parent_page => {
            return try ir.select(ir.allocator, base, core.Query.parentPage());
        },
        .children => {
            return try ir.select(ir.allocator, base, core.Query.children());
        },
        .descendants => {
            return try ir.select(ir.allocator, base, core.Query.descendants());
        },
        .document_pages => {
            return try ir.select(ir.allocator, base, core.Query.documentPages());
        },
        .page_objects_by_role => {
            const role = try evalCallRoleArg(ir, page_id, context, mode, env, functions, closures, current_origin, call, 2);
            return try ir.select(ir.allocator, base, core.Query.pageObjectsByRole(role));
        },
        .document_objects_by_role => {
            const role = try evalCallRoleArg(ir, page_id, context, mode, env, functions, closures, current_origin, call, 2);
            return try ir.select(ir.allocator, base, core.Query.documentObjectsByRole(role));
        },
    }
}

fn validateFixedArity(ir: *core.Ir, actual: usize, expected: usize, origin: []const u8) !void {
    if (actual != expected) {
        try reportLowerDiagnostic(ir, .{
            .err = error.InvalidArity,
            .origin = origin,
            .data = .{ .invalid_arity = .{ .actual = actual, .min = expected, .max = expected } },
        });
        return error.InvalidArity;
    }
}

fn validateUserFunctionArity(ir: *core.Ir, actual: usize, func: FunctionDecl, origin: []const u8) !void {
    const range = eval_functions.arity(func);
    if (actual < range.min or actual > range.max) {
        try reportLowerDiagnostic(ir, .{
            .err = error.InvalidArity,
            .origin = origin,
            .data = .{ .invalid_arity = .{ .actual = actual, .min = range.min, .max = range.max } },
        });
        return error.InvalidArity;
    }
}

fn validateArityRange(ir: *core.Ir, actual: usize, min: usize, max: usize, origin: []const u8) !void {
    if (actual < min or actual > max) {
        try reportLowerDiagnostic(ir, .{
            .err = error.InvalidArity,
            .origin = origin,
            .data = .{ .invalid_arity = .{ .actual = actual, .min = min, .max = max } },
        });
        return error.InvalidArity;
    }
}

fn bindUserFunctionArgs(
    ir: *core.Ir,
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
            break :blk try evalExpr(ir, page_id, context, mode, caller_env, functions, closures, current_origin, call.args.items[index]);
        } else blk: {
            const previous_module_id = active_module_id;
            active_module_id = module_id;
            defer active_module_id = previous_module_id;
            break :blk try evalExpr(ir, page_id, context, mode, local_env, functions, closures, current_origin, (param.default_value orelse return error.InvalidArity).*);
        };
        value_contracts.ensureValueConformsToType(ir, page_id, value, param.ty, current_origin, .UnmatchedArgumentType) catch |err| {
            var owned = value;
            owned.deinit(ir.allocator);
            return err;
        };
        try putEnvValue(ir.allocator, local_env, param.name, value);
    }
}

fn bindUserFunctionValueArgs(
    ir: *core.Ir,
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
    try validateUserFunctionArity(ir, args.len, func, current_origin);
    for (func.params.items, 0..) |param, index| {
        const value = if (index < args.len) blk: {
            break :blk try args[index].clone(ir.allocator);
        } else blk: {
            const previous_module_id = active_module_id;
            active_module_id = module_id;
            defer active_module_id = previous_module_id;
            break :blk try evalExpr(ir, page_id, context, mode, local_env, functions, closures, current_origin, (param.default_value orelse return error.InvalidArity).*);
        };
        value_contracts.ensureValueConformsToType(ir, page_id, value, param.ty, current_origin, .UnmatchedArgumentType) catch |err| {
            var owned = value;
            owned.deinit(ir.allocator);
            return err;
        };
        try putEnvValue(ir.allocator, local_env, param.name, value);
    }
    _ = caller_env;
}

fn normalizeForUse(ir: *core.Ir, mode: EvalMode, value: core.Value) !core.Value {
    _ = ir;
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

fn resolveValueObjectId(ir: *core.Ir, mode: EvalMode, value: core.Value) !core.NodeId {
    return switch (try normalizeForUse(ir, mode, value)) {
        .object => |id| id,
        else => return error.ExpectedObject,
    };
}

fn evalCallArg(
    ir: *core.Ir,
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
    return try evalExpr(ir, page_id, context, mode, env, functions, closures, current_origin, call.args.items[index]);
}

fn evalCallStringArg(
    ir: *core.Ir,
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
    return try resolveValueString(try evalCallArg(ir, page_id, context, mode, env, functions, closures, current_origin, call, index));
}

fn evalCallNumberArg(
    ir: *core.Ir,
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
    return try resolveValueNumber(try evalCallArg(ir, page_id, context, mode, env, functions, closures, current_origin, call, index));
}

fn evalCallObjectArg(
    ir: *core.Ir,
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
    return try resolveValueObjectId(ir, mode, try evalCallArg(ir, page_id, context, mode, env, functions, closures, current_origin, call, index));
}

fn evalCallAnchorArg(
    ir: *core.Ir,
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
    return try resolveValueAnchor(try evalCallArg(ir, page_id, context, mode, env, functions, closures, current_origin, call, index));
}

fn evalCallRoleArg(
    ir: *core.Ir,
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
    const role_name = try evalCallStringArg(ir, page_id, context, mode, env, functions, closures, current_origin, call, index);
    return names.parseRoleName(role_name) orelse {
        try reportNamedResolutionError(ir, error.UnknownRole, "role", role_name, current_origin);
        return error.UnknownRole;
    };
}

fn evalCallPayloadArg(
    ir: *core.Ir,
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
    const payload_name = try evalCallStringArg(ir, page_id, context, mode, env, functions, closures, current_origin, call, index);
    return names.parsePayloadName(payload_name) orelse {
        try reportNamedResolutionError(ir, error.UnknownPayloadKind, "payload kind", payload_name, current_origin);
        return error.UnknownPayloadKind;
    };
}

fn singleConstraintSet(ir: *core.Ir, constraint: core.Constraint) !core.ConstraintSet {
    var bundle = core.ConstraintSet.init();
    errdefer bundle.deinit(ir.allocator);
    try bundle.items.append(ir.allocator, constraint);
    return bundle;
}

fn anchorEqualityConstraintSet(
    ir: *core.Ir,
    target: core.AnchorValue,
    source: core.AnchorValue,
    offset: f32,
    origin: []const u8,
) !core.ConstraintSet {
    return switch (target) {
        .page => error.PageCannotBeConstraintTarget,
        .node => |node| try singleConstraintSet(ir, .{
            .target_node = node.node_id,
            .target_anchor = node.anchor,
            .source = source.toConstraintSource(),
            .offset = offset,
            .origin = origin,
        }),
    };
}

const ResolvedTarget = struct {
    node_id: core.NodeId,
    anchor: core.Anchor,
};

fn executeStatement(
    ir: *core.Ir,
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
    const origin = if (origin_override) |override| override else try statementOrigin(ir.allocator, stmt.span);
    switch (stmt.kind) {
        .let_binding => |binding| {
            const value = try evalExpr(ir, page_id, context, mode, env, functions, closures, origin, binding.expr);
            if (names.isDiscardBindingName(binding.name)) {
                defer {
                    var owned = value;
                    owned.deinit(ir.allocator);
                }
                try discardStatementValue(ir, value);
                return .none;
            }
            try putEnvValue(ir.allocator, env, binding.name, value);
        },
        .return_expr => |expr| {
            const value = try evalExpr(ir, page_id, context, mode, env, functions, closures, origin, expr);
            return .{ .returned = value };
        },
        .return_void => return .{ .returned = .{ .void = {} } },
        .property_set => |property_set| {
            const base = env.get(property_set.object_name) orelse {
                try reportUnknownIdentifier(ir, property_set.object_name, origin);
                return error.UnknownIdentifier;
            };
            const object_id = try resolveValueObjectId(ir, mode, base);
            const value = try evalExpr(ir, page_id, context, mode, env, functions, closures, origin, property_set.value);
            defer {
                var owned = value;
                owned.deinit(ir.allocator);
            }
            switch (value) {
                .none => {
                    try ir.unsetNodeProperty(object_id, property_set.property_name);
                    return .none;
                },
                else => {},
            }
            const text = try resolveValuePropertyString(ir.allocator, value);
            defer if (eval_value.propertyStringNeedsFree(value)) ir.allocator.free(text);
            ir.setNodeProperty(object_id, property_set.property_name, text) catch |err| switch (err) {
                error.DuplicatePropertyDefinition => {
                    try reportDuplicatePropertyDefinition(ir, origin, property_set.property_name);
                    return err;
                },
                else => return err,
            };
        },
        .if_stmt => |if_stmt| {
            const value = try evalExpr(ir, page_id, context, mode, env, functions, closures, origin, if_stmt.condition);
            const condition = try resolveValueBoolean(value);
            const branch = if (condition) if_stmt.then_statements.items else if_stmt.else_statements.items;
            var branch_env = try cloneValueEnv(ir.allocator, env);
            defer deinitValueEnv(ir.allocator, &branch_env);
            for (branch) |nested| {
                const flow = try executeStatement(ir, page_id, context, mode, &branch_env, functions, closures, last_code_like, nested, null);
                switch (flow) {
                    .none => {},
                    .returned => return flow,
                }
            }
        },
        .constrain => |decl| {
            if (context != .page) return error.NoCurrentPage;
            const target = try resolveAnchorRef(ir, mode, env, origin, decl.target, true);
            const source = try resolveAnchorRef(ir, mode, env, origin, decl.source, false);
            const offset: f32 = if (decl.offset) |expr| blk: {
                const value = try evalExpr(ir, page_id, context, mode, env, functions, closures, origin, expr);
                break :blk try resolveValueNumber(value);
            } else 0;
            try ir.addAnchorConstraint(target.node_id, target.anchor, source, offset, origin);
        },
        .expr_stmt => |expr| switch (expr) {
            .call => |call| {
                const sema = SemanticEnv.init(ir, null, functions).forModule(active_module_id);
                if (sema.resolvedFunction(call.callee) != null) {
                    try executeCallStatement(ir, page_id, context, mode, env, functions, closures, last_code_like, origin, call);
                } else {
                    var value = try evalExpr(ir, page_id, context, mode, env, functions, closures, origin, expr);
                    defer value.deinit(ir.allocator);
                    try materializeStatementValue(ir, mode, last_code_like, value);
                }
            },
            else => {
                var value = try evalExpr(ir, page_id, context, mode, env, functions, closures, origin, expr);
                defer value.deinit(ir.allocator);
                try materializeStatementValue(ir, mode, last_code_like, value);
            },
        },
    }
    return .none;
}

fn materializeStatementValue(ir: *core.Ir, mode: EvalMode, last_code_like: *?core.NodeId, value: core.Value) !void {
    _ = mode;
    switch (value) {
        .constraints => |constraints| try ir.addConstraintSet(constraints),
        .object => |id| last_code_like.* = id,
        else => {},
    }
}

fn connectReturnedObject(ir: *core.Ir, value: core.Value, start_node_count: usize) !void {
    switch (value) {
        .object => |id| try ir.connectGeneratedReturnObjects(id, start_node_count),
        else => {},
    }
}

fn connectValueObjects(ir: *core.Ir, value: core.Value, start_node_count: usize) !void {
    switch (value) {
        .object => |id| try ir.connectGeneratedReturnObjects(id, start_node_count),
        .record => |record| {
            for (record.fields.items) |field| try connectValueObjects(ir, field.value, start_node_count);
        },
        else => {},
    }
}

fn discardStatementValue(ir: *core.Ir, value: core.Value) !void {
    switch (value) {
        .object => |id| try ir.discardObjectSubtree(id),
        .selection => |selection| {
            if (selection.item_tag != .object) return;
            for (selection.ids.items) |id| try ir.discardObjectSubtree(id);
        },
        else => {},
    }
}

fn executeCallStatement(
    ir: *core.Ir,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const core.FunctionMap,
    closures: *ClosureStore,
    last_code_like: *?core.NodeId,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!void {
    const sema = SemanticEnv.init(ir, null, functions).forModule(active_module_id);
    const resolved = sema.resolvedFunction(call.callee) orelse {
        _ = try evalCall(ir, page_id, context, mode, env, functions, closures, current_origin, call);
        return;
    };
    const func = resolved.decl;
    try validateUserFunctionArity(ir, call.args.items.len, func, current_origin);

    var local_env = try cloneValueEnv(ir.allocator, env);
    defer deinitValueEnv(ir.allocator, &local_env);
    try bindUserFunctionArgs(ir, page_id, context, mode, env, &local_env, functions, closures, resolved.module_id, func, current_origin, call);
    const start_node_count = ir.nodeCount();
    const previous_module_id = active_module_id;
    active_module_id = resolved.module_id;
    defer active_module_id = previous_module_id;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(ir, page_id, context, mode, &local_env, functions, closures, last_code_like, inner, current_origin);
        switch (flow) {
            .none => {},
            .returned => |value| {
                defer {
                    var owned = value;
                    owned.deinit(ir.allocator);
                }
                if (func.result_type.kind == .void) {
                    try value_contracts.ensureValueTypeWithCode(ir, page_id, value, .void, current_origin, .UnmatchedReturnType);
                } else {
                    try value_contracts.ensureValueConformsToType(ir, page_id, value, func.result_type, current_origin, .UnmatchedReturnType);
                    try connectReturnedObject(ir, value, start_node_count);
                    try materializeStatementValue(ir, mode, last_code_like, value);
                }
                return;
            },
        }
    }
    if (func.result_type.kind != .void) return error.FunctionDidNotReturnValue;
}

fn invokeFunctionRef(
    ir: *core.Ir,
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
        return try invokeClosureValues(ir, page_id, context, mode, env, functions, closures, closure_id, current_origin, args);
    }
    const sema = SemanticEnv.init(ir, null, functions).forModule(function.module_id);
    const resolved = sema.resolvedFunction(ast.CallableName.bare(function.name)) orelse {
        try reportUnknownFunction(ir, function.name, current_origin);
        return error.UnknownFunction;
    };
    return try invokeUserFunctionValues(ir, page_id, context, mode, env, functions, closures, resolved.module_id, resolved.decl, current_origin, args);
}

fn invokeClosureValues(
    ir: *core.Ir,
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
        try reportUnknownFunction(ir, "#lambda", current_origin);
        return error.UnknownFunction;
    };
    try validateFixedArity(ir, args.len, closure.lambda.params.items.len, current_origin);

    var local_env = try cloneValueEnv(ir.allocator, &closure.env);
    defer deinitValueEnv(ir.allocator, &local_env);
    for (closure.lambda.params.items, 0..) |param, index| {
        const value = try args[index].clone(ir.allocator);
        value_contracts.ensureValueConformsToType(ir, page_id, value, param.ty, current_origin, .UnmatchedArgumentType) catch |err| {
            var owned = value;
            owned.deinit(ir.allocator);
            return err;
        };
        try putEnvValue(ir.allocator, &local_env, param.name, value);
    }
    const start_node_count = ir.nodeCount();
    const value = try evalExpr(ir, page_id, context, mode, &local_env, functions, closures, current_origin, closure.lambda.body.*);
    try connectReturnedObject(ir, value, start_node_count);
    return value;
}

fn invokeUserFunctionValue(
    ir: *core.Ir,
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
    return invokeUserFunctionValueInModule(ir, page_id, context, mode, env, functions, closures, active_module_id, func, current_origin, call);
}

fn invokeUserFunctionValueInModule(
    ir: *core.Ir,
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
    var func_ref = try eval_functions.functionRefForInModule(ir.allocator, module_id, func);
    defer func_ref.deinit(ir.allocator);
    if (!func_ref.returns_value) return error.FunctionDoesNotReturnValue;
    try validateUserFunctionArity(ir, call.args.items.len, func, current_origin);

    var local_env = try cloneValueEnv(ir.allocator, env);
    defer deinitValueEnv(ir.allocator, &local_env);
    try bindUserFunctionArgs(ir, page_id, context, mode, env, &local_env, functions, closures, module_id, func, current_origin, call);

    var last_code_like: ?core.NodeId = null;
    const start_node_count = ir.nodeCount();
    const previous_module_id = active_module_id;
    active_module_id = module_id;
    defer active_module_id = previous_module_id;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(ir, page_id, context, mode, &local_env, functions, closures, &last_code_like, inner, current_origin);
        switch (flow) {
            .none => {},
            .returned => |value| {
                try value_contracts.ensureValueConformsToType(ir, page_id, value, func.result_type, current_origin, .UnmatchedReturnType);
                try connectReturnedObject(ir, value, start_node_count);
                return value;
            },
        }
    }

    return error.FunctionDidNotReturnValue;
}

fn invokeUserFunctionValues(
    ir: *core.Ir,
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
    var local_env = try cloneValueEnv(ir.allocator, env);
    defer deinitValueEnv(ir.allocator, &local_env);
    try bindUserFunctionValueArgs(ir, page_id, context, mode, env, &local_env, functions, closures, module_id, func, current_origin, args);

    var last_code_like: ?core.NodeId = null;
    const start_node_count = ir.nodeCount();
    const previous_module_id = active_module_id;
    active_module_id = module_id;
    defer active_module_id = previous_module_id;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(ir, page_id, context, mode, &local_env, functions, closures, &last_code_like, inner, current_origin);
        switch (flow) {
            .none => {},
            .returned => |value| {
                try value_contracts.ensureValueConformsToType(ir, page_id, value, func.result_type, current_origin, .UnmatchedReturnType);
                try connectReturnedObject(ir, value, start_node_count);
                return value;
            },
        }
    }

    if (func.result_type.kind == .void) return .{ .void = {} };
    return error.FunctionDidNotReturnValue;
}

fn statementOrigin(allocator: std.mem.Allocator, span: ast.Span) ![]const u8 {
    if (diagnostic_path.len != 0) {
        return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ diagnostic_path, span.start, span.end });
    }
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}

fn originForActiveModuleSpan(ir: *core.Ir, span: ast.Span) ![]const u8 {
    if (ir.modulePath(active_module_id)) |path| {
        return std.fmt.allocPrint(ir.allocator, "path:{s}:bytes:{d}-{d}", .{ path, span.start, span.end });
    }
    return statementOrigin(ir.allocator, span);
}

fn resolveAnchorRef(
    ir: *core.Ir,
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
            const value = env.get(anchor_ref.node_name.?) orelse {
                try reportUnknownIdentifier(ir, anchor_ref.node_name.?, current_origin);
                return error.UnknownIdentifier;
            };
            const node_id = try resolveValueObjectId(ir, mode, value);
            if (is_target) {
                return .{ .node_id = node_id, .anchor = anchor_ref.anchor };
            }
            return .{ .node = .{ .node_id = node_id, .anchor = anchor_ref.anchor } };
        },
    }
}
