const std = @import("std");
const core = @import("core");
const builtin = @import("builtin.zig");
const doc = @import("document.zig");
const eval_functions = @import("../eval/functions.zig");
const eval_value = @import("../eval/value.zig");
const utils = @import("utils");
const fs_utils = utils.fs;
const ast = @import("ast");
const names = @import("../language/names.zig");
const semantic_env = @import("../language/env.zig");
const registry = @import("../language/registry.zig");
const dependencies = @import("../analysis/dependencies.zig");
const value_contracts = @import("value_contracts.zig");
const typecheck = @import("../analysis/typecheck.zig");

const Program = ast.Program;
const FunctionDecl = ast.FunctionDecl;
const PageDecl = ast.PageDecl;
const Statement = ast.Statement;
const Expr = ast.Expr;
const CallExpr = ast.CallExpr;
const AnchorRef = ast.AnchorRef;
const SemanticEnv = semantic_env.SemanticEnv;

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

const ScheduledUnit = struct {
    module_id: core.SourceModuleId,
    source: []const u8,
    path: []const u8,
    source_order: usize,
    span: ast.Span,
    summary: dependencies.AccessSummary,
    kind: Kind,

    const Kind = union(enum) {
        document_statement: struct {
            stmt: Statement,
            index: usize,
        },
        page: struct {
            decl: PageDecl,
            page_id: core.NodeId,
        },
    };

    fn deinit(self: *ScheduledUnit) void {
        self.summary.deinit();
    }
};

const ScheduleEdge = struct {
    from: usize,
    to: usize,
};

const ScheduleGraph = struct {
    allocator: std.mem.Allocator,
    functions: *const std.StringHashMap(FunctionDecl),
    document: *doc.Document,
    units: std.ArrayList(ScheduledUnit),
    edges: std.ArrayList(ScheduleEdge),
    order: []usize,

    fn build(allocator: std.mem.Allocator, ir: *const core.Ir, document: *doc.Document) !ScheduleGraph {
        var graph = ScheduleGraph{
            .allocator = allocator,
            .functions = &ir.functions,
            .document = document,
            .units = .empty,
            .edges = .empty,
            .order = &.{},
        };
        errdefer graph.deinit();

        var collected_modules = std.AutoHashMap(core.SourceModuleId, void).init(allocator);
        defer collected_modules.deinit();
        var source_order: usize = 0;
        try collectScheduledUnits(ir, ir.projectModule(), graph.document, &ir.functions, &graph.units, &collected_modules, &source_order);
        try validateScheduledUnits(graph.document, graph.units.items);
        try buildScheduleEdges(allocator, graph.units.items, &graph.edges);
        graph.order = scheduleFromEdges(allocator, graph.units.items, graph.edges.items) catch |err| {
            if (err == error.ScheduledDependencyCycle and graph.units.items.len != 0) {
                try addUnitErrorDiagnostic(graph.document, graph.units.items[0], lowerErrorMessage(err));
            }
            return err;
        };
        return graph;
    }

    fn deinit(self: *ScheduleGraph) void {
        self.allocator.free(self.order);
        self.edges.deinit(self.allocator);
        for (self.units.items) |*unit| unit.deinit();
        self.units.deinit(self.allocator);
    }
};

fn reportUnknownFunction(ir: *doc.Document, name: []const u8, origin: []const u8) !void {
    try reportNamedResolutionError(ir, error.UnknownFunction, "function", name, origin);
}

fn reportUnknownQuery(ir: *doc.Document, name: []const u8, origin: []const u8) !void {
    try reportNamedResolutionError(ir, error.UnknownQuery, "query", name, origin);
}

fn reportUnknownIdentifier(ir: *doc.Document, name: []const u8, origin: []const u8) !void {
    try reportNamedResolutionError(ir, error.UnknownIdentifier, "identifier", name, origin);
}

fn reportNamedResolutionError(ir: *doc.Document, err: anyerror, kind: []const u8, name: []const u8, origin: []const u8) !void {
    try reportLowerDiagnostic(ir, .{
        .err = err,
        .origin = origin,
        .data = .{ .unknown_name = .{ .kind = kind, .name = name } },
    });
}

fn reportLowerError(ir: *doc.Document, err: anyerror, origin: []const u8) !void {
    try reportLowerDiagnostic(ir, .{
        .err = err,
        .origin = origin,
        .data = .generic,
    });
}

fn reportLowerDiagnostic(ir: *doc.Document, diagnostic: LowerDiagnostic) !void {
    var message_buf: [256]u8 = undefined;
    const message = formatLowerDiagnostic(&message_buf, diagnostic);
    try ir.addValidationDiagnostic(.@"error", null, null, diagnostic.origin, .{
        .user_report = .{ .message = try ir.allocator.dupe(u8, message) },
    });
}

