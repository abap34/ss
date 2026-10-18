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
const environment = @import("environment.zig");
const Environment = environment.Environment;
const Binding = environment.Binding;
const CaptureIndex = @import("../analysis/captures.zig").Index;

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
    env: Environment,

    fn deinit(self: *Closure) void {
        self.env.deinit();
    }
};

const ClosureStore = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Closure),

    fn init(allocator: std.mem.Allocator) ClosureStore {
        return .{ .allocator = allocator, .items = .empty };
    }

    fn deinit(self: *ClosureStore) void {
        for (self.items.items) |*closure| closure.deinit();
        self.items.deinit(self.allocator);
    }

    fn add(self: *ClosureStore, lambda: ast.LambdaExpr, env: *const Environment, names_to_capture: []const []const u8) !usize {
        var captured = try Environment.capture(self.allocator, env, names_to_capture);
        errdefer captured.deinit();
        const id = self.items.items.len;
        try self.items.append(self.allocator, .{ .lambda = lambda, .env = captured });
        return id;
    }

    fn get(self: *ClosureStore, id: usize) ?Closure {
        if (id >= self.items.items.len) return null;
        return self.items.items[id];
    }
};

const call_frames = @import("frames.zig");

pub const EvalContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *core.DocumentState,
    functions: *const core.FunctionMap,
    closures: ClosureStore,
    module_id: core.SourceModuleId = 0,
    execution_unit: ?usize = null,
    display_inputs: std.ArrayList(std.ArrayList(core.NodeId)) = .empty,
    display_entries: std.AutoHashMap(struct { producer: usize, call_id: u64 }, usize),
    frames: call_frames.Stack,
    elaboration_origin: ?core.SourceOrigin = null,
    declarations: *const declarations.DeclarationIndex,
    captures: *const CaptureIndex,
    name_resolution_cache: analysis_cache.NameResolutionCache,
    cancellation: ?utils.Cancellation,

    pub fn init(allocator: std.mem.Allocator, state: *core.DocumentState, graph: *const execution.ExecutionGraph, options: ExecuteOptions) !EvalContext {
        var result = EvalContext{
            .allocator = allocator,
            .io = options.io,
            .state = state,
            .functions = &state.functions,
            .closures = ClosureStore.init(allocator),
            .display_entries = .init(allocator),
            .frames = call_frames.Stack.init(allocator, options.max_call_frames),
            .declarations = graph.declarations,
            .captures = &graph.captures,
            .name_resolution_cache = analysis_cache.NameResolutionCache.init(allocator),
            .cancellation = options.cancellation,
        };
        errdefer result.deinit();
        try checkCancellation(&result);
        try result.name_resolution_cache.reserve(state);
        try result.display_inputs.resize(allocator, graph.units.items.len);
        @memset(result.display_inputs.items, .empty);
        for (graph.units.items, 0..) |unit, index| {
            if (unit.kind != .display or unit.kind.display.step != 0) continue;
            const display = unit.kind.display;
            try result.display_entries.put(.{ .producer = display.producer, .call_id = display.call_id }, index);
        }
        return result;
    }

    pub fn deinit(self: *EvalContext) void {
        for (self.display_inputs.items) |*inputs| inputs.deinit(self.allocator);
        self.display_inputs.deinit(self.allocator);
        self.display_entries.deinit();
        self.frames.deinit();
        self.closures.deinit();
        self.name_resolution_cache.deinit();
    }

    /// The checked target is selected during analysis. Returned closures remain
    /// valid for this evaluation context, just like ordinary function results.
    pub fn displayValue(self: *EvalContext, id: core.NodeId, target: core.FunctionKey) !core.Value {
        try checkCancellation(self);
        const node = self.state.getNode(id) orelse return error.UnknownNode;
        if (node.discarded) return error.InvalidPlacementParent;
        const placement = node.placement orelse return error.InvalidValueTag;
        const function = self.functions.get(target) orelse return error.UnknownFunction;
        if (!function.isDisplay() or (function.type_params.items.len != 0 and function.instance_id == null)) return error.UnpreparedDisplay;
        const page_id = placement.page_id;
        const origin = node.origin orelse self.state.sourceOrigin(target.module_id, function.span);
        var env = Environment.init(self.state.allocator);
        defer env.deinit();
        return invokeUserFunctionValues(self, page_id, .page, &env, target.module_id, function, origin, &.{.{ .object = id }});
    }

    /// Executes one prepared display unit. The returned child is registered but
    /// not expanded here: its own reads and producers determine when it can run.
    pub fn expandDisplay(self: *EvalContext, id: core.NodeId, target: core.FunctionKey) !core.NodeId {
        try checkCancellation(self);
        const node = self.state.getNode(id) orelse return error.UnknownNode;
        if (node.discarded) return error.InvalidPlacementParent;
        const placement = if (node.placement) |*value| value else return error.InvalidValueTag;
        switch (placement.display) {
            .pending => {},
            .running => return error.DisplayExpansionCycle,
            .native, .group => return error.DisplayTargetMismatch,
            .expanded => |result| {
                if (!result.target.eql(target)) return error.DisplayTargetMismatch;
                return result.child;
            },
        }
        const origin = node.origin;
        placement.display = .running;
        // Evaluation and child registration can grow the node store. Never
        // retain a node pointer across either operation.
        errdefer self.state.getNode(id).?.placement.?.display = .pending;
        var output = try self.displayValue(id, target);
        defer output.deinit(self.state.allocator);
        try checkCancellation(self);
        const child = try self.state.registerPlacement(id, output, origin);
        const parent = self.state.getNode(id).?;
        parent.object_kind = .overlay;
        parent.placement.?.display = .{ .expanded = .{ .target = target, .child = child } };
        return child;
    }

    pub fn expandDisplayTarget(self: *EvalContext, id: core.NodeId, target: core.native_display.Target) ![]const core.NodeId {
        switch (target) {
            .group => {
                try checkCancellation(self);
                const node = self.state.getNode(id) orelse return error.UnknownNode;
                const placement = node.placement orelse return error.InvalidValueTag;
                if (placement.value != .group) return error.InvalidValueTag;
                switch (placement.display) {
                    .pending => {},
                    .group => return self.state.childrenOf(id) orelse &.{},
                    else => return error.DisplayTargetMismatch,
                }
                const children = try self.state.registerPlacementChildren(id, placement.value.group.children.items, node.origin);
                const parent = self.state.getNode(id).?;
                parent.object_kind = .overlay;
                parent.placement.?.display = .group;
                return children;
            },
            .function => |function| {
                _ = try self.expandDisplay(id, function);
                return self.state.childrenOf(id) orelse return error.InvalidDisplayPlan;
            },
            .native => |kind| {
                try checkCancellation(self);
                const node = self.state.getNode(id) orelse return error.UnknownNode;
                if (node.discarded) return error.InvalidPlacementParent;
                const placement = if (node.placement) |*value| value else return error.InvalidValueTag;
                core.native_display.validateValue(self.state, placement.value, kind) catch |err| switch (err) {
                    error.InvalidFontAwesomeIcon => {
                        const source = placement.value.record.field("source").?.string;
                        const origin = core.ContentProvenance.originForSpan(self.state.stringProvenance(source), 0, source.len) orelse node.origin;
                        try self.state.addValidationDiagnostic(.@"error", placement.page_id, id, origin, .{
                            .user_report = .{
                                .code = "InvalidFontAwesomeIcon",
                                .message = try std.fmt.allocPrint(self.state.allocator, "Unknown Font Awesome icon '{s}'. Use a bundled icon name such as 'fa-solid:star'.", .{source}),
                            },
                        });
                        return err;
                    },
                    else => return err,
                };
                switch (placement.display) {
                    .pending => {},
                    .native => |existing| {
                        if (existing != kind) return error.DisplayTargetMismatch;
                        return &.{};
                    },
                    .running => return error.DisplayExpansionCycle,
                    .expanded, .group => return error.DisplayTargetMismatch,
                }
                const payload_kind: core.PayloadKind = switch (kind) {
                    .text, .code, .icon => .text,
                    .latex => .latex,
                    .image => .image_ref,
                    .pdf => .pdf_ref,
                    .path_shape => .text,
                };
                if (kind == .image or kind == .pdf) {
                    const path = placement.value.record.field("path").?.string;
                    const origin = core.ContentProvenance.originForSpan(self.state.stringProvenance(path), 0, path.len) orelse node.origin;
                    try validateAssetPath(self.state, placement.page_id, id, path, payload_kind, origin);
                }
                if (kind == .pdf) {
                    const style = placement.value.record.field("style").?.record;
                    const page = style.field("asset").?.record.field("pdf_page").?.number;
                    if (core.render_policy.pdfPageNumber(page) == null) {
                        try self.state.addValidationDiagnostic(.@"error", placement.page_id, id, node.origin, .{
                            .asset_invalid = .{ .reason = try self.state.allocator.dupe(u8, "PDF page number must be a positive integer within the supported range") },
                        });
                    }
                }
                node.object_kind = switch (kind) {
                    .text, .code, .latex => .text,
                    .image, .pdf, .icon => .asset,
                    .path_shape => .text,
                };
                node.payload_kind = payload_kind;
                placement.display = .{ .native = kind };
                return &.{};
            },
        }
    }
};

