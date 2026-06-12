const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const language_names = @import("../language/names.zig");
const semantic_env = @import("../language/env.zig");

const SemanticEnv = semantic_env.SemanticEnv;

const Label = union(enum) {
    function: core.FunctionKey,
    lambda: ast.Span,

    fn lessThan(_: void, left: Label, right: Label) bool {
        return switch (left) {
            .function => |left_key| switch (right) {
                .function => |right_key| functionKeyLessThan(left_key, right_key),
                .lambda => true,
            },
            .lambda => |left_span| switch (right) {
                .function => false,
                .lambda => |right_span| spanLessThan(left_span, right_span),
            },
        };
    }
};

const LabelContext = struct {
    pub fn hash(_: LabelContext, label: Label) u64 {
        var hasher = std.hash.Wyhash.init(0);
        switch (label) {
            .function => |key| {
                hasher.update(&.{0});
                hasher.update(std.mem.asBytes(&key.module_id));
                hasher.update(key.name);
            },
            .lambda => |span| {
                hasher.update(&.{1});
                hasher.update(std.mem.asBytes(&span.start));
                hasher.update(std.mem.asBytes(&span.end));
            },
        }
        return hasher.final();
    }

    pub fn eql(_: LabelContext, left: Label, right: Label) bool {
        return switch (left) {
            .function => |left_key| switch (right) {
                .function => |right_key| left_key.eql(right_key),
                .lambda => false,
            },
            .lambda => |left_span| switch (right) {
                .function => false,
                .lambda => |right_span| spanEql(left_span, right_span),
            },
        };
    }
};

const LabelMap = std.HashMap(Label, void, LabelContext, std.hash_map.default_max_load_percentage);
const LambdaMap = std.AutoHashMap(ast.Span, ast.LambdaExpr);
const LambdaCaptureMap = std.AutoHashMap(ast.Span, std.ArrayList(FunctionEnv));

const LabelSet = struct {
    labels: LabelMap,

    fn init(allocator: std.mem.Allocator) LabelSet {
        return .{ .labels = LabelMap.init(allocator) };
    }

    fn singleton(allocator: std.mem.Allocator, label: Label) !LabelSet {
        var set = init(allocator);
        try set.add(label);
        return set;
    }

    fn add(self: *LabelSet, label: Label) !void {
        try self.labels.put(label, {});
    }

    fn deinit(self: *LabelSet) void {
        self.labels.deinit();
    }

    fn unionWith(self: *LabelSet, other: LabelSet) !void {
        var iterator = other.labels.keyIterator();
        while (iterator.next()) |label| try self.add(label.*);
    }

    fn clone(self: LabelSet, allocator: std.mem.Allocator) !LabelSet {
        var out = init(allocator);
        try out.unionWith(self);
        return out;
    }

    fn count(self: LabelSet) usize {
        return self.labels.count();
    }
};

const FunctionEnv = struct {
    values: std.StringHashMap(LabelSet),

    fn init(allocator: std.mem.Allocator) FunctionEnv {
        return .{ .values = std.StringHashMap(LabelSet).init(allocator) };
    }

    fn clone(self: FunctionEnv, allocator: std.mem.Allocator) !FunctionEnv {
        var out = init(allocator);
        var iterator = self.values.iterator();
        while (iterator.next()) |entry| {
            try out.values.put(entry.key_ptr.*, try entry.value_ptr.clone(allocator));
        }
        return out;
    }

    fn set(self: *FunctionEnv, allocator: std.mem.Allocator, name: []const u8, value: LabelSet) !void {
        try self.values.put(name, try value.clone(allocator));
    }

    fn get(self: *const FunctionEnv, name: []const u8) ?LabelSet {
        return self.values.get(name);
    }
};

const Activation = struct {
    label: Label,
    env: FunctionEnv,
    owner: ?ast.FunctionDecl,
    module_id: core.SourceModuleId,
};

