const std = @import("std");
const core = @import("core");
const builtin = @import("builtin.zig");
const doc = @import("document.zig");
const eval_functions = @import("../eval/functions.zig");
const eval_value = @import("../eval/value.zig");
const utils = @import("utils");
const error_report = utils.err;
const fs_utils = utils.fs;
const ast = @import("ast");
const names = @import("../language/names.zig");
const semantic_env = @import("../language/env.zig");
const registry = @import("../language/registry.zig");
const dependencies = @import("../analysis/dependencies.zig");
const contracts = @import("../analysis/contracts.zig");
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

const EvalMode = union(enum) {
    attached,
    detached: *DetachedBuilder,
};

const EvalContext = enum {
    document,
    page,
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

const DetachedBuilder = struct {
    page_id: core.NodeId,
    node_ids: std.ArrayList(core.NodeId),
    constraints: core.ConstraintSet,
    deps: std.ArrayList(*core.Fragment),

    fn init(page_id: core.NodeId) DetachedBuilder {
        return .{
            .page_id = page_id,
            .node_ids = std.ArrayList(core.NodeId).empty,
            .constraints = core.ConstraintSet.init(),
            .deps = std.ArrayList(*core.Fragment).empty,
        };
    }

    fn deinit(self: *DetachedBuilder, allocator: std.mem.Allocator) void {
        self.node_ids.deinit(allocator);
        self.constraints.deinit(allocator);
        self.deps.deinit(allocator);
    }

    fn trackNode(self: *DetachedBuilder, allocator: std.mem.Allocator, node_id: core.NodeId) !void {
        for (self.node_ids.items) |existing| {
            if (existing == node_id) return;
        }
        try self.node_ids.append(allocator, node_id);
    }

    fn appendConstraintSet(self: *DetachedBuilder, allocator: std.mem.Allocator, constraints: core.ConstraintSet) !void {
        try self.constraints.items.appendSlice(allocator, constraints.items.items);
    }

    fn trackFragment(self: *DetachedBuilder, allocator: std.mem.Allocator, fragment: *core.Fragment) !void {
        for (self.deps.items) |existing| {
            if (existing == fragment) return;
        }
        try self.deps.append(allocator, fragment);
    }

    fn isEmpty(self: *const DetachedBuilder) bool {
        return self.node_ids.items.len == 0 and self.constraints.items.items.len == 0 and self.deps.items.len == 0;
    }
};

var diagnostic_source: []const u8 = "";
var diagnostic_path: []const u8 = "";
var diagnostic_reported = false;

const LowerDiagnostic = struct {
    err: anyerror,
    span: ?error_report.ByteSpan,
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
        invalid_sort: struct {
            expected: core.SemanticSort,
            actual: core.SemanticSort,
        },
        generic: void,
    };
};

const ScheduledRoot = struct {
    module_id: core.SourceModuleId,
    source: []const u8,
    path: []const u8,
    source_order: usize,
    span: ast.Span,
    summary: dependencies.AccessSummary,
    kind: Kind,

    const Kind = union(enum) {
        document: []const Statement,
        page: PageDecl,
    };

    fn deinit(self: *ScheduledRoot) void {
        self.summary.deinit();
    }
};

fn reportUnknownFunction(name: []const u8, origin: []const u8) void {
    reportNamedResolutionError(error.UnknownFunction, "function", name, origin);
}

fn reportUnknownQuery(name: []const u8, origin: []const u8) void {
    reportNamedResolutionError(error.UnknownQuery, "query", name, origin);
}

fn reportUnknownIdentifier(name: []const u8, origin: []const u8) void {
    reportNamedResolutionError(error.UnknownIdentifier, "identifier", name, origin);
}

fn reportNamedResolutionError(err: anyerror, kind: []const u8, name: []const u8, origin: []const u8) void {
    reportLowerDiagnostic(.{
        .err = err,
        .span = error_report.spanFromOrigin(origin),
        .data = .{ .unknown_name = .{ .kind = kind, .name = name } },
    });
}

fn reportLowerError(err: anyerror, origin: []const u8) void {
    if (diagnostic_reported) return;
    reportLowerDiagnostic(.{
        .err = err,
        .span = error_report.spanFromOrigin(origin),
        .data = .generic,
    });
}

