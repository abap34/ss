const std = @import("std");
const core = @import("core");
const builtin = @import("builtin.zig");
const doc = @import("doc.zig");
const utils = @import("utils");
const error_report = utils.err;
const fs_utils = utils.fs;
const ast = @import("ast");
const names = @import("../language/names.zig");
const registry = @import("../language/registry.zig");
const typecheck = @import("../analysis/typecheck.zig");

const Program = ast.Program;
const FunctionDecl = ast.FunctionDecl;
const Statement = ast.Statement;
const Expr = ast.Expr;
const CallExpr = ast.CallExpr;
const AnchorRef = ast.AnchorRef;

const ExecFlow = union(enum) {
    none,
    returned: core.Value,
};

const EvalMode = union(enum) {
    attached,
    detached: *DetachedBuilder,
};

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

fn reportUnknownFunction(name: []const u8, origin: []const u8) void {
    reportNamedResolutionError(error.UnknownFunction, "function", name, origin);
}

fn reportUnknownQuery(name: []const u8, origin: []const u8) void {
    reportNamedResolutionError(error.UnknownQuery, "query", name, origin);
}

fn reportUnknownTransform(name: []const u8, origin: []const u8) void {
    reportNamedResolutionError(error.UnknownTransform, "transform", name, origin);
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
    if (std.mem.eql(u8, kind, "transform")) return "UnknownTransform";
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
        error.UnknownAnchor => "UnknownAnchor: unknown anchor",
        error.UnknownRole => "UnknownRole: unknown role",
        error.UnknownPayloadKind => "UnknownPayloadKind: unknown payload kind",
        error.PageCannotBeConstraintTarget => "PageCannotBeConstraintTarget: page anchors cannot be constraint targets",
        error.MissingHighlightTarget => "MissingHighlightTarget: highlight needs a previous code-like object",
        error.UnsupportedFragmentRoot => "UnsupportedFragmentRoot: unsupported fragment root",
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
    diagnostic_source = source;
    diagnostic_path = path;
    diagnostic_reported = false;

    for (program.pages.items) |page| {
        const page_id = try ir.addPage(page.name);
        var last_code_like: ?core.NodeId = null;
        var env = std.StringHashMap(core.Value).init(ir.allocator);
        defer env.deinit();

        for (page.statements.items) |stmt| {
            const flow = executeStatement(ir, page_id, .attached, &env, functions, &last_code_like, stmt, null) catch |err| {
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
}

fn evalExpr(
    ir: *doc.Document,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    expr: Expr,
) anyerror!core.Value {
    return switch (expr) {
        .ident => |name| blk: {
            if (env.get(name)) |value| break :blk value;
            if (functions.get(name)) |func| {
                if (func.kind == .constant) {
                    break :blk try invokeUserFunctionValue(ir, page_id, mode, env, functions, func, current_origin, .{
                        .name = name,
                        .args = std.ArrayList(Expr).empty,
                    });
                }
            }
            reportUnknownIdentifier(name, current_origin);
            break :blk error.UnknownIdentifier;
        },
        .string => |text| .{ .string = text },
        .number => |value| .{ .number = value },
        .call => |call| try evalCall(ir, page_id, mode, env, functions, current_origin, call),
    };
}

fn evalCall(
    ir: *doc.Document,
    page_id: core.NodeId,
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
                return try invokeUserFunctionValue(ir, page_id, mode, env, functions, func, current_origin, call);
            },
            else => {},
        }
    }
    if (functions.get(call.name)) |func| {
        if (func.kind == .constant) {
            reportUnknownFunction(call.name, current_origin);
            return error.UnknownFunction;
        }
        if (!typecheck.functionContract(func).returns_value) return error.FunctionDoesNotReturnValue;
        return try invokeUserFunctionValue(ir, page_id, mode, env, functions, func, current_origin, call);
    }
    if (registry.lookupPrimitiveCall(call.name)) |descriptor| {
        return try evalPrimitiveCall(ir, page_id, mode, env, functions, current_origin, call, descriptor);
    }
    reportUnknownFunction(call.name, current_origin);
    return error.UnknownFunction;
}

