const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const eval_functions = @import("../eval/functions.zig");
const eval_value = @import("../eval/value.zig");
const builtin = @import("../stage0/builtin.zig");
const declarations = @import("../language/declarations.zig");
const semantic_env = @import("../language/env.zig");
const names = @import("../language/names.zig");
const registry = @import("../language/registry.zig");
const contracts = @import("../analysis/contracts.zig");

const FunctionDecl = ast.FunctionDecl;
const Statement = ast.Statement;
const Expr = ast.Expr;
const CallExpr = ast.CallExpr;
const SemanticEnv = semantic_env.SemanticEnv;
const PassDescriptor = declarations.PassDescriptor;
const PassSlot = declarations.PassSlot;

const ExecFlow = union(enum) {
    none,
    returned: core.Value,
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

pub fn runPreLayoutPasses(ir: *core.Ir) !void {
    try runPassSlots(ir, &.{ .augment, .resolve });
}

pub fn runPostLayoutPasses(ir: *core.Ir) !void {
    try runPassSlots(ir, &.{ .inspect_layout, .prepare_render });
}

pub fn runPassSlots(ir: *core.Ir, slots: []const PassSlot) !void {
    var index = try declarations.build(ir.allocator, ir);
    defer index.deinit();
    const sema = SemanticEnv.init(ir, &index, &ir.functions);

    try rejectRemovedAnnotations(ir, &sema);
    for (sema.passes()) |pass| {
        try validatePass(ir, sema.passes(), pass, pass.function);
    }
    for (slots) |slot| {
        const schedule = try schedulePasses(ir, sema.passes(), slot);
        defer ir.allocator.free(schedule);
        for (schedule) |pass_index| {
            const pass = sema.passes()[pass_index];
            const func = pass.function;
            try validatePass(ir, sema.passes(), pass, func);
            try validatePassEffects(ir, &sema, pass, func);
            const allowed = allowedEffects(slot);
            const declared_effects = pass.effects.?.withoutPure();
            if (!allowed.containsAll(declared_effects)) {
                const disallowed = declared_effects.difference(allowed);
                const disallowed_text = try disallowed.formatAlloc(ir.allocator);
                defer ir.allocator.free(disallowed_text);
                try addPassDiagnostic(ir, pass, "InvalidPassEffects: @pass({s}) declares effects not allowed in this slot: {s}", .{ pass.slot_name, disallowed_text });
                return error.InvalidPassEffects;
            }
            if (slot != .augment and pass.effects.?.contains(.CreateNode)) {
                try addPassDiagnostic(ir, pass, "InvalidPassEffects: CreateNode is only allowed in @pass(augment)", .{});
                return error.InvalidPassEffects;
            }
            if (slot != .augment and pass.effects.?.contains(.CreatePage)) {
                try addPassDiagnostic(ir, pass, "InvalidPassEffects: CreatePage is only allowed in @pass(augment)", .{});
                return error.InvalidPassEffects;
            }
            try executePass(ir, pass, func);
        }
    }
}

fn executePass(ir: *core.Ir, pass: PassDescriptor, func: FunctionDecl) !void {
    var env = std.StringHashMap(core.Value).init(ir.allocator);
    defer deinitValueEnv(ir.allocator, &env);
    const args = [_]core.Value{.{ .code = .{ .root = .{ .document = ir.document_id } } }};
    const origin = try functionOrigin(ir, pass, func);
    defer ir.allocator.free(origin);
    var result = try invokeUserFunctionValues(ir, &env, &ir.functions, func, origin, &args);
    defer result.deinit(ir.allocator);
    try ensureReturnedDocumentCode(ir, result, origin);
}

fn ensureReturnedDocumentCode(ir: *core.Ir, result: core.Value, origin: []const u8) !void {
    switch (result) {
        .code => |code| switch (code.root) {
            .document => |id| {
                if (id == ir.document_id) return;
                try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try ir.allocator.dupe(u8, "InvalidPassReturn: pass returned a different document root") },
                });
                return error.InvalidSemanticSort;
            },
            else => {
                try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try ir.allocator.dupe(u8, "InvalidPassReturn: @pass must return code<document>") },
                });
                return error.InvalidSemanticSort;
            },
        },
        else => {
            try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                .type_mismatch = .{ .code = .UnmatchedReturnType, .expected = .code, .actual = contracts.valueSort(result) },
            });
            return error.InvalidSemanticSort;
        },
    }
}