pub const ExecuteOptions = struct {
    io: std.Io,
    max_call_frames: u32 = call_frames.default_max_frames,
    cancellation: ?utils.Cancellation = null,
};

fn enterCall(
    evaluation: *EvalContext,
    module_id: core.SourceModuleId,
    origin: core.SourceOrigin,
    captured: ?*const Environment,
) !*call_frames.Frame {
    try checkCancellation(evaluation);
    const frame = evaluation.frames.push(module_id, evaluation.module_id, origin, captured) catch |err| {
        if (err == error.EvaluationResourceLimit) {
            try evaluation.state.addValidationDiagnostic(.@"error", null, null, origin, .{
                .user_report = .{
                    .code = "EvaluationResourceLimit",
                    .message = try std.fmt.allocPrint(evaluation.state.allocator, "evaluation exceeded its limit of {d} active call frames", .{evaluation.frames.maximum}),
                },
            });
        }
        return err;
    };
    evaluation.module_id = frame.module_id;
    return frame;
}

fn leaveCall(evaluation: *EvalContext, frame: *call_frames.Frame) void {
    evaluation.module_id = frame.caller_module_id;
    evaluation.frames.pop(frame);
}

fn checkCancellation(evaluation: *EvalContext) !void {
    if (evaluation.cancellation) |cancellation| try cancellation.check();
}

fn resolvedFunction(evaluation: *EvalContext, sema: *const SemanticEnv, callee: ast.CallableName) !?semantic_env.ResolvedFunction {
    return evaluation.name_resolution_cache.resolvedFunction(sema, callee);
}

const LowerDiagnostic = struct {
    err: anyerror,
    origin: ?core.SourceOrigin,
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

fn reportUnknownFunction(state: *core.DocumentState, name: []const u8, origin: core.SourceOrigin) !void {
    try reportNamedResolutionError(state, error.UnknownFunction, "function", name, origin);
}

fn reportUnknownCallable(state: *core.DocumentState, sema: *const SemanticEnv, callee: ast.CallableName, origin: core.SourceOrigin) !void {
    switch (sema.resolveFunction(callee)) {
        .unknown_alias => |alias| try reportNamedResolutionError(state, error.UnknownFunction, "import alias", alias, origin),
        else => {
            const name = try callee.displayAlloc(state.allocator);
            defer state.allocator.free(name);
            try reportUnknownFunction(state, name, origin);
        },
    }
}

fn reportUnknownQuery(state: *core.DocumentState, name: []const u8, origin: core.SourceOrigin) !void {
    try reportNamedResolutionError(state, error.UnknownQuery, "query", name, origin);
}

fn reportUnknownIdentifier(state: *core.DocumentState, name: []const u8, origin: core.SourceOrigin) !void {
    try reportNamedResolutionError(state, error.UnknownIdentifier, "identifier", name, origin);
}

fn reportNamedResolutionError(state: *core.DocumentState, err: anyerror, kind: []const u8, name: []const u8, origin: core.SourceOrigin) !void {
    try reportLowerDiagnostic(state, .{
        .err = err,
        .origin = origin,
        .data = .{ .unknown_name = .{ .kind = kind, .name = name } },
    });
}

fn reportLowerError(state: *core.DocumentState, err: anyerror, origin: ?core.SourceOrigin) !void {
    try reportLowerDiagnostic(state, .{
        .err = err,
        .origin = origin,
        .data = .generic,
    });
}

fn reportDuplicatePropertyDefinition(state: *core.DocumentState, origin: core.SourceOrigin, node_id: core.NodeId, key: []const u8) !void {
    const message = if (state.conflictingPropertyDefinition(node_id, key)) |previous| blk: {
        if (previous.origin) |previous_origin| {
            if (previous_origin.span) |span| {
                break :blk try std.fmt.allocPrint(state.allocator, "property '{s}' is already defined on this target; overlaps '{s}' at {s}:bytes:{d}-{d}", .{ key, previous.path, previous_origin.path orelse "<unknown>", span.start, span.end });
            }
        }
        break :blk try std.fmt.allocPrint(state.allocator, "property '{s}' is already defined on this target; overlaps '{s}'", .{ key, previous.path });
    } else try std.fmt.allocPrint(state.allocator, "property '{s}' is already defined on this target", .{key});
    try state.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{
            .code = "DuplicatePropertyDefinition",
            .message = message,
        },
    });
}

fn reportDuplicateContentDefinition(state: *core.DocumentState, origin: core.SourceOrigin) !void {
    try state.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .code = "DuplicateContentDefinition", .message = try state.allocator.dupe(u8, "object content is already defined") },
    });
}

fn reportDuplicateReprDefinition(state: *core.DocumentState, origin: core.SourceOrigin) !void {
    try state.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .code = "DuplicateReprDefinition", .message = try state.allocator.dupe(u8, "object repr is already defined") },
    });
}

fn reportRecordUpdateError(state: *core.DocumentState, origin: core.SourceOrigin, code: []const u8, comptime fmt: []const u8, args: anytype) !void {
    try state.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{
            .code = code,
            .message = try std.fmt.allocPrint(state.allocator, fmt, args),
        },
    });
}

fn reportInvalidTypeConstruction(state: *core.DocumentState, origin: core.SourceOrigin, type_name: []const u8) !void {
    try state.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{
            .code = "InvalidTypeConstruction",
            .message = try std.fmt.allocPrint(state.allocator, "{s} is an enum type; use {s}.<case>", .{ type_name, type_name }),
        },
    });
}

fn reportLowerDiagnostic(state: *core.DocumentState, diagnostic: LowerDiagnostic) !void {
    var message_buf: [256]u8 = undefined;
    const message = formatLowerDiagnostic(&message_buf, diagnostic);
    try state.addValidationDiagnostic(.@"error", null, null, diagnostic.origin, .{
        .user_report = .{ .code = lowerDiagnosticCode(diagnostic), .message = try state.allocator.dupe(u8, message) },
    });
}