fn reportLowerDiagnostic(diagnostic: LowerDiagnostic) void {
    diagnostic_reported = true;
    var message_buf: [256]u8 = undefined;
    error_report.print(.{
        .path = diagnostic_path,
        .source = diagnostic_source,
        .severity = .@"error",
        .message = formatLowerDiagnostic(&message_buf, diagnostic),
        .span = diagnostic.span,
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
        .invalid_sort => |data| std.fmt.bufPrint(buf, "InvalidSemanticSort: expected {s}, got {s}", .{ @tagName(data.expected), @tagName(data.actual) }) catch lowerErrorMessage(diagnostic.err),
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
        error.InvalidSemanticSort => "InvalidSemanticSort: value has the wrong semantic kind",
        error.RecursiveFunction => "RecursiveFunction: recursive functions are not allowed",
        error.ExpectedSelection => "ExpectedSelection: expected a selection value",
        error.ExpectedConstraintSet => "ExpectedConstraintSet: expected a constraint set",
        error.ExpectedStringArgument => "ExpectedStringArgument: expected a string argument",
        error.ExpectedNumberArgument => "ExpectedNumberArgument: expected a number argument",
        error.ExpectedStyleArgument => "ExpectedStyleArgument: expected a style argument",
        error.ExpectedAnchor => "ExpectedAnchor: expected an anchor argument",
        error.ExpectedObject => "ExpectedObject: expected an object argument",
        error.NoCurrentPage => "NoCurrentPage: this operation is only valid inside a page block",
        error.UnknownAnchor => "UnknownAnchor: unknown anchor",
        error.UnknownRole => "UnknownRole: unknown role",
        error.UnknownPayloadKind => "UnknownPayloadKind: unknown payload kind",
        error.PageCannotBeConstraintTarget => "PageCannotBeConstraintTarget: page anchors cannot be constraint targets",
        error.UnsupportedFragmentRoot => "UnsupportedFragmentRoot: unsupported fragment root",
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

    diagnostic_reported = false;
    var roots = std.ArrayList(ScheduledRoot).empty;
    defer {
        for (roots.items) |*root| root.deinit();
        roots.deinit(allocator);
    }
    var collected_modules = std.AutoHashMap(core.SourceModuleId, void).init(allocator);
    defer collected_modules.deinit();
    var source_order: usize = 0;
    try collectScheduledRoots(ir, ir.projectModule(), &ir.functions, &roots, &collected_modules, &source_order);

    try validateScheduledRoots(&document, roots.items);
    const schedule = try scheduleRoots(allocator, roots.items);
    defer allocator.free(schedule);
    for (schedule) |root_index| try executeScheduledRoot(&document, &ir.functions, roots.items[root_index]);
    return document;
}

fn collectScheduledRoots(
    core_ir: *const core.Ir,
    module: *const core.SourceModule,
    functions: *const std.StringHashMap(FunctionDecl),
    roots: *std.ArrayList(ScheduledRoot),
    collected_modules: *std.AutoHashMap(core.SourceModuleId, void),
    source_order: *usize,
) !void {
    if (module.kind == .library) {
        if (collected_modules.contains(module.id)) return;
        try collected_modules.put(module.id, {});
    }

    if (module.program.document_statements.items.len > 0) {
        try appendDocumentRoot(core_ir.allocator, module, functions, roots, source_order);
    }

    if (module.program.top_level_items.items.len == 0) {
        for (module.program.pages.items) |page| try appendPageRoot(core_ir.allocator, module, functions, roots, source_order, page);
        return;
    }

    for (module.program.top_level_items.items) |item| {
        switch (item) {
            .import => |import_index| {
                if (import_index >= module.resolved_import_ids.items.len) continue;
                const import_id = module.resolved_import_ids.items[import_index];
                const imported = core_ir.moduleById(import_id) orelse continue;
                try collectScheduledRoots(core_ir, imported, functions, roots, collected_modules, source_order);
            },
            .page => |page_index| {
                if (page_index >= module.program.pages.items.len) continue;
                try appendPageRoot(core_ir.allocator, module, functions, roots, source_order, module.program.pages.items[page_index]);
            },
        }
    }
}

fn appendDocumentRoot(
    allocator: std.mem.Allocator,
    module: *const core.SourceModule,
    functions: *const std.StringHashMap(FunctionDecl),
    roots: *std.ArrayList(ScheduledRoot),
    source_order: *usize,
) !void {
    var analyzer = dependencies.Analyzer.init(allocator, functions);
    defer analyzer.deinit();
    const statements = module.program.document_statements.items;
    const span = documentStatementsSpan(statements);
    const summary = try analyzer.documentStatements(statements);
    errdefer {
        var owned = summary;
        owned.deinit();
    }
    try roots.append(allocator, .{
        .module_id = module.id,
        .source = module.source,
        .path = module.path orelse module.spec,
        .source_order = source_order.*,
        .span = span,
        .summary = summary,
        .kind = .{ .document = statements },
    });
    source_order.* += 1;
}

fn appendPageRoot(
    allocator: std.mem.Allocator,
    module: *const core.SourceModule,
    functions: *const std.StringHashMap(FunctionDecl),
    roots: *std.ArrayList(ScheduledRoot),
    source_order: *usize,
    page: PageDecl,
) !void {
    var analyzer = dependencies.Analyzer.init(allocator, functions);
    defer analyzer.deinit();
    const summary = try analyzer.page(page);
    errdefer {
        var owned = summary;
        owned.deinit();
    }
    try roots.append(allocator, .{
        .module_id = module.id,
        .source = module.source,
        .path = module.path orelse module.spec,
        .source_order = source_order.*,
        .span = page.span,
        .summary = summary,
        .kind = .{ .page = page },
    });
    source_order.* += 1;
}

fn documentStatementsSpan(statements: []const Statement) ast.Span {
    if (statements.len == 0) return .{ .start = 0, .end = 0 };
    var span = statements[0].span;
    for (statements[1..]) |stmt| {
        span.start = @min(span.start, stmt.span.start);
        span.end = @max(span.end, stmt.span.end);
    }
    return span;
}

fn validateScheduledRoots(ir: *doc.Document, roots: []const ScheduledRoot) !void {
    for (roots) |root| {
        if (root.summary.invalid_foreach) |invalid| {
            const origin = try rootOrigin(ir.allocator, root);
            defer ir.allocator.free(origin);
            try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                .user_report = .{ .message = try ir.allocator.dupe(u8, "InvalidForeachMutation: foreach callbacks must not add objects or pages to the selection being iterated") },
            });
            _ = invalid;
            return error.InvalidForeachMutation;
        }
        if (root.summary.reads_layout and root.summary.writes_layout_input) {
            const origin = try rootOrigin(ir.allocator, root);
            defer ir.allocator.free(origin);
            try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                .user_report = .{ .message = try ir.allocator.dupe(u8, "LayoutDependencyCycle: layout reads cannot feed object creation, content, properties, or constraints because layout is solved once") },
            });
            return error.LayoutDependencyCycle;
        }
        if (root.summary.reads_layout) {
            const origin = try rootOrigin(ir.allocator, root);
            defer ir.allocator.free(origin);
            try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                .user_report = .{ .message = try ir.allocator.dupe(u8, "PostLayoutComputationUnsupported: layout-reading root computations are not implemented yet") },
            });
            return error.PostLayoutComputationUnsupported;
        }
    }
}