fn rejectRemovedAnnotations(ir: *core.Ir, sema: *const SemanticEnv) !void {
    for (sema.removedAnnotations()) |annotation| {
        const origin = try annotationOrigin(ir, annotation.module_id, annotation.function_name);
        defer ir.allocator.free(origin);
        try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
            .user_report = .{ .message = try ir.allocator.dupe(u8, "@phase is removed; use @pass(augment), @pass(resolve), @pass(inspect_layout), or @pass(prepare_render)") },
        });
        return error.LegacyPhaseAnnotation;
    }
}

fn validatePass(ir: *core.Ir, passes: []const PassDescriptor, pass: PassDescriptor, func: FunctionDecl) !void {
    if (pass.slot == null) {
        try addPassDiagnostic(ir, pass, "UnknownPassSlot: unknown pass slot '{s}'", .{pass.slot_name});
        return error.UnknownPassSlot;
    }
    if (pass.effects_parse_failed) {
        try addPassDiagnostic(ir, pass, "UnknownEffect: @pass({s}) declares an unknown effect", .{pass.slot_name});
        return error.UnknownEffect;
    }
    if (pass.effects == null) {
        try addPassDiagnostic(ir, pass, "MissingEffects: @pass functions must declare effects with '! Effect | Effect'", .{});
        return error.MissingEffects;
    }
    if (func.params.items.len != 1 or
        func.params.items[0].ty.tag != .code or
        func.params.items[0].ty.param != .document or
        func.result_type.tag != .code or
        func.result_type.param != .document or
        func.statements.items.len == 0)
    {
        try addPassDiagnostic(ir, pass, "@pass functions must have signature fn f(doc: code<document>) -> code<document> and a body", .{});
        return error.InvalidSemanticSort;
    }
    for (pass.after) |dependency| _ = try resolvePassDependency(ir, passes, dependency, pass);
    for (pass.before) |dependency| _ = try resolvePassDependency(ir, passes, dependency, pass);
}

fn allowedEffects(slot: PassSlot) core.EffectSet {
    var set = core.EffectSet.empty();
    switch (slot) {
        .augment => {
            set.insert(.ReadGraph);
            set.insert(.CreatePage);
            set.insert(.CreateNode);
            set.insert(.WriteContent);
            set.insert(.WriteProperty);
            set.insert(.WriteConstraint);
            set.insert(.EmitDiagnostics);
        },
        .resolve => {
            set.insert(.ReadGraph);
            set.insert(.WriteContent);
            set.insert(.WriteProperty);
            set.insert(.WriteConstraint);
            set.insert(.EmitDiagnostics);
        },
        .inspect_layout => {
            set.insert(.ReadGraph);
            set.insert(.ReadLayout);
            set.insert(.EmitDiagnostics);
        },
        .prepare_render => {
            set.insert(.ReadGraph);
            set.insert(.ReadLayout);
            set.insert(.WriteRenderPolicy);
            set.insert(.EmitDiagnostics);
        },
    }
    return set;
}

fn validatePassEffects(ir: *core.Ir, sema: *const SemanticEnv, pass: PassDescriptor, func: FunctionDecl) !void {
    var visiting = std.StringHashMap(void).init(ir.allocator);
    defer visiting.deinit();
    const inferred = try inferFunctionEffects(ir, sema, pass, func, &visiting);
    const declared = pass.effects.?;
    const required = inferred.withoutPure();
    if (!declared.containsAll(required)) {
        const missing = required.difference(declared);
        const missing_text = try missing.formatAlloc(ir.allocator);
        defer ir.allocator.free(missing_text);
        try addPassDiagnostic(ir, pass, "MissingEffects: @pass({s}) body uses effects not listed in its signature: {s}", .{ pass.slot_name, missing_text });
        return error.MissingEffects;
    }
}

