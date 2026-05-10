const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const builtin = @import("../stage0/builtin.zig");
const declarations = @import("../language/declarations.zig");
const semantic_env = @import("../language/env.zig");
const names = @import("../language/names.zig");
const typecheck = @import("../analysis/typecheck.zig");

const FunctionDecl = ast.FunctionDecl;
const Statement = ast.Statement;
const Expr = ast.Expr;
const CallExpr = ast.CallExpr;
const SemanticEnv = semantic_env.SemanticEnv;

const ExecFlow = union(enum) {
    none,
    returned: core.Value,
};

pub fn runAfterPages(ir: *core.Ir) !void {
    var index = try declarations.build(ir.allocator, ir);
    defer index.deinit();

    for (index.phases.items) |phase| {
        if (!isAfterPages(phase.args)) continue;
        const func = ir.functions.get(phase.function_name) orelse return error.UnknownFunction;
        try validateAfterPagesSignature(ir, phase, func);
        var env = std.StringHashMap(core.Value).init(ir.allocator);
        defer env.deinit();
        const args = [_]core.Value{.{ .document = ir.document_id }};
        var result = try invokeUserFunctionValues(ir, &env, &ir.functions, func, try functionOrigin(ir, phase, func), &args);
        defer result.deinit(ir.allocator);
        try typecheck.ensureValueSortWithCode(ir, null, result, .document, try functionOrigin(ir, phase, func), .UnmatchedReturnType);
    }
}

fn isAfterPages(args: ?[]const u8) bool {
    const text = std.mem.trim(u8, args orelse "", " \t\r\n");
    return std.mem.eql(u8, text, "after_pages");
}

fn validateAfterPagesSignature(ir: *core.Ir, phase: declarations.FunctionAnnotationDescriptor, func: FunctionDecl) !void {
    if (func.params.items.len == 1 and func.params.items[0].sort == .document and func.result_sort == .document and func.statements.items.len > 0) return;
    try ir.addValidationDiagnostic(.@"error", null, null, try functionOrigin(ir, phase, func), .{
        .user_report = .{ .message = try ir.allocator.dupe(u8, "@phase(after_pages) functions must have signature fn f(doc: document) -> document and a body") },
    });
    return error.InvalidSemanticSort;
}

fn evalExpr(
    ir: *core.Ir,
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
                    break :blk try invokeUserFunctionValue(ir, env, functions, func, current_origin, .{
                        .name = name,
                        .args = std.ArrayList(Expr).empty,
                    });
                }
                break :blk .{ .function = try typecheck.functionRefFor(ir.allocator, func) };
            }
            return error.UnknownIdentifier;
        },
        .string => |text| .{ .string = text },
        .number => |value| .{ .number = value },
        .call => |call| try evalCall(ir, env, functions, current_origin, call),
    };
}

fn evalCall(
    ir: *core.Ir,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    if (env.get(call.name)) |value| {
        switch (value) {
            .function => |func_ref| {
                if (!func_ref.returns_value) return error.FunctionDoesNotReturnValue;
                const func = functions.get(func_ref.name) orelse return error.UnknownFunction;
                return try invokeUserFunctionValue(ir, env, functions, func, current_origin, call);
            },
            else => {},
        }
    }
    const sema = SemanticEnv.init(ir, null, functions);
    if (sema.function(call.name)) |func| {
        if (func.kind == .constant) return error.UnknownFunction;
        if (!typecheck.functionContract(func).returns_value) return error.FunctionDoesNotReturnValue;
        return try invokeUserFunctionValue(ir, env, functions, func, current_origin, call);
    }
    if (sema.primitive(call.name)) |descriptor| {
        var ctx = BuiltinContext{
            .ir = ir,
            .env = env,
            .functions = functions,
            .current_origin = current_origin,
        };
        return try builtin.evalCall(&ctx, call, descriptor);
    }
    return error.UnknownFunction;
}