fn scheduleRoots(allocator: std.mem.Allocator, roots: []const ScheduledRoot) ![]usize {
    const count = roots.len;
    const indegree = try allocator.alloc(usize, count);
    defer allocator.free(indegree);
    @memset(indegree, 0);

    const edges = try allocator.alloc(std.ArrayList(usize), count);
    defer {
        for (edges) |*list| list.deinit(allocator);
        allocator.free(edges);
    }
    for (edges) |*list| list.* = .empty;

    for (roots, 0..) |left, left_index| {
        for (roots, 0..) |right, right_index| {
            if (left_index == right_index) continue;
            if (hasResourceDependency(left.summary, right.summary)) {
                try addScheduleEdge(allocator, edges, indegree, left_index, right_index);
            }
        }
    }

    var done = try allocator.alloc(bool, count);
    defer allocator.free(done);
    @memset(done, false);

    var out = try allocator.alloc(usize, count);
    errdefer allocator.free(out);
    var produced: usize = 0;
    while (produced < count) {
        var best: ?usize = null;
        for (roots, 0..) |root, index| {
            if (done[index] or indegree[index] != 0) continue;
            if (best == null or root.source_order < roots[best.?].source_order) best = index;
        }
        const next = best orelse return error.ScheduledDependencyCycle;
        done[next] = true;
        out[produced] = next;
        produced += 1;
        for (edges[next].items) |target| {
            std.debug.assert(indegree[target] > 0);
            indegree[target] -= 1;
        }
    }
    return out;
}

fn addScheduleEdge(
    allocator: std.mem.Allocator,
    edges: []std.ArrayList(usize),
    indegree: []usize,
    from: usize,
    to: usize,
) !void {
    for (edges[from].items) |existing| {
        if (existing == to) return;
    }
    try edges[from].append(allocator, to);
    indegree[to] += 1;
}

fn hasResourceDependency(left: dependencies.AccessSummary, right: dependencies.AccessSummary) bool {
    for (left.writes.items) |write| {
        for (right.reads.items) |read| {
            if (write.intersects(read)) return true;
        }
    }
    return false;
}

fn executeScheduledRoot(
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
    root: ScheduledRoot,
) !void {
    setLowerDiagnosticOrigin(root.source, root.path);
    switch (root.kind) {
        .document => |statements| try executeDocumentStatementSlice(ir, functions, statements),
        .page => |page| try executePage(page, ir, functions),
    }
}

fn rootOrigin(allocator: std.mem.Allocator, root: ScheduledRoot) ![]const u8 {
    if (root.path.len != 0) {
        return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ root.path, root.span.start, root.span.end });
    }
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ root.span.start, root.span.end });
}

fn executeModuleProgramInSourceOrder(
    core_ir: *const core.Ir,
    module: *const core.SourceModule,
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
    executed_modules: *std.AutoHashMap(core.SourceModuleId, void),
) !void {
    if (module.kind == .library) {
        if (executed_modules.contains(module.id)) return;
        try executed_modules.put(module.id, {});
    }

    setLowerDiagnosticOrigin(module.source, module.path orelse module.spec);
    try executeDocumentStatements(module.program, ir, functions);

    if (module.program.top_level_items.items.len == 0) {
        for (module.program.pages.items) |page| {
            setLowerDiagnosticOrigin(module.source, module.path orelse module.spec);
            try executePage(page, ir, functions);
        }
        return;
    }

    for (module.program.top_level_items.items) |item| {
        switch (item) {
            .import => |import_index| {
                if (import_index >= module.resolved_import_ids.items.len) continue;
                const import_id = module.resolved_import_ids.items[import_index];
                const imported = core_ir.moduleById(import_id) orelse continue;
                try executeModuleProgramInSourceOrder(core_ir, imported, ir, functions, executed_modules);
            },
            .page => |page_index| {
                if (page_index >= module.program.pages.items.len) continue;
                setLowerDiagnosticOrigin(module.source, module.path orelse module.spec);
                try executePage(module.program.pages.items[page_index], ir, functions);
            },
        }
    }
}