const BuiltinContext = struct {
    ir: *doc.Document,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,

    pub fn checkArityRange(self: *const BuiltinContext, actual: usize, min: usize, max: usize) !void {
        try validateArityRange(actual, min, max, self.current_origin);
    }

    pub fn currentPageValue(self: *const BuiltinContext) core.Value {
        return .{ .page = self.page_id };
    }

    pub fn currentDocumentValue(self: *const BuiltinContext) core.Value {
        return .{ .document = self.ir.document_id };
    }

    pub fn runSelectCall(self: *BuiltinContext, call: CallExpr) anyerror!core.Value {
        return try evalSelectCall(self.ir, self.page_id, self.mode, self.env, self.functions, self.current_origin, call);
    }

    pub fn runDeriveCall(self: *BuiltinContext, call: CallExpr) anyerror!core.Value {
        return try evalDeriveCall(self.ir, self.page_id, self.mode, self.env, self.functions, self.current_origin, call);
    }

    pub fn evalExprValue(self: *BuiltinContext, expr: Expr) anyerror!core.Value {
        return try evalExpr(self.ir, self.page_id, self.mode, self.env, self.functions, self.current_origin, expr);
    }

    pub fn evalStringArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror![]const u8 {
        return try evalCallStringArg(self.ir, self.page_id, self.mode, self.env, self.functions, self.current_origin, call, index);
    }

    pub fn evalPropertyStringArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror![]const u8 {
        return try resolveValuePropertyString(self.ir.allocator, try self.evalExprValue(call.args.items[index]));
    }

    pub fn evalNumberArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!f32 {
        return try evalCallNumberArg(self.ir, self.page_id, self.mode, self.env, self.functions, self.current_origin, call, index);
    }

    pub fn evalObjectArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.NodeId {
        return try evalCallObjectArg(self.ir, self.page_id, self.mode, self.env, self.functions, self.current_origin, call, index);
    }

    pub fn evalAnchorArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.AnchorValue {
        return try evalCallAnchorArg(self.ir, self.page_id, self.mode, self.env, self.functions, self.current_origin, call, index);
    }

    pub fn evalRoleArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.Role {
        return try evalCallRoleArg(self.ir, self.page_id, self.mode, self.env, self.functions, self.current_origin, call, index);
    }

    pub fn evalPayloadArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!names.ParsedPayload {
        return try evalCallPayloadArg(self.ir, self.page_id, self.mode, self.env, self.functions, self.current_origin, call, index);
    }

    pub fn evalStyleArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.StyleRef {
        return try evalCallStyleArg(self.ir, self.page_id, self.mode, self.env, self.functions, self.current_origin, call, index);
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
        return switch (self.mode) {
            .attached => try self.ir.makeGroupWithOrigin(self.page_id, true, child_ids, self.current_origin),
            .detached => |builder| blk: {
                const id = try self.ir.makeGroupWithOrigin(self.page_id, false, child_ids, self.current_origin);
                try builder.trackNode(self.ir.allocator, id);
                break :blk id;
            },
        };
    }

    pub fn setNodeProperty(self: *BuiltinContext, object_id: core.NodeId, key: []const u8, value: []const u8) !void {
        try self.ir.setNodeProperty(object_id, key, value);
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
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    const base = try normalizeForUse(ir, mode, try evalExpr(ir, page_id, mode, env, functions, current_origin, call.args.items[0]));
    const op_name = try evalCallStringArg(ir, page_id, mode, env, functions, current_origin, call, 1);
    const descriptor = registry.lookupQueryOp(op_name) orelse {
        reportUnknownQuery(op_name, current_origin);
        return error.UnknownQuery;
    };
    try validateFixedArity(call.args.items.len, descriptor.arity, current_origin);
    try typecheck.ensureValueSortWithCode(ir, null, base, descriptor.input_sort, current_origin, .UnmatchedInputType);
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
        .document_pages => {
            return try ir.select(ir.allocator, base, core.Query.documentPages());
        },
        .page_objects_by_role => {
            const role = try evalCallRoleArg(ir, page_id, mode, env, functions, current_origin, call, 2);
            return try ir.select(ir.allocator, base, core.Query.pageObjectsByRole(role));
        },
        .document_objects_by_role => {
            const role = try evalCallRoleArg(ir, page_id, mode, env, functions, current_origin, call, 2);
            return try ir.select(ir.allocator, base, core.Query.documentObjectsByRole(role));
        },
    }
}