fn formatLowerDiagnostic(buf: []u8, diagnostic: LowerDiagnostic) []const u8 {
    return switch (diagnostic.data) {
        .unknown_name => |data| std.fmt.bufPrint(buf, "unknown {s}: {s}", .{ data.kind, data.name }) catch "unknown name",
        .invalid_arity => |data| blk: {
            if (data.min == data.max) {
                break :blk std.fmt.bufPrint(buf, "expected {d}, got {d}", .{ data.min, data.actual }) catch formatGenericLowerDiagnostic(buf, diagnostic.err);
            }
            break :blk std.fmt.bufPrint(buf, "expected {d}..{d}, got {d}", .{ data.min, data.max, data.actual }) catch formatGenericLowerDiagnostic(buf, diagnostic.err);
        },
        .invalid_value_tag => |data| std.fmt.bufPrint(buf, "expected {s}, got {s}", .{ @tagName(data.expected), @tagName(data.actual) }) catch formatGenericLowerDiagnostic(buf, diagnostic.err),
        .generic => formatGenericLowerDiagnostic(buf, diagnostic.err),
    };
}

fn lowerDiagnosticCode(diagnostic: LowerDiagnostic) []const u8 {
    return switch (diagnostic.data) {
        .unknown_name => |data| unknownNameCode(data.kind),
        .invalid_arity => "InvalidArity",
        .invalid_value_tag => "InvalidValueTag",
        .generic => if (lowerErrorMessage(diagnostic.err) != null) @errorName(diagnostic.err) else "LoweringFailed",
    };
}

fn unknownNameCode(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "function")) return "UnknownFunction";
    if (std.mem.eql(u8, kind, "import alias")) return "UnknownModuleAlias";
    if (std.mem.eql(u8, kind, "query")) return "UnknownQuery";
    if (std.mem.eql(u8, kind, "identifier")) return "UnknownIdentifier";
    if (std.mem.eql(u8, kind, "type")) return "UnknownType";
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
        "document evaluation could not finish: {s}",
        .{utils.err.formatErrorReason(&reason_buf, err)},
    ) catch "document evaluation could not finish; please report this as an ss bug";
}

fn lowerErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ReturnOutsideFunction => "return is only valid inside a function",
        error.InvalidLibraryModule => "imported modules must contain functions, constants, and imports only",
        error.InvalidArity => "wrong number of arguments",
        error.InvalidValueTag => "value has the wrong semantic kind",
        error.RecursiveFunction => "recursive functions are not allowed",
        error.RecursiveConst => "recursive constants are not allowed",
        error.EmptySelection => "selection is empty",
        error.InvalidSelectionItemType => "selection item kinds do not match",
        error.InvalidSelectionMutation => "primitive callbacks must not add objects or pages to the selection being iterated",
        error.LayoutDependencyCycle => "layout reads cannot feed object creation, content, properties, or constraints because layout is solved once",
        error.PostLayoutComputationUnsupported => "layout-reading scheduled computations are not implemented yet",
        error.ExecutionDependencyCycle => "document evaluation dependencies contain a cycle",
        error.DuplicatePlacement => "object is already placed on a page",
        error.DuplicateObjectParent => "object occurs under multiple parents in the placed group",
        error.DuplicateContentDefinition => "object content is already defined",
        error.DuplicatePropertyDefinition => "property is already defined on this target",
        error.DuplicateReprDefinition => "object repr is already defined",
        error.ExpectedSelection => "expected a selection value",
        error.ExpectedConstraintSet => "expected a constraint set",
        error.ExpectedStringArgument => "expected a string argument",
        error.ExpectedNumberArgument => "expected a number argument",
        error.ExpectedPathCommand => "expected a PathCommand argument",
        error.InvalidPathArity => "path expects between 1 and 255 commands",
        error.InvalidPathCommandOrder => "drawing commands require an open subpath",
        error.InvalidPathVerb => "unknown path command verb",
        error.MissingPathCommandField => "path command field is missing",
        error.InvalidPathCommandField => "path command field has the wrong type",
        error.NonFinitePathCoordinate => "path coordinates must be finite",
        error.InvalidArcRadius => "arc radii must not be negative",
        error.ExpectedAnchor => "expected an anchor argument",
        error.ExpectedObject => "expected an object argument",
        error.NoCurrentPage => "this operation is only valid inside a page block",
        error.UnknownAnchor => "unknown anchor",
        error.UnknownRole => "unknown role",
        error.UnknownPayloadKind => "unknown payload kind",
        error.PageCannotBeConstraintTarget => "page anchors cannot be constraint targets",
        error.UnsupportedDocumentEvaluationPrimitive => "this operation is not valid during document evaluation",
        error.FunctionDidNotReturnValue => "function did not return a value",
        error.EvaluationResourceLimit => "evaluation exhausted its call-frame resource limit",
        else => null,
    };
}

pub fn executeGraph(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    graph: *const execution.ExecutionGraph,
    options: ExecuteOptions,
) !void {
    var evaluation_context = try EvalContext.init(allocator, state, graph, options);
    defer evaluation_context.deinit();
    const evaluation = &evaluation_context;
    var document_states = std.AutoHashMap(core.SourceModuleId, DocumentExecutionState).init(allocator);
    defer {
        var iter = document_states.valueIterator();
        while (iter.next()) |execution_state| execution_state.deinit();
        document_states.deinit();
    }
    var page_states = std.AutoHashMap(core.NodeId, PageExecutionState).init(allocator);
    defer {
        var iter = page_states.valueIterator();
        while (iter.next()) |execution_state| execution_state.deinit();
        page_states.deinit();
    }
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordWysiwyg(.execute_units, measure_start);
        for (graph.order) |unit_index| {
            evaluation.execution_unit = unit_index;
            try executeUnit(evaluation, &document_states, &page_states, graph.units.items[unit_index]);
        }
        evaluation.execution_unit = null;
    }
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordWysiwyg(.materialize_display, measure_start);
        try materializeDisplayContent(evaluation);
    }
}

fn materializeDisplayContent(evaluation: *EvalContext) !void {
    const state = evaluation.state;
    var env = Environment.init(state.allocator);
    defer env.deinit();

    var index: usize = 0;
    while (index < state.graph.nodes.items.len) : (index += 1) {
        try checkCancellation(evaluation);
        const node_id = state.graph.nodes.items[index].id;
        const node = state.getNode(node_id) orelse continue;
        if (node.kind != .object) continue;
        const function = if (node.repr_function) |repr_function|
            repr_function
        else
            continue;

        const page_id = state.parentPageOf(node_id) orelse state.graph.document_id;
        const scope: EvalScope = if (page_id == state.graph.document_id) .document else .page;
        const origin: core.SourceOrigin = node.origin orelse .{};
        const error_count = diagnosticErrorCount(state);
        const text = evalNodeReprWithFunction(evaluation, page_id, scope, &env, origin, node_id, function) catch |err| {
            if (err == error.Canceled) return err;
            if (diagnosticErrorCount(state) == error_count) try reportLowerError(state, err, origin);
            return err;
        };
        try state.setNodeDisplayContent(node_id, text);
    }
}