fn inferFunctionEffects(
    ir: *core.Ir,
    sema: *const SemanticEnv,
    pass: PassDescriptor,
    func: FunctionDecl,
    visiting: *std.StringHashMap(void),
) anyerror!core.EffectSet {
    if (visiting.contains(func.name)) {
        if (func.effects) |effects| return declarations.parseEffectSet(effects);
        return core.EffectSet.empty();
    }
    try visiting.put(func.name, {});
    defer _ = visiting.remove(func.name);

    var set = core.EffectSet.empty();
    for (func.params.items) |param| {
        if (param.default_value) |default_expr| {
            set.unionWith(try inferExprEffects(ir, sema, pass, default_expr.*, visiting));
        }
    }
    for (func.statements.items) |stmt| {
        set.unionWith(try inferStatementEffects(ir, sema, pass, stmt, visiting));
    }
    return set;
}

fn inferStatementEffects(
    ir: *core.Ir,
    sema: *const SemanticEnv,
    pass: PassDescriptor,
    stmt: Statement,
    visiting: *std.StringHashMap(void),
) anyerror!core.EffectSet {
    var set = core.EffectSet.empty();
    switch (stmt.kind) {
        .let_binding => |binding| set.unionWith(try inferExprEffects(ir, sema, pass, binding.expr, visiting)),
        .return_expr => |expr| set.unionWith(try inferExprEffects(ir, sema, pass, expr, visiting)),
        .property_set => |property| {
            set.insert(.WriteProperty);
            set.unionWith(try inferExprEffects(ir, sema, pass, property.value, visiting));
        },
        .if_stmt => |if_stmt| {
            set.unionWith(try inferExprEffects(ir, sema, pass, if_stmt.condition, visiting));
            for (if_stmt.then_statements.items) |nested| set.unionWith(try inferStatementEffects(ir, sema, pass, nested, visiting));
            for (if_stmt.else_statements.items) |nested| set.unionWith(try inferStatementEffects(ir, sema, pass, nested, visiting));
        },
        .expr_stmt => |expr| set.unionWith(try inferExprEffects(ir, sema, pass, expr, visiting)),
        .constrain => |decl| {
            set.insert(.WriteConstraint);
            if (decl.offset) |expr| set.unionWith(try inferExprEffects(ir, sema, pass, expr, visiting));
        },
    }
    return set;
}

fn inferExprEffects(
    ir: *core.Ir,
    sema: *const SemanticEnv,
    pass: PassDescriptor,
    expr: Expr,
    visiting: *std.StringHashMap(void),
) anyerror!core.EffectSet {
    return switch (expr) {
        .ident, .string, .number, .boolean => core.EffectSet.empty(),
        .call => |call| try inferCallEffects(ir, sema, pass, call, visiting),
    };
}

fn inferCallEffects(
    ir: *core.Ir,
    sema: *const SemanticEnv,
    pass: PassDescriptor,
    call: CallExpr,
    visiting: *std.StringHashMap(void),
) anyerror!core.EffectSet {
    var set = core.EffectSet.empty();
    for (call.args.items) |arg| set.unionWith(try inferExprEffects(ir, sema, pass, arg, visiting));
    const descriptor = sema.call(call.name) orelse return set;
    switch (descriptor) {
        .primitive => |primitive| {
            if (primitive.op == .object or primitive.op == .group) {
                try addPassDiagnostic(ir, pass, "UnsupportedPassPrimitive: @pass bodies must use new_object(page, ...) or new_group(page, ...) instead of {s}()", .{primitive.name});
                return error.UnsupportedPassPrimitive;
            }
            set.unionWith(registry.primitiveEffects(primitive));
            if (primitive.callback_arg_index) |raw_index| {
                const callback_index: usize = raw_index;
                if (call.args.items.len > callback_index) switch (call.args.items[callback_index]) {
                    .ident => |callback_name| if (sema.function(callback_name)) |callback| {
                        set.unionWith(try inferFunctionEffects(ir, sema, pass, callback, visiting));
                    },
                    else => {},
                };
            }
        },
        .function => |callee| set.unionWith(try inferFunctionEffects(ir, sema, pass, callee, visiting)),
    }
    return set;
}