fn addUnitErrorDiagnostic(ir: *doc.Document, unit: ScheduledUnit, message: []const u8) !void {
    const origin = try unitOrigin(ir.allocator, unit);
    defer ir.allocator.free(origin);
    try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
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
        error.EmptySelection => "EmptySelection: selection is empty",
        error.InvalidSelectionItemType => "InvalidSelectionItemType: selection item kinds do not match",
        error.InvalidSelectionMutation => "InvalidSelectionMutation: primitive callbacks must not add objects or pages to the selection being iterated",
        error.LayoutDependencyCycle => "LayoutDependencyCycle: layout reads cannot feed object creation, content, properties, or constraints because layout is solved once",
        error.PostLayoutComputationUnsupported => "PostLayoutComputationUnsupported: layout-reading scheduled computations are not implemented yet",
        error.ScheduledDependencyCycle => "ScheduledDependencyCycle: document elaboration dependencies contain a cycle",
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
        error.UnsupportedScheduledPrimitive => "UnsupportedScheduledPrimitive: this operation is not valid during document elaboration",
        error.FunctionDidNotReturnValue => "FunctionDidNotReturnValue: function did not return a value",
        else => @errorName(err),
    };
}

pub fn elaborateProgram(
    allocator: std.mem.Allocator,
    asset_base_dir: []const u8,
    program: Program,
    source: []const u8,
    path: []const u8,
    functions: *const std.StringHashMap(FunctionDecl),
) !doc.Document {
    var document = try doc.Document.init(allocator, asset_base_dir);
    errdefer document.deinit();
    try executeProgram(program, source, path, &document, functions);
    return document;
}

pub fn elaborateIr(allocator: std.mem.Allocator, ir: *const core.Ir) !doc.Document {
    var document = try doc.Document.init(allocator, ir.asset_base_dir);
    errdefer document.deinit();
    try elaborateIrInto(allocator, ir, &document);
    return document;
}

pub fn elaborateIrInto(allocator: std.mem.Allocator, ir: *const core.Ir, document: *doc.Document) !void {
    document.type_source = ir;
    var graph = try ScheduleGraph.build(allocator, ir, document);
    defer {
        graph.allocator.free(graph.order);
        graph.edges.deinit(graph.allocator);
        for (graph.units.items) |*unit| unit.deinit();
        graph.units.deinit(graph.allocator);
    }
    var closures = ClosureStore.init(allocator);
    defer closures.deinit();
    var document_states = std.AutoHashMap(core.SourceModuleId, DocumentExecutionState).init(allocator);
    defer {
        var iter = document_states.valueIterator();
        while (iter.next()) |state| state.deinit(allocator);
        document_states.deinit();
    }
    for (graph.order) |unit_index| try executeScheduledUnit(document, &ir.functions, &closures, &document_states, graph.units.items[unit_index]);
}

fn collectScheduledUnits(
    core_ir: *const core.Ir,
    module: *const core.SourceModule,
    document: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
    units: *std.ArrayList(ScheduledUnit),
    collected_modules: *std.AutoHashMap(core.SourceModuleId, void),
    source_order: *usize,
) !void {
    if (module.kind == .library) {
        if (collected_modules.contains(module.id)) return;
        try collected_modules.put(module.id, {});
    }

    if (module.program.top_level_items.items.len == 0) {
        try appendDocumentStatementUnits(core_ir.allocator, module, functions, units, source_order, 0, module.program.document_statements.items.len);
        for (module.program.pages.items) |page| try appendPageUnit(core_ir.allocator, module, document, functions, units, source_order, page);
        return;
    }

    for (module.program.top_level_items.items) |item| {
        switch (item) {
            .import => |import_index| {
                if (import_index >= module.resolved_import_ids.items.len) continue;
                const import_id = module.resolved_import_ids.items[import_index];
                const imported = core_ir.moduleById(import_id) orelse continue;
                try collectScheduledUnits(core_ir, imported, document, functions, units, collected_modules, source_order);
            },
            .document => |document_index| {
                if (document_index >= module.program.document_blocks.items.len) continue;
                const block = module.program.document_blocks.items[document_index];
                try appendDocumentStatementUnits(core_ir.allocator, module, functions, units, source_order, block.statement_start, block.statement_count);
            },
            .page => |page_index| {
                if (page_index >= module.program.pages.items.len) continue;
                try appendPageUnit(core_ir.allocator, module, document, functions, units, source_order, module.program.pages.items[page_index]);
            },
        }
    }
}