fn evalDeriveCall(
    ir: *doc.Document,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    const base = try normalizeForUse(ir, mode, try evalExpr(ir, page_id, mode, env, functions, current_origin, call.args.items[0]));
    const op_name = try evalCallStringArg(ir, page_id, mode, env, functions, current_origin, call, 1);
    const descriptor = registry.lookupTransformOp(op_name) orelse {
        reportUnknownTransform(op_name, current_origin);
        return error.UnknownTransform;
    };
    try validateArityRange(call.args.items.len, descriptor.min_arity, descriptor.max_arity, current_origin);
    if (descriptor.input_sort) |expected| try typecheck.ensureValueSortWithCode(ir, null, base, expected, current_origin, .UnmatchedInputType);
    switch (descriptor.op) {
        .page_number => {
            return .{ .object = switch (mode) {
                .attached => try ir.deriveWithOrigin(page_id, base, core.Transform.pageNumber(), current_origin),
                .detached => |builder| blk: {
                    const id = try ir.deriveDetachedWithOrigin(page_id, base, core.Transform.pageNumber(), current_origin);
                    try builder.trackNode(ir.allocator, id);
                    break :blk id;
                },
            } };
        },
        .toc => {
            return .{ .object = switch (mode) {
                .attached => try ir.deriveWithOrigin(page_id, base, core.Transform.toc(), current_origin),
                .detached => |builder| blk: {
                    const id = try ir.deriveDetachedWithOrigin(page_id, base, core.Transform.toc(), current_origin);
                    try builder.trackNode(ir.allocator, id);
                    break :blk id;
                },
            } };
        },
        .rewrite_text => {
            const old = try evalCallStringArg(ir, page_id, mode, env, functions, current_origin, call, 2);
            const new = try evalCallStringArg(ir, page_id, mode, env, functions, current_origin, call, 3);
            return .{ .object = switch (mode) {
                .attached => try ir.deriveWithOrigin(page_id, base, core.Transform.rewriteText(old, new), current_origin),
                .detached => |builder| blk: {
                    const id = try ir.deriveDetachedWithOrigin(page_id, base, core.Transform.rewriteText(old, new), current_origin);
                    try builder.trackNode(ir.allocator, id);
                    break :blk id;
                },
            } };
        },
        .highlight => {
            const note = try evalCallStringArg(ir, page_id, mode, env, functions, current_origin, call, 2);
            return .{ .object = try deriveHighlight(ir, page_id, mode, current_origin, base, note) };
        },
    }
}