const BuiltinContext = struct {
    ir: *core.Ir,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    current_origin: []const u8,

    pub fn checkArityRange(self: *const BuiltinContext, actual: usize, min: usize, max: usize) !void {
        _ = self;
        if (actual < min or actual > max) return error.InvalidArity;
    }

    pub fn currentPageValue(self: *const BuiltinContext) anyerror!core.Value {
        _ = self;
        return error.NoCurrentPage;
    }

    pub fn currentDocumentValue(self: *const BuiltinContext) core.Value {
        return .{ .document = self.ir.document_id };
    }

    pub fn runSelectCall(self: *BuiltinContext, call: CallExpr) anyerror!core.Value {
        const base = try self.evalExprValue(call.args.items[0]);
        const op_name = try self.evalStringArg(call, 1);
        const sema = SemanticEnv.init(self.ir, null, self.functions);
        const descriptor = sema.query(op_name) orelse return error.UnknownQuery;
        switch (descriptor.op) {
            .self_object => return try self.ir.select(self.ir.allocator, base, core.Query.selfObject()),
            .previous_page => return try self.ir.select(self.ir.allocator, base, core.Query.previousPage()),
            .parent_page => return try self.ir.select(self.ir.allocator, base, core.Query.parentPage()),
            .children => return try self.ir.select(self.ir.allocator, base, core.Query.children()),
            .descendants => return try self.ir.select(self.ir.allocator, base, core.Query.descendants()),
            .document_pages => return try self.ir.select(self.ir.allocator, base, core.Query.documentPages()),
            .page_objects_by_role => {
                const role = try self.evalRoleArg(call, 2);
                return try self.ir.select(self.ir.allocator, base, core.Query.pageObjectsByRole(role));
            },
            .document_objects_by_role => {
                const role = try self.evalRoleArg(call, 2);
                return try self.ir.select(self.ir.allocator, base, core.Query.documentObjectsByRole(role));
            },
        }
    }

    pub fn runDeriveCall(self: *BuiltinContext, call: CallExpr) anyerror!core.Value {
        _ = self;
        _ = call;
        return error.UnsupportedPhasePrimitive;
    }

    pub fn evalExprValue(self: *BuiltinContext, expr: Expr) anyerror!core.Value {
        return try evalExpr(self.ir, self.env, self.functions, self.current_origin, expr);
    }

    pub fn evalStringArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror![]const u8 {
        return try resolveValueString(try self.evalExprValue(call.args.items[index]));
    }

    pub fn evalPropertyStringArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror![]const u8 {
        return try resolveValuePropertyString(self.ir.allocator, try self.evalExprValue(call.args.items[index]));
    }

    pub fn evalNumberArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!f32 {
        return try resolveValueNumber(try self.evalExprValue(call.args.items[index]));
    }

    pub fn evalObjectArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.NodeId {
        return switch (try self.evalExprValue(call.args.items[index])) {
            .object => |id| id,
            else => error.ExpectedObject,
        };
    }

    pub fn evalAnchorArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.AnchorValue {
        return switch (try self.evalExprValue(call.args.items[index])) {
            .anchor => |anchor| anchor,
            else => error.ExpectedAnchor,
        };
    }

    pub fn evalRoleArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.Role {
        const role_name = try self.evalStringArg(call, index);
        return names.parseRoleName(role_name) orelse error.UnknownRole;
    }

    pub fn evalPayloadArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!names.ParsedPayload {
        const payload_name = try self.evalStringArg(call, index);
        return names.parsePayloadName(payload_name) orelse error.UnknownPayloadKind;
    }

    pub fn evalStyleArg(self: *BuiltinContext, call: CallExpr, index: usize) anyerror!core.StyleRef {
        return switch (try self.evalExprValue(call.args.items[index])) {
            .style => |style| style,
            else => error.ExpectedStyleArgument,
        };
    }

    pub fn materializeForUse(self: *BuiltinContext, value: core.Value) !core.Value {
        _ = self;
        return value;
    }

    pub fn anchorValueForObject(self: *BuiltinContext, node_id: core.NodeId, anchor_name: []const u8) !core.Value {
        _ = self;
        const anchor = names.parseAnchorName(anchor_name) orelse return error.UnknownAnchor;
        return .{ .anchor = .{ .node = .{ .node_id = node_id, .anchor = anchor } } };
    }

    pub fn pageAnchorValue(self: *BuiltinContext, anchor_name: []const u8) !core.Value {
        _ = self;
        const anchor = names.parseAnchorName(anchor_name) orelse return error.UnknownAnchor;
        return .{ .anchor = .{ .page = anchor } };
    }

    pub fn makeObject(self: *BuiltinContext, role_name: []const u8, role: core.Role, object_kind: core.ObjectKind, payload_kind: core.PayloadKind, content: []const u8) !core.NodeId {
        _ = self;
        _ = role_name;
        _ = role;
        _ = object_kind;
        _ = payload_kind;
        _ = content;
        return error.UnsupportedPhasePrimitive;
    }

    pub fn makeGroup(self: *BuiltinContext, child_ids: []const core.NodeId) !core.NodeId {
        _ = self;
        _ = child_ids;
        return error.UnsupportedPhasePrimitive;
    }

    pub fn setNodeProperty(self: *BuiltinContext, object_id: core.NodeId, key: []const u8, value: []const u8) !void {
        try self.ir.setNodeProperty(object_id, key, value);
    }

    pub fn extendRenderEnv(self: *BuiltinContext, node_id: core.NodeId, op: []const u8, key: []const u8, value: []const u8) !void {
        try self.ir.extendRenderEnv(node_id, op, key, value);
    }

    pub fn invokeCallback(self: *BuiltinContext, function: core.FunctionRef, args: []const core.Value) !core.Value {
        const func = self.functions.get(function.name) orelse return error.UnknownFunction;
        return try invokeUserFunctionValues(self.ir, self.env, self.functions, func, self.current_origin, args);
    }

    pub fn pageIndex(self: *BuiltinContext, page_id: core.NodeId) usize {
        return self.ir.pageIndexOf(page_id);
    }

    pub fn pageCount(self: *BuiltinContext) usize {
        return self.ir.pageCount();
    }

    pub fn nodeContent(self: *BuiltinContext, object_id: core.NodeId) ?[]const u8 {
        const node = self.ir.getNode(object_id) orelse return null;
        return node.content;
    }

    pub fn setNodeContent(self: *BuiltinContext, object_id: core.NodeId, text: []const u8) !void {
        try self.ir.setNodeContent(object_id, text);
    }

    pub fn appendNodeContent(self: *BuiltinContext, object_id: core.NodeId, text: []const u8) !void {
        try self.ir.appendNodeContent(object_id, text);
    }

    pub fn equalAnchorConstraintSet(self: *BuiltinContext, target: core.AnchorValue, source: core.AnchorValue, offset: f32) !core.ConstraintSet {
        _ = self;
        _ = target;
        _ = source;
        _ = offset;
        return error.UnsupportedPhasePrimitive;
    }

    pub fn emitDiagnosticReport(self: *BuiltinContext, severity: core.DiagnosticSeverity, message: []const u8) !void {
        try self.ir.addValidationDiagnostic(severity, null, null, self.current_origin, .{
            .user_report = .{ .message = try self.ir.allocator.dupe(u8, message) },
        });
    }

    pub fn checkAssetExists(self: *BuiltinContext, object_id: core.NodeId) !void {
        _ = self;
        _ = object_id;
        return error.UnsupportedPhasePrimitive;
    }
};