fn appendDocumentStatementUnits(
    allocator: std.mem.Allocator,
    module: *const core.SourceModule,
    functions: *const std.StringHashMap(FunctionDecl),
    units: *std.ArrayList(ScheduledUnit),
    source_order: *usize,
    statement_start: usize,
    statement_count: usize,
) !void {
    var analyzer = dependencies.Analyzer.init(allocator, functions);
    defer analyzer.deinit();
    const statement_end = @min(statement_start + statement_count, module.program.document_statements.items.len);
    for (module.program.document_statements.items[statement_start..statement_end], statement_start..) |stmt, stmt_index| {
        const summary = try analyzer.statement(stmt);
        errdefer {
            var owned = summary;
            owned.deinit();
        }
        try units.append(allocator, .{
            .module_id = module.id,
            .source = module.source,
            .path = module.path orelse module.spec,
            .source_order = source_order.*,
            .span = stmt.span,
            .summary = summary,
            .kind = .{ .document_statement = .{
                .stmt = stmt,
                .index = stmt_index,
            } },
        });
        source_order.* += 1;
    }
}

fn appendPageUnit(
    allocator: std.mem.Allocator,
    module: *const core.SourceModule,
    document: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
    units: *std.ArrayList(ScheduledUnit),
    source_order: *usize,
    page: PageDecl,
) !void {
    const page_id = try document.addPage(page.name);
    var analyzer = dependencies.Analyzer.init(allocator, functions);
    defer analyzer.deinit();
    const summary = try analyzer.page(page);
    errdefer {
        var owned = summary;
        owned.deinit();
    }
    try units.append(allocator, .{
        .module_id = module.id,
        .source = module.source,
        .path = module.path orelse module.spec,
        .source_order = source_order.*,
        .span = page.span,
        .summary = summary,
        .kind = .{ .page = .{ .decl = page, .page_id = page_id } },
    });
    source_order.* += 1;
}

fn validateScheduledUnits(ir: *doc.Document, units: []const ScheduledUnit) !void {
    for (units) |unit| {
        if (unit.summary.invalid_selection_mutation) |invalid| {
            const message = "InvalidSelectionMutation: primitive callbacks must not add objects or pages to the selection being iterated";
            try addUnitErrorDiagnostic(ir, unit, message);
            _ = invalid;
            return error.InvalidSelectionMutation;
        }
        if (unit.summary.reads_layout and unit.summary.writes_layout_input) {
            const message = "LayoutDependencyCycle: layout reads cannot feed object creation, content, properties, or constraints because layout is solved once";
            try addUnitErrorDiagnostic(ir, unit, message);
            return error.LayoutDependencyCycle;
        }
        if (unit.summary.reads_layout) {
            const message = "PostLayoutComputationUnsupported: layout-reading scheduled computations are not implemented yet";
            try addUnitErrorDiagnostic(ir, unit, message);
            return error.PostLayoutComputationUnsupported;
        }
    }
}

fn buildScheduleEdges(allocator: std.mem.Allocator, units: []const ScheduledUnit, edges: *std.ArrayList(ScheduleEdge)) !void {
    for (units, 0..) |left, left_index| {
        for (units, 0..) |right, right_index| {
            if (left_index == right_index) continue;
            if (!sameDocumentStatementSequence(left, right) or left.source_order < right.source_order) {
                try addResourceScheduleEdges(allocator, edges, left.summary, right.summary, left_index, right_index);
            }
            if (unitKindIsPage(left) and unitKindIsDocumentStatement(right) and documentStatementNeedsPageBody(right.summary)) {
                try addScheduleEdge(allocator, edges, left_index, right_index);
            }
            if (consecutiveDocumentStatements(left, right)) {
                try addScheduleEdge(allocator, edges, left_index, right_index);
            }
        }
    }
}

fn scheduleFromEdges(allocator: std.mem.Allocator, units: []const ScheduledUnit, edges: []const ScheduleEdge) ![]usize {
    const count = units.len;
    const indegree = try allocator.alloc(usize, count);
    defer allocator.free(indegree);
    @memset(indegree, 0);

    for (edges) |edge| indegree[edge.to] += 1;

    var done = try allocator.alloc(bool, count);
    defer allocator.free(done);
    @memset(done, false);

    var out = try allocator.alloc(usize, count);
    errdefer allocator.free(out);
    var produced: usize = 0;
    while (produced < count) {
        var best: ?usize = null;
        for (units, 0..) |unit, index| {
            if (done[index] or indegree[index] != 0) continue;
            if (best == null or unit.source_order < units[best.?].source_order) best = index;
        }
        const next = best orelse return error.ScheduledDependencyCycle;
        done[next] = true;
        out[produced] = next;
        produced += 1;
        for (edges) |edge| {
            if (edge.from != next) continue;
            std.debug.assert(indegree[edge.to] > 0);
            indegree[edge.to] -= 1;
        }
    }
    return out;
}