fn schedulePasses(ir: *core.Ir, passes: []const PassDescriptor, slot: PassSlot) ![]usize {
    var candidates = std.ArrayList(usize).empty;
    errdefer candidates.deinit(ir.allocator);
    for (passes, 0..) |pass, index| {
        if (pass.slot != null and pass.slot.? == slot) try candidates.append(ir.allocator, index);
    }

    var deps = try ir.allocator.alloc(std.ArrayList(usize), candidates.items.len);
    errdefer ir.allocator.free(deps);
    for (deps) |*list| list.* = .empty;
    errdefer for (deps) |*list| list.deinit(ir.allocator);

    for (candidates.items, 0..) |global_index, local_index| {
        const pass = passes[global_index];
        for (pass.after) |dependency| {
            const dep_global = try resolvePassDependency(ir, passes, dependency, pass);
            const dep_local = candidateLocalIndex(candidates.items, dep_global) orelse {
                try addPassDiagnostic(ir, pass, "PassDependencySlotMismatch: dependency '{s}' is not in the same pass slot", .{dependency});
                return error.PassDependencySlotMismatch;
            };
            try deps[local_index].append(ir.allocator, dep_local);
        }
        for (pass.before) |dependency| {
            const dep_global = try resolvePassDependency(ir, passes, dependency, pass);
            const dep_local = candidateLocalIndex(candidates.items, dep_global) orelse {
                try addPassDiagnostic(ir, pass, "PassDependencySlotMismatch: dependency '{s}' is not in the same pass slot", .{dependency});
                return error.PassDependencySlotMismatch;
            };
            try deps[dep_local].append(ir.allocator, local_index);
        }
    }

    var scheduled = try ir.allocator.alloc(bool, candidates.items.len);
    defer ir.allocator.free(scheduled);
    @memset(scheduled, false);
    var order = std.ArrayList(usize).empty;
    errdefer order.deinit(ir.allocator);

    while (order.items.len < candidates.items.len) {
        var progressed = false;
        for (candidates.items, 0..) |global_index, local_index| {
            if (scheduled[local_index]) continue;
            if (!dependenciesScheduled(deps[local_index].items, scheduled)) continue;
            try order.append(ir.allocator, global_index);
            scheduled[local_index] = true;
            progressed = true;
        }
        if (!progressed) {
            if (candidates.items.len > 0) try addPassDiagnostic(ir, passes[candidates.items[0]], "PassDependencyCycle: pass dependencies contain a cycle in slot '{s}'", .{@tagName(slot)});
            return error.PassDependencyCycle;
        }
    }

    for (deps) |*list| list.deinit(ir.allocator);
    ir.allocator.free(deps);
    candidates.deinit(ir.allocator);
    return try order.toOwnedSlice(ir.allocator);
}

fn dependenciesScheduled(deps: []const usize, scheduled: []const bool) bool {
    for (deps) |dep| {
        if (!scheduled[dep]) return false;
    }
    return true;
}

fn candidateLocalIndex(candidates: []const usize, global_index: usize) ?usize {
    for (candidates, 0..) |candidate, index| {
        if (candidate == global_index) return index;
    }
    return null;
}

fn resolvePassDependency(ir: *core.Ir, passes: []const PassDescriptor, name: []const u8, owner: PassDescriptor) !usize {
    var match_index: ?usize = null;
    var matches: usize = 0;
    for (passes, 0..) |pass, index| {
        if (std.mem.eql(u8, pass.id, name) or std.mem.eql(u8, pass.function_name, name)) {
            match_index = index;
            matches += 1;
        }
    }
    if (matches == 0) {
        try addPassDiagnostic(ir, owner, "UnknownPassDependency: unknown pass dependency '{s}'", .{name});
        return error.UnknownPassDependency;
    }
    if (matches > 1) {
        try addPassDiagnostic(ir, owner, "AmbiguousPassDependency: dependency '{s}' matches multiple passes; use a fully qualified pass id", .{name});
        return error.AmbiguousPassDependency;
    }
    return match_index.?;
}