fn executeStatement(
    ir: *core.Ir,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    stmt: Statement,
    origin_override: ?[]const u8,
) anyerror!ExecFlow {
    const origin = origin_override orelse try statementOrigin(ir.allocator, stmt.span);
    switch (stmt.kind) {
        .let_binding => |binding| {
            const value = try evalExpr(ir, env, functions, origin, binding.expr);
            try env.put(binding.name, value);
        },
        .bind_binding => return error.UnsupportedPhasePrimitive,
        .return_expr => |expr| {
            return .{ .returned = try evalExpr(ir, env, functions, origin, expr) };
        },
        .property_set => |property_set| {
            const base = env.get(property_set.object_name) orelse return error.UnknownIdentifier;
            const object_id = switch (base) {
                .object => |id| id,
                else => return error.ExpectedObject,
            };
            const value = try evalExpr(ir, env, functions, origin, property_set.value);
            const text = try resolveValuePropertyString(ir.allocator, value);
            try ir.setNodeProperty(object_id, property_set.property_name, text);
        },
        .expr_stmt => |expr| {
            var value = try evalExpr(ir, env, functions, origin, expr);
            defer value.deinit(ir.allocator);
        },
        .constrain => return error.UnsupportedPhasePrimitive,
    }
    return .none;
}

fn bindUserFunctionCallArgs(
    ir: *core.Ir,
    caller_env: *std.StringHashMap(core.Value),
    local_env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    func: FunctionDecl,
    current_origin: []const u8,
    call: CallExpr,
) !void {
    if (call.args.items.len < typecheck.requiredParamCount(func) or call.args.items.len > func.params.items.len) return error.InvalidArity;
    for (func.params.items, 0..) |param, index| {
        const value = if (index < call.args.items.len)
            try evalExpr(ir, caller_env, functions, current_origin, call.args.items[index])
        else
            try evalExpr(ir, local_env, functions, current_origin, (param.default_value orelse return error.InvalidArity).*);
        try typecheck.ensureValueSortWithCode(ir, null, value, param.sort, current_origin, .UnmatchedArgumentType);
        try local_env.put(param.name, value);
    }
}