pub fn executeProgramWithLegacyIndex(program: Program, source: []const u8, ir: *doc.Document, io: std.Io) !void {
    diagnostic_source = source;
    diagnostic_path = "";
    return executeProgramWithPath(program, source, "", ir, io);
}

pub fn executeProgramWithPath(program: Program, source: []const u8, path: []const u8, ir: *doc.Document, io: std.Io) !void {
    diagnostic_source = source;
    diagnostic_path = path;
    diagnostic_reported = false;
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
    diagnostic_reported = false;

    try executeDocumentStatements(program, ir, functions);
    for (program.pages.items) |page| try executePage(page, ir, functions);
}

fn setLowerDiagnosticOrigin(source: []const u8, path: []const u8) void {
    diagnostic_source = source;
    diagnostic_path = path;
}

fn executeDocumentStatements(
    program: Program,
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
) !void {
    try executeDocumentStatementSlice(ir, functions, program.document_statements.items);
}

fn executeDocumentStatementSlice(
    ir: *doc.Document,
    functions: *const std.StringHashMap(FunctionDecl),
    statements: []const Statement,
) !void {
    var document_env = std.StringHashMap(core.Value).init(ir.allocator);
    defer deinitValueEnv(ir.allocator, &document_env);
    var document_last_code_like: ?core.NodeId = null;
    for (statements) |stmt| {
        const flow = executeStatement(ir, ir.document_id, .document, .attached, &document_env, functions, &document_last_code_like, stmt, null) catch |err| {
            const origin = statementOrigin(ir.allocator, stmt.span) catch "bytes:0-1";
            if (ir.diagnostics.items.len == 0) reportLowerError(err, origin);
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
) !void {
    const page_id = try ir.addPage(page.name);
    var last_code_like: ?core.NodeId = null;
    var env = std.StringHashMap(core.Value).init(ir.allocator);
    defer deinitValueEnv(ir.allocator, &env);

    for (page.statements.items) |stmt| {
        const flow = executeStatement(ir, page_id, .page, .attached, &env, functions, &last_code_like, stmt, null) catch |err| {
            const origin = statementOrigin(ir.allocator, stmt.span) catch "bytes:0-1";
            if (ir.diagnostics.items.len == 0) reportLowerError(err, origin);
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
    current_origin: []const u8,
    expr: Expr,
) anyerror!core.Value {
    return switch (expr) {
        .ident => |name| blk: {
            if (env.get(name)) |value| break :blk try value.clone(ir.allocator);
            if (functions.get(name)) |func| {
                if (func.kind == .constant) {
                    break :blk try invokeUserFunctionValue(ir, page_id, context, mode, env, functions, func, current_origin, .{
                        .name = name,
                        .args = std.ArrayList(Expr).empty,
                    });
                }
                break :blk .{ .function = try eval_functions.functionRefFor(ir.allocator, func) };
            }
            reportUnknownIdentifier(name, current_origin);
            break :blk error.UnknownIdentifier;
        },
        .string => |text| .{ .string = text },
        .number => |value| .{ .number = value },
        .boolean => |value| .{ .boolean = value },
        .call => |call| try evalCall(ir, page_id, context, mode, env, functions, current_origin, call),
    };
}

fn evalCall(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    if (env.get(call.name)) |value| {
        switch (value) {
            .function => |func_ref| {
                if (!func_ref.returns_value) return error.FunctionDoesNotReturnValue;
                const func = functions.get(func_ref.name) orelse {
                    reportUnknownFunction(func_ref.name, current_origin);
                    return error.UnknownFunction;
                };
                try validateFixedArity(call.args.items.len, func_ref.param_count, current_origin);
                return try invokeUserFunctionValue(ir, page_id, context, mode, env, functions, func, current_origin, call);
            },
            else => {},
        }
    }
    const sema = SemanticEnv.init(null, null, functions);
    const descriptor = sema.call(call.name) orelse {
        reportUnknownFunction(call.name, current_origin);
        return error.UnknownFunction;
    };
    return switch (descriptor) {
        .function => |func| blk: {
            if (func.kind == .constant) {
                reportUnknownFunction(call.name, current_origin);
                return error.UnknownFunction;
            }
            try eval_functions.requireReturnsValue(func);
            break :blk try invokeUserFunctionValue(ir, page_id, context, mode, env, functions, func, current_origin, call);
        },
        .primitive => |primitive| try evalPrimitiveCall(ir, page_id, context, mode, env, functions, current_origin, call, primitive),
    };
}

const BuiltinContext = struct {
    ir: *doc.Document,
    page_id: core.NodeId,
    eval_context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,

    pub fn checkArityRange(self: *const BuiltinContext, actual: usize, min: usize, max: usize) !void {
        try validateArityRange(actual, min, max, self.current_origin);
    }

    pub fn currentPageValue(self: *const BuiltinContext) !core.Value {
        if (self.eval_context != .page) return error.NoCurrentPage;
        return .{ .page = self.page_id };
    }

    pub fn currentDocumentValue(self: *const BuiltinContext) core.Value {
        return .{ .document = self.ir.document_id };
    }

    pub fn runSelectCall(self: *BuiltinContext, call: CallExpr) anyerror!core.Value {
        return try evalSelectCall(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.current_origin, call);
    }

    pub fn evalExprValue(self: *BuiltinContext, expr: Expr) anyerror!core.Value {
        return try evalExpr(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.current_origin, expr);
    }

    pub fn evalStringArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror![]const u8 {
        return try evalCallStringArg(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.current_origin, call, index);
    }

    pub fn evalPropertyStringArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror![]const u8 {
        return try resolveValuePropertyString(self.ir.allocator, try self.evalExprValue(call.args.items[index]));
    }

    pub fn evalNumberArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!f32 {
        return try evalCallNumberArg(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.current_origin, call, index);
    }

    pub fn evalObjectArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.NodeId {
        return try evalCallObjectArg(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.current_origin, call, index);
    }

    pub fn evalAnchorArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.AnchorValue {
        return try evalCallAnchorArg(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.current_origin, call, index);
    }

    pub fn evalRoleArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.Role {
        return try evalCallRoleArg(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.current_origin, call, index);
    }

    pub fn evalPayloadArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!names.ParsedPayload {
        return try evalCallPayloadArg(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.current_origin, call, index);
    }

    pub fn evalStyleArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.StyleRef {
        return try evalCallStyleArg(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, self.current_origin, call, index);
    }

    pub fn ownString(self: *BuiltinContext, text: []u8) ![]const u8 {
        return try self.ir.ownString(text);
    }

    pub fn materializeForUse(self: *BuiltinContext, value: core.Value) !core.Value {
        return try normalizeForUse(self.ir, self.mode, value);
    }

    pub fn anchorValueForObject(self: *BuiltinContext, node_id: core.NodeId, anchor_name: []const u8) !core.Value {
        const anchor = names.parseAnchorName(anchor_name) orelse {
            reportNamedResolutionError(error.UnknownAnchor, "anchor", anchor_name, self.current_origin);
            return error.UnknownAnchor;
        };
        return .{ .anchor = .{ .node = .{ .node_id = node_id, .anchor = anchor } } };
    }

    pub fn pageAnchorValue(self: *BuiltinContext, anchor_name: []const u8) !core.Value {
        const anchor = names.parseAnchorName(anchor_name) orelse {
            reportNamedResolutionError(error.UnknownAnchor, "anchor", anchor_name, self.current_origin);
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
        return switch (self.mode) {
            .attached => try self.ir.makeObjectWithOrigin(self.page_id, role_name, role, object_kind, payload_kind, content, self.current_origin),
            .detached => |builder| blk: {
                const id = try self.ir.makeDetachedObjectWithOrigin(self.page_id, role_name, role, object_kind, payload_kind, content, self.current_origin);
                try builder.trackNode(self.ir.allocator, id);
                break :blk id;
            },
        };
    }

    pub fn makeGroup(self: *BuiltinContext, child_ids: []const core.NodeId) !core.NodeId {
        if (self.eval_context != .page) return error.NoCurrentPage;
        return switch (self.mode) {
            .attached => try self.ir.makeGroupWithOrigin(self.page_id, true, child_ids, self.current_origin),
            .detached => |builder| blk: {
                const id = try self.ir.makeGroupWithOrigin(self.page_id, false, child_ids, self.current_origin);
                try builder.trackNode(self.ir.allocator, id);
                break :blk id;
            },
        };
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
        return switch (self.mode) {
            .attached => try self.ir.makeObjectWithOrigin(page_id, role_name, role, object_kind, payload_kind, content, self.current_origin),
            .detached => |builder| blk: {
                const id = try self.ir.makeDetachedObjectWithOrigin(page_id, role_name, role, object_kind, payload_kind, content, self.current_origin);
                try builder.trackNode(self.ir.allocator, id);
                break :blk id;
            },
        };
    }

    pub fn makeGroupOnPage(self: *BuiltinContext, page_id: core.NodeId, child_ids: []const core.NodeId) !core.NodeId {
        return switch (self.mode) {
            .attached => try self.ir.makeGroupWithOrigin(page_id, true, child_ids, self.current_origin),
            .detached => |builder| blk: {
                const id = try self.ir.makeGroupWithOrigin(page_id, false, child_ids, self.current_origin);
                try builder.trackNode(self.ir.allocator, id);
                break :blk id;
            },
        };
    }

    pub fn setNodeProperty(self: *BuiltinContext, object_id: core.NodeId, key: []const u8, value: []const u8) !void {
        try self.ir.setNodeProperty(object_id, key, value);
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
        const func = self.functions.get(function.name) orelse {
            reportUnknownFunction(function.name, self.current_origin);
            return error.UnknownFunction;
        };
        return try invokeUserFunctionValues(self.ir, self.page_id, self.eval_context, self.mode, self.env, self.functions, func, self.current_origin, args);
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
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    const base = try normalizeForUse(ir, mode, try evalExpr(ir, page_id, context, mode, env, functions, current_origin, call.args.items[0]));
    const op_name = try evalCallStringArg(ir, page_id, context, mode, env, functions, current_origin, call, 1);
    const sema = SemanticEnv.init(null, null, functions);
    const descriptor = sema.query(op_name) orelse {
        reportUnknownQuery(op_name, current_origin);
        return error.UnknownQuery;
    };
    registry.validateQueryArity(descriptor, call.args.items.len) catch |err| {
        if (err == error.InvalidArity) try validateFixedArity(call.args.items.len, descriptor.arity, current_origin);
        return err;
    };
    try contracts.ensureValueSortWithCode(ir, null, base, descriptor.input_sort, current_origin, .UnmatchedInputType);
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
            const role = try evalCallRoleArg(ir, page_id, context, mode, env, functions, current_origin, call, 2);
            return try ir.select(ir.allocator, base, core.Query.pageObjectsByRole(role));
        },
        .document_objects_by_role => {
            const role = try evalCallRoleArg(ir, page_id, context, mode, env, functions, current_origin, call, 2);
            return try ir.select(ir.allocator, base, core.Query.documentObjectsByRole(role));
        },
    }
}

fn validateFixedArity(actual: usize, expected: usize, origin: []const u8) !void {
    if (actual != expected) {
        reportLowerDiagnostic(.{
            .err = error.InvalidArity,
            .span = error_report.spanFromOrigin(origin),
            .data = .{ .invalid_arity = .{ .actual = actual, .min = expected, .max = expected } },
        });
        return error.InvalidArity;
    }
}

fn validateUserFunctionArity(actual: usize, func: FunctionDecl, origin: []const u8) !void {
    const range = eval_functions.arity(func);
    if (actual < range.min or actual > range.max) {
        reportLowerDiagnostic(.{
            .err = error.InvalidArity,
            .span = error_report.spanFromOrigin(origin),
            .data = .{ .invalid_arity = .{ .actual = actual, .min = range.min, .max = range.max } },
        });
        return error.InvalidArity;
    }
}

fn validateArityRange(actual: usize, min: usize, max: usize, origin: []const u8) !void {
    if (actual < min or actual > max) {
        reportLowerDiagnostic(.{
            .err = error.InvalidArity,
            .span = error_report.spanFromOrigin(origin),
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
    func: FunctionDecl,
    current_origin: []const u8,
    call: CallExpr,
) !void {
    for (func.params.items, 0..) |param, index| {
        const value = if (index < call.args.items.len)
            try evalExpr(ir, page_id, context, mode, caller_env, functions, current_origin, call.args.items[index])
        else
            try evalExpr(ir, page_id, context, mode, local_env, functions, current_origin, (param.default_value orelse return error.InvalidArity).*);
        contracts.ensureValueSortWithCode(ir, page_id, value, param.sort, current_origin, .UnmatchedArgumentType) catch |err| {
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
    func: FunctionDecl,
    current_origin: []const u8,
    args: []const core.Value,
) !void {
    try eval_functions.requireArity(args.len, func);
    for (func.params.items, 0..) |param, index| {
        const value = if (index < args.len)
            try args[index].clone(ir.allocator)
        else
            try evalExpr(ir, page_id, context, mode, local_env, functions, current_origin, (param.default_value orelse return error.InvalidArity).*);
        contracts.ensureValueSortWithCode(ir, page_id, value, param.sort, current_origin, .UnmatchedArgumentType) catch |err| {
            var owned = value;
            owned.deinit(ir.allocator);
            return err;
        };
        try putEnvValue(ir.allocator, local_env, param.name, value);
    }
    _ = caller_env;
}

fn fragmentRootToValue(allocator: std.mem.Allocator, fragment: *const core.Fragment) !core.Value {
    const root = fragment.root orelse unreachable;
    return switch (root) {
        .document => |id| .{ .document = id },
        .page => |id| .{ .page = id },
        .object => |id| .{ .object = id },
        .selection => |selection| .{ .selection = try selection.clone(allocator) },
        .anchor => |anchor| .{ .anchor = anchor },
        .function => |function| .{ .function = try function.clone(allocator) },
        .style => |style| .{ .style = style },
        .string => |text| .{ .string = text },
        .number => |number| .{ .number = number },
        .boolean => |boolean| .{ .boolean = boolean },
        .constraints => |constraints| .{ .constraints = try constraints.clone(allocator) },
    };
}

fn fragmentRootCloneFromFragment(allocator: std.mem.Allocator, fragment: *const core.Fragment) !core.FragmentRoot {
    const root = fragment.root orelse unreachable;
    return try root.clone(allocator);
}

fn normalizeForUse(ir: *doc.Document, mode: EvalMode, value: core.Value) !core.Value {
    return switch (value) {
        .code => |code| switch (code.root) {
            .document => |id| .{ .document = id },
            .page => |id| .{ .page = id },
            .object => |id| .{ .object = id },
            .selection => |selection| .{ .selection = try selection.clone(ir.allocator) },
        },
        .fragment => |fragment| switch (mode) {
            .attached => blk: {
                try ir.materializeFragment(fragment);
                break :blk try fragmentRootToValue(ir.allocator, fragment);
            },
            .detached => |builder| blk: {
                try builder.trackFragment(ir.allocator, fragment);
                break :blk try fragmentRootToValue(ir.allocator, fragment);
            },
        },
        else => value,
    };
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

fn resolveValueStyle(value: core.Value) !core.StyleRef {
    return switch (value) {
        .style => |style| style,
        else => return error.ExpectedStyleArgument,
    };
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
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.Value {
    return try evalExpr(ir, page_id, context, mode, env, functions, current_origin, call.args.items[index]);
}

fn evalCallStringArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror![]const u8 {
    return try resolveValueString(try evalCallArg(ir, page_id, context, mode, env, functions, current_origin, call, index));
}

fn evalCallNumberArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!f32 {
    return try resolveValueNumber(try evalCallArg(ir, page_id, context, mode, env, functions, current_origin, call, index));
}

fn evalCallObjectArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.NodeId {
    return try resolveValueObjectId(ir, mode, try evalCallArg(ir, page_id, context, mode, env, functions, current_origin, call, index));
}

fn evalCallAnchorArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.AnchorValue {
    return try resolveValueAnchor(try evalCallArg(ir, page_id, context, mode, env, functions, current_origin, call, index));
}

fn evalCallStyleArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.StyleRef {
    return try resolveValueStyle(try evalCallArg(ir, page_id, context, mode, env, functions, current_origin, call, index));
}

fn evalCallRoleArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.Role {
    const role_name = try evalCallStringArg(ir, page_id, context, mode, env, functions, current_origin, call, index);
    return names.parseRoleName(role_name) orelse {
        reportNamedResolutionError(error.UnknownRole, "role", role_name, current_origin);
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
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!names.ParsedPayload {
    const payload_name = try evalCallStringArg(ir, page_id, context, mode, env, functions, current_origin, call, index);
    return names.parsePayloadName(payload_name) orelse {
        reportNamedResolutionError(error.UnknownPayloadKind, "payload kind", payload_name, current_origin);
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
    last_code_like: *?core.NodeId,
    stmt: Statement,
    origin_override: ?[]const u8,
) anyerror!ExecFlow {
    const origin = if (origin_override) |override| override else try statementOrigin(ir.allocator, stmt.span);
    switch (stmt.kind) {
        .let_binding => |binding| {
            const value = try evalExpr(ir, page_id, context, mode, env, functions, origin, binding.expr);
            try putEnvValue(ir.allocator, env, binding.name, value);
        },
        .return_expr => |expr| {
            const value = try evalExpr(ir, page_id, context, mode, env, functions, origin, expr);
            return .{ .returned = value };
        },
        .property_set => |property_set| {
            const base = env.get(property_set.object_name) orelse return error.UnknownIdentifier;
            const object_id = try resolveValueObjectId(ir, mode, base);
            const value = try evalExpr(ir, page_id, context, mode, env, functions, origin, property_set.value);
            defer {
                var owned = value;
                owned.deinit(ir.allocator);
            }
            const text = try resolveValuePropertyString(ir.allocator, value);
            defer if (eval_value.propertyStringNeedsFree(value)) ir.allocator.free(text);
            try ir.setNodeProperty(object_id, property_set.property_name, text);
        },
        .if_stmt => |if_stmt| {
            const value = try evalExpr(ir, page_id, context, mode, env, functions, origin, if_stmt.condition);
            const condition = try resolveValueBoolean(value);
            const branch = if (condition) if_stmt.then_statements.items else if_stmt.else_statements.items;
            var branch_env = try cloneValueEnv(ir.allocator, env);
            defer deinitValueEnv(ir.allocator, &branch_env);
            for (branch) |nested| {
                const flow = try executeStatement(ir, page_id, context, mode, &branch_env, functions, last_code_like, nested, null);
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
                const value = try evalExpr(ir, page_id, context, mode, env, functions, origin, expr);
                break :blk try resolveValueNumber(value);
            } else 0;
            switch (mode) {
                .attached => try ir.addAnchorConstraint(target.node_id, target.anchor, source, offset, origin),
                .detached => |builder| try builder.constraints.items.append(ir.allocator, .{
                    .target_node = target.node_id,
                    .target_anchor = target.anchor,
                    .source = source,
                    .offset = offset,
                }),
            }
        },
        .expr_stmt => |expr| switch (expr) {
            .call => |call| {
                if (functions.contains(call.name)) {
                    try executeCallStatement(ir, page_id, context, mode, env, functions, last_code_like, origin, call);
                } else {
                    var value = try evalExpr(ir, page_id, context, mode, env, functions, origin, expr);
                    defer value.deinit(ir.allocator);
                    try materializeStatementValue(ir, mode, last_code_like, value);
                }
            },
            else => {
                var value = try evalExpr(ir, page_id, context, mode, env, functions, origin, expr);
                defer value.deinit(ir.allocator);
                try materializeStatementValue(ir, mode, last_code_like, value);
            },
        },
    }
    return .none;
}

fn materializeStatementValue(ir: *doc.Document, mode: EvalMode, last_code_like: *?core.NodeId, value: core.Value) !void {
    switch (mode) {
        .attached => switch (value) {
            .code => |code| switch (code.root) {
                .object => |id| last_code_like.* = id,
                else => {},
            },
            .fragment => |fragment| {
                try ir.materializeFragment(fragment);
                if (fragment.root) |root| {
                    switch (root) {
                        .object => |id| last_code_like.* = id,
                        .constraints => {},
                        else => {},
                    }
                }
            },
            .constraints => |constraints| try ir.addConstraintSet(constraints),
            .object => |id| last_code_like.* = id,
            else => {},
        },
        .detached => |builder| switch (value) {
            .code => |code| switch (code.root) {
                .object => |id| {
                    last_code_like.* = id;
                    try builder.trackNode(ir.allocator, id);
                },
                else => {},
            },
            .constraints => |constraints| try builder.appendConstraintSet(ir.allocator, constraints),
            .object => |id| {
                last_code_like.* = id;
                try builder.trackNode(ir.allocator, id);
            },
            .fragment => |fragment| {
                try builder.trackFragment(ir.allocator, fragment);
                if (fragment.root) |root| {
                    switch (root) {
                        .object => |id| last_code_like.* = id,
                        else => {},
                    }
                }
            },
            else => {},
        },
    }
}

fn fragmentRootFromValue(allocator: std.mem.Allocator, value: core.Value) !core.FragmentRoot {
    return switch (value) {
        .code => |code| try fragmentRootFromCodeRoot(code.root),
        .document => |id| .{ .document = id },
        .page => |id| .{ .page = id },
        .object => |id| .{ .object = id },
        .metadata => error.UnsupportedFragmentRoot,
        .selection => |selection| .{ .selection = try selection.clone(allocator) },
        .anchor => |anchor| .{ .anchor = anchor },
        .function => |function| .{ .function = try function.clone(allocator) },
        .style => |style| .{ .style = style },
        .string => |text| .{ .string = text },
        .number => |number| .{ .number = number },
        .boolean => |boolean| .{ .boolean = boolean },
        .constraints => |constraints| .{ .constraints = try constraints.clone(allocator) },
        .fragment => error.UnsupportedFragmentRoot,
    };
}

fn fragmentRootFromCodeRoot(root: core.CodeRoot) !core.FragmentRoot {
    return switch (root) {
        .document => |id| .{ .document = id },
        .page => |id| .{ .page = id },
        .object => |id| .{ .object = id },
        .selection => |selection| .{ .selection = selection },
    };
}

fn executeCallStatement(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    last_code_like: *?core.NodeId,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!void {
    const func = functions.get(call.name) orelse {
        _ = try evalCall(ir, page_id, context, mode, env, functions, current_origin, call);
        return;
    };
    try validateUserFunctionArity(call.args.items.len, func, current_origin);

    var local_env = try cloneValueEnv(ir.allocator, env);
    defer deinitValueEnv(ir.allocator, &local_env);
    try bindUserFunctionArgs(ir, page_id, context, mode, env, &local_env, functions, func, current_origin, call);
    for (func.statements.items) |inner| {
        const flow = try executeStatement(ir, page_id, context, mode, &local_env, functions, last_code_like, inner, current_origin);
        switch (flow) {
            .none => {},
            .returned => |value| {
                defer {
                    var owned = value;
                    owned.deinit(ir.allocator);
                }
                try contracts.ensureValueSortWithCode(ir, page_id, value, func.result_sort, current_origin, .UnmatchedReturnType);
                try materializeStatementValue(ir, mode, last_code_like, value);
                return;
            },
        }
    }
}

fn invokeUserFunctionValue(
    ir: *doc.Document,
    page_id: core.NodeId,
    context: EvalContext,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    func: FunctionDecl,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    var func_ref = try eval_functions.functionRefFor(ir.allocator, func);
    defer func_ref.deinit(ir.allocator);
    if (!func_ref.returns_value) return error.FunctionDoesNotReturnValue;
    try validateUserFunctionArity(call.args.items.len, func, current_origin);

    var local_env = try cloneValueEnv(ir.allocator, env);
    defer deinitValueEnv(ir.allocator, &local_env);
    try bindUserFunctionArgs(ir, page_id, context, mode, env, &local_env, functions, func, current_origin, call);

    var last_code_like: ?core.NodeId = null;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(ir, page_id, context, mode, &local_env, functions, &last_code_like, inner, current_origin);
        switch (flow) {
            .none => {},
            .returned => |value| {
                try contracts.ensureValueSortWithCode(ir, page_id, value, func.result_sort, current_origin, .UnmatchedReturnType);
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
    func: FunctionDecl,
    current_origin: []const u8,
    args: []const core.Value,
) anyerror!core.Value {
    try eval_functions.requireReturnsValue(func);

    var local_env = try cloneValueEnv(ir.allocator, env);
    defer deinitValueEnv(ir.allocator, &local_env);
    try bindUserFunctionValueArgs(ir, page_id, context, mode, env, &local_env, functions, func, current_origin, args);

    var last_code_like: ?core.NodeId = null;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(ir, page_id, context, mode, &local_env, functions, &last_code_like, inner, current_origin);
        switch (flow) {
            .none => {},
            .returned => |value| {
                try contracts.ensureValueSortWithCode(ir, page_id, value, func.result_sort, current_origin, .UnmatchedReturnType);
                return value;
            },
        }
    }

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
                reportUnknownIdentifier(anchor_ref.node_name.?, current_origin);
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