fn addPassDiagnostic(ir: *core.Ir, pass: PassDescriptor, comptime fmt: []const u8, args: anytype) !void {
    const origin = try functionOrigin(ir, pass, pass.function);
    defer ir.allocator.free(origin);
    try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = try std.fmt.allocPrint(ir.allocator, fmt, args) },
    });
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
            if (env.get(name)) |value| break :blk try value.clone(ir.allocator);
            if (functions.get(name)) |func| {
                if (func.kind == .constant) {
                    break :blk try invokeUserFunctionValue(ir, env, functions, func, current_origin, .{
                        .name = name,
                        .args = std.ArrayList(Expr).empty,
                    });
                }
                break :blk .{ .function = try eval_functions.functionRefFor(ir.allocator, func) };
            }
            return error.UnknownIdentifier;
        },
        .string => |text| .{ .string = text },
        .number => |value| .{ .number = value },
        .boolean => |value| .{ .boolean = value },
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
    const descriptor = sema.call(call.name) orelse return error.UnknownFunction;
    return switch (descriptor) {
        .function => |func| blk: {
            if (func.kind == .constant) return error.UnknownFunction;
            try eval_functions.requireReturnsValue(func);
            break :blk try invokeUserFunctionValue(ir, env, functions, func, current_origin, call);
        },
        .primitive => |primitive| blk: {
            var ctx = BuiltinContext{
                .ir = ir,
                .env = env,
                .functions = functions,
                .current_origin = current_origin,
            };
            break :blk try builtin.evalCall(&ctx, call, primitive);
        },
    };
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
        const base = try self.materializeForUse(try self.evalExprValue(call.args.items[0]));
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
        return error.UnsupportedPassPrimitive;
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
        return try resolveValueObjectId(try self.evalExprValue(call.args.items[index]));
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

    pub fn ownString(self: *BuiltinContext, text: []u8) ![]const u8 {
        return try self.ir.ownString(text);
    }

    pub fn materializeForUse(self: *BuiltinContext, value: core.Value) !core.Value {
        return try materializeCodeRoot(self.ir.allocator, value);
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
        return error.UnsupportedPassPrimitive;
    }

    pub fn makeGroup(self: *BuiltinContext, child_ids: []const core.NodeId) !core.NodeId {
        _ = self;
        _ = child_ids;
        return error.UnsupportedPassPrimitive;
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

    pub fn frameX(self: *BuiltinContext, object_id: core.NodeId) !f32 {
        return (self.ir.getNode(object_id) orelse return error.UnknownNode).frame.x;
    }

    pub fn frameY(self: *BuiltinContext, object_id: core.NodeId) !f32 {
        return (self.ir.getNode(object_id) orelse return error.UnknownNode).frame.y;
    }

    pub fn frameWidth(self: *BuiltinContext, object_id: core.NodeId) !f32 {
        return (self.ir.getNode(object_id) orelse return error.UnknownNode).frame.width;
    }

    pub fn frameHeight(self: *BuiltinContext, object_id: core.NodeId) !f32 {
        return (self.ir.getNode(object_id) orelse return error.UnknownNode).frame.height;
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

    pub fn equalAnchorConstraintSet(self: *BuiltinContext, target: core.AnchorValue, source: core.AnchorValue, offset: f32) !core.ConstraintSet {
        return switch (target) {
            .page => error.PageCannotBeConstraintTarget,
            .node => |node| blk: {
                var bundle = core.ConstraintSet.init();
                errdefer bundle.deinit(self.ir.allocator);
                try bundle.items.append(self.ir.allocator, .{
                    .target_node = node.node_id,
                    .target_anchor = node.anchor,
                    .source = source.toConstraintSource(),
                    .offset = offset,
                    .origin = self.current_origin,
                });
                break :blk bundle;
            },
        };
    }

    pub fn emitDiagnosticReport(self: *BuiltinContext, severity: core.DiagnosticSeverity, message: []const u8) !void {
        try self.ir.addValidationDiagnostic(severity, null, null, self.current_origin, .{
            .user_report = .{ .message = try self.ir.allocator.dupe(u8, message) },
        });
    }

    pub fn checkAssetExists(self: *BuiltinContext, object_id: core.NodeId) !void {
        _ = self;
        _ = object_id;
        return error.UnsupportedPassPrimitive;
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
            try putEnvValue(ir.allocator, env, binding.name, value);
        },
        .return_expr => |expr| {
            return .{ .returned = try evalExpr(ir, env, functions, origin, expr) };
        },
        .property_set => |property_set| {
            const base = env.get(property_set.object_name) orelse return error.UnknownIdentifier;
            const object_id = try resolveValueObjectId(base);
            const value = try evalExpr(ir, env, functions, origin, property_set.value);
            const text = try resolveValuePropertyString(ir.allocator, value);
            defer if (eval_value.propertyStringNeedsFree(value)) ir.allocator.free(text);
            try ir.setNodeProperty(object_id, property_set.property_name, text);
        },
        .if_stmt => |if_stmt| {
            const value = try evalExpr(ir, env, functions, origin, if_stmt.condition);
            const condition = try resolveValueBoolean(value);
            const branch = if (condition) if_stmt.then_statements.items else if_stmt.else_statements.items;
            var branch_env = try cloneValueEnv(ir.allocator, env);
            defer deinitValueEnv(ir.allocator, &branch_env);
            for (branch) |nested| {
                const flow = try executeStatement(ir, &branch_env, functions, nested, null);
                switch (flow) {
                    .none => {},
                    .returned => return flow,
                }
            }
        },
        .expr_stmt => |expr| {
            var value = try evalExpr(ir, env, functions, origin, expr);
            defer value.deinit(ir.allocator);
            switch (value) {
                .constraints => |constraints| try ir.constraints.appendSlice(ir.allocator, constraints.items.items),
                else => {},
            }
        },
        .constrain => |decl| {
            const target = try resolveAnchorRef(ir, env, origin, decl.target, true);
            const source = try resolveAnchorRef(ir, env, origin, decl.source, false);
            const offset: f32 = if (decl.offset) |expr| try resolveValueNumber(try evalExpr(ir, env, functions, origin, expr)) else 0;
            try ir.constraints.append(ir.allocator, .{
                .target_node = target.node_id,
                .target_anchor = target.anchor,
                .source = source,
                .offset = offset,
                .origin = origin,
            });
        },
    }
    return .none;
}