fn addResourceScheduleEdges(
    allocator: std.mem.Allocator,
    edges: *std.ArrayList(ScheduleEdge),
    left: dependencies.AccessSummary,
    right: dependencies.AccessSummary,
    from: usize,
    to: usize,
) !void {
    for (left.writes.items) |write| {
        if (!resourceNeedsScheduleEdge(write)) continue;
        for (right.reads.items) |read| {
            if (!resourceNeedsScheduleEdge(read)) continue;
            if (write.intersects(read)) {
                try addScheduleEdge(allocator, edges, from, to);
            }
        }
    }
}

fn addScheduleEdge(
    allocator: std.mem.Allocator,
    edges: *std.ArrayList(ScheduleEdge),
    from: usize,
    to: usize,
) !void {
    for (edges.items) |edge| {
        if (edge.from == from and edge.to == to) return;
    }
    try edges.append(allocator, .{
        .from = from,
        .to = to,
    });
}

fn resourceNeedsScheduleEdge(resource: dependencies.Resource) bool {
    return switch (resource.kind) {
        .graph_pages, .graph_objects, .metadata => true,
        .property, .content, .constraints, .render_env, .diagnostics, .layout, .asset => false,
    };
}

fn unitKindIsPage(unit: ScheduledUnit) bool {
    return switch (unit.kind) {
        .page => true,
        .document_statement => false,
    };
}

fn unitKindIsDocumentStatement(unit: ScheduledUnit) bool {
    return switch (unit.kind) {
        .document_statement => true,
        .page => false,
    };
}

fn sameDocumentStatementSequence(left: ScheduledUnit, right: ScheduledUnit) bool {
    if (left.module_id != right.module_id) return false;
    return switch (left.kind) {
        .document_statement => switch (right.kind) {
            .document_statement => true,
            .page => false,
        },
        .page => false,
    };
}

fn consecutiveDocumentStatements(left: ScheduledUnit, right: ScheduledUnit) bool {
    if (left.module_id != right.module_id) return false;
    const left_index = switch (left.kind) {
        .document_statement => |stmt| stmt.index,
        .page => return false,
    };
    const right_index = switch (right.kind) {
        .document_statement => |stmt| stmt.index,
        .page => return false,
    };
    return left_index + 1 == right_index;
}

fn documentStatementNeedsPageBody(summary: dependencies.AccessSummary) bool {
    for (summary.reads.items) |resource| {
        if (resource.kind == .graph_objects or resource.kind == .metadata) return true;
    }
    for (summary.writes.items) |resource| {
        if (resource.kind == .graph_objects or resource.kind == .metadata) return true;
    }
    return false;
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

fn executeScheduledUnit(
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    document_states: *std.AutoHashMap(core.SourceModuleId, DocumentExecutionState),
    unit: ScheduledUnit,
) !void {
    setLowerDiagnosticOrigin(unit.source, unit.path);
    switch (unit.kind) {
        .document_statement => |document_statement| {
            const entry = try document_states.getOrPut(unit.module_id);
            if (!entry.found_existing) entry.value_ptr.* = DocumentExecutionState.init(ir.allocator);
            try executeScheduledDocumentStatement(ir, functions, closures, entry.value_ptr, document_statement.stmt);
        },
        .page => |page| try executePageBody(page.decl, page.page_id, ir, functions, closures),
    }
}

fn executeScheduledDocumentStatement(
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
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

fn diagnosticErrorCount(ir: *const doc.Document) usize {
    var count: usize = 0;
    for (ir.diagnostics.items) |diagnostic| {
        if (diagnostic.severity == .@"error") count += 1;
    }
    return count;
}

fn unitOrigin(allocator: std.mem.Allocator, unit: ScheduledUnit) ![]const u8 {
    if (unit.path.len != 0) {
        return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ unit.path, unit.span.start, unit.span.end });
    }
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ unit.span.start, unit.span.end });
}

fn executeModuleProgramInSourceOrder(
    core_ir: *const core.Ir,
    module: *const core.SourceModule,
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
    executed_modules: *std.AutoHashMap(core.SourceModuleId, void),
) !void {
    var closures = ClosureStore.init(ir.allocator);
    defer closures.deinit();
    try executeModuleProgramInSourceOrderWithClosures(core_ir, module, ir, functions, executed_modules, &closures);
}