const Analyzer = struct {
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: SemanticEnv,
    states: std.StringHashMap(u8),
    returns: std.StringHashMap(LabelSet),
    lambda_exprs: LambdaMap,
    lambda_captures: LambdaCaptureMap,

    fn init(allocator: std.mem.Allocator, ir: *core.Ir, sema: *const SemanticEnv) Analyzer {
        return .{
            .allocator = allocator,
            .ir = ir,
            .sema = sema.*,
            .states = std.StringHashMap(u8).init(allocator),
            .returns = std.StringHashMap(LabelSet).init(allocator),
            .lambda_exprs = LambdaMap.init(allocator),
            .lambda_captures = LambdaCaptureMap.init(allocator),
        };
    }

    fn checkAll(self: *Analyzer) !void {
        var it = self.sema.functions.iterator();
        while (it.next()) |entry| {
            const func = entry.value_ptr.*;
            const label = self.namedLabel(entry.key_ptr.*);
            const env = FunctionEnv.init(self.allocator);
            _ = try self.enter(.{ .label = label, .env = env, .owner = func, .module_id = entry.key_ptr.module_id });
        }
        try self.checkRoots();
    }

    fn checkRoots(self: *Analyzer) !void {
        for (self.ir.module_order.items) |module_id| {
            const module = self.ir.moduleById(module_id) orelse continue;
            const previous = self.sema;
            self.sema = self.sema.forModule(module_id);
            {
                defer self.sema = previous;
                var document_env = FunctionEnv.init(self.allocator);
                var document_returns = LabelSet.init(self.allocator);
                try self.analyzeStatements(module.program.document_statements.items, &document_env, &document_returns, null);
                for (module.program.pages.items) |page| {
                    var page_env = FunctionEnv.init(self.allocator);
                    var page_returns = LabelSet.init(self.allocator);
                    try self.analyzeStatements(page.statements.items, &page_env, &page_returns, null);
                }
            }
        }
    }

    fn namedLabel(_: *Analyzer, key: core.FunctionKey) Label {
        return .{ .function = key };
    }

    fn lambdaLabel(_: *Analyzer, lambda: ast.LambdaExpr) Label {
        return .{ .lambda = lambda.span };
    }

    fn enter(self: *Analyzer, activation: Activation) anyerror!LabelSet {
        const key = try self.activationKey(activation);
        if (self.states.get(key)) |state| {
            if (state == 1) {
                try self.reportRecursiveActivation(activation);
                return error.RecursiveFunction;
            }
            if (self.returns.get(key)) |cached| return try cached.clone(self.allocator);
            return LabelSet.init(self.allocator);
        }

        try self.states.put(key, 1);
        var result = LabelSet.init(self.allocator);
        switch (activation.label) {
            .function => |function_key| {
                const func = self.sema.functions.get(function_key) orelse return LabelSet.init(self.allocator);
                var env = try activation.env.clone(self.allocator);
                const previous = self.sema;
                self.sema = self.sema.forModule(activation.module_id);
                defer self.sema = previous;
                try self.analyzeStatements(func.statements.items, &env, &result, func);
            },
            .lambda => |span| {
                const lambda = self.lambda_exprs.get(span) orelse return LabelSet.init(self.allocator);
                const body_labels = try self.exprLabels(lambda.body.*, &activation.env, activation.owner);
                try result.unionWith(body_labels);
            },
        }
        try self.states.put(key, 2);
        try self.returns.put(key, try result.clone(self.allocator));
        return result;
    }

    fn analyzeStatements(
        self: *Analyzer,
        statements: []const ast.Statement,
        env: *FunctionEnv,
        returns: *LabelSet,
        owner: ?ast.FunctionDecl,
    ) anyerror!void {
        for (statements) |stmt| {
            switch (stmt.kind) {
                .let_binding => |binding| {
                    const labels = try self.exprLabels(binding.expr, env, owner);
                    if (language_names.isDiscardBindingName(binding.name)) continue;
                    try env.set(self.allocator, binding.name, labels);
                },
                .return_expr => |expr| {
                    const labels = try self.exprLabels(expr, env, owner);
                    try returns.unionWith(labels);
                },
                .return_void => {},
                .property_set => |property_set| {
                    _ = try self.exprLabels(property_set.value, env, owner);
                },
                .if_stmt => |if_stmt| {
                    _ = try self.exprLabels(if_stmt.condition, env, owner);
                    var then_env = try env.clone(self.allocator);
                    try self.analyzeStatements(if_stmt.then_statements.items, &then_env, returns, owner);
                    var else_env = try env.clone(self.allocator);
                    try self.analyzeStatements(if_stmt.else_statements.items, &else_env, returns, owner);
                },
                .constrain => |decl| if (decl.offset) |expr| {
                    _ = try self.exprLabels(expr, env, owner);
                },
                .expr_stmt => |expr| {
                    _ = try self.exprLabels(expr, env, owner);
                },
            }
        }
    }

    fn exprLabels(self: *Analyzer, expr: ast.Expr, env: *const FunctionEnv, owner: ?ast.FunctionDecl) anyerror!LabelSet {
        switch (expr) {
            .ident => |name| {
                if (env.get(name)) |labels| return try labels.clone(self.allocator);
                if (self.sema.resolvedFunction(ast.CallableName.bare(name))) |resolved| {
                    const label = self.namedLabel(resolved.key);
                    if (resolved.decl.kind == .constant) {
                        const empty_env = FunctionEnv.init(self.allocator);
                        return try self.enter(.{ .label = label, .env = empty_env, .owner = resolved.decl, .module_id = resolved.module_id });
                    }
                    return try LabelSet.singleton(self.allocator, label);
                }
                return LabelSet.init(self.allocator);
            },
            .string, .color, .number, .boolean, .none, .enum_case => return LabelSet.init(self.allocator),
            .lambda => |lambda| {
                const label = try self.registerLambda(lambda, env);
                return try LabelSet.singleton(self.allocator, label);
            },
            .call => |call| return try self.callLabels(call, env, owner),
            .apply => |apply| {
                const callee_labels = try self.exprLabels(apply.callee.*, env, owner);
                const arg_labels = try self.argumentLabelSets(apply.args.items, env, owner);
                return try self.invokeLabels(callee_labels, arg_labels.items, owner);
            },
            .member => |member| return try self.exprLabels(member.target.*, env, owner),
            .optional_check => |check| return try self.exprLabels(check.target.*, env, owner),
            .coalesce => |coalesce| {
                var target = try self.exprLabels(coalesce.target.*, env, owner);
                errdefer target.deinit();
                var fallback = try self.exprLabels(coalesce.fallback.*, env, owner);
                defer fallback.deinit();
                try target.unionWith(fallback);
                return target;
            },
        }
    }

    fn callLabels(self: *Analyzer, call: ast.CallExpr, env: *const FunctionEnv, owner: ?ast.FunctionDecl) anyerror!LabelSet {
        if (!call.callee.isQualified()) {
            if (env.get(call.callee.name)) |callee_labels| {
                const arg_labels = try self.argumentLabelSets(call.args.items, env, owner);
                return try self.invokeLabels(callee_labels, arg_labels.items, owner);
            }
        }

        const descriptor = self.sema.callCallee(call.callee) orelse {
            const arg_labels = try self.argumentLabelSets(call.args.items, env, owner);
            _ = arg_labels;
            return LabelSet.init(self.allocator);
        };

        switch (descriptor) {
            .function => |resolved| {
                const func = resolved.decl;
                const label = self.namedLabel(resolved.key);
                const arg_labels = try self.argumentLabelSets(call.args.items, env, owner);
                if (func.kind == .constant and func.result_type.kind == .function) {
                    const const_labels = try self.invokeNamed(label, resolved.module_id, func, &.{});
                    return try self.invokeLabels(const_labels, arg_labels.items, owner);
                }
                return try self.invokeNamed(label, resolved.module_id, func, arg_labels.items);
            },
            .primitive => |primitive| {
                const arg_labels = try self.argumentLabelSets(call.args.items, env, owner);
                if (primitive.callback) |callback_spec| {
                    if (call.args.items.len > callback_spec.function_arg_index) {
                        const callback = try self.exprLabels(call.args.items[callback_spec.function_arg_index], env, owner);
                        var callback_args = std.ArrayList(LabelSet).empty;
                        var fixed_index: usize = 0;
                        while (fixed_index < callback_spec.supplied_arg_count) : (fixed_index += 1) {
                            try callback_args.append(self.allocator, LabelSet.init(self.allocator));
                        }
                        var index = callback_spec.function_arg_index + 1;
                        while (index < arg_labels.items.len) : (index += 1) {
                            try callback_args.append(self.allocator, arg_labels.items[index]);
                        }
                        _ = try self.invokeLabels(callback, callback_args.items, owner);
                    }
                }
                return LabelSet.init(self.allocator);
            },
        }
    }

    fn argumentLabelSets(
        self: *Analyzer,
        args: []const ast.Expr,
        env: *const FunctionEnv,
        owner: ?ast.FunctionDecl,
    ) !std.ArrayList(LabelSet) {
        var labels = std.ArrayList(LabelSet).empty;
        for (args) |arg| {
            try labels.append(self.allocator, try self.exprLabels(arg, env, owner));
        }
        return labels;
    }

    fn invokeLabels(
        self: *Analyzer,
        labels: LabelSet,
        args: []const LabelSet,
        owner: ?ast.FunctionDecl,
    ) anyerror!LabelSet {
        var result = LabelSet.init(self.allocator);
        var iterator = labels.labels.keyIterator();
        while (iterator.next()) |label_ptr| {
            const returned = try self.invokeLabel(label_ptr.*, args, owner);
            try result.unionWith(returned);
        }
        return result;
    }

    fn invokeLabel(
        self: *Analyzer,
        label: Label,
        args: []const LabelSet,
        owner: ?ast.FunctionDecl,
    ) anyerror!LabelSet {
        return switch (label) {
            .function => |key| blk: {
                const func = self.sema.functions.get(key) orelse break :blk LabelSet.init(self.allocator);
                break :blk try self.invokeNamed(label, key.module_id, func, args);
            },
            .lambda => |span| blk: {
                const captures = self.lambda_captures.get(span) orelse break :blk LabelSet.init(self.allocator);
                var result = LabelSet.init(self.allocator);
                for (captures.items) |capture_env| {
                    const lambda = self.lambda_exprs.get(span) orelse break :blk LabelSet.init(self.allocator);
                    var env = try capture_env.clone(self.allocator);
                    try self.bindParams(&env, lambda.params.items, args);
                    const returned = try self.enter(.{ .label = label, .env = env, .owner = owner, .module_id = self.sema.module_id });
                    try result.unionWith(returned);
                }
                break :blk result;
            },
        };
    }

    fn invokeNamed(
        self: *Analyzer,
        label: Label,
        module_id: core.SourceModuleId,
        func: ast.FunctionDecl,
        args: []const LabelSet,
    ) anyerror!LabelSet {
        var env = FunctionEnv.init(self.allocator);
        try self.bindParams(&env, func.params.items, args);
        var index: usize = args.len;
        while (index < func.params.items.len) : (index += 1) {
            const param = func.params.items[index];
            if (param.default_value) |default_value| {
                const previous = self.sema;
                self.sema = self.sema.forModule(module_id);
                {
                    defer self.sema = previous;
                    const labels = try self.exprLabels(default_value.*, &env, func);
                    try env.set(self.allocator, param.name, labels);
                }
            }
        }
        return try self.enter(.{ .label = label, .env = env, .owner = func, .module_id = module_id });
    }

    fn bindParams(self: *Analyzer, env: *FunctionEnv, params: []const ast.ParamDecl, args: []const LabelSet) !void {
        var index: usize = 0;
        while (index < params.len and index < args.len) : (index += 1) {
            if (params[index].ty.kind == .function) {
                try env.set(self.allocator, params[index].name, args[index]);
            }
        }
    }

    fn registerLambda(self: *Analyzer, lambda: ast.LambdaExpr, env: *const FunctionEnv) !Label {
        const label = self.lambdaLabel(lambda);
        if (!self.lambda_exprs.contains(lambda.span)) try self.lambda_exprs.put(lambda.span, lambda);
        const capture = try env.clone(self.allocator);
        const gop = try self.lambda_captures.getOrPut(lambda.span);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(FunctionEnv).empty;
        try gop.value_ptr.append(self.allocator, capture);
        return label;
    }

    fn activationKey(self: *Analyzer, activation: Activation) ![]const u8 {
        var names = std.ArrayList([]const u8).empty;
        var iterator = activation.env.values.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.count() != 0) try names.append(self.allocator, entry.key_ptr.*);
        }
        std.mem.sort([]const u8, names.items, {}, stringLessThan);

        var out = std.ArrayList(u8).empty;
        try self.appendLabel(&out, activation.label);
        for (names.items) |name| {
            try out.append(self.allocator, '|');
            try out.appendSlice(self.allocator, name);
            try out.appendSlice(self.allocator, "=[");
            const labels = activation.env.values.get(name).?;
            var label_names = std.ArrayList([]const u8).empty;
            var label_iterator = labels.labels.keyIterator();
            while (label_iterator.next()) |label| {
                try label_names.append(self.allocator, try self.labelText(label.*));
            }
            std.mem.sort([]const u8, label_names.items, {}, stringLessThan);
            for (label_names.items, 0..) |label, index| {
                if (index > 0) try out.append(self.allocator, ',');
                try out.appendSlice(self.allocator, label);
            }
            try out.append(self.allocator, ']');
        }
        return try out.toOwnedSlice(self.allocator);
    }

    fn appendLabel(self: *Analyzer, out: *std.ArrayList(u8), label: Label) !void {
        const text = try self.labelText(label);
        try out.appendSlice(self.allocator, text);
    }

    fn labelText(self: *Analyzer, label: Label) ![]const u8 {
        return switch (label) {
            .function => |key| try std.fmt.allocPrint(self.allocator, "fn:{d}:{s}", .{ key.module_id, key.name }),
            .lambda => |span| try std.fmt.allocPrint(self.allocator, "lambda:{d}-{d}", .{ span.start, span.end }),
        };
    }

    fn reportRecursiveActivation(self: *Analyzer, activation: Activation) !void {
        if (activation.owner) |func| {
            try reportRecursiveFunction(self.allocator, self.ir, activation.module_id, func);
            return;
        }
        try self.ir.addValidationDiagnostic(.@"error", null, null, "bytes:0-0", .{
            .user_report = .{ .message = try self.allocator.dupe(u8, "RecursiveFunction: recursive function value application") },
        });
    }
};