const ResolvedTarget = struct {
    node_id: core.NodeId,
    anchor: core.Anchor,
};

fn resolveAnchorRef(
    ir: *core.Ir,
    env: *std.StringHashMap(core.Value),
    origin: []const u8,
    anchor_ref: ast.AnchorRef,
    comptime is_target: bool,
) !if (is_target) ResolvedTarget else core.ConstraintSource {
    _ = ir;
    _ = origin;
    switch (anchor_ref.kind) {
        .page => {
            if (is_target) return error.PageCannotBeConstraintTarget;
            return .{ .page = anchor_ref.anchor };
        },
        .node => {
            const value = env.get(anchor_ref.node_name.?) orelse return error.UnknownIdentifier;
            const node_id = try resolveValueObjectId(value);
            if (is_target) return .{ .node_id = node_id, .anchor = anchor_ref.anchor };
            return .{ .node = .{ .node_id = node_id, .anchor = anchor_ref.anchor } };
        },
    }
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
    try eval_functions.requireArity(call.args.items.len, func);
    for (func.params.items, 0..) |param, index| {
        const value = if (index < call.args.items.len)
            try evalExpr(ir, caller_env, functions, current_origin, call.args.items[index])
        else
            try evalExpr(ir, local_env, functions, current_origin, (param.default_value orelse return error.InvalidArity).*);
        contracts.ensureValueSortWithCode(ir, null, value, param.sort, current_origin, .UnmatchedArgumentType) catch |err| {
            var owned = value;
            owned.deinit(ir.allocator);
            return err;
        };
        try putEnvValue(ir.allocator, local_env, param.name, value);
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
    try eval_functions.requireArity(args.len, func);
    for (func.params.items, 0..) |param, index| {
        const value = if (index < args.len)
            try args[index].clone(ir.allocator)
        else
            try evalExpr(ir, local_env, functions, current_origin, (param.default_value orelse return error.InvalidArity).*);
        contracts.ensureValueSortWithCode(ir, null, value, param.sort, current_origin, .UnmatchedArgumentType) catch |err| {
            var owned = value;
            owned.deinit(ir.allocator);
            return err;
        };
        try putEnvValue(ir.allocator, local_env, param.name, value);
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
    var local_env = try cloneValueEnv(ir.allocator, env);
    defer deinitValueEnv(ir.allocator, &local_env);
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
    var local_env = try cloneValueEnv(ir.allocator, env);
    defer deinitValueEnv(ir.allocator, &local_env);
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
    try eval_functions.requireReturnsValue(func);
    for (func.statements.items) |inner| {
        const flow = try executeStatement(ir, env, functions, inner, current_origin);
        switch (flow) {
            .none => {},
            .returned => |value| {
                try contracts.ensureValueSortWithCode(ir, null, value, func.result_sort, current_origin, .UnmatchedReturnType);
                return value;
            },
        }
    }
    return error.FunctionDidNotReturnValue;
}

fn resolveValueString(value: core.Value) ![]const u8 {
    return eval_value.string(value);
}

fn resolveValuePropertyString(allocator: std.mem.Allocator, value: core.Value) ![]const u8 {
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
        .code => |code| switch (code.root) {
            .object => |id| id,
            else => error.ExpectedObject,
        },
        else => error.ExpectedObject,
    };
}

fn materializeCodeRoot(allocator: std.mem.Allocator, value: core.Value) !core.Value {
    return switch (value) {
        .code => |code| switch (code.root) {
            .document => |id| .{ .document = id },
            .page => |id| .{ .page = id },
            .object => |id| .{ .object = id },
            .selection => |selection| .{ .selection = try selection.clone(allocator) },
        },
        else => value,
    };
}

fn functionOrigin(ir: *const core.Ir, pass: PassDescriptor, func: FunctionDecl) ![]const u8 {
    const module = ir.moduleById(pass.module_id);
    const path = if (module) |m| m.path orelse m.spec else "";
    if (path.len == 0) return std.fmt.allocPrint(ir.allocator, "bytes:{d}-{d}", .{ func.span.start, func.span.end });
    return std.fmt.allocPrint(ir.allocator, "path:{s}:bytes:{d}-{d}", .{ path, func.span.start, func.span.end });
}

fn annotationOrigin(ir: *const core.Ir, module_id: core.SourceModuleId, function_name: []const u8) ![]const u8 {
    const module = ir.moduleById(module_id);
    const path = if (module) |m| m.path orelse m.spec else "";
    if (module) |m| {
        for (m.program.functions.items) |func| {
            if (!std.mem.eql(u8, func.name, function_name)) continue;
            if (path.len == 0) return std.fmt.allocPrint(ir.allocator, "bytes:{d}-{d}", .{ func.span.start, func.span.end });
            return std.fmt.allocPrint(ir.allocator, "path:{s}:bytes:{d}-{d}", .{ path, func.span.start, func.span.end });
        }
    }
    if (path.len == 0) return std.fmt.allocPrint(ir.allocator, "function:{s}", .{function_name});
    return std.fmt.allocPrint(ir.allocator, "path:{s}", .{path});
}

fn statementOrigin(allocator: std.mem.Allocator, span: ast.Span) ![]const u8 {
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}
