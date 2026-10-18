const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const registry = @import("../language/registry.zig");
const language_names = @import("../language/names.zig");
const semantic_env = @import("../language/env.zig");
const analysis_env = @import("env.zig");

const SemanticEnv = semantic_env.SemanticEnv;
const input_facts = core.placement_inputs;
const captures = @import("captures.zig");

// Closure specialization can create an unbounded sequence of environments.
// Exhaustion rejects the program before evaluation; it is not a termination proof.
const max_call_analysis_depth = 128;

const LambdaKey = struct {
    module_id: core.SourceModuleId,
    span: ast.Span,
    capture_id: usize = 0,
    analysis_id: ?u64 = null,
};

const Label = union(enum) {
    function: core.FunctionKey,
    lambda: LambdaKey,

    fn moduleId(self: Label) core.SourceModuleId {
        return switch (self) {
            .function => |key| key.module_id,
            .lambda => |key| key.module_id,
        };
    }

    fn lessThan(_: void, left: Label, right: Label) bool {
        return switch (left) {
            .function => |left_key| switch (right) {
                .function => |right_key| functionKeyLessThan(left_key, right_key),
                .lambda => true,
            },
            .lambda => |left_key| switch (right) {
                .function => false,
                .lambda => |right_key| if (left_key.module_id != right_key.module_id)
                    left_key.module_id < right_key.module_id
                else if (!spanEql(left_key.span, right_key.span))
                    spanLessThan(left_key.span, right_key.span)
                else if (left_key.analysis_id != right_key.analysis_id)
                    optionalIdLessThan(u64, left_key.analysis_id, right_key.analysis_id)
                else
                    left_key.capture_id < right_key.capture_id,
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
                std.hash.autoHash(&hasher, key.instance_id);
            },
            .lambda => |key| {
                hasher.update(&.{1});
                hasher.update(std.mem.asBytes(&key.module_id));
                hasher.update(std.mem.asBytes(&key.span.start));
                hasher.update(std.mem.asBytes(&key.span.end));
                hasher.update(std.mem.asBytes(&key.capture_id));
                std.hash.autoHash(&hasher, key.analysis_id);
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
            .lambda => |left_key| switch (right) {
                .function => false,
                .lambda => |right_key| left_key.module_id == right_key.module_id and spanEql(left_key.span, right_key.span) and left_key.capture_id == right_key.capture_id and left_key.analysis_id == right_key.analysis_id,
            },
        };
    }
};

const LabelMap = std.HashMap(Label, void, LabelContext, std.hash_map.default_max_load_percentage);
const ConstVisitSet = std.HashMap(core.FunctionKey, void, core.FunctionKeyContext, std.hash_map.default_max_load_percentage);
const LambdaMap = std.AutoHashMap(LambdaKey, ast.LambdaExpr);
const LambdaCaptureMap = std.AutoHashMap(LambdaKey, FunctionEnv);

// Function candidates follow the runtime value shape. Optional values use the
// same facts as their present value; none contributes no function candidates.
// Unknown facts also describe unspecified record fields. Explicit fields can
// refine them, for example after a record update.
const ValueFacts = struct {
    labels: LabelMap,
    fields: std.StringHashMap(ValueFacts),
    children: std.ArrayList(ValueFacts) = .empty,
    objects: std.AutoHashMap(usize, void),
    unknown_objects: bool = false,
    unknown: bool = false,
    selected_types: std.ArrayList(ast.Type) = .empty,
    reference: ?input_facts.Value.Reference = null,
    string_literal: ?[]const u8 = null,
    unknown_string: bool = false,
    unknown_reference: bool = false,

    fn init(allocator: std.mem.Allocator) ValueFacts {
        return .{ .labels = LabelMap.init(allocator), .fields = std.StringHashMap(ValueFacts).init(allocator), .objects = std.AutoHashMap(usize, void).init(allocator) };
    }

    fn unknownValue(allocator: std.mem.Allocator) ValueFacts {
        var value = init(allocator);
        value.unknown = true;
        value.unknown_objects = true;
        return value;
    }

    fn singleton(allocator: std.mem.Allocator, label: Label) !ValueFacts {
        var value = init(allocator);
        try value.labels.put(label, {});
        return value;
    }

    fn deinit(self: *ValueFacts) void {
        var fields = self.fields.valueIterator();
        while (fields.next()) |field| field.deinit();
        for (self.children.items) |*child| child.deinit();
        self.children.deinit(self.fields.allocator);
        self.selected_types.deinit(self.fields.allocator);
        self.fields.deinit();
        self.labels.deinit();
        self.objects.deinit();
    }

    fn eql(self: ValueFacts, other: ValueFacts) bool {
        if (self.selected_types.items.len != other.selected_types.items.len) return false;
        for (self.selected_types.items) |ty| {
            var found = false;
            for (other.selected_types.items) |other_ty| if (ast.Type.eql(ty, other_ty)) {
                found = true;
                break;
            };
            if (!found) return false;
        }
        if (self.unknown != other.unknown or self.unknown_objects != other.unknown_objects or
            self.unknown_string != other.unknown_string or self.unknown_reference != other.unknown_reference or
            self.labels.count() != other.labels.count() or self.objects.count() != other.objects.count() or
            self.fields.count() != other.fields.count() or self.children.items.len != other.children.items.len or
            !referenceEql(self.reference, other.reference) or !optionalStringEql(self.string_literal, other.string_literal)) return false;
        var labels = self.labels.keyIterator();
        while (labels.next()) |label| if (!other.labels.contains(label.*)) return false;
        var objects = self.objects.keyIterator();
        while (objects.next()) |id| if (!other.objects.contains(id.*)) return false;
        var fields = self.fields.iterator();
        while (fields.next()) |field| if (!field.value_ptr.eql(other.fields.get(field.key_ptr.*) orelse return false)) return false;
        for (self.children.items, other.children.items) |left, right| if (!left.eql(right)) return false;
        return true;
    }

    fn isEmpty(self: ValueFacts) bool {
        return !self.unknown and !self.unknown_objects and !self.unknown_string and !self.unknown_reference and self.labels.count() == 0 and
            self.objects.count() == 0 and self.fields.count() == 0 and self.children.items.len == 0 and
            self.reference == null and self.string_literal == null and self.selected_types.items.len == 0;
    }

    fn unionWith(self: *ValueFacts, other: ValueFacts) anyerror!void {
        if (other.isEmpty()) return;
        const empty = self.isEmpty();
        for (other.selected_types.items) |ty| {
            var found = false;
            for (self.selected_types.items) |existing| if (ast.Type.eql(ty, existing)) {
                found = true;
                break;
            };
            if (!found) try self.selected_types.append(self.fields.allocator, ty);
        }
        self.unknown_reference = self.unknown_reference or other.unknown_reference or (!empty and !referenceEql(self.reference, other.reference));
        self.unknown_string = self.unknown_string or other.unknown_string or (!empty and !optionalStringEql(self.string_literal, other.string_literal));
        self.reference = if (self.unknown_reference) null else other.reference;
        self.string_literal = if (self.unknown_string) null else other.string_literal;
        var objects = other.objects.keyIterator();
        while (objects.next()) |id| try self.objects.put(id.*, {});
        self.unknown_objects = self.unknown_objects or other.unknown_objects;
        var labels = other.labels.keyIterator();
        while (labels.next()) |label| try self.labels.put(label.*, {});
        var fields = self.fields.iterator();
        while (fields.next()) |field| {
            if (other.fields.get(field.key_ptr.*)) |value| {
                try field.value_ptr.unionWith(value);
            } else if (other.unknown) {
                try field.value_ptr.unionWith(unknownValue(self.fields.allocator));
            }
        }
        var other_fields = other.fields.iterator();
        while (other_fields.next()) |field| {
            if (self.fields.contains(field.key_ptr.*)) continue;
            var value = try field.value_ptr.clone(self.fields.allocator);
            if (self.unknown) try value.unionWith(unknownValue(self.fields.allocator));
            try self.fields.put(field.key_ptr.*, value);
        }
        for (self.children.items, 0..) |*child, index| {
            if (index < other.children.items.len) {
                try child.unionWith(other.children.items[index]);
            } else if (other.unknown) try child.unionWith(unknownValue(self.fields.allocator));
        }
        if (other.children.items.len > self.children.items.len) {
            try self.children.ensureTotalCapacity(self.fields.allocator, other.children.items.len);
            for (other.children.items[self.children.items.len..]) |child| {
                var copy = try child.clone(self.fields.allocator);
                errdefer copy.deinit();
                if (self.unknown) try copy.unionWith(unknownValue(self.fields.allocator));
                self.children.appendAssumeCapacity(copy);
            }
        }
        self.unknown = self.unknown or other.unknown;
    }

    fn clone(self: ValueFacts, allocator: std.mem.Allocator) anyerror!ValueFacts {
        var out = init(allocator);
        errdefer out.deinit();
        try out.unionWith(self);
        return out;
    }

    fn collectFunctions(self: ValueFacts, out: *LabelMap) anyerror!void {
        var labels = self.labels.keyIterator();
        while (labels.next()) |label| try out.put(label.*, {});
        var fields = self.fields.valueIterator();
        while (fields.next()) |field| try field.collectFunctions(out);
        for (self.children.items) |child| try child.collectFunctions(out);
    }

    fn forgetFunctions(self: *ValueFacts) void {
        self.labels.clearRetainingCapacity();
        self.unknown = true;
        var fields = self.fields.valueIterator();
        while (fields.next()) |field| field.forgetFunctions();
        for (self.children.items) |*child| child.forgetFunctions();
    }

    fn getField(self: ValueFacts, name: []const u8, allocator: std.mem.Allocator) !ValueFacts {
        if (self.fields.get(name)) |value| return value.clone(allocator);
        return if (self.unknown) unknownValue(allocator) else init(allocator);
    }

    fn putField(self: *ValueFacts, name: []const u8, value: ValueFacts) !void {
        if (self.fields.fetchRemove(name)) |entry| {
            var old = entry.value;
            old.deinit();
        }
        // Closed scalar fields carry no call or object facts. Omitting them
        // avoids copying complete presentation records through every call.
        // An explicit empty field must still refine an unknown record.
        if (!self.unknown and !value.unknown and !value.unknown_objects and !value.unknown_string and !value.unknown_reference and
            value.labels.count() == 0 and value.objects.count() == 0 and value.fields.count() == 0 and value.children.items.len == 0 and
            value.reference == null and value.string_literal == null and value.selected_types.items.len == 0)
        {
            var empty = value;
            empty.deinit();
            return;
        }
        try self.fields.put(name, value);
    }

    fn updatePath(self: *ValueFacts, path: []const ast.RecordPathSegment, value: ValueFacts) !void {
        std.debug.assert(path.len != 0);
        if (path.len == 1) return self.putField(path[0].name, value);
        var nested = try self.getField(path[0].name, self.fields.allocator);
        try nested.updatePath(path[1..], value);
        try self.putField(path[0].name, nested);
    }
};

fn cloneValueFacts(allocator: std.mem.Allocator, labels: ValueFacts) anyerror!ValueFacts {
    return labels.clone(allocator);
}

fn deinitValueFacts(labels: *ValueFacts) void {
    labels.deinit();
}

const FunctionEnv = analysis_env.CloneEnv(ValueFacts, cloneValueFacts, deinitValueFacts);

const Activation = struct {
    label: Label,
    env: FunctionEnv,
    owner: ?ast.FunctionDecl,
};

const CallSummary = struct { value: ValueFacts, places_objects: bool };
const EffectFrame = struct {
    function: ?core.FunctionKey = null,
    places_objects: bool = false,
    parameter_functions: ?LabelMap = null,
    forwarding_depth: usize = 0,
};

const Analyzer = struct {
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: SemanticEnv,
    states: std.StringHashMap(u8),
    returns: std.StringHashMap(CallSummary),
    effect_frames: std.ArrayList(EffectFrame) = .empty,
    const_visiting: ConstVisitSet,
    const_values: std.HashMap(core.FunctionKey, CallSummary, core.FunctionKeyContext, std.hash_map.default_max_load_percentage),
    lambda_exprs: LambdaMap,
    lambda_captures: LambdaCaptureMap,
    capture_keys: std.StringHashMap(Label),
    capture_index: captures.Index,
    require_known_calls: bool = false,
    current_origin: ?core.SourceOrigin = null,
    call_depth: usize = 0,
    checking_display: bool = false,
    types_checked: bool = true,
    object_properties: std.ArrayList(ValueFacts) = .empty,
    unknown_properties: ValueFacts,
    collecting_inputs: bool = false,
    inputs_changed: bool = false,
    typed_inputs: std.ArrayList(struct { input: ast.Type, receiver: ValueFacts }) = .empty,
    input_type_keys: std.ArrayList(ast.Type) = .empty,
    typed_displays: std.ArrayList(struct { plan: usize, receiver: ValueFacts, origin: ?core.SourceOrigin }) = .empty,

    fn init(allocator: std.mem.Allocator, state: *core.DocumentState, sema: *const SemanticEnv) Analyzer {
        return .{
            .allocator = allocator,
            .state = state,
            .sema = sema.*,
            .states = std.StringHashMap(u8).init(allocator),
            .returns = std.StringHashMap(CallSummary).init(allocator),
            .const_visiting = ConstVisitSet.init(allocator),
            .const_values = .init(allocator),
            .lambda_exprs = LambdaMap.init(allocator),
            .lambda_captures = LambdaCaptureMap.init(allocator),
            .capture_keys = std.StringHashMap(Label).init(allocator),
            .capture_index = captures.Index.init(allocator),
            .unknown_properties = ValueFacts.init(allocator),
        };
    }

    fn checkAll(self: *Analyzer) !void {
        var const_it = self.state.constants.declarations.iterator();
        while (const_it.next()) |entry| {
            var labels = try self.constFacts(.{
                .key = entry.key_ptr.*,
                .module_id = entry.key_ptr.module_id,
                .decl = entry.value_ptr.*,
            });
            labels.deinit();
        }
        var it = self.sema.functions.iterator();
        while (it.next()) |entry| {
            const func = entry.value_ptr.*;
            const label = self.namedLabel(entry.key_ptr.*);
            var env = FunctionEnv.init(self.allocator);
            for (func.params.items) |param| try env.bind(param.name, ValueFacts.unknownValue(self.allocator));
            _ = try self.enter(.{ .label = label, .env = env, .owner = func });
        }
        // Display bodies use the same call analysis in a read-only environment.
        // Keep its summaries separate from ordinary construction calls.
        var displays = Analyzer.init(self.allocator, self.state, &self.sema);
        displays.checking_display = true;
        displays.types_checked = self.types_checked;
        var display_it = self.sema.functions.iterator();
        while (display_it.next()) |entry| {
            const func = entry.value_ptr.*;
            if (!func.isDisplay()) continue;
            var env = FunctionEnv.init(self.allocator);
            for (func.params.items) |param| try env.bind(param.name, ValueFacts.unknownValue(self.allocator));
            _ = try displays.enter(.{ .label = displays.namedLabel(entry.key_ptr.*), .env = env, .owner = func });
        }
        // Declaration checking leaves higher-order parameters open. Recheck
        // executed roots with actual arguments, without reusing open captures
        // or summaries as evidence that a call has been verified.
        var roots = Analyzer.init(self.allocator, self.state, &self.sema);
        roots.types_checked = self.types_checked;
        if (self.types_checked) try roots.collectPlacementInputs();
        roots.require_known_calls = self.types_checked;
        roots.clearPass();
        try roots.checkRoots();
        try roots.checkDisplayFunctions();
        if (self.types_checked) try roots.publishInputs();
    }

    fn clearPass(self: *Analyzer) void {
        self.states.clearRetainingCapacity();
        self.returns.clearRetainingCapacity();
        self.const_values.clearRetainingCapacity();
        self.typed_displays.clearRetainingCapacity();
    }

    // Queries start with no candidates. Join immutable inputs to a fixed point,
    // then check executed calls strictly; discovery never licenses an unknown call.
    fn collectPlacementInputs(self: *Analyzer) !void {
        self.collecting_inputs = true;
        defer self.collecting_inputs = false;
        for (0..max_call_analysis_depth) |_| {
            self.inputs_changed = false;
            self.clearPass();
            try self.checkRoots();
            try self.checkDisplayFunctions();
            if (!self.inputs_changed) return;
        }
        try self.state.addValidationDiagnostic(.@"error", null, null, self.current_origin, .{
            .user_report = .{ .code = "FunctionAnalysisLimitExceeded", .message = try self.state.allocator.dupe(u8, "cannot establish a finite set of function candidates in placement inputs") },
        });
        return error.FunctionAnalysisLimitExceeded;
    }

    fn rememberInput(self: *Analyzer, input: ast.Type, receiver: ValueFacts) !void {
        for (self.typed_inputs.items) |*entry| {
            if (!ast.Type.eql(entry.input, input)) continue;
            var combined = try entry.receiver.clone(self.allocator);
            try combined.unionWith(receiver);
            if (!combined.eql(entry.receiver)) {
                entry.receiver = combined;
                self.inputs_changed = true;
            }
            return;
        }
        try self.typed_inputs.append(self.allocator, .{ .input = input, .receiver = try receiver.clone(self.allocator) });
        self.inputs_changed = true;
    }

    fn selectedInput(self: *Analyzer, input: ast.Type) !ValueFacts {
        for (self.typed_inputs.items) |entry| if (ast.Type.eql(entry.input, input)) return entry.receiver.clone(self.allocator);
        return ValueFacts.init(self.allocator);
    }

    fn checkRoots(self: *Analyzer) !void {
        for (self.state.modules.order.items) |module_id| {
            const module = self.state.moduleById(module_id) orelse continue;
            const previous = self.sema;
            self.sema = self.sema.forModule(module_id);
            {
                defer self.sema = previous;
                var document_env = FunctionEnv.init(self.allocator);
                var document_returns = ValueFacts.init(self.allocator);
                try self.analyzeStatements(module.syntax.document_statements.items, &document_env, &document_returns, null);
                for (module.syntax.pages.items) |page| {
                    var page_env = FunctionEnv.init(self.allocator);
                    var page_returns = ValueFacts.init(self.allocator);
                    try self.analyzeStatements(page.statements.items, &page_env, &page_returns, null);
                }
            }
        }
    }

    fn namedLabel(_: *Analyzer, key: core.FunctionKey) Label {
        return .{ .function = key };
    }

    fn lambdaLabel(self: *Analyzer, lambda: ast.LambdaExpr) Label {
        return .{ .lambda = .{ .module_id = self.sema.module_id, .span = lambda.span, .analysis_id = lambda.analysis_id } };
    }

    fn enter(self: *Analyzer, activation: Activation) anyerror!ValueFacts {
        if (self.call_depth >= max_call_analysis_depth) {
            try self.state.addValidationDiagnostic(.@"error", null, null, activationOrigin(self.state, activation), .{
                .user_report = .{ .code = "FunctionAnalysisLimitExceeded", .message = try self.state.allocator.dupe(u8, "cannot establish termination within the function analysis depth limit") },
            });
            return error.FunctionAnalysisLimitExceeded;
        }
        self.call_depth += 1;
        defer self.call_depth -= 1;
        const key = try self.activationKey(activation);
        const frame_index = self.effect_frames.items.len;
        const frame = if (activation.label == .function)
            try self.functionEffectFrame(activation.label.function, &activation.env)
        else
            EffectFrame{};
        try self.effect_frames.append(self.allocator, frame);
        defer _ = self.effect_frames.pop();
        // Construction calls allocate fresh abstract objects and may register
        // display functions. Their effects cannot be skipped by a return cache.
        const memoize = !self.collecting_inputs and (!self.require_known_calls or self.checking_display);
        defer if (!memoize) {
            _ = self.states.remove(key);
        };
        if (self.states.get(key)) |state| {
            if (state == 1) {
                try self.reportRecursiveActivation(activation);
                return error.RecursiveFunction;
            }
            if (self.returns.get(key)) |cached| {
                if (cached.places_objects) {
                    // The cached activation already checked its own body. Its
                    // effect must still be checked in the current caller.
                    self.effect_frames.items[frame_index].forwarding_depth += 1;
                    defer self.effect_frames.items[frame_index].forwarding_depth -= 1;
                    try self.recordPlacement();
                }
                return try cached.value.clone(self.allocator);
            }
            return ValueFacts.init(self.allocator);
        }

        const previous = self.sema;
        self.sema = self.sema.forModule(activation.label.moduleId());
        defer self.sema = previous;

        try self.states.put(key, 1);
        var result = ValueFacts.init(self.allocator);
        switch (activation.label) {
            .function => |function_key| {
                const func = self.sema.functions.get(function_key) orelse return ValueFacts.init(self.allocator);
                var env = try activation.env.clone();
                try self.analyzeStatements(func.statements.items, &env, &result, func);
            },
            .lambda => |lambda_key| {
                const lambda = self.lambda_exprs.get(lambda_key) orelse return ValueFacts.init(self.allocator);
                const previous_origin = self.current_origin;
                self.current_origin = self.state.sourceOrigin(lambda_key.module_id, lambda_key.span);
                defer self.current_origin = previous_origin;
                const body_labels = try self.exprFacts(lambda.body.*, &activation.env, activation.owner);
                try result.unionWith(body_labels);
            },
        }
        if (memoize) {
            try self.states.put(key, 2);
            try self.returns.put(key, .{ .value = try result.clone(self.allocator), .places_objects = self.effect_frames.items[frame_index].places_objects });
        }
        return result;
    }

    fn analyzeStatements(
        self: *Analyzer,
        statements: []const ast.Statement,
        env: *FunctionEnv,
        returns: *ValueFacts,
        owner: ?ast.FunctionDecl,
    ) anyerror!void {
        const previous_origin = self.current_origin;
        defer self.current_origin = previous_origin;
        for (statements) |stmt| {
            self.current_origin = self.state.sourceOrigin(self.sema.module_id, stmt.span);
            switch (stmt.kind) {
                .hole => {},
                .let_binding => |binding| {
                    const labels = try self.exprFacts(binding.expr, env, owner);
                    if (language_names.isDiscardBindingName(binding.name)) continue;
                    try env.bind(binding.name, labels);
                },
                .return_expr => |expr| {
                    const labels = try self.exprFacts(expr, env, owner);
                    try returns.unionWith(labels);
                },
                .return_void => {},
                .property_set => |property_set| {
                    if (self.checking_display) return self.rejectDisplayWrite();
                    const target = try self.exprFacts(property_set.target, env, owner);
                    const value = try self.exprFacts(property_set.value, env, owner);
                    try self.writeProperty(target, property_set.path.items, value);
                },
                .if_stmt => |if_stmt| {
                    _ = try self.exprFacts(if_stmt.condition, env, owner);
                    var then_env = try env.clone();
                    try self.analyzeStatements(if_stmt.then_statements.items, &then_env, returns, owner);
                    var else_env = try env.clone();
                    try self.analyzeStatements(if_stmt.else_statements.items, &else_env, returns, owner);
                },
                .constrain => |decl| {
                    if (self.checking_display) return self.rejectDisplayWrite();
                    if (decl.offset) |expr| _ = try self.exprFacts(expr, env, owner);
                },
                .expr_stmt => |expr| {
                    _ = try self.exprFacts(expr, env, owner);
                },
            }
        }
    }

    fn exprFacts(self: *Analyzer, expr: ast.Expr, env: *const FunctionEnv, owner: ?ast.FunctionDecl) anyerror!ValueFacts {
        try self.state.checkAnalysisCanceled();
        switch (expr) {
            .hole => return ValueFacts.init(self.allocator),
            .ident => |ident| {
                const name = ident.name;
                switch (try self.sema.resolveValue(ValueFacts, ident.reference(), env.get(name))) {
                    .local => |labels| return try labels.clone(self.allocator),
                    .constant => |resolved| return try self.constFacts(resolved),
                    .function => |resolved| return try ValueFacts.singleton(self.allocator, self.namedLabel(resolved.key)),
                    .primitive, .unknown => return ValueFacts.unknownValue(self.allocator),
                }
            },
            .string => |literal| {
                var value = ValueFacts.init(self.allocator);
                value.string_literal = literal.text;
                return value;
            },
            .color, .number, .boolean, .none, .enum_case => return ValueFacts.init(self.allocator),
            .lambda => |lambda| {
                const label = try self.registerLambda(lambda, env);
                return try ValueFacts.singleton(self.allocator, label);
            },
            .record => |record| {
                var value = ValueFacts.init(self.allocator);
                const resolved = self.sema.recordConstruction(record) orelse return ValueFacts.unknownValue(self.allocator);
                const previous = self.sema;
                {
                    self.sema = self.sema.forModule(resolved.module_id);
                    defer self.sema = previous;
                    const default_env = FunctionEnv.init(self.allocator);
                    for (resolved.decl.fields.items) |field| {
                        if (resolved.decl.type_params.items.len != 0) continue;
                        if (record.hasField(field.name)) continue;
                        if (field.default_value) |expr_value| {
                            try value.putField(field.name, try self.exprFacts(expr_value.*, &default_env, owner));
                        }
                    }
                }
                for (record.fields.items) |field| {
                    try value.putField(field.name, try self.exprFacts(field.value, env, owner));
                }
                return value;
            },
            .record_update => |update| {
                var value = try self.exprFacts(update.target.*, env, owner);
                for (update.fields.items) |field| {
                    try value.updatePath(field.path.items, try self.exprFacts(field.value, env, owner));
                }
                return value;
            },
            .call => |call| return try self.callFacts(call, env, owner),
            .apply => |apply| {
                const callee_labels = try self.exprFacts(apply.callee.*, env, owner);
                const arg_labels = try self.argumentFacts(apply.args.items, env, owner);
                return try self.invokeValue(callee_labels, arg_labels.items, owner);
            },
            .member => |member| {
                var value = try self.exprFacts(member.target.*, env, owner);
                defer value.deinit();
                return self.memberFacts(value, member.name);
            },
            .optional_check => |check| {
                _ = try self.exprFacts(check.target.*, env, owner);
                return ValueFacts.init(self.allocator);
            },
            .coalesce => |coalesce| {
                var target = try self.exprFacts(coalesce.target.*, env, owner);
                errdefer target.deinit();
                var fallback = try self.exprFacts(coalesce.fallback.*, env, owner);
                defer fallback.deinit();
                try target.unionWith(fallback);
                return target;
            },
        }
    }

    fn callFacts(self: *Analyzer, call: ast.CallExpr, env: *const FunctionEnv, owner: ?ast.FunctionDecl) anyerror!ValueFacts {
        if (call.callee.name_hole != null) return ValueFacts.init(self.allocator);
        switch (try self.sema.resolveValue(ValueFacts, call.callee, env.get(call.callee.name))) {
            .local => |labels| {
                const args = try self.argumentFacts(call.args.items, env, owner);
                return try self.invokeValue(labels, args.items, owner);
            },
            .constant => |resolved| {
                const labels = try self.constFacts(resolved);
                const args = try self.argumentFacts(call.args.items, env, owner);
                return try self.invokeValue(labels, args.items, owner);
            },
            .unknown => {
                _ = try self.argumentFacts(call.args.items, env, owner);
                // Name resolution reports undefined names during type checking.
                return ValueFacts.unknownValue(self.allocator);
            },
            .function => |resolved| {
                const key = if (call.callee.call_id) |id| self.state.instantiations.call_targets.get(id) orelse resolved.key else resolved.key;
                const func = self.state.functions.get(key) orelse resolved.decl;
                const label = self.namedLabel(key);
                const arg_labels = try self.argumentFacts(call.args.items, env, owner);
                return try self.invokeNamed(label, resolved.module_id, func, arg_labels.items);
            },
            .primitive => |primitive| {
                const typed_group = primitive.op == .group and self.state.displays.isTypedGroupCall(call.callee.call_id);
                const unresolved_group = primitive.op == .group and (!self.types_checked or
                    (owner != null and owner.?.type_params.items.len != 0 and owner.?.instance_id == null));
                if (self.checking_display and !typed_group and !unresolved_group and !registry.primitiveAllowsDisplayEvaluation(primitive.op)) return self.rejectDisplayWrite();
                const arg_labels = try self.argumentFacts(call.args.items, env, owner);
                if (primitive.places_objects) try self.recordPlacement();
                if (primitive.callback) |callback_spec| {
                    if (arg_labels.items.len <= callback_spec.function_arg_index) return ValueFacts.unknownValue(self.allocator);
                    const callback = arg_labels.items[callback_spec.function_arg_index];
                    var accumulator = if (primitive.op == .fold) try arg_labels.items[1].clone(self.allocator) else ValueFacts.init(self.allocator);
                    for (0..max_call_analysis_depth) |_| {
                        var callback_args = std.ArrayList(ValueFacts).empty;
                        for (0..callback_spec.supplied_arg_count) |index| {
                            const value = if (primitive.op == .fold and index == 0)
                                accumulator
                            else if ((primitive.op == .fold and index == 1) or index == 0)
                                arg_labels.items[0]
                            else
                                ValueFacts.init(self.allocator);
                            try callback_args.append(self.allocator, value);
                        }
                        try callback_args.appendSlice(self.allocator, arg_labels.items[callback_spec.function_arg_index + 1 ..]);
                        const returned = try self.invokeValue(callback, callback_args.items, owner);
                        if (primitive.op != .fold) break;
                        var combined = try accumulator.clone(self.allocator);
                        try combined.unionWith(returned);
                        if (combined.eql(accumulator)) return combined;
                        accumulator = combined;
                    } else {
                        try self.state.addValidationDiagnostic(.@"error", null, null, self.current_origin, .{
                            .user_report = .{ .code = "FunctionAnalysisLimitExceeded", .message = try self.state.allocator.dupe(u8, "cannot establish a finite set of function candidates in a fold accumulator") },
                        });
                        return error.FunctionAnalysisLimitExceeded;
                    }
                }
                return self.primitiveFacts(primitive, call, arg_labels.items);
            },
        }
    }

    fn primitiveFacts(self: *Analyzer, primitive: registry.PrimitiveDescriptor, call: ast.CallExpr, args: []const ValueFacts) !ValueFacts {
        if (primitive.op == .group and self.state.displays.isTypedGroupCall(call.callee.call_id)) {
            var value = ValueFacts.init(self.allocator);
            errdefer value.deinit();
            try value.children.ensureTotalCapacity(self.allocator, args.len);
            for (args) |arg| value.children.appendAssumeCapacity(try arg.clone(self.allocator));
            return value;
        }
        switch (primitive.op) {
            .docctx, .pagectx => {
                var value = ValueFacts.init(self.allocator);
                value.reference = if (primitive.op == .docctx) .document else .page;
                return value;
            },
            .select => {
                if (!self.types_checked) return ValueFacts.unknownValue(self.allocator);
                if (call.type_args.items.len == 1) {
                    var result = try self.selectedInput(call.type_args.items[0]);
                    try result.selected_types.append(self.allocator, call.type_args.items[0]);
                    return result;
                }
                if (args.len > 1) if (args[1].string_literal) |name| {
                    if (registry.lookupQueryOp(name)) |query| if (query.op == .self_placement) return args[0].clone(self.allocator);
                };
            },
            .selection_union, .selection_intersection => if (args.len == 2) {
                var combined = try args[0].clone(self.allocator);
                try combined.unionWith(args[1]);
                return combined;
            },
            .selection_difference, .sub => if (args.len > 0) return args[0].clone(self.allocator),
            .new, .group => {
                if (!self.require_known_calls) return ValueFacts.unknownValue(self.allocator);
                var value = ValueFacts.init(self.allocator);
                const id = self.object_properties.items.len;
                try self.object_properties.append(self.allocator, ValueFacts.init(self.allocator));
                try value.objects.put(id, {});
                return value;
            },
            .set_prop => {
                if (args.len >= 3 and call.args.items[1] == .string) {
                    const path = [_]ast.RecordPathSegment{.{ .name = call.args.items[1].string.text, .span = .{ .start = 0, .end = 0 } }};
                    try self.writeProperty(args[0], &path, args[2]);
                } else if (args.len >= 3 and self.require_known_calls) {
                    // A computed name may affect any property of the target.
                    try self.mergeProperties(args[0], ValueFacts.unknownValue(self.allocator));
                }
            },
            .require_asset_exists => if (args.len >= 1) return args[0].clone(self.allocator),
            else => {},
        }
        switch (primitive.result_policy) {
            .placement => {
                if (call.callee.call_id) |id| if (self.state.displays.call_targets.get(id)) |plan| {
                    var receiver = ValueFacts.init(self.allocator);
                    receiver.reference = .{ .placement = .{ .call = id, .path = &.{} } };
                    try receiver.putField("value", try args[primitive.result_arg_index].clone(self.allocator));
                    try receiver.putField("page", try args[0].clone(self.allocator));
                    var document = ValueFacts.init(self.allocator);
                    document.reference = .document;
                    try receiver.putField("document", document);
                    if (self.collecting_inputs or self.require_known_calls) try self.typed_displays.append(self.allocator, .{ .plan = plan, .receiver = try receiver.clone(self.allocator), .origin = self.current_origin });
                    return receiver;
                };
                if (args.len > primitive.result_arg_index) return args[primitive.result_arg_index].clone(self.allocator);
            },
            .first_selection_item => if (args.len >= 1) {
                var result = try args[0].clone(self.allocator);
                result.selected_types.clearRetainingCapacity();
                return result;
            },
            .first_arg => if (args.len >= 1) return args[0].clone(self.allocator),
            .target_arg => if (args.len > primitive.result_arg_index) return args[primitive.result_arg_index].clone(self.allocator),
            else => {},
        }
        return ValueFacts.unknownValue(self.allocator);
    }

    fn writeProperty(self: *Analyzer, target: ValueFacts, path: []const ast.RecordPathSegment, value: ValueFacts) !void {
        if (!self.require_known_calls or path.len == 0) return;
        // Property definitions in alternative branches are joined. References
        // point into this store, so later definitions are visible to displays.
        var written = ValueFacts.init(self.allocator);
        try written.updatePath(path, try value.clone(self.allocator));
        try self.mergeProperties(target, written);
    }

    fn mergeProperties(self: *Analyzer, target: ValueFacts, written: ValueFacts) !void {
        if (target.unknown_objects) try self.unknown_properties.unionWith(written);
        var objects = target.objects.keyIterator();
        while (objects.next()) |id| try self.object_properties.items[id.*].unionWith(written);
    }

    fn memberFacts(self: *Analyzer, target: ValueFacts, name: []const u8) !ValueFacts {
        // Explicit record updates refine even an otherwise unknown record.
        if (target.fields.get(name)) |field| return field.clone(self.allocator);
        if (target.unknown_objects) return ValueFacts.unknownValue(self.allocator);
        if (target.objects.count() == 0) return target.getField(name, self.allocator);
        // Construction units are scheduled independently of source order. Only
        // display checking can read the completed store as a fixed set of facts.
        if (!self.checking_display) return ValueFacts.unknownValue(self.allocator);
        var result = ValueFacts.init(self.allocator);
        var objects = target.objects.keyIterator();
        while (objects.next()) |id| {
            const properties = self.object_properties.items[id.*];
            const value = properties.fields.get(name) orelse ValueFacts.unknownValue(self.allocator);
            try result.unionWith(value);
        }
        if (self.unknown_properties.fields.get(name)) |value| {
            try result.unionWith(value);
        } else if (self.unknown_properties.unknown) {
            try result.unionWith(ValueFacts.unknownValue(self.allocator));
        }
        // This store refines object references only. Property-based function
        // calls still require a separate lifetime and storage contract.
        result.forgetFunctions();
        return result;
    }

    fn checkDisplayFunctions(self: *Analyzer) !void {
        self.checking_display = true;
        defer self.checking_display = false;
        self.states.clearRetainingCapacity();
        self.returns.clearRetainingCapacity();
        for (self.typed_displays.items) |registration| {
            self.current_origin = registration.origin;
            const plan = self.state.displays.plans.items[registration.plan];
            const receivers = try self.allocator.alloc(ValueFacts, plan.steps.items.len);
            defer self.allocator.free(receivers);
            receivers[0] = registration.receiver;
            for (plan.steps.items, 0..) |step, index| {
                if (self.collecting_inputs) try self.rememberInput(step.input, receivers[index]);
                switch (step.target) {
                    .native => {},
                    .group => {
                        const input = try receivers[index].getField("value", self.allocator);
                        for (step.children.items, 0..) |child_index, position| {
                            var receiver = ValueFacts.init(self.allocator);
                            const value = if (position < input.children.items.len) try input.children.items[position].clone(self.allocator) else ValueFacts.unknownValue(self.allocator);
                            receiver.reference = if (registration.receiver.reference) |reference| switch (reference) {
                                .placement => |placement| .{ .placement = .{ .call = placement.call, .path = plan.steps.items[child_index].path } },
                                else => null,
                            } else null;
                            try receiver.putField("value", value);
                            try receiver.putField("page", try registration.receiver.getField("page", self.allocator));
                            try receiver.putField("document", try registration.receiver.getField("document", self.allocator));
                            receivers[child_index] = receiver;
                        }
                    },
                    .function => |key| {
                        const output = try self.invokeNamed(self.namedLabel(key), key.module_id, self.state.functions.get(key).?, &.{receivers[index]});
                        var receiver = ValueFacts.init(self.allocator);
                        receiver.reference = if (registration.receiver.reference) |reference| switch (reference) {
                            .placement => |placement| .{ .placement = .{ .call = placement.call, .path = plan.steps.items[step.children.items[0]].path } },
                            else => null,
                        } else null;
                        try receiver.putField("value", output);
                        try receiver.putField("page", try registration.receiver.getField("page", self.allocator));
                        try receiver.putField("document", try registration.receiver.getField("document", self.allocator));
                        std.debug.assert(step.children.items.len == 1);
                        receivers[step.children.items[0]] = receiver;
                    },
                }
            }
        }
    }

    fn recordPlacement(self: *Analyzer) !void {
        if (self.checking_display) return self.rejectDisplayWrite();
        // A function value has no placement effect until it is invoked. Apply
        // the same rule through named calls, closures, defaults and caches.
        for (self.effect_frames.items) |*frame| {
            frame.places_objects = true;
            const key = frame.function orelse continue;
            const function = self.sema.functions.get(key) orelse continue;
            if (function.isDisplay()) return self.rejectDisplayWrite();
            if (frame.forwarding_depth != 0) continue;
            if (std.mem.endsWith(u8, function.name, "!")) continue;
            try self.state.addValidationDiagnostic(.@"error", null, null, self.state.sourceOrigin(key.module_id, function.span), .{
                .user_report = .{ .code = "PlacementEffect", .message = try std.fmt.allocPrint(self.state.allocator, "function '{s}' calls a placing operation and must end with '!'", .{function.name}) },
            });
            return error.DiagnosticsFailed;
        }
    }

    fn functionEffectFrame(self: *Analyzer, key: core.FunctionKey, env: *const FunctionEnv) !EffectFrame {
        var callbacks = LabelMap.init(self.allocator);
        if (self.sema.functions.get(key)) |function| {
            for (function.params.items) |param| if (env.get(param.name)) |value| try value.collectFunctions(&callbacks);
        }
        return .{ .function = key, .parameter_functions = callbacks };
    }

    fn rejectDisplayWrite(self: *Analyzer) anyerror {
        try self.state.addValidationDiagnostic(.@"error", null, null, self.current_origin, .{
            .user_report = .{ .code = "ImpureDisplayFunction", .message = try self.state.allocator.dupe(u8, "display functions must be pure and read-only, including indirect calls") },
        });
        return error.ImpureDisplayFunction;
    }

    fn argumentFacts(
        self: *Analyzer,
        args: []const ast.Expr,
        env: *const FunctionEnv,
        owner: ?ast.FunctionDecl,
    ) !std.ArrayList(ValueFacts) {
        var labels = std.ArrayList(ValueFacts).empty;
        for (args) |arg| {
            try labels.append(self.allocator, try self.exprFacts(arg, env, owner));
        }
        return labels;
    }

    fn invokeValue(
        self: *Analyzer,
        labels: ValueFacts,
        args: []const ValueFacts,
        owner: ?ast.FunctionDecl,
    ) anyerror!ValueFacts {
        if (labels.unknown and self.require_known_calls) {
            try self.state.addValidationDiagnostic(.@"error", null, null, self.current_origin, .{
                .user_report = .{ .code = "UnresolvedFunctionCall", .message = try self.state.allocator.dupe(u8, "cannot establish termination: function call candidates are unknown") },
            });
            return error.UnresolvedFunctionCall;
        }
        var result = if (labels.unknown) ValueFacts.unknownValue(self.allocator) else ValueFacts.init(self.allocator);
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
        args: []const ValueFacts,
        owner: ?ast.FunctionDecl,
    ) anyerror!ValueFacts {
        // Higher-order functions forward effects supplied by their arguments.
        // Their callers still observe those effects, and display remains pure.
        var forwarding_frames = std.ArrayList(usize).empty;
        for (self.effect_frames.items, 0..) |*frame, index| if (frame.parameter_functions) |callbacks| {
            if (!callbacks.contains(label)) continue;
            try forwarding_frames.append(self.allocator, index);
            frame.forwarding_depth += 1;
        };
        defer for (forwarding_frames.items) |index| {
            self.effect_frames.items[index].forwarding_depth -= 1;
        };
        const returned = switch (label) {
            .function => |key| blk: {
                const func = self.sema.functions.get(key) orelse break :blk ValueFacts.init(self.allocator);
                break :blk try self.invokeNamed(label, key.module_id, func, args);
            },
            .lambda => |lambda_key| blk: {
                const capture = self.lambda_captures.get(lambda_key) orelse break :blk ValueFacts.unknownValue(self.allocator);
                const lambda = self.lambda_exprs.get(lambda_key) orelse break :blk ValueFacts.unknownValue(self.allocator);
                var env = try capture.clone();
                try self.bindParams(&env, lambda.params.items, args);
                break :blk try self.enter(.{ .label = label, .env = env, .owner = owner });
            },
        };
        for (forwarding_frames.items) |index| try returned.collectFunctions(&self.effect_frames.items[index].parameter_functions.?);
        return returned;
    }

    fn invokeNamed(
        self: *Analyzer,
        label: Label,
        module_id: core.SourceModuleId,
        func: ast.FunctionDecl,
        args: []const ValueFacts,
    ) anyerror!ValueFacts {
        var env = FunctionEnv.init(self.allocator);
        try self.bindParams(&env, func.params.items, args);
        if (args.len < func.params.items.len) {
            for (self.effect_frames.items) |frame| if (frame.function) |key| {
                if (key.eql(label.function)) {
                    try reportRecursiveFunction(self.state, module_id, func);
                    return error.RecursiveFunction;
                }
            };
            if (self.effect_frames.items.len >= max_call_analysis_depth) {
                try self.state.addValidationDiagnostic(.@"error", null, null, self.state.sourceOrigin(module_id, func.span), .{
                    .user_report = .{ .code = "FunctionAnalysisLimitExceeded", .message = try self.state.allocator.dupe(u8, "cannot establish termination within the function analysis depth limit") },
                });
                return error.FunctionAnalysisLimitExceeded;
            }
            try self.effect_frames.append(self.allocator, try self.functionEffectFrame(label.function, &env));
            defer _ = self.effect_frames.pop();
            var index: usize = args.len;
            while (index < func.params.items.len) : (index += 1) {
                const param = func.params.items[index];
                if (param.default_value) |default_value| {
                    const previous = self.sema;
                    self.sema = self.sema.forModule(module_id);
                    {
                        defer self.sema = previous;
                        const labels = try self.exprFacts(default_value.*, &env, func);
                        try env.bind(param.name, labels);
                    }
                }
            }
        }
        return try self.enter(.{ .label = label, .env = env, .owner = func });
    }

    fn constFacts(self: *Analyzer, resolved: semantic_env.ResolvedConst) anyerror!ValueFacts {
        // Runtime constants retain their first value, including object identity.
        // Check initializer purity again in displays, independently of whether
        // an ordinary construction call has already forced the constant.
        if (!self.checking_display) {
            if (self.const_values.get(resolved.key)) |summary| {
                if (summary.places_objects) try self.recordPlacement();
                return summary.value.clone(self.allocator);
            }
        }
        if (self.const_visiting.contains(resolved.key)) return ValueFacts.init(self.allocator);
        try self.const_visiting.put(resolved.key, {});
        defer _ = self.const_visiting.remove(resolved.key);

        const previous = self.sema;
        self.sema = self.sema.forModule(resolved.module_id);
        defer self.sema = previous;

        const env = FunctionEnv.init(self.allocator);
        const frame_index = self.effect_frames.items.len;
        try self.effect_frames.append(self.allocator, .{});
        defer _ = self.effect_frames.pop();
        const value = try self.exprFacts(resolved.decl.value, &env, null);
        if (!self.checking_display) try self.const_values.put(resolved.key, .{ .value = try value.clone(self.allocator), .places_objects = self.effect_frames.items[frame_index].places_objects });
        return value;
    }

    fn bindParams(self: *Analyzer, env: *FunctionEnv, params: []const ast.ParamDecl, args: []const ValueFacts) !void {
        _ = self;
        var index: usize = 0;
        while (index < params.len and index < args.len) : (index += 1) {
            try env.bind(params[index].name, args[index]);
        }
    }

    fn registerLambda(self: *Analyzer, lambda: ast.LambdaExpr, env: *const FunctionEnv) !Label {
        var label = self.lambdaLabel(lambda);
        var captured = FunctionEnv.init(self.allocator);
        {
            const references = try self.capture_index.lambdaNames(lambda);
            for (references) |name| if (env.get(name)) |value| try captured.bind(name, value);
        }
        const key = try self.activationKey(.{ .label = label, .env = captured, .owner = null });
        if (self.capture_keys.get(key)) |existing| return existing;
        label.lambda.capture_id = self.capture_keys.count() + 1;
        try self.lambda_exprs.put(label.lambda, lambda);
        try self.lambda_captures.put(label.lambda, captured);
        try self.capture_keys.put(key, label);
        return label;
    }

    fn publishInputs(self: *Analyzer) !void {
        const store = &self.state.displays.inputs;
        store.clear();
        const allocator = store.arena.allocator();
        var closures = std.HashMap(Label, *input_facts.Closure, LabelContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        for (self.typed_inputs.items) |entry| try store.entries.append(allocator, .{
            .input = try entry.input.clone(allocator),
            .receiver = try self.exportInput(entry.receiver, allocator, &closures),
        });
    }

    fn exportInput(self: *Analyzer, value: ValueFacts, allocator: std.mem.Allocator, closures: *std.HashMap(Label, *input_facts.Closure, LabelContext, std.hash_map.default_max_load_percentage)) anyerror!input_facts.Value {
        const candidates = try allocator.alloc(input_facts.Value.Callable, value.labels.count());
        var labels = value.labels.keyIterator();
        var index: usize = 0;
        while (labels.next()) |label| : (index += 1) candidates[index] = switch (label.*) {
            .function => |key| .{ .function = key },
            .lambda => |key| blk: {
                if (closures.get(label.*)) |existing| break :blk .{ .closure = existing };
                const closure = try allocator.create(input_facts.Closure);
                try closures.put(label.*, closure);
                const env = self.lambda_captures.get(key).?;
                const bindings = try allocator.alloc(input_facts.Value.Field, env.values.count());
                var iterator = env.values.iterator();
                var position: usize = 0;
                while (iterator.next()) |binding| : (position += 1) bindings[position] = .{
                    .name = try allocator.dupe(u8, binding.key_ptr.*),
                    .value = try self.exportInput(binding.value_ptr.*, allocator, closures),
                };
                closure.* = .{ .module_id = key.module_id, .lambda = self.lambda_exprs.get(key).?, .bindings = bindings };
                break :blk .{ .closure = closure };
            },
        };
        const fields = try allocator.alloc(input_facts.Value.Field, value.fields.count());
        var iterator = value.fields.iterator();
        index = 0;
        while (iterator.next()) |field| : (index += 1) fields[index] = .{
            .name = try allocator.dupe(u8, field.key_ptr.*),
            .value = try self.exportInput(field.value_ptr.*, allocator, closures),
        };
        const children = try allocator.alloc(input_facts.Value, value.children.items.len);
        for (value.children.items, children) |child, *output| output.* = try self.exportInput(child, allocator, closures);
        const reference: ?input_facts.Value.Reference = if (value.unknown_reference or value.unknown_objects or value.objects.count() != 0) .unknown else if (value.reference) |reference| switch (reference) {
            .placement => |placement| .{ .placement = .{ .call = placement.call, .path = try allocator.dupe(usize, placement.path) } },
            else => reference,
        } else null;
        const selected_types = try allocator.alloc(ast.Type, value.selected_types.items.len);
        for (value.selected_types.items, selected_types) |ty, *output| output.* = try ty.clone(allocator);
        return .{ .selected_types = selected_types, .unknown = value.unknown, .candidates = candidates, .fields = fields, .children = children, .reference = reference, .string_literal = if (value.string_literal) |literal| try allocator.dupe(u8, literal) else null };
    }

    fn activationKey(self: *Analyzer, activation: Activation) ![]const u8 {
        var names = std.ArrayList([]const u8).empty;
        var iterator = activation.env.values.iterator();
        while (iterator.next()) |entry| {
            try names.append(self.allocator, entry.key_ptr.*);
        }
        std.mem.sort([]const u8, names.items, {}, stringLessThan);

        var out = std.ArrayList(u8).empty;
        try self.appendLabel(&out, activation.label);
        for (names.items) |name| {
            try out.append(self.allocator, '|');
            try out.appendSlice(self.allocator, name);
            try out.append(self.allocator, '=');
            try self.appendValue(&out, activation.env.values.get(name).?);
        }
        return try out.toOwnedSlice(self.allocator);
    }

    fn appendValue(self: *Analyzer, out: *std.ArrayList(u8), value: ValueFacts) anyerror!void {
        if (value.unknown_string) try out.appendSlice(self.allocator, "string:?");
        if (value.unknown_reference) try out.appendSlice(self.allocator, "reference:?");
        if (value.reference) |reference| switch (reference) {
            .unknown => try out.appendSlice(self.allocator, "reference:?"),
            .document => try out.appendSlice(self.allocator, "doc"),
            .page => try out.appendSlice(self.allocator, "page"),
            .placement => |placement| {
                try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "place:{d}:", .{placement.call}));
                for (placement.path) |position| try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}/", .{position}));
            },
        };
        // Intern exact types, including defining modules and type arguments.
        // Display names alone can collide across modules. Sort the set so joins
        // with different insertion orders share the same closure identity.
        var type_keys = std.ArrayList(usize).empty;
        for (value.selected_types.items) |ty| {
            const key = for (self.input_type_keys.items, 0..) |existing, index| {
                if (ast.Type.eql(ty, existing)) break index;
            } else blk: {
                const index = self.input_type_keys.items.len;
                try self.input_type_keys.append(self.allocator, ty);
                break :blk index;
            };
            try type_keys.append(self.allocator, key);
        }
        std.mem.sort(usize, type_keys.items, {}, std.sort.asc(usize));
        for (type_keys.items) |key| try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "select:{d};", .{key}));
        if (value.string_literal) |literal| try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "string:{d}:{s}", .{ literal.len, literal }));
        try out.appendSlice(self.allocator, if (value.unknown) "?[" else "[");
        var labels = std.ArrayList(Label).empty;
        var iterator = value.labels.keyIterator();
        while (iterator.next()) |label| try labels.append(self.allocator, label.*);
        std.mem.sort(Label, labels.items, {}, Label.lessThan);
        for (labels.items) |label| {
            try self.appendLabel(out, label);
            try out.append(self.allocator, ',');
        }
        try out.appendSlice(self.allocator, "]{");
        var names = std.ArrayList([]const u8).empty;
        var fields = value.fields.keyIterator();
        while (fields.next()) |name| try names.append(self.allocator, name.*);
        std.mem.sort([]const u8, names.items, {}, stringLessThan);
        for (names.items) |name| {
            try out.appendSlice(self.allocator, name);
            try out.append(self.allocator, '=');
            try self.appendValue(out, value.fields.get(name).?);
            try out.append(self.allocator, ';');
        }
        try out.appendSlice(self.allocator, "children[");
        for (value.children.items) |child| {
            try self.appendValue(out, child);
            try out.append(self.allocator, ';');
        }
        try out.append(self.allocator, ']');
        try out.appendSlice(self.allocator, if (value.unknown_objects) "}?objects[" else "}objects[");
        var ids = std.ArrayList(usize).empty;
        var objects = value.objects.keyIterator();
        while (objects.next()) |id| try ids.append(self.allocator, id.*);
        std.mem.sort(usize, ids.items, {}, std.sort.asc(usize));
        for (ids.items) |id| try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "{d},", .{id}));
        try out.append(self.allocator, ']');
    }

    fn appendLabel(self: *Analyzer, out: *std.ArrayList(u8), label: Label) !void {
        const text = try self.labelText(label);
        try out.appendSlice(self.allocator, text);
    }

    fn labelText(self: *Analyzer, label: Label) ![]const u8 {
        return switch (label) {
            .function => |key| try std.fmt.allocPrint(self.allocator, "fn:{d}:{s}:{?d}:{?d}", .{ key.module_id, key.name, key.declaration_start, key.instance_id }),
            .lambda => |key| try std.fmt.allocPrint(self.allocator, "lambda:{d}:{d}-{d}:{d}:{?d}", .{ key.module_id, key.span.start, key.span.end, key.capture_id, key.analysis_id }),
        };
    }

    fn reportRecursiveActivation(self: *Analyzer, activation: Activation) !void {
        if (activation.label == .function) {
            if (activation.owner) |func| {
                try reportRecursiveFunction(self.state, activation.label.moduleId(), func);
                return;
            }
        }
        const origin = activationOrigin(self.state, activation);
        try self.state.addValidationDiagnostic(.@"error", null, null, origin, .{
            .user_report = .{ .code = "RecursiveFunction", .message = try self.state.allocator.dupe(u8, "recursive function value application") },
        });
    }
};