const DocumentExecutionState = struct {
    env: Environment,

    fn init(allocator: std.mem.Allocator) DocumentExecutionState {
        return .{ .env = Environment.init(allocator) };
    }

    fn deinit(self: *DocumentExecutionState) void {
        self.env.deinit();
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
    const previous_cursor = state.graph.composition_cursor;
    state.graph.composition_cursor = .{ .source_order = unit.source_order };
    defer state.graph.composition_cursor = previous_cursor;
    const previous_module_id = evaluation.module_id;
    std.debug.assert(evaluation.frames.depth == 0);
    evaluation.module_id = unit.module_id;
    defer evaluation.module_id = previous_module_id;
    switch (unit.kind) {
        .display => |display| {
            const plan = state.displays.plans.items[display.plan];
            const step = plan.steps.items[display.step];
            const index = evaluation.execution_unit.?;
            const inputs = evaluation.display_inputs.items[index].items;
            const first_unit = index - display.step;
            for (step.children.items) |child_step| {
                try evaluation.display_inputs.items[first_unit + child_step].ensureUnusedCapacity(evaluation.allocator, inputs.len);
            }
            for (inputs) |id| {
                const children = try evaluation.expandDisplayTarget(id, step.target);
                if (children.len != step.children.items.len) return error.InvalidDisplayPlan;
                for (children, step.children.items) |child, child_step| {
                    evaluation.display_inputs.items[first_unit + child_step].appendAssumeCapacity(child);
                }
            }
        },
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
    const flow = executeStatement(evaluation, state.graph.document_id, .document, &execution_state.env, stmt, null) catch |err| {
        if (err == error.Canceled) return err;
        const origin = state.sourceOrigin(evaluation.module_id, stmt.span);
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
    const flow = executeStatement(evaluation, page_id, .page, &execution_state.env, stmt, null) catch |err| {
        if (err == error.Canceled) return err;
        const origin = state.sourceOrigin(evaluation.module_id, stmt.span);
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
    for (state.diagnostics.entries.items) |diagnostic| {
        if (diagnostic.severity == .@"error") count += 1;
    }
    return count;
}

fn evalExpr(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *Environment,
    current_origin: core.SourceOrigin,
    expr: Expr,
) anyerror!core.Value {
    const state = evaluation.state;
    const functions = evaluation.functions;
    try checkCancellation(evaluation);
    return switch (expr) {
        .hole => error.HoleExpression,
        .ident => |ident| blk: {
            const name = ident.name;
            const sema = SemanticEnv.init(state, evaluation.declarations, functions).forModule(evaluation.module_id);
            switch (try evaluation.name_resolution_cache.resolveValue(&sema, core.Value, ast.CallableName.bare(name), env.get(name))) {
                .local => |value| break :blk try value.clone(state.allocator),
                .constant => |resolved| break :blk try evalConstValue(evaluation, page_id, scope, current_origin, resolved),
                .function => |resolved| break :blk .{ .function = try eval_functions.functionRefForInModule(state.allocator, resolved.module_id, resolved.decl) },
                .primitive, .unknown => {},
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
    const origin = state.sourceOrigin(evaluation.module_id, source_span);
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
    current_origin: core.SourceOrigin,
    resolved: semantic_env.ResolvedConst,
) anyerror!core.Value {
    const state = evaluation.state;
    if (state.constants.values.get(resolved.key)) |value| return try value.clone(state.allocator);
    if (state.constants.eval_states.get(resolved.key)) |eval_state| {
        if (eval_state == 1) return error.RecursiveConst;
    }
    try state.constants.eval_states.put(resolved.key, 1);
    var state_committed = false;
    errdefer {
        if (!state_committed) _ = state.constants.eval_states.remove(resolved.key);
    }

    var local_env = Environment.init(state.allocator);
    defer local_env.deinit();

    const previous_module_id = evaluation.module_id;
    evaluation.module_id = resolved.module_id;
    defer evaluation.module_id = previous_module_id;

    const start_node_count = state.nodeCount();
    var value = try evalExpr(evaluation, page_id, scope, &local_env, current_origin, resolved.decl.value);
    var value_moved = false;
    errdefer if (!value_moved) value.deinit(state.allocator);
    try value_contracts.ensureValueConformsToType(state, page_id, value, resolved.decl.value_type, current_origin, .UnmatchedReturnType);
    try markReturnedValueOrigins(state, value, start_node_count, current_origin);
    try state.constants.values.put(resolved.key, value);
    value_moved = true;
    try state.constants.eval_states.put(resolved.key, 2);
    state_committed = true;
    return try state.constants.values.get(resolved.key).?.clone(state.allocator);
}

fn evalMember(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *Environment,
    current_origin: core.SourceOrigin,
    member: ast.MemberExpr,
) !core.Value {
    const state = evaluation.state;
    const functions = evaluation.functions;
    if (borrowLocalValue(env, member.target.*)) |target| {
        if (target == .record or target == .group) return evalMemberValue(state, functions, target, member.name);
    }
    var target = try evalExpr(evaluation, page_id, scope, env, current_origin, member.target.*);
    defer target.deinit(state.allocator);
    if (member.optional and target == .none) return .{ .none = {} };
    return evalMemberValue(state, functions, target, member.name);
}

fn borrowLocalValue(env: *const Environment, expr: Expr) ?core.Value {
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
    if (target == .group) {
        if (std.mem.eql(u8, name, "gap")) return .{ .number = target.group.gap };
        return error.UnknownField;
    }
    if (target == .record) {
        const value = target.record.field(name) orelse return .{ .none = {} };
        return try value.clone(state.allocator);
    }
    if (target == .object) {
        const node = state.getNode(target.object) orelse return error.UnknownNode;
        if (node.placement != null) return eval_value.placementMember(state, node.id, name);
    }
    if (target == .object or target == .page) {
        if (names.parseAnchorName(name)) |anchor| {
            return .{ .anchor = if (target == .object)
                .{ .node = .{ .node_id = target.object, .anchor = anchor } }
            else
                .{ .page = .{ .page_id = target.page, .anchor = anchor } } };
        }
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
    env: *Environment,
    current_origin: core.SourceOrigin,
    record: ast.RecordExpr,
) !core.Value {
    const state = evaluation.state;
    const instance = state.type_instances.construction(record);
    const resolved = (if (instance) |concrete| declarations.RecordDescriptor{
        .decl = &concrete.declaration,
        .name = concrete.declaration.name,
        .module_id = concrete.ty.nominal_module_id.?,
    } else findRecordDecl(state, record.module_id, record.type_name)) orelse {
        if (findEnumDecl(state, record.module_id, record.type_name) != null) {
            try reportInvalidTypeConstruction(state, current_origin, record.type_name);
            return error.InvalidType;
        }
        try reportNamedResolutionError(state, error.UnknownType, "type", record.type_name, current_origin);
        return error.UnknownType;
    };
    const caller_module_id = evaluation.module_id;
    defer evaluation.module_id = caller_module_id;

    if (resolved.decl.type_params.items.len != 0) return error.InvalidType;
    var value = core.RecordValue.init(if (instance) |concrete|
        try concrete.ty.clone(state.allocator)
    else
        ast.Type.recordType(resolved.decl.name).inModule(resolved.module_id));
    errdefer value.deinit(state.allocator);

    var default_env = Environment.init(state.allocator);
    defer default_env.deinit();
    evaluation.module_id = resolved.module_id;
    for (resolved.decl.fields.items) |field| {
        if (record.hasField(field.name)) continue;
        const default_expr = field.default_value orelse {
            try reportRecordUpdateError(state, current_origin, "MissingField", "value of type '{s}' requires field '{s}'", .{ record.type_name, field.name });
            return error.InvalidType;
        };
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

fn evalRecordDefaults(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    current_origin: core.SourceOrigin,
    record_id: core.NominalId,
) !core.RecordValue {
    const state = evaluation.state;
    const resolved = findRecordDecl(state, record_id.module_id, record_id.name) orelse {
        try reportNamedResolutionError(state, error.UnknownType, "type", record_id.name, current_origin);
        return error.UnknownType;
    };
    const caller_module_id = evaluation.module_id;
    defer evaluation.module_id = caller_module_id;

    var value = core.RecordValue.init(ast.Type.recordType(resolved.decl.name).inModule(resolved.module_id));
    errdefer value.deinit(state.allocator);

    var default_env = Environment.init(state.allocator);
    defer default_env.deinit();
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
    env: *Environment,
    current_origin: core.SourceOrigin,
    update: ast.RecordUpdateExpr,
) !core.Value {
    const state = evaluation.state;
    var target = try evalExpr(evaluation, page_id, scope, env, current_origin, update.target.*);
    errdefer target.deinit(state.allocator);
    if (target != .record and target != .group) {
        try reportRecordUpdateError(state, current_origin, "InvalidValueUpdate", "with expects a value with fields", .{});
        return error.InvalidValueTag;
    }

    for (update.fields.items) |field| {
        var field_value = try evalExpr(evaluation, page_id, scope, env, current_origin, field.value);
        var field_value_moved = false;
        errdefer if (!field_value_moved) field_value.deinit(state.allocator);
        updateRecordFieldPath(state.allocator, &target, field.path.items, field_value) catch |err| switch (err) {
            error.InvalidValueTag => {
                const path = try ast.formatRecordPath(state.allocator, field.path.items);
                defer state.allocator.free(path);
                try reportRecordUpdateError(state, current_origin, "InvalidValueUpdatePath", "'{s}' does not resolve to a nested value with fields", .{path});
                return err;
            },
            error.UnknownField => {
                const path = try ast.formatRecordPath(state.allocator, field.path.items);
                defer state.allocator.free(path);
                try reportRecordUpdateError(state, current_origin, "MissingField", "value update path '{s}' is not present at runtime", .{path});
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
    target: *core.Value,
    path: []const ast.RecordPathSegment,
    value: core.Value,
) !void {
    if (path.len == 0) return error.UnknownField;
    if (target.* == .group) {
        if (!std.mem.eql(u8, path[0].name, "gap")) return error.UnknownField;
        if (path.len != 1 or value != .number) return error.InvalidValueTag;
        target.group.gap = value.number;
        return;
    }
    if (target.* != .record) return error.InvalidValueTag;
    if (path.len == 1) {
        try putRecordFieldValue(allocator, &target.record, path[0].name, value, true);
        return;
    }
    for (target.record.fields.items) |*field| {
        if (!std.mem.eql(u8, field.name, path[0].name)) continue;
        try updateRecordFieldPath(allocator, &field.value, path[1..], value);
        return;
    }
    return error.UnknownField;
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
    origin: core.SourceOrigin,
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
        try reportRecordUpdateError(state, origin, "InvalidValueUpdatePath", "ss produced a type without a resolved declaration while evaluating this update; report this as an ss bug with the source file", .{});
        return error.InvalidType;
    };
    return evalRecordDefaults(evaluation, page_id, scope, origin, record_id);
}

fn cloneTaggedRecordForRuntime(state: *core.DocumentState, record: core.RecordValue) anyerror!core.RecordValue {
    var cloned = core.RecordValue.init(try record.ty.clone(state.allocator));
    errdefer cloned.deinit(state.allocator);
    try retainTypeNames(state, &cloned.ty);
    for (record.fields.items) |field| {
        const name = try state.copyString(field.name);
        const value = try cloneTaggedValueForRuntime(state, field.value);
        try putRecordFieldValue(state.allocator, &cloned, name, value, field.explicit);
    }
    return cloned;
}

fn retainTypeNames(state: *core.DocumentState, ty: *ast.Type) anyerror!void {
    if (ty.class_name) |name| ty.class_name = try state.copyString(name);
    if (ty.enum_name) |name| ty.enum_name = try state.copyString(name);
    for (ty.mutableArguments()) |*argument| try retainTypeNames(state, argument);
    for (ty.fn_params) |*parameter| try retainTypeNames(state, parameter);
    if (ty.fn_result) |result| try retainTypeNames(state, result);
    if (ty.optional_child) |child| try retainTypeNames(state, child);
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
    env: *Environment,
    current_origin: core.SourceOrigin,
    call: CallExpr,
) anyerror!core.Value {
    const state = evaluation.state;
    const functions = evaluation.functions;
    const sema = SemanticEnv.init(state, evaluation.declarations, functions).forModule(evaluation.module_id);
    const binding = try evaluation.name_resolution_cache.resolveValue(&sema, core.Value, call.callee, env.get(call.callee.name));
    return switch (binding) {
        .local => |value| blk: {
            const func_ref = switch (value) {
                .function => |func| func,
                else => {
                    try reportUnknownFunction(state, call.callee.name, current_origin);
                    return error.UnknownFunction;
                },
            };
            var args = try evalCallArgs(evaluation, page_id, scope, env, current_origin, call.args.items);
            defer deinitCallArgs(state.allocator, &args);
            break :blk try invokeFunctionRef(evaluation, page_id, scope, env, func_ref, current_origin, args.items(.value));
        },
        .constant => |resolved| blk: {
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
            defer deinitCallArgs(state.allocator, &args);
            break :blk try invokeFunctionRef(evaluation, page_id, scope, env, function, current_origin, args.items(.value));
        },
        .function => |resolved| blk: {
            try validateUserFunctionArity(state, call.args.items.len, resolved.decl, current_origin);
            var args = try evalCallArgs(evaluation, page_id, scope, env, current_origin, call.args.items);
            defer deinitCallArgs(state.allocator, &args);
            const previous_origin = evaluation.elaboration_origin;
            evaluation.elaboration_origin = elaboratedCallOrigin(evaluation, call) orelse previous_origin;
            defer evaluation.elaboration_origin = previous_origin;
            break :blk try invokeUserFunctionValues(evaluation, page_id, scope, env, resolved.module_id, resolved.decl, current_origin, args.items(.value));
        },
        .primitive => |primitive| try evalPrimitiveCall(evaluation, page_id, scope, env, current_origin, call, primitive),
        .unknown => {
            try reportUnknownCallable(state, &sema, call.callee, current_origin);
            return error.UnknownFunction;
        },
    };
}

fn evalLambda(
    evaluation: *EvalContext,
    env: *Environment,
    lambda: ast.LambdaExpr,
) !core.Value {
    const closures = &evaluation.closures;
    const free_names = evaluation.captures.names(lambda) orelse return error.MissingLambdaCaptures;
    const id = try closures.add(lambda, env, free_names);
    return .{ .function = .{
        .name = "#lambda",
        .module_id = evaluation.module_id,
        .closure_id = id,
    } };
}

fn evalApply(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *Environment,
    current_origin: core.SourceOrigin,
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
    defer deinitCallArgs(state.allocator, &args);
    return try invokeFunctionRef(evaluation, page_id, scope, env, function, current_origin, args.items(.value));
}

const CallArguments = std.MultiArrayList(Binding);

fn deinitCallArgs(allocator: std.mem.Allocator, args: *CallArguments) void {
    for (args.items(.value), args.items(.owned)) |*value, owned| {
        if (owned) value.deinit(allocator);
    }
    args.deinit(allocator);
}

fn evalArgument(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *Environment,
    current_origin: core.SourceOrigin,
    expr: Expr,
) !Binding {
    try checkCancellation(evaluation);
    if (borrowLocalValue(env, expr)) |value| return .{ .value = value, .owned = false };
    return .{ .value = try evalExpr(evaluation, page_id, scope, env, current_origin, expr), .owned = true };
}

fn evalCallArgs(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *Environment,
    current_origin: core.SourceOrigin,
    args: []const Expr,
) !CallArguments {
    const state = evaluation.state;
    var values = CallArguments{};
    errdefer deinitCallArgs(state.allocator, &values);
    try values.ensureTotalCapacity(state.allocator, args.len);
    for (args) |arg| {
        values.appendAssumeCapacity(try evalArgument(evaluation, page_id, scope, env, current_origin, arg));
    }
    return values;
}

fn evalNodeRepr(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *Environment,
    current_origin: core.SourceOrigin,
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
    env: *Environment,
    current_origin: core.SourceOrigin,
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
    env: *Environment,
    current_origin: core.SourceOrigin,

    pub fn checkArityRange(self: *const BuiltinContext, actual: usize, min: usize, max: usize) !void {
        try validateArityRange(self.state, actual, min, max, self.current_origin);
    }

    pub fn currentPageValue(self: *const BuiltinContext) !core.Value {
        if (self.scope != .page) return error.NoCurrentPage;
        return .{ .page = self.page_id };
    }

    pub fn currentDocumentValue(self: *const BuiltinContext) core.Value {
        return .{ .document = self.state.graph.document_id };
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

    pub fn pageAnchorValue(self: *BuiltinContext, page_id: core.NodeId, anchor_name: []const u8) !core.Value {
        const anchor = names.parseAnchorName(anchor_name) orelse {
            try reportNamedResolutionError(self.state, error.UnknownAnchor, "anchor", anchor_name, self.current_origin);
            return error.UnknownAnchor;
        };
        return .{ .anchor = .{ .page = .{ .page_id = page_id, .anchor = anchor } } };
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

    pub fn makeGroup(self: *BuiltinContext, child_ids: []const core.NodeId, composition: ?ast.GroupComposition) !core.NodeId {
        const id = try self.state.createGroupWithOrigin(child_ids, self.current_origin);
        // Removed with the remaining legacy Object constructors. Typed groups
        // keep the configuration in their immutable input instead of fields.
        if (composition) |mode| {
            const axis: core.Value = .{ .string = if (mode.isHorizontal()) "horizontal" else "vertical" };
            const depth = self.evaluation.frames.depth;
            try self.state.setNodeFieldValueWithOrigin(id, "join_axis", axis, depth, self.current_origin);
            if (mode.equal()) try self.state.setNodeFieldValueWithOrigin(id, "split_axis", axis, depth, self.current_origin);
            try self.state.setNodeFieldValueWithOrigin(id, "split_gap", .{ .number = 32 }, depth, self.current_origin);
            try self.state.setNodeFieldValueWithOrigin(id, "align_children_y", .{ .boolean = mode.isHorizontal() }, depth, self.current_origin);
        }
        return id;
    }

    pub fn makePage(self: *BuiltinContext, title: []const u8) !core.NodeId {
        return try self.state.addPage(title);
    }

    pub fn placeObjectOnPage(self: *BuiltinContext, page_id: core.NodeId, object_id: core.NodeId) !void {
        try self.state.placeObjectOnPage(page_id, object_id);
    }

    pub fn registerPlacement(self: *BuiltinContext, page_id: core.NodeId, input: core.Value, call_id: ?u64) !core.NodeId {
        const call = call_id orelse return error.UnpreparedDisplay;
        const plan_index = self.state.displays.call_targets.get(call) orelse return error.UnpreparedDisplay;
        const plan = self.state.displays.plans.items[plan_index];
        if (!ast.Type.eql(input.presentationType() orelse return error.InvalidValueTag, plan.steps.items[0].input)) return error.InvalidValueTag;
        const producer = self.evaluation.execution_unit orelse return error.UnpreparedDisplay;
        const unit = self.evaluation.display_entries.get(.{ .producer = producer, .call_id = call }) orelse return error.UnpreparedDisplay;
        const inputs = &self.evaluation.display_inputs.items[unit];
        try inputs.ensureUnusedCapacity(self.evaluation.allocator, 1);
        const id = try self.state.registerPlacement(page_id, input, self.current_origin);
        inputs.appendAssumeCapacity(id);
        return id;
    }

    pub fn setNodeFieldValue(self: *BuiltinContext, object_id: core.NodeId, key: []const u8, value: core.Value) !void {
        self.state.setNodeFieldValueWithOrigin(object_id, key, value, self.evaluation.frames.depth, self.current_origin) catch |err| switch (err) {
            error.DuplicatePropertyDefinition => {
                try reportDuplicatePropertyDefinition(self.state, self.current_origin, object_id, key);
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

    pub fn registerConstraints(self: *BuiltinContext, page_id: core.NodeId, rules: []const core.Constraint) !void {
        try registerConstraintsOnPage(self.evaluation, page_id, rules, self.current_origin);
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
    env: *Environment,
    current_origin: core.SourceOrigin,
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
    origin: core.SourceOrigin,
    severity: core.DiagnosticSeverity,
    message: []const u8,
) !void {
    try state.addValidationDiagnostic(
        severity,
        page_id,
        null,
        origin,
        .{ .user_report = .{ .code = "UserReport", .message = try state.allocator.dupe(u8, message) } },
    );
}

fn validateAssetExists(state: *core.DocumentState, page_id: core.NodeId, object_id: core.NodeId, origin: core.SourceOrigin) !void {
    const node = state.getNode(object_id) orelse return error.UnknownNode;
    const diagnostic_origin = assetContentDiagnosticOrigin(node, origin);
    if (node.object_kind == null or node.object_kind.? != .asset or core.nodeContent(node) == null) {
        try state.addValidationDiagnostic(.@"error", page_id, object_id, diagnostic_origin, .{
            .asset_invalid = .{
                .reason = try state.allocator.dupe(u8, "expected an asset object with a path"),
                .payload_kind = node.payload_kind,
            },
        });
        return;
    }

    try validateAssetPath(state, page_id, object_id, core.nodeContent(node).?, node.payload_kind, diagnostic_origin);
}

fn validateAssetPath(
    state: *core.DocumentState,
    page_id: core.NodeId,
    object_id: core.NodeId,
    requested: []const u8,
    payload_kind: ?core.PayloadKind,
    origin: ?core.SourceOrigin,
) !void {
    if (state.file_inputs) |inputs| try inputs.record(state.asset_base_dir, requested, .file);
    const resolved = try resolveAssetPath(state.allocator, state.asset_base_dir, requested);
    var resolved_owned = true;
    defer if (resolved_owned) state.allocator.free(resolved);
    if (!try fs_utils.fileExists(state.allocator, resolved)) {
        const requested_path = try state.allocator.dupe(u8, requested);
        resolved_owned = false;
        try state.addValidationDiagnostic(.@"error", page_id, object_id, origin, .{
            .asset_not_found = .{
                .requested_path = requested_path,
                .resolved_path = resolved,
                .payload_kind = payload_kind,
            },
        });
        return;
    }
}

fn assetContentDiagnosticOrigin(node: *const core.Node, fallback: core.SourceOrigin) core.SourceOrigin {
    const content = core.nodeContent(node) orelse return fallback;
    return core.ContentProvenance.originForSpan(node.content_provenance.items, 0, content.len) orelse fallback;
}

const resolveAssetPath = utils.fs.resolveAssetPath;

fn evalSelectCall(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *Environment,
    current_origin: core.SourceOrigin,
    call: CallExpr,
) anyerror!core.Value {
    const state = evaluation.state;
    const functions = evaluation.functions;
    var base = try evalExpr(evaluation, page_id, scope, env, current_origin, call.args.items[0]);
    defer base.deinit(state.allocator);
    if (call.type_args.items.len != 0) {
        if (call.type_args.items.len != 1 or call.args.items.len != 1) return error.InvalidArity;
        return .{ .selection = try state.selectTypedPlacements(state.allocator, base, call.type_args.items[0]) };
    }
    if (call.args.items.len < 2) return error.InvalidArity;
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
        .self_placement => {
            return try state.select(state.allocator, base, core.Query.selfPlacement());
        },
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

fn validateFixedArity(state: *core.DocumentState, actual: usize, expected: usize, origin: core.SourceOrigin) !void {
    if (actual != expected) {
        try reportLowerDiagnostic(state, .{
            .err = error.InvalidArity,
            .origin = origin,
            .data = .{ .invalid_arity = .{ .actual = actual, .min = expected, .max = expected } },
        });
        return error.InvalidArity;
    }
}

fn validateUserFunctionArity(state: *core.DocumentState, actual: usize, func: FunctionDecl, origin: core.SourceOrigin) !void {
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

fn validateArityRange(state: *core.DocumentState, actual: usize, min: usize, max: usize, origin: core.SourceOrigin) !void {
    if (actual < min or actual > max) {
        try reportLowerDiagnostic(state, .{
            .err = error.InvalidArity,
            .origin = origin,
            .data = .{ .invalid_arity = .{ .actual = actual, .min = min, .max = max } },
        });
        return error.InvalidArity;
    }
}

fn bindFunctionArgument(
    state: *core.DocumentState,
    page_id: core.NodeId,
    local_env: *Environment,
    param: ast.ParamDecl,
    current_origin: core.SourceOrigin,
    binding: Binding,
) !void {
    value_contracts.ensureValueConformsToType(state, page_id, binding.value, param.ty, current_origin, .UnmatchedArgumentType) catch |err| {
        var owned = binding;
        owned.deinit(state.allocator);
        return err;
    };
    try local_env.put(param.name, binding);
}

fn bindUserFunctionValueArgs(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    caller_env: *Environment,
    local_env: *Environment,
    module_id: core.SourceModuleId,
    func: FunctionDecl,
    current_origin: core.SourceOrigin,
    args: []const core.Value,
) !void {
    const state = evaluation.state;
    try validateUserFunctionArity(state, args.len, func, current_origin);
    for (func.params.items, 0..) |param, index| {
        const binding: Binding = if (index < args.len)
            .{ .value = args[index], .owned = false }
        else blk: {
            const previous_module_id = evaluation.module_id;
            evaluation.module_id = module_id;
            defer evaluation.module_id = previous_module_id;
            break :blk try evalArgument(evaluation, page_id, scope, local_env, current_origin, (param.default_value orelse return error.InvalidArity).*);
        };
        try bindFunctionArgument(state, page_id, local_env, param, current_origin, binding);
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
    env: *Environment,
    current_origin: core.SourceOrigin,
    call: CallExpr,
    index: usize,
) anyerror!core.Value {
    return try evalExpr(evaluation, page_id, scope, env, current_origin, call.args.items[index]);
}

fn evalCallStringArg(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *Environment,
    current_origin: core.SourceOrigin,
    call: CallExpr,
    index: usize,
) anyerror![]const u8 {
    return try resolveValueString(try evalCallArg(evaluation, page_id, scope, env, current_origin, call, index));
}

fn evalCallNumberArg(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *Environment,
    current_origin: core.SourceOrigin,
    call: CallExpr,
    index: usize,
) anyerror!f32 {
    return try resolveValueNumber(try evalCallArg(evaluation, page_id, scope, env, current_origin, call, index));
}

fn evalCallObjectArg(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *Environment,
    current_origin: core.SourceOrigin,
    call: CallExpr,
    index: usize,
) anyerror!core.NodeId {
    return try resolveValueObjectId(try evalCallArg(evaluation, page_id, scope, env, current_origin, call, index));
}

fn evalCallRoleArg(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *Environment,
    current_origin: core.SourceOrigin,
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
    env: *Environment,
    current_origin: core.SourceOrigin,
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
    origin: core.SourceOrigin,
) !core.ConstraintSet {
    const state = evaluation.state;
    return switch (target) {
        .page => error.PageCannotBeConstraintTarget,
        .node => |node| try singleConstraintSet(state, .{
            .target_node = node.node_id,
            .target_anchor = node.anchor,
            .source = source.toConstraintSource(),
            .offset = offset + source.offset() - target.offset(),
            .origin = origin,
            .role = core.constraintRoleForRelation(node.node_id, node.anchor, source.toConstraintSource()),
            .page_id = if (source == .page) source.page.page_id else null,
        }),
    };
}

fn registerConstraintsOnPage(evaluation: *EvalContext, page_id: core.NodeId, rules: []const core.Constraint, origin: core.SourceOrigin) !void {
    const state = evaluation.state;
    const page = state.getNode(page_id) orelse return error.ExpectedPage;
    if (page.kind != .page) return error.ExpectedPage;
    for (rules) |rule| {
        if (rule.page_id) |required_page| {
            if (required_page != page_id) {
                try state.addValidationDiagnostic(.@"error", page_id, rule.target_node, origin, .{
                    .user_report = .{ .code = "CrossPageConstraint", .message = try state.allocator.dupe(u8, "constraint page anchor refers to a different page from its registration") },
                });
                return error.DiagnosticsFailed;
            }
        }
    }
    try state.constraints.active.ensureUnusedCapacity(state.allocator, rules.len);
    for (rules) |rule| {
        var registered = rule;
        registered.page_id = page_id;
        registered.scope_depth = evaluation.frames.depth;
        registered.origin = origin;
        state.constraints.active.appendAssumeCapacity(registered);
    }
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
    origin: core.SourceOrigin,
    scope_depth: u32,
) !void {
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
    state.setNodeFieldValueWithOrigin(node_id, field_name, value, scope_depth, origin) catch |err| switch (err) {
        error.DuplicatePropertyDefinition => {
            try reportDuplicatePropertyDefinition(state, origin, node_id, field_name);
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
    origin: core.SourceOrigin,
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
    origin: core.SourceOrigin,
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
    origin: core.SourceOrigin,
    node_id: core.NodeId,
    path: []const ast.RecordPathSegment,
    value: core.Value,
) !void {
    const state = evaluation.state;
    const functions = evaluation.functions;
    if (path.len == 0) return error.ExpectedObject;
    const property_name = path[0].name;
    if (path.len == 1) {
        try writeNodeFieldValue(state, node_id, property_name, value, origin, evaluation.frames.depth);
        return;
    }

    const path_text = try ast.formatRecordPath(state.allocator, path);
    defer state.allocator.free(path_text);
    if (state.conflictingPropertyDefinition(node_id, path_text) != null) {
        try reportDuplicatePropertyDefinition(state, origin, node_id, path_text);
        return error.DuplicatePropertyDefinition;
    }
    const node = state.getNode(node_id) orelse return error.UnknownNode;
    const sema = SemanticEnv.init(state, evaluation.declarations, functions).forModule(evaluation.module_id);
    const maybe_field = if (core.fields.classId(state, node)) |class_name|
        sema.field(class_name, property_name)
    else
        sema.fieldByName(property_name);
    const field = maybe_field orelse return error.InvalidType;
    if (field.value_type.kind != .record) return error.InvalidValueTag;
    var record = core.Value{ .record = try materializePropertyRecord(evaluation, page_id, scope, origin, node, property_name, field.value_type) };
    defer record.deinit(state.allocator);

    var value_copy = try value.clone(state.allocator);
    var value_moved = false;
    defer if (!value_moved) value_copy.deinit(state.allocator);
    updateRecordFieldPath(state.allocator, &record, path[1..], value_copy) catch |err| switch (err) {
        error.InvalidValueTag => {
            try reportRecordUpdateError(state, origin, "InvalidValueUpdatePath", "'{s}' does not resolve to a nested value with fields", .{path_text});
            return err;
        },
        error.UnknownField => {
            try reportRecordUpdateError(state, origin, "MissingField", "value update path '{s}' is not present at runtime", .{path_text});
            return err;
        },
        else => return err,
    };
    value_moved = true;
    state.defineNodeFieldPath(node_id, property_name, path_text, record, evaluation.frames.depth, origin) catch |err| switch (err) {
        error.DuplicatePropertyDefinition => {
            try reportDuplicatePropertyDefinition(state, origin, node_id, path_text);
            return err;
        },
        else => return err,
    };
}

fn executeStatement(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *Environment,
    stmt: Statement,
    origin_override: ?core.SourceOrigin,
) anyerror!ExecFlow {
    const state = evaluation.state;
    try checkCancellation(evaluation);
    const origin = origin_override orelse evaluation.elaboration_origin orelse state.sourceOrigin(evaluation.module_id, stmt.span);
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
            if (scope == .page and evaluation.frames.depth == 0) {
                try addValueObjectSources(state, page_id, evaluation.module_id, binding.name, null, stmt.span, value);
            }
            try env.putOwned(binding.name, value);
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
            var branch_env = Environment.child(state.allocator, env);
            defer branch_env.deinit();
            for (branch) |nested| {
                const flow = try executeStatement(evaluation, page_id, scope, &branch_env, nested, null);
                switch (flow) {
                    .none => {},
                    .returned => return flow,
                }
            }
        },
        .constrain => |decl| {
            if (scope != .page) return error.NoCurrentPage;
            const target = try resolveAnchorRef(state, env, origin, page_id, decl.target, true);
            const source_value: ?core.AnchorValue = if (decl.source) |source_ref|
                try resolveAnchorRef(state, env, origin, page_id, source_ref, false)
            else
                null;
            const resolved_source: ?core.ConstraintSource = if (source_value) |value| value.toConstraintSource() else null;
            if (source_value) |value| {
                if (value == .page and value.page.page_id != page_id) {
                    try state.addValidationDiagnostic(.@"error", page_id, target.node_id, origin, .{
                        .user_report = .{ .code = "CrossPageConstraint", .message = try state.allocator.dupe(u8, "constraint page anchor refers to a different page from its registration") },
                    });
                    return error.DiagnosticsFailed;
                }
            }
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
                .add => try registerConstraintsOnPage(evaluation, page_id, &.{.{
                    .target_node = target.node_id,
                    .target_anchor = target.anchor,
                    .source = resolved_source orelse return error.InvalidConstraint,
                    .offset = offset,
                    .origin = origin,
                    .role = role,
                }}, origin),
                .update => try state.constraints.addUpdate(
                    state.allocator,
                    target.node_id,
                    target.anchor,
                    role,
                    evaluation.frames.depth,
                    resolved_source,
                    offset,
                    origin,
                ),
            }
        },
        .expr_stmt => |expr| {
            var value = try evalExpr(evaluation, page_id, scope, env, origin, expr);
            defer value.deinit(state.allocator);
            if (scope == .page and evaluation.frames.depth == 0) {
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

fn markReturnedValueOrigins(state: *core.DocumentState, value: core.Value, start_node_count: usize, origin: core.SourceOrigin) !void {
    switch (value) {
        .object => |id| try state.markReturnedObjectOrigins(id, start_node_count, origin),
        .record => |record| {
            for (record.fields.items) |field| try markReturnedValueOrigins(state, field.value, start_node_count, origin);
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

fn invokeFunctionRef(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *Environment,
    function: core.FunctionRef,
    current_origin: core.SourceOrigin,
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
    caller_env: *Environment,
    module_id: core.SourceModuleId,
    closure_id: usize,
    current_origin: core.SourceOrigin,
    args: []const core.Value,
) anyerror!core.Value {
    const state = evaluation.state;
    const closures = &evaluation.closures;
    _ = caller_env;
    const closure = closures.get(closure_id) orelse {
        try reportUnknownFunction(state, "#lambda", current_origin);
        return error.UnknownFunction;
    };
    try validateFixedArity(state, args.len, closure.lambda.params.items.len, current_origin);

    const frame = try enterCall(evaluation, module_id, current_origin, &closure.env);
    defer leaveCall(evaluation, frame);
    const local_env = &frame.environment;
    for (closure.lambda.params.items, 0..) |param, index| {
        const value = args[index];
        try value_contracts.ensureValueConformsToType(state, page_id, value, param.ty, current_origin, .UnmatchedArgumentType);
        try local_env.putBorrowed(param.name, value);
    }
    const start_node_count = state.nodeCount();
    var value = try evalExpr(evaluation, page_id, scope, local_env, current_origin, closure.lambda.body.*);
    errdefer value.deinit(state.allocator);
    try markReturnedValueOrigins(state, value, start_node_count, current_origin);
    return value;
}

fn elaboratedCallOrigin(evaluation: *EvalContext, call: CallExpr) ?core.SourceOrigin {
    const qualifier = call.callee.qualifier orelse return null;
    if (!std.mem.startsWith(u8, qualifier, "std:")) return null;
    return evaluation.state.sourceOrigin(evaluation.module_id, call.callee.name_span orelse return null);
}

fn invokeUserFunctionValues(
    evaluation: *EvalContext,
    page_id: core.NodeId,
    scope: EvalScope,
    env: *Environment,
    module_id: core.SourceModuleId,
    func: FunctionDecl,
    current_origin: core.SourceOrigin,
    args: []const core.Value,
) anyerror!core.Value {
    const state = evaluation.state;
    const frame = try enterCall(evaluation, module_id, current_origin, null);
    defer leaveCall(evaluation, frame);
    const local_env = &frame.environment;
    try bindUserFunctionValueArgs(evaluation, page_id, scope, env, local_env, module_id, func, current_origin, args);

    const start_node_count = state.nodeCount();
    for (func.statements.items) |inner| {
        const flow = try executeStatement(evaluation, page_id, scope, local_env, inner, evaluation.elaboration_origin);
        switch (flow) {
            .none => {},
            .returned => |result| {
                var value = result;
                errdefer value.deinit(state.allocator);
                try value_contracts.ensureValueConformsToType(state, page_id, value, func.result_type, current_origin, .UnmatchedReturnType);
                try markReturnedValueOrigins(state, value, start_node_count, evaluation.elaboration_origin orelse current_origin);
                return value;
            },
        }
    }

    if (func.result_type.kind == .void) return .{ .void = {} };
    return error.FunctionDidNotReturnValue;
}

fn resolveAnchorRef(
    state: *core.DocumentState,
    env: *Environment,
    current_origin: core.SourceOrigin,
    page_id: core.NodeId,
    anchor_ref: AnchorRef,
    comptime is_target: bool,
) !if (is_target) ResolvedTarget else core.AnchorValue {
    switch (anchor_ref.kind) {
        .page => {
            if (is_target) return error.PageCannotBeConstraintTarget;
            return .{ .page = .{ .page_id = page_id, .anchor = anchor_ref.anchor } };
        },
        .node => {
            var value = try resolveAnchorPathValue(state, env, current_origin, anchor_ref.node_path orelse anchor_ref.node_name.?);
            defer value.deinit(state.allocator);
            if (!is_target and value == .page) return .{ .page = .{ .page_id = value.page, .anchor = anchor_ref.anchor } };
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
    env: *Environment,
    current_origin: core.SourceOrigin,
    path: []const u8,
) !core.Value {
    var iter = std.mem.splitScalar(u8, path, '.');
    const first = iter.next() orelse return error.UnknownIdentifier;
    const base = env.get(first) orelse {
        try reportUnknownIdentifier(state, first, current_origin);
        return error.UnknownIdentifier;
    };
    var current = try base.clone(state.allocator);
    errdefer current.deinit(state.allocator);
    while (iter.next()) |field_name| {
        const next = switch (current) {
            .object => |id| try eval_value.placementMember(state, id, field_name),
            .record => |record| blk: {
                const field_value = record.field(field_name) orelse {
                    try reportUnknownIdentifier(state, field_name, current_origin);
                    return error.UnknownIdentifier;
                };
                break :blk try field_value.clone(state.allocator);
            },
            else => return error.InvalidValueTag,
        };
        current.deinit(state.allocator);
        current = next;
    }
    return current;
}