fn bindUserFunctionValueArgs(
    ir: *core.Ir,
    local_env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    func: FunctionDecl,
    current_origin: []const u8,
    args: []const core.Value,
) !void {
    if (args.len < typecheck.requiredParamCount(func) or args.len > func.params.items.len) return error.InvalidArity;
    for (func.params.items, 0..) |param, index| {
        const value = if (index < args.len)
            args[index]
        else
            try evalExpr(ir, local_env, functions, current_origin, (param.default_value orelse return error.InvalidArity).*);
        try typecheck.ensureValueSortWithCode(ir, null, value, param.sort, current_origin, .UnmatchedArgumentType);
        try local_env.put(param.name, value);
    }
}

fn invokeUserFunctionValue(
    ir: *core.Ir,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    func: FunctionDecl,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    var local_env = std.StringHashMap(core.Value).init(ir.allocator);
    defer local_env.deinit();
    var it = env.iterator();
    while (it.next()) |entry| try local_env.put(entry.key_ptr.*, entry.value_ptr.*);
    try bindUserFunctionCallArgs(ir, env, &local_env, functions, func, current_origin, call);
    return try executeUserFunctionBody(ir, &local_env, functions, func, current_origin);
}

fn invokeUserFunctionValues(
    ir: *core.Ir,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    func: FunctionDecl,
    current_origin: []const u8,
    args: []const core.Value,
) anyerror!core.Value {
    var local_env = std.StringHashMap(core.Value).init(ir.allocator);
    defer local_env.deinit();
    var it = env.iterator();
    while (it.next()) |entry| try local_env.put(entry.key_ptr.*, entry.value_ptr.*);
    try bindUserFunctionValueArgs(ir, &local_env, functions, func, current_origin, args);
    return try executeUserFunctionBody(ir, &local_env, functions, func, current_origin);
}

fn executeUserFunctionBody(
    ir: *core.Ir,
    env: *std.StringHashMap(core.Value),
    functions: *const std.StringHashMap(FunctionDecl),
    func: FunctionDecl,
    current_origin: []const u8,
) anyerror!core.Value {
    if (!typecheck.functionContract(func).returns_value) return error.FunctionDoesNotReturnValue;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(ir, env, functions, inner, current_origin);
        switch (flow) {
            .none => {},
            .returned => |value| {
                try typecheck.ensureValueSortWithCode(ir, null, value, func.result_sort, current_origin, .UnmatchedReturnType);
                return value;
            },
        }
    }
    return error.FunctionDidNotReturnValue;
}

fn resolveValueString(value: core.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.ExpectedStringArgument,
    };
}

fn resolveValuePropertyString(allocator: std.mem.Allocator, value: core.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        .number => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
        else => error.ExpectedStringArgument,
    };
}

fn resolveValueNumber(value: core.Value) !f32 {
    return switch (value) {
        .number => |number| number,
        else => error.ExpectedNumberArgument,
    };
}

fn functionOrigin(ir: *const core.Ir, phase: declarations.FunctionAnnotationDescriptor, func: FunctionDecl) ![]const u8 {
    const module = ir.moduleById(phase.module_id);
    const path = if (module) |m| m.path orelse m.spec else "";
    if (path.len == 0) return std.fmt.allocPrint(ir.allocator, "bytes:{d}-{d}", .{ func.span.start, func.span.end });
    return std.fmt.allocPrint(ir.allocator, "path:{s}:bytes:{d}-{d}", .{ path, func.span.start, func.span.end });
}

fn statementOrigin(allocator: std.mem.Allocator, span: ast.Span) ![]const u8 {
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}