pub fn checkFunctionCallGraphBeforeTypes(allocator: std.mem.Allocator, state: *core.DocumentState, sema: *const SemanticEnv) anyerror!void {
    return checkCallGraph(allocator, state, sema, false);
}

pub fn checkFunctionCallGraph(allocator: std.mem.Allocator, state: *core.DocumentState, sema: *const SemanticEnv) anyerror!void {
    return checkCallGraph(allocator, state, sema, true);
}

fn checkCallGraph(allocator: std.mem.Allocator, state: *core.DocumentState, sema: *const SemanticEnv, types_checked: bool) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var analyzer = Analyzer.init(arena.allocator(), state, sema);
    analyzer.types_checked = types_checked;
    defer analyzer.const_visiting.deinit();
    try analyzer.checkAll();
}

fn reportRecursiveFunction(state: *core.DocumentState, module_id: core.SourceModuleId, func: ast.FunctionDecl) !void {
    const origin = state.sourceOrigin(module_id, func.span);
    try state.addValidationDiagnostic(.@"error", null, null, origin, .{
        .recursive_function = .{ .function_name = func.name },
    });
}

fn activationOrigin(state: *const core.DocumentState, activation: Activation) ?core.SourceOrigin {
    return switch (activation.label) {
        .function => |key| if (state.functions.get(key)) |func|
            state.sourceOrigin(key.module_id, func.span)
        else
            null,
        .lambda => |key| state.sourceOrigin(key.module_id, key.span),
    };
}

fn functionKeyLessThan(left: core.FunctionKey, right: core.FunctionKey) bool {
    if (left.module_id != right.module_id) return left.module_id < right.module_id;
    if (!std.mem.eql(u8, left.name, right.name)) return std.mem.lessThan(u8, left.name, right.name);
    if (left.declaration_start != right.declaration_start) return optionalIdLessThan(usize, left.declaration_start, right.declaration_start);
    return optionalIdLessThan(u32, left.instance_id, right.instance_id);
}

fn optionalIdLessThan(comptime T: type, left: ?T, right: ?T) bool {
    if (left) |value| return if (right) |other| value < other else false;
    return right != null;
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

fn optionalStringEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |value| return if (right) |other| std.mem.eql(u8, value, other) else false;
    return right == null;
}

fn referenceEql(left: ?input_facts.Value.Reference, right: ?input_facts.Value.Reference) bool {
    if (left) |value| {
        const other = right orelse return false;
        if (std.meta.activeTag(value) != std.meta.activeTag(other)) return false;
        return switch (value) {
            .unknown, .page, .document => true,
            .placement => |placement| placement.call == other.placement.call and std.mem.eql(usize, placement.path, other.placement.path),
        };
    }
    return right == null;
}