fn deriveHighlight(
    ir: *doc.Document,
    page_id: core.NodeId,
    mode: EvalMode,
    current_origin: []const u8,
    base: core.Value,
    note: []const u8,
) !core.NodeId {
    return switch (base) {
        .object => |id| blk: {
            const selection = try ir.select(ir.allocator, .{ .object = id }, core.Query.selfObject());
            break :blk switch (mode) {
                .attached => try ir.deriveWithOrigin(page_id, selection, core.Transform.highlight(note), current_origin),
                .detached => |builder| blk2: {
                    const derived = try ir.deriveDetachedWithOrigin(page_id, selection, core.Transform.highlight(note), current_origin);
                    try builder.trackNode(ir.allocator, derived);
                    break :blk2 derived;
                },
            };
        },
        .selection => blk: {
            break :blk switch (mode) {
                .attached => try ir.deriveWithOrigin(page_id, base, core.Transform.highlight(note), current_origin),
                .detached => |builder| blk2: {
                    const derived = try ir.deriveDetachedWithOrigin(page_id, base, core.Transform.highlight(note), current_origin);
                    try builder.trackNode(ir.allocator, derived);
                    break :blk2 derived;
                },
            };
        },
        else => return error.ExpectedObject,
    };
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
    const min = typecheck.requiredParamCount(func);
    const max = func.params.items.len;
    if (actual < min or actual > max) {
        reportLowerDiagnostic(.{
            .err = error.InvalidArity,
            .span = error_report.spanFromOrigin(origin),
            .data = .{ .invalid_arity = .{ .actual = actual, .min = min, .max = max } },
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
            try evalExpr(ir, page_id, mode, caller_env, functions, current_origin, call.args.items[index])
        else
            try evalExpr(ir, page_id, mode, local_env, functions, current_origin, (param.default_value orelse return error.InvalidArity).*);
        try typecheck.ensureValueSortWithCode(ir, page_id, value, param.sort, current_origin, .UnmatchedArgumentType);
        try local_env.put(param.name, value);
    }
}

fn fragmentRootToValue(allocator: std.mem.Allocator, fragment: *const core.Fragment) !core.Value {
    const root = fragment.root orelse unreachable;
    return switch (root) {
        .document => |id| .{ .document = id },
        .page => |id| .{ .page = id },
        .object => |id| .{ .object = id },
        .selection => |selection| .{ .selection = try selection.clone(allocator) },
        .anchor => |anchor| .{ .anchor = anchor },
        .function => |function| .{ .function = function },
        .style => |style| .{ .style = style },
        .string => |text| .{ .string = text },
        .number => |number| .{ .number = number },
        .constraints => |constraints| .{ .constraints = try constraints.clone(allocator) },
    };
}

fn fragmentRootCloneFromFragment(allocator: std.mem.Allocator, fragment: *const core.Fragment) !core.FragmentRoot {
    const root = fragment.root orelse unreachable;
    return try root.clone(allocator);
}

fn normalizeForUse(ir: *doc.Document, mode: EvalMode, value: core.Value) !core.Value {
    return switch (value) {
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
    return switch (value) {
        .string => |text| text,
        else => return error.ExpectedStringArgument,
    };
}

pub fn resolveValuePropertyString(allocator: std.mem.Allocator, value: core.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        .number => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
        else => error.ExpectedStringArgument,
    };
}

fn resolveValueNumber(value: core.Value) !f32 {
    return switch (value) {
        .number => |number| number,
        else => return error.ExpectedNumberArgument,
    };
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
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.Value {
    return try evalExpr(ir, page_id, mode, env, functions, current_origin, call.args.items[index]);
}

fn evalCallStringArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror![]const u8 {
    return try resolveValueString(try evalCallArg(ir, page_id, mode, env, functions, current_origin, call, index));
}

fn evalCallNumberArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!f32 {
    return try resolveValueNumber(try evalCallArg(ir, page_id, mode, env, functions, current_origin, call, index));
}

fn evalCallObjectArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.NodeId {
    return try resolveValueObjectId(ir, mode, try evalCallArg(ir, page_id, mode, env, functions, current_origin, call, index));
}

fn evalCallAnchorArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.AnchorValue {
    return try resolveValueAnchor(try evalCallArg(ir, page_id, mode, env, functions, current_origin, call, index));
}

fn evalCallStyleArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.StyleRef {
    return try resolveValueStyle(try evalCallArg(ir, page_id, mode, env, functions, current_origin, call, index));
}

fn evalCallRoleArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.Role {
    const role_name = try evalCallStringArg(ir, page_id, mode, env, functions, current_origin, call, index);
    return names.parseRoleName(role_name) orelse {
        reportNamedResolutionError(error.UnknownRole, "role", role_name, current_origin);
        return error.UnknownRole;
    };
}

fn evalCallPayloadArg(
    ir: *doc.Document,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!names.ParsedPayload {
    const payload_name = try evalCallStringArg(ir, page_id, mode, env, functions, current_origin, call, index);
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
            const value = try evalExpr(ir, page_id, mode, env, functions, origin, binding.expr);
            switch (mode) {
                .attached => try materializeStatementValue(ir, mode, last_code_like, value),
                .detached => {},
            }
            try env.put(binding.name, value);
        },
        .bind_binding => |binding| {
            switch (mode) {
                .attached => {
                    var builder = DetachedBuilder.init(page_id);
                    errdefer builder.deinit(ir.allocator);
                    const value = try evalExpr(ir, page_id, .{ .detached = &builder }, env, functions, origin, binding.expr);
                    switch (value) {
                        .fragment => {
                            if (builder.isEmpty()) {
                                builder.deinit(ir.allocator);
                                try env.put(binding.name, value);
                            } else {
                                const root = try fragmentRootCloneFromFragment(ir.allocator, value.fragment);
                                try builder.trackFragment(ir.allocator, value.fragment);
                                const fragment = try ir.createFragment(page_id, root, builder.node_ids, builder.constraints, builder.deps);
                                try env.put(binding.name, .{ .fragment = fragment });
                            }
                        },
                        else => {
                            const root = try fragmentRootFromValue(value);
                            const fragment = try ir.createFragment(page_id, root, builder.node_ids, builder.constraints, builder.deps);
                            try env.put(binding.name, .{ .fragment = fragment });
                        },
                    }
                },
                .detached => {
                    const value = try evalExpr(ir, page_id, mode, env, functions, origin, binding.expr);
                    try env.put(binding.name, value);
                },
            }
        },
        .return_expr => |expr| {
            const value = try evalExpr(ir, page_id, mode, env, functions, origin, expr);
            return .{ .returned = value };
        },
        .property_set => |property_set| {
            const base = env.get(property_set.object_name) orelse return error.UnknownIdentifier;
            const object_id = try resolveValueObjectId(ir, mode, base);
            const value = try evalExpr(ir, page_id, mode, env, functions, origin, property_set.value);
            defer {
                var owned = value;
                owned.deinit(ir.allocator);
            }
            const text = try resolveValuePropertyString(ir.allocator, value);
            defer ir.allocator.free(text);
            try ir.setNodeProperty(object_id, property_set.property_name, text);
        },
        .constrain => |decl| {
            const target = try resolveAnchorRef(ir, mode, env, origin, decl.target, true);
            const source = try resolveAnchorRef(ir, mode, env, origin, decl.source, false);
            const offset: f32 = if (decl.offset) |expr| blk: {
                const value = try evalExpr(ir, page_id, mode, env, functions, origin, expr);
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
                    try executeCallStatement(ir, page_id, mode, env, functions, last_code_like, origin, call);
                } else {
                    var value = try evalExpr(ir, page_id, mode, env, functions, origin, expr);
                    defer value.deinit(ir.allocator);
                    try materializeStatementValue(ir, mode, last_code_like, value);
                }
            },
            else => {
                var value = try evalExpr(ir, page_id, mode, env, functions, origin, expr);
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

fn fragmentRootFromValue(value: core.Value) !core.FragmentRoot {
    return switch (value) {
        .document => |id| .{ .document = id },
        .page => |id| .{ .page = id },
        .object => |id| .{ .object = id },
        .selection => |selection| .{ .selection = selection },
        .anchor => |anchor| .{ .anchor = anchor },
        .function => |function| .{ .function = function },
        .style => |style| .{ .style = style },
        .string => |text| .{ .string = text },
        .number => |number| .{ .number = number },
        .constraints => |constraints| .{ .constraints = constraints },
        .fragment => error.UnsupportedFragmentRoot,
    };
}

fn executeCallStatement(
    ir: *doc.Document,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    last_code_like: *?core.NodeId,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!void {
    const func = functions.get(call.name) orelse {
        _ = try evalCall(ir, page_id, mode, env, functions, current_origin, call);
        return;
    };
    try validateUserFunctionArity(call.args.items.len, func, current_origin);

    var local_env = std.StringHashMap(core.Value).init(ir.allocator);
    defer local_env.deinit();
    var it = env.iterator();
    while (it.next()) |entry| {
        try local_env.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    try bindUserFunctionArgs(ir, page_id, mode, env, &local_env, functions, func, current_origin, call);
    for (func.statements.items) |inner| {
        const flow = try executeStatement(ir, page_id, mode, &local_env, functions, last_code_like, inner, current_origin);
        switch (flow) {
            .none => {},
            .returned => |value| {
                defer {
                    var owned = value;
                    owned.deinit(ir.allocator);
                }
                try typecheck.ensureValueSortWithCode(ir, page_id, value, func.result_sort, current_origin, .UnmatchedReturnType);
                try materializeStatementValue(ir, mode, last_code_like, value);
                return;
            },
        }
    }
}

fn invokeUserFunctionValue(
    ir: *doc.Document,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    func: FunctionDecl,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    const func_ref = try typecheck.functionRefFor(ir.allocator, func);
    if (!func_ref.returns_value) return error.FunctionDoesNotReturnValue;
    try validateUserFunctionArity(call.args.items.len, func, current_origin);

    var local_env = std.StringHashMap(core.Value).init(ir.allocator);
    defer local_env.deinit();
    var it = env.iterator();
    while (it.next()) |entry| {
        try local_env.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    try bindUserFunctionArgs(ir, page_id, mode, env, &local_env, functions, func, current_origin, call);

    var last_code_like: ?core.NodeId = null;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(ir, page_id, mode, &local_env, functions, &last_code_like, inner, current_origin);
        switch (flow) {
            .none => {},
            .returned => |value| {
                try typecheck.ensureValueSortWithCode(ir, page_id, value, func.result_sort, current_origin, .UnmatchedReturnType);
                return value;
            },
        }
    }

    return error.FunctionDidNotReturnValue;
}

fn statementOrigin(allocator: std.mem.Allocator, span: ast.Span) ![]const u8 {
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