pub fn checkFunctionCallGraph(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var analyzer = Analyzer.init(arena.allocator(), ir, sema);
    try analyzer.checkAll();
}

fn reportRecursiveFunction(allocator: std.mem.Allocator, ir: *core.Ir, module_id: core.SourceModuleId, func: ast.FunctionDecl) !void {
    const origin = try functionOrigin(allocator, ir, module_id, func);
    try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
        .recursive_function = .{ .function_name = func.name },
    });
}

fn functionOrigin(allocator: std.mem.Allocator, ir: *const core.Ir, module_id: core.SourceModuleId, func: ast.FunctionDecl) ![]const u8 {
    if (ir.moduleById(module_id)) |module| {
        const path = module.path orelse module.spec;
        if (path.len != 0) return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ path, func.span.start, func.span.end });
    }
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ func.span.start, func.span.end });
}

fn functionKeyLessThan(left: core.FunctionKey, right: core.FunctionKey) bool {
    if (left.module_id != right.module_id) return left.module_id < right.module_id;
    return std.mem.lessThan(u8, left.name, right.name);
}

fn spanEql(left: ast.Span, right: ast.Span) bool {
    return left.start == right.start and left.end == right.end;
}

fn spanLessThan(left: ast.Span, right: ast.Span) bool {
    if (left.start != right.start) return left.start < right.start;
    return left.end < right.end;
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