fn executeModuleProgramInSourceOrderWithClosures(
    core_ir: *const core.Ir,
    module: *const core.SourceModule,
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
    executed_modules: *std.AutoHashMap(core.SourceModuleId, void),
    closures: *ClosureStore,
) !void {
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

pub fn executeProgramWithLegacyIndex(program: Program, source: []const u8, ir: *doc.Document, io: std.Io) !void {
    return executeProgramWithPath(program, source, "", ir, io);
}

pub fn executeProgramWithPath(program: Program, source: []const u8, path: []const u8, ir: *doc.Document, io: std.Io) !void {
    var index = try typecheck.loadProgramIndex(ir.allocator, io, ir.asset_base_dir, program);
    defer index.deinit();
    return executeProgramWithIndex(program, source, path, ir, &index);
}

pub fn executeProgramWithIndex(
    program: Program,
    source: []const u8,
    path: []const u8,
    ir: *doc.Document,
    index: *const typecheck.ProgramIndex,
) !void {
    return executeProgram(program, source, path, ir, &index.functions);
}

pub fn executeProgram(
    program: Program,
    source: []const u8,
    path: []const u8,
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
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
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
) !void {
    try executeDocumentStatementSlice(ir, functions, closures, program.document_statements.items);
}

fn executeDocumentStatementsWithState(
    program: Program,
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    state: *DocumentExecutionState,
) !void {
    try executeDocumentStatementSliceWithState(ir, functions, closures, state, program.document_statements.items);
}

fn executeDocumentBlockWithState(
    program: Program,
    block: ast.DocumentBlockDecl,
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    state: *DocumentExecutionState,
) !void {
    const statement_end = @min(block.statement_start + block.statement_count, program.document_statements.items.len);
    try executeDocumentStatementSliceWithState(ir, functions, closures, state, program.document_statements.items[block.statement_start..statement_end]);
}

fn executeDocumentStatementSliceWithState(
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    state: *DocumentExecutionState,
    statements: []const Statement,
) !void {
    for (statements) |stmt| try executeScheduledDocumentStatement(ir, functions, closures, state, stmt);
}

fn executeDocumentStatementSlice(
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
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
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
) !void {
    const page_id = try ir.addPage(page.name);
    try executePageBody(page, page_id, ir, functions, closures);
}

fn executePageBody(
    page: PageDecl,
    page_id: core.NodeId,
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
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
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    current_origin: []const u8,
    expr: Expr,
) anyerror!core.Value {
    return switch (expr) {
        .ident => |name| blk: {
            if (env.get(name)) |value| break :blk try value.clone(ir.allocator);
            if (functions.get(name)) |func| {
                if (func.kind == .constant) {
                    break :blk try invokeUserFunctionValue(ir, page_id, context, mode, env, functions, closures, func, current_origin, .{
                        .name = name,
                        .args = std.ArrayList(Expr).empty,
                    });
                }
                break :blk .{ .function = try eval_functions.functionRefFor(ir.allocator, func) };
            }
            try reportUnknownIdentifier(ir, name, current_origin);
            break :blk error.UnknownIdentifier;
        },
        .string => |text| .{ .string = text },
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

fn evalMember(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    current_origin: []const u8,
    member: ast.MemberExpr,
) !core.Value {
    var target = try evalExpr(ir, page_id, context, mode, env, functions, closures, current_origin, member.target.*);
    defer target.deinit(ir.allocator);
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
    const type_source = ir.type_source orelse return .{ .string = value };
    const sema = SemanticEnv.init(type_source, null, functions);
    const class_name = core.class_fields.classNameForNodeWithEnv(node, &sema) orelse return .{ .string = value };
    const field = sema.field(class_name, member.name) orelse return .{ .string = value };
    var field_type = (try sema.resolveTypeText(ir.allocator, field.module_id, field.value_type)) orelse return .{ .string = value };
    defer field_type.deinit(ir.allocator);
    return typedPropertyValue(value, field_type);
}

fn typedPropertyValue(value: []const u8, ty: ast.Type) !core.Value {
    if (ty.kind == .optional) {
        const child = ty.optional_child orelse return .{ .string = value };
        return typedPropertyValue(value, child.*);
    }
    return switch (ty.kind) {
        .none => .{ .none = {} },
        .string, .color => .{ .string = value },
        .enum_type => .{ .enum_case = .{
            .enum_name = ty.enum_name orelse "",
            .case_name = value,
        } },
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
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    if (env.get(call.name)) |value| {
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
    const sema = SemanticEnv.init(null, null, functions);
    const descriptor = sema.call(call.name) orelse {
        try reportUnknownFunction(ir, call.name, current_origin);
        return error.UnknownFunction;
    };
    return switch (descriptor) {
        .function => |func| blk: {
            if (func.kind == .constant) {
                if (func.result_type.kind == .function) {
                    var const_value = try invokeUserFunctionValue(ir, page_id, context, mode, env, functions, closures, func, current_origin, .{
                        .name = call.name,
                        .args = std.ArrayList(Expr).empty,
                    });
                    defer const_value.deinit(ir.allocator);
                    const function = switch (const_value) {
                        .function => |function| function,
                        else => return error.InvalidValueTag,
                    };
                    var args = try evalCallArgs(ir, page_id, context, mode, env, functions, closures, current_origin, call.args.items);
                    defer args.deinit(ir.allocator);
                    defer deinitValues(ir.allocator, args.items);
                    break :blk try invokeFunctionRef(ir, page_id, context, mode, env, functions, closures, function, current_origin, args.items);
                }
                try reportUnknownFunction(ir, call.name, current_origin);
                return error.UnknownFunction;
            }
            try eval_functions.requireReturnsValue(func);
            break :blk try invokeUserFunctionValue(ir, page_id, context, mode, env, functions, closures, func, current_origin, call);
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
        .closure_id = id,
        .param_count = lambda.params.items.len,
        .returns_value = true,
    } };
}

fn evalApply(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
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
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
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

const BuiltinContext = struct {
    ir: *doc.Document,
    page_id: core.NodeId,
    eval_context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
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
        if (self.eval_context != .page) return error.NoCurrentPage;
        return try self.ir.makeObjectWithOrigin(self.page_id, role_name, role, object_kind, payload_kind, content, self.current_origin);
    }

    pub fn makeGroup(self: *BuiltinContext, child_ids: []const core.NodeId) !core.NodeId {
        if (self.eval_context != .page) return error.NoCurrentPage;
        return try self.ir.makeGroupWithOrigin(self.page_id, true, child_ids, self.current_origin);
    }

    pub fn makePage(self: *BuiltinContext, title: []const u8) !core.NodeId {
        return try self.ir.addPage(title);
    }

    pub fn makeObjectOnPage(
        self: *BuiltinContext,
        page_id: core.NodeId,
        role_name: []const u8,
        role: core.Role,
        object_kind: core.ObjectKind,
        payload_kind: core.PayloadKind,
        content: []const u8,
    ) !core.NodeId {
        return try self.ir.makeObjectWithOrigin(page_id, role_name, role, object_kind, payload_kind, content, self.current_origin);
    }

    pub fn makeGroupOnPage(self: *BuiltinContext, page_id: core.NodeId, child_ids: []const core.NodeId) !core.NodeId {
        return try self.ir.makeGroupWithOrigin(page_id, true, child_ids, self.current_origin);
    }

    pub fn setNodeProperty(self: *BuiltinContext, object_id: core.NodeId, key: []const u8, value: []const u8) !void {
        try self.ir.setNodeProperty(object_id, key, value);
    }

    pub fn unsetNodeProperty(self: *BuiltinContext, object_id: core.NodeId, key: []const u8) !void {
        try self.ir.unsetNodeProperty(object_id, key);
    }

    pub fn extendRenderEnv(self: *BuiltinContext, node_id: core.NodeId, op: []const u8, key: []const u8, value: []const u8) !void {
        try self.ir.extendRenderEnv(node_id, op, key, value);
    }

    pub fn emitMetadata(self: *BuiltinContext, target: core.Value, kind: []const u8, value: []const u8) !core.MetadataId {
        return try self.ir.emitMetadata(target, kind, value, self.current_origin);
    }

    pub fn metadataInDocument(self: *BuiltinContext, kind: []const u8) !core.Selection {
        return try self.ir.selectDocumentMetadataByKind(self.ir.allocator, kind, "metadata-in-document");
    }

    pub fn metadataOnPage(self: *BuiltinContext, page_id: core.NodeId, kind: []const u8) !core.Selection {
        return try self.ir.selectPageMetadataByKind(self.ir.allocator, page_id, kind, "metadata-on-page");
    }

    pub fn metadataContent(self: *BuiltinContext, metadata_id: core.MetadataId) ![]const u8 {
        return try self.ir.metadataContent(metadata_id);
    }

    pub fn metadataKind(self: *BuiltinContext, metadata_id: core.MetadataId) ![]const u8 {
        return try self.ir.metadataKind(metadata_id);
    }

    pub fn metadataPage(self: *BuiltinContext, metadata_id: core.MetadataId) !core.NodeId {
        return try self.ir.metadataPage(metadata_id);
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
        try self.ir.setNodeContent(object_id, text);
    }

    pub fn appendNodeContent(self: *BuiltinContext, object_id: core.NodeId, text: []const u8) !void {
        try self.ir.appendNodeContent(object_id, text);
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
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
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
    ir: *doc.Document,
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

fn validateAssetExists(ir: *doc.Document, page_id: core.NodeId, object_id: core.NodeId, origin: []const u8) !void {
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

fn attachIntrinsicImageSize(ir: *doc.Document, object_id: core.NodeId, resolved_path: []const u8) !void {
    const dimensions = fs_utils.readImageDimensions(ir.allocator, resolved_path) catch return;
    try attachIntrinsicAssetSize(ir, object_id, dimensions);
}

fn attachIntrinsicPdfSize(ir: *doc.Document, object_id: core.NodeId, resolved_path: []const u8) !void {
    const dimensions = fs_utils.readPdfDimensions(ir.allocator, resolved_path) catch return;
    try attachIntrinsicAssetSize(ir, object_id, dimensions);
}

fn attachIntrinsicAssetSize(ir: *doc.Document, object_id: core.NodeId, dimensions: fs_utils.ImageDimensions) !void {
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

fn evalSelectCall(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
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

fn validateFixedArity(ir: *doc.Document, actual: usize, expected: usize, origin: []const u8) !void {
    if (actual != expected) {
        try reportLowerDiagnostic(ir, .{
            .err = error.InvalidArity,
            .origin = origin,
            .data = .{ .invalid_arity = .{ .actual = actual, .min = expected, .max = expected } },
        });
        return error.InvalidArity;
    }
}

fn validateUserFunctionArity(ir: *doc.Document, actual: usize, func: FunctionDecl, origin: []const u8) !void {
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

fn validateArityRange(ir: *doc.Document, actual: usize, min: usize, max: usize, origin: []const u8) !void {
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
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    caller_env: *std.StringHashMap(core.Value),
    local_env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    func: FunctionDecl,
    current_origin: []const u8,
    call: CallExpr,
) !void {
    for (func.params.items, 0..) |param, index| {
        const value = if (index < call.args.items.len)
            try evalExpr(ir, page_id, context, mode, caller_env, functions, closures, current_origin, call.args.items[index])
        else
            try evalExpr(ir, page_id, context, mode, local_env, functions, closures, current_origin, (param.default_value orelse return error.InvalidArity).*);
        value_contracts.ensureValueConformsToType(ir, page_id, value, param.ty, current_origin, .UnmatchedArgumentType) catch |err| {
            var owned = value;
            owned.deinit(ir.allocator);
            return err;
        };
        try putEnvValue(ir.allocator, local_env, param.name, value);
    }
}

fn bindUserFunctionValueArgs(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    caller_env: *std.StringHashMap(core.Value),
    local_env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    func: FunctionDecl,
    current_origin: []const u8,
    args: []const core.Value,
) !void {
    try validateUserFunctionArity(ir, args.len, func, current_origin);
    for (func.params.items, 0..) |param, index| {
        const value = if (index < args.len)
            try args[index].clone(ir.allocator)
        else
            try evalExpr(ir, page_id, context, mode, local_env, functions, closures, current_origin, (param.default_value orelse return error.InvalidArity).*);
        value_contracts.ensureValueConformsToType(ir, page_id, value, param.ty, current_origin, .UnmatchedArgumentType) catch |err| {
            var owned = value;
            owned.deinit(ir.allocator);
            return err;
        };
        try putEnvValue(ir.allocator, local_env, param.name, value);
    }
    _ = caller_env;
}

fn normalizeForUse(ir: *doc.Document, mode: EvalMode, value: core.Value) !core.Value {
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

fn resolveValueObjectId(ir: *doc.Document, mode: EvalMode, value: core.Value) !core.NodeId {
    return switch (try normalizeForUse(ir, mode, value)) {
        .object => |id| id,
        else => return error.ExpectedObject,
    };
}

fn evalCallArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.Value {
    return try evalExpr(ir, page_id, context, mode, env, functions, closures, current_origin, call.args.items[index]);
}

fn evalCallStringArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror![]const u8 {
    return try resolveValueString(try evalCallArg(ir, page_id, context, mode, env, functions, closures, current_origin, call, index));
}

fn evalCallNumberArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!f32 {
    return try resolveValueNumber(try evalCallArg(ir, page_id, context, mode, env, functions, closures, current_origin, call, index));
}

fn evalCallObjectArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.NodeId {
    return try resolveValueObjectId(ir, mode, try evalCallArg(ir, page_id, context, mode, env, functions, closures, current_origin, call, index));
}

fn evalCallAnchorArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.AnchorValue {
    return try resolveValueAnchor(try evalCallArg(ir, page_id, context, mode, env, functions, closures, current_origin, call, index));
}

fn evalCallRoleArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
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
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
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

fn singleConstraintSet(ir: *doc.Document, constraint: core.Constraint) !core.ConstraintSet {
    var bundle = core.ConstraintSet.init();
    errdefer bundle.deinit(ir.allocator);
    try bundle.items.append(ir.allocator, constraint);
    return bundle;
}

fn anchorEqualityConstraintSet(
    ir: *doc.Document,
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
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    last_code_like: *?core.NodeId,
    stmt: Statement,
    origin_override: ?[]const u8,
) anyerror!ExecFlow {
    const origin = if (origin_override) |override| override else try statementOrigin(ir.allocator, stmt.span);
    switch (stmt.kind) {
        .let_binding => |binding| {
            const value = try evalExpr(ir, page_id, context, mode, env, functions, closures, origin, binding.expr);
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
            try ir.setNodeProperty(object_id, property_set.property_name, text);
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
                if (functions.contains(call.name)) {
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

fn materializeStatementValue(ir: *doc.Document, mode: EvalMode, last_code_like: *?core.NodeId, value: core.Value) !void {
    _ = mode;
    switch (value) {
        .constraints => |constraints| try ir.addConstraintSet(constraints),
        .object => |id| last_code_like.* = id,
        else => {},
    }
}

fn executeCallStatement(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    last_code_like: *?core.NodeId,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!void {
    const func = functions.get(call.name) orelse {
        _ = try evalCall(ir, page_id, context, mode, env, functions, closures, current_origin, call);
        return;
    };
    try validateUserFunctionArity(ir, call.args.items.len, func, current_origin);

    var local_env = try cloneValueEnv(ir.allocator, env);
    defer deinitValueEnv(ir.allocator, &local_env);
    try bindUserFunctionArgs(ir, page_id, context, mode, env, &local_env, functions, closures, func, current_origin, call);
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
                    try materializeStatementValue(ir, mode, last_code_like, value);
                }
                return;
            },
        }
    }
    if (func.result_type.kind != .void) return error.FunctionDidNotReturnValue;
}

fn invokeFunctionRef(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    function: core.FunctionRef,
    current_origin: []const u8,
    args: []const core.Value,
) anyerror!core.Value {
    if (function.closure_id) |closure_id| {
        return try invokeClosureValues(ir, page_id, context, mode, env, functions, closures, closure_id, current_origin, args);
    }
    const func = functions.get(function.name) orelse {
        try reportUnknownFunction(ir, function.name, current_origin);
        return error.UnknownFunction;
    };
    return try invokeUserFunctionValues(ir, page_id, context, mode, env, functions, closures, func, current_origin, args);
}

fn invokeClosureValues(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    caller_env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
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
    return try evalExpr(ir, page_id, context, mode, &local_env, functions, closures, current_origin, closure.lambda.body.*);
}

fn invokeUserFunctionValue(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    func: FunctionDecl,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    var func_ref = try eval_functions.functionRefFor(ir.allocator, func);
    defer func_ref.deinit(ir.allocator);
    if (!func_ref.returns_value) return error.FunctionDoesNotReturnValue;
    try validateUserFunctionArity(ir, call.args.items.len, func, current_origin);

    var local_env = try cloneValueEnv(ir.allocator, env);
    defer deinitValueEnv(ir.allocator, &local_env);
    try bindUserFunctionArgs(ir, page_id, context, mode, env, &local_env, functions, closures, func, current_origin, call);

    var last_code_like: ?core.NodeId = null;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(ir, page_id, context, mode, &local_env, functions, closures, &last_code_like, inner, current_origin);
        switch (flow) {
            .none => {},
            .returned => |value| {
                try value_contracts.ensureValueConformsToType(ir, page_id, value, func.result_type, current_origin, .UnmatchedReturnType);
                return value;
            },
        }
    }

    return error.FunctionDidNotReturnValue;
}

fn invokeUserFunctionValues(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    closures: *ClosureStore,
    func: FunctionDecl,
    current_origin: []const u8,
    args: []const core.Value,
) anyerror!core.Value {
    var local_env = try cloneValueEnv(ir.allocator, env);
    defer deinitValueEnv(ir.allocator, &local_env);
    try bindUserFunctionValueArgs(ir, page_id, context, mode, env, &local_env, functions, closures, func, current_origin, args);

    var last_code_like: ?core.NodeId = null;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(ir, page_id, context, mode, &local_env, functions, closures, &last_code_like, inner, current_origin);
        switch (flow) {
            .none => {},
            .returned => |value| {
                try value_contracts.ensureValueConformsToType(ir, page_id, value, func.result_type, current_origin, .UnmatchedReturnType);
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

fn resolveAnchorRef(
    ir: *doc.Document,
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
