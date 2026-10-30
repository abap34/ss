const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const profile = @import("utils").profile;

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
//
// Collection storage is immutable and belongs to one analysis pass arena.
// Copying a value shares its collections; updates publish new storage for the
// changed collection and retain unchanged subtrees. No value owns its storage
// independently of that arena, including values saved by closures and caches.
const ValueFacts = struct {
    const Labels = LabelMap.Unmanaged;
    const Fields = std.StringHashMapUnmanaged(ValueFacts);
    const Objects = std.AutoHashMapUnmanaged(usize, void);

    allocator: std.mem.Allocator,
    labels: *const Labels = &.{},
    fields: *const Fields = &.{},
    children: []const ValueFacts = &.{},
    objects: *const Objects = &.{},
    unknown_objects: bool = false,
    unknown: bool = false,
    selected_types: []const ast.Type = &.{},
    reference: ?input_facts.Value.Reference = null,
    string_literal: ?[]const u8 = null,
    unknown_string: bool = false,
    unknown_reference: bool = false,

    fn init(allocator: std.mem.Allocator) ValueFacts {
        return .{ .allocator = allocator };
    }

    fn unknownValue(allocator: std.mem.Allocator) ValueFacts {
        var value = init(allocator);
        value.unknown = true;
        value.unknown_objects = true;
        return value;
    }

    fn singleton(allocator: std.mem.Allocator, label: Label) !ValueFacts {
        var value = init(allocator);
        var labels: Labels = .empty;
        try labels.put(allocator, label, {});
        value.labels = try value.freeze(labels);
        return value;
    }

    fn freeze(self: ValueFacts, value: anytype) !*const @TypeOf(value) {
        const stored = try self.allocator.create(@TypeOf(value));
        stored.* = value;
        return stored;
    }

    fn isEmpty(self: ValueFacts) bool {
        return !self.unknown and !self.unknown_objects and !self.unknown_string and !self.unknown_reference and self.labels.count() == 0 and
            self.objects.count() == 0 and self.fields.count() == 0 and self.children.len == 0 and
            self.reference == null and self.string_literal == null and self.selected_types.len == 0;
    }

    fn sameSnapshot(self: ValueFacts, other: ValueFacts) bool {
        return self.labels == other.labels and self.fields == other.fields and self.objects == other.objects and
            self.children.ptr == other.children.ptr and self.children.len == other.children.len and
            self.selected_types.ptr == other.selected_types.ptr and self.selected_types.len == other.selected_types.len and
            self.unknown == other.unknown and self.unknown_objects == other.unknown_objects and
            self.unknown_string == other.unknown_string and self.unknown_reference == other.unknown_reference and
            referenceEql(self.reference, other.reference) and optionalStringEql(self.string_literal, other.string_literal);
    }

    fn unionWith(self: *ValueFacts, other: ValueFacts) anyerror!void {
        _ = try self.join(other);
    }

    // Join snapshots without modifying facts retained by another environment.
    // Unchanged joins allocate nothing; only changed collections are copied.
    fn join(self: *ValueFacts, other: ValueFacts) anyerror!bool {
        if (other.isEmpty() or self.sameSnapshot(other)) return false;
        if (self.isEmpty()) {
            self.* = other;
            return true;
        }
        var next = self.*;
        var changed = false;
        for (other.selected_types) |ty| {
            if (try next.addSelectedType(ty)) changed = true;
        }
        next.unknown_reference = self.unknown_reference or other.unknown_reference or !referenceEql(self.reference, other.reference);
        next.unknown_string = self.unknown_string or other.unknown_string or !optionalStringEql(self.string_literal, other.string_literal);
        next.reference = if (next.unknown_reference) null else other.reference;
        next.string_literal = if (next.unknown_string) null else other.string_literal;
        changed = changed or self.unknown_reference != next.unknown_reference or self.unknown_string != next.unknown_string or
            !referenceEql(self.reference, next.reference) or !optionalStringEql(self.string_literal, next.string_literal);

        var updated_objects: ?Objects = null;
        if (self.objects != other.objects) {
            var objects = other.objects.keyIterator();
            while (objects.next()) |id| {
                if (self.objects.contains(id.*)) continue;
                if (updated_objects == null) updated_objects = try self.objects.clone(self.allocator);
                try updated_objects.?.put(self.allocator, id.*, {});
            }
        }
        if (updated_objects) |objects| {
            next.objects = try self.freeze(objects);
            changed = true;
        }
        if (other.unknown_objects and !self.unknown_objects) changed = true;
        next.unknown_objects = self.unknown_objects or other.unknown_objects;

        var updated_labels: ?Labels = null;
        if (self.labels != other.labels) {
            var labels = other.labels.keyIterator();
            while (labels.next()) |label| {
                if (self.labels.contains(label.*)) continue;
                if (updated_labels == null) updated_labels = try self.labels.clone(self.allocator);
                try updated_labels.?.put(self.allocator, label.*, {});
            }
        }
        if (updated_labels) |labels| {
            next.labels = try self.freeze(labels);
            changed = true;
        }

        var updated_fields: ?Fields = null;
        var fields = self.fields.iterator();
        while (fields.next()) |field| {
            const incoming = other.fields.get(field.key_ptr.*) orelse if (other.unknown) unknownValue(self.allocator) else continue;
            var value = field.value_ptr.*;
            if (!try value.join(incoming)) continue;
            if (updated_fields == null) updated_fields = try self.fields.clone(self.allocator);
            try updated_fields.?.put(self.allocator, field.key_ptr.*, value);
        }
        var other_fields = other.fields.iterator();
        while (other_fields.next()) |field| {
            if (self.fields.contains(field.key_ptr.*)) continue;
            var value = field.value_ptr.*;
            if (self.unknown) try value.unionWith(unknownValue(self.allocator));
            if (updated_fields == null) updated_fields = try self.fields.clone(self.allocator);
            try updated_fields.?.put(self.allocator, field.key_ptr.*, value);
        }
        if (updated_fields) |updated| {
            next.fields = try self.freeze(updated);
            changed = true;
        }

        var updated_children: ?[]ValueFacts = null;
        const child_count = @max(self.children.len, other.children.len);
        for (0..child_count) |index| {
            var value = if (index < self.children.len) self.children[index] else other.children[index];
            const grew = if (index >= self.children.len) blk: {
                if (self.unknown) try value.unionWith(unknownValue(self.allocator));
                break :blk true;
            } else if (index < other.children.len)
                try value.join(other.children[index])
            else if (other.unknown)
                try value.join(unknownValue(self.allocator))
            else
                false;
            if (!grew) continue;
            if (updated_children == null) {
                updated_children = try self.allocator.alloc(ValueFacts, child_count);
                @memcpy(updated_children.?[0..self.children.len], self.children);
            }
            updated_children.?[index] = value;
        }
        if (updated_children) |children| {
            next.children = children;
            changed = true;
        }
        if (other.unknown and !self.unknown) changed = true;
        next.unknown = self.unknown or other.unknown;
        self.* = next;
        return changed;
    }

    fn addSelectedType(self: *ValueFacts, ty: ast.Type) !bool {
        for (self.selected_types) |existing| if (ast.Type.eql(ty, existing)) return false;
        const types = try self.allocator.alloc(ast.Type, self.selected_types.len + 1);
        @memcpy(types[0..self.selected_types.len], self.selected_types);
        types[self.selected_types.len] = ty;
        self.selected_types = types;
        return true;
    }

    fn collectFunctions(self: ValueFacts, out: *LabelMap) anyerror!void {
        var labels = self.labels.keyIterator();
        while (labels.next()) |label| try out.put(label.*, {});
        var fields = self.fields.valueIterator();
        while (fields.next()) |field| try field.collectFunctions(out);
        for (self.children) |child| try child.collectFunctions(out);
    }

    fn forgetFunctions(self: *ValueFacts) anyerror!void {
        var next = self.*;
        next.labels = &.{};
        next.unknown = true;
        var updated_fields: ?Fields = null;
        var fields = self.fields.iterator();
        while (fields.next()) |field| {
            var value = field.value_ptr.*;
            try value.forgetFunctions();
            if (value.sameSnapshot(field.value_ptr.*)) continue;
            if (updated_fields == null) updated_fields = try self.fields.clone(self.allocator);
            try updated_fields.?.put(self.allocator, field.key_ptr.*, value);
        }
        if (updated_fields) |updated| next.fields = try self.freeze(updated);
        var updated_children: ?[]ValueFacts = null;
        for (self.children, 0..) |child, index| {
            var value = child;
            try value.forgetFunctions();
            if (value.sameSnapshot(child)) continue;
            if (updated_children == null) updated_children = try self.allocator.dupe(ValueFacts, self.children);
            updated_children.?[index] = value;
        }
        if (updated_children) |children| next.children = children;
        self.* = next;
    }

    fn getField(self: ValueFacts, name: []const u8) ValueFacts {
        return self.fields.get(name) orelse if (self.unknown) unknownValue(self.allocator) else init(self.allocator);
    }

    fn putField(self: *ValueFacts, name: []const u8, value: ValueFacts) !void {
        // Closed scalar fields carry no call or object facts. An explicit
        // empty field must still refine an unknown record.
        const omit = !self.unknown and value.isEmpty();
        if (omit and !self.fields.contains(name)) return;
        var fields = try self.fields.clone(self.allocator);
        if (omit) {
            _ = fields.remove(name);
        } else {
            try fields.put(self.allocator, name, value);
        }
        self.fields = try self.freeze(fields);
    }

    fn updatePath(self: *ValueFacts, path: []const ast.RecordPathSegment, value: ValueFacts) !void {
        std.debug.assert(path.len != 0);
        if (path.len == 1) return self.putField(path[0].name, value);
        var nested = self.getField(path[0].name);
        try nested.updatePath(path[1..], value);
        try self.putField(path[0].name, nested);
    }
};

// Binding maps are copied for branches and captures. Their values share
// immutable collections in the analysis pass arena.
const FunctionEnv = analysis_env.ValueEnv(ValueFacts);

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

// Sorting storage belongs to one key construction. Nested records retain
// their binding range while children may grow the same buffer.
const KeyScratch = struct {
    const Binding = struct {
        name: []const u8,
        value: *const ValueFacts,

        fn lessThan(_: void, left: Binding, right: Binding) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    };

    bindings: std.ArrayList(Binding) = .empty,
    labels: std.ArrayList(Label) = .empty,
    integers: std.ArrayList(usize) = .empty,

    fn deinit(self: *KeyScratch, allocator: std.mem.Allocator) void {
        self.bindings.deinit(allocator);
        self.labels.deinit(allocator);
        self.integers.deinit(allocator);
    }
};

const Analyzer = struct {
    allocator: std.mem.Allocator,
    key_allocator: std.mem.Allocator,
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

    fn init(allocator: std.mem.Allocator, key_allocator: std.mem.Allocator, state: *core.DocumentState, sema: *const SemanticEnv) Analyzer {
        return .{
            .allocator = allocator,
            .key_allocator = key_allocator,
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

    fn checkDeclarations(self: *Analyzer) !void {
        var const_it = self.state.constants.declarations.iterator();
        while (const_it.next()) |entry| {
            _ = try self.constFacts(.{
                .key = entry.key_ptr.*,
                .module_id = entry.key_ptr.module_id,
                .decl = entry.value_ptr.*,
            });
        }
        var it = self.sema.functions.iterator();
        while (it.next()) |entry| {
            const func = entry.value_ptr.*;
            const label = self.namedLabel(entry.key_ptr.*);
            var env = FunctionEnv.init(self.allocator);
            for (func.params.items) |param| try env.bind(param.name, ValueFacts.unknownValue(self.allocator));
            _ = try self.enter(.{ .label = label, .env = env, .owner = func });
        }
    }

    fn checkDeclaredDisplays(self: *Analyzer) !void {
        self.checking_display = true;
        var display_it = self.sema.functions.iterator();
        while (display_it.next()) |entry| {
            const func = entry.value_ptr.*;
            if (!func.isDisplay()) continue;
            var env = FunctionEnv.init(self.allocator);
            for (func.params.items) |param| try env.bind(param.name, ValueFacts.unknownValue(self.allocator));
            _ = try self.enter(.{ .label = self.namedLabel(entry.key_ptr.*), .env = env, .owner = func });
        }
    }

    fn checkExecutedRoots(self: *Analyzer) !void {
        // Actual arguments are checked independently of open declarations.
        if (self.types_checked) try self.collectPlacementInputs();
        self.require_known_calls = self.types_checked;
        self.clearPass();
        try self.checkRoots();
        try self.checkDisplayFunctions();
        if (self.types_checked) try self.publishInputs();
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
        const measure_start = profile.start();
        defer profile.recordAnalysis(.semantics_placement_inputs, measure_start);
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
        const measure_start = profile.start();
        defer profile.recordAnalysis(.semantics_input_join, measure_start);
        for (self.typed_inputs.items) |*entry| {
            if (!ast.Type.eql(entry.input, input)) continue;
            if (try entry.receiver.join(receiver)) self.inputs_changed = true;
            return;
        }
        try self.typed_inputs.append(self.allocator, .{ .input = input, .receiver = receiver });
        self.inputs_changed = true;
    }

    fn selectedInput(self: *Analyzer, input: ast.Type) !ValueFacts {
        var result = ValueFacts.init(self.allocator);
        for (self.typed_inputs.items) |entry| if (ast.Type.accepts(input, entry.input) or ast.Type.accepts(entry.input, input)) try result.unionWith(entry.receiver);
        return result;
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
        defer self.key_allocator.free(key);
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
                return cached.value;
            }
            return ValueFacts.init(self.allocator);
        }

        const previous = self.sema;
        self.sema = self.sema.forModule(activation.label.moduleId());
        defer self.sema = previous;

        const stored_key = if (memoize) try self.allocator.dupe(u8, key) else key;
        try self.states.put(stored_key, 1);
        var result = ValueFacts.init(self.allocator);
        switch (activation.label) {
            .function => |function_key| {
                const func = self.sema.functions.get(function_key) orelse return ValueFacts.init(self.allocator);
                // Every activation owns its parameter environment. Captures
                // are copied when the activation is created, not again here.
                var env = activation.env;
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
            try self.states.put(stored_key, 2);
            try self.returns.put(stored_key, .{ .value = result, .places_objects = self.effect_frames.items[frame_index].places_objects });
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
                .if_stmt, .drawing => |if_stmt| {
                    if (stmt.kind == .drawing) try self.recordPlacement();
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
                    .local => |labels| return labels,
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
                // Build the unpublished field table once. Persistent updates
                // are needed only after a value has been shared.
                var fields: ValueFacts.Fields = .empty;
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
                            const default = try self.exprFacts(expr_value.*, &default_env, owner);
                            if (!default.isEmpty()) try fields.put(self.allocator, field.name, default);
                        }
                    }
                }
                for (record.fields.items) |field| {
                    const provided = try self.exprFacts(field.value, env, owner);
                    if (provided.isEmpty()) {
                        _ = fields.remove(field.name);
                    } else {
                        try fields.put(self.allocator, field.name, provided);
                    }
                }
                if (fields.count() != 0) value.fields = try value.freeze(fields);
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
                // Immutable local records can be inspected without copying
                // every sibling field at each step of a member path.
                if (borrowLocalFacts(env, member.target.*)) |target| return self.memberFacts(target, member.name);
                const value = try self.exprFacts(member.target.*, env, owner);
                return self.memberFacts(value, member.name);
            },
            .optional_check => |check| {
                _ = try self.exprFacts(check.target.*, env, owner);
                return ValueFacts.init(self.allocator);
            },
            .coalesce => |coalesce| {
                var target = try self.exprFacts(coalesce.target.*, env, owner);
                const fallback = try self.exprFacts(coalesce.fallback.*, env, owner);
                try target.unionWith(fallback);
                return target;
            },
        }
    }

    fn borrowLocalFacts(env: *const FunctionEnv, expr: ast.Expr) ?ValueFacts {
        return switch (expr) {
            .ident => |ident| if (!ident.reference().isQualified()) env.get(ident.name) else null,
            .member => |member| if (borrowLocalFacts(env, member.target.*)) |target| target.fields.get(member.name) else null,
            else => null,
        };
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
                if (self.checking_display and !registry.primitiveAllowsDisplayEvaluation(primitive.op)) return self.rejectDisplayWrite();
                const arg_labels = try self.argumentFacts(call.args.items, env, owner);
                if (primitive.places_objects or (primitive.op == .group and call.callee.call_id != null and self.state.displays.adoptions.contains(call.callee.call_id.?))) try self.recordPlacement();
                if (primitive.callback) |callback_spec| {
                    if (arg_labels.items.len <= callback_spec.function_arg_index) return ValueFacts.unknownValue(self.allocator);
                    const callback = arg_labels.items[callback_spec.function_arg_index];
                    var accumulator = if (primitive.op == .fold) arg_labels.items[1] else ValueFacts.init(self.allocator);
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
                        // A callback can capture its parameter facts. Keep
                        // that snapshot immutable while growing the next one.
                        var next = accumulator;
                        if (!try next.join(returned)) return next;
                        accumulator = next;
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
        if (primitive.op == .group_placed or (primitive.op == .group and call.callee.call_id != null and self.state.displays.adoptions.contains(call.callee.call_id.?))) {
            var receiver = ValueFacts.init(self.allocator);
            if (call.callee.call_id) |id| receiver.reference = .{ .placement = .{ .call = id, .path = &.{} } };
            var input = ValueFacts.init(self.allocator);
            const group_type = if (call.callee.call_id) |id| self.state.displays.adoptions.get(id) else null;
            if (group_type != null and group_type.?.arguments.len == 0) {
                // A dynamic selection does not define a child tuple. Expanding
                // its membership here would recursively embed a group's own
                // collection facts before the execution graph can reject it.
                input.unknown = true;
                const children = try self.allocator.alloc(ValueFacts, args.len);
                receiver.children = children;
                for (args, children) |arg, *output| {
                    // Retain the original registration, without recursively
                    // embedding the selected group's own child/input facts.
                    var child = ValueFacts.init(self.allocator);
                    child.reference = arg.reference;
                    child.unknown_reference = arg.unknown_reference;
                    child.unknown = arg.unknown;
                    output.* = child;
                }
            } else {
                receiver.children = try self.allocator.dupe(ValueFacts, args);
                const children = try self.allocator.alloc(ValueFacts, args.len);
                for (args, children) |arg, *child| child.* = arg.getField("value");
                input.children = children;
            }
            try receiver.putField("value", input);
            if (args.len != 0) try receiver.putField("page", args[0].getField("page"));
            var document = ValueFacts.init(self.allocator);
            document.reference = .document;
            try receiver.putField("document", document);
            if (self.collecting_inputs) if (call.callee.call_id) |id| if (self.state.displays.adoptions.get(id)) |ty| try self.rememberInput(ty, receiver);
            return receiver;
        }
        if (primitive.op == .group) {
            var value = ValueFacts.init(self.allocator);
            value.children = try self.allocator.dupe(ValueFacts, args);
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
                    _ = try result.addSelectedType(call.type_args.items[0]);
                    return result;
                }
                if (args.len > 1) if (args[1].string_literal) |name| {
                    if (registry.lookupQueryOp(name)) |query| if (query.op == .self_placement) return args[0];
                };
            },
            .selection_union, .selection_intersection => if (args.len == 2) {
                var combined = args[0];
                try combined.unionWith(args[1]);
                return combined;
            },
            .selection_difference, .sub => if (args.len > 0) return args[0],
            else => {},
        }
        switch (primitive.result_policy) {
            .placement => {
                if (call.callee.call_id) |id| if (self.state.displays.call_targets.get(id)) |plan| {
                    var receiver = ValueFacts.init(self.allocator);
                    receiver.reference = .{ .placement = .{ .call = id, .path = &.{} } };
                    try receiver.putField("value", args[primitive.result_arg_index]);
                    try receiver.putField("page", args[0]);
                    var document = ValueFacts.init(self.allocator);
                    document.reference = .document;
                    try receiver.putField("document", document);
                    if (self.collecting_inputs or self.require_known_calls) try self.typed_displays.append(self.allocator, .{ .plan = plan, .receiver = receiver, .origin = self.current_origin });
                    return receiver;
                };
                if (args.len > primitive.result_arg_index) return args[primitive.result_arg_index];
            },
            .first_selection_item => if (args.len >= 1) {
                var result = args[0];
                result.selected_types = &.{};
                return result;
            },
            .first_arg => if (args.len >= 1) return args[0],
            else => {},
        }
        return ValueFacts.unknownValue(self.allocator);
    }

    fn writeProperty(self: *Analyzer, target: ValueFacts, path: []const ast.RecordPathSegment, value: ValueFacts) !void {
        if (!self.require_known_calls or path.len == 0) return;
        // Property definitions in alternative branches are joined. References
        // point into this store, so later definitions are visible to displays.
        var written = ValueFacts.init(self.allocator);
        try written.updatePath(path, value);
        try self.mergeProperties(target, written);
    }

    fn mergeProperties(self: *Analyzer, target: ValueFacts, written: ValueFacts) !void {
        if (target.unknown_objects) try self.unknown_properties.unionWith(written);
        var objects = target.objects.keyIterator();
        while (objects.next()) |id| try self.object_properties.items[id.*].unionWith(written);
    }

    fn memberFacts(self: *Analyzer, target: ValueFacts, name: []const u8) !ValueFacts {
        // Explicit record updates refine even an otherwise unknown record.
        if (target.fields.get(name)) |field| return field;
        if (target.unknown_objects) return ValueFacts.unknownValue(self.allocator);
        if (target.objects.count() == 0) return target.getField(name);
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
        try result.forgetFunctions();
        return result;
    }

    fn checkDisplayFunctions(self: *Analyzer) !void {
        const measure_start = profile.start();
        defer profile.recordAnalysis(.semantics_displays, measure_start);
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
                        const input = receivers[index].getField("value");
                        for (step.children.items, 0..) |child_index, position| {
                            var receiver = ValueFacts.init(self.allocator);
                            const value = if (position < input.children.len) input.children[position] else ValueFacts.unknownValue(self.allocator);
                            receiver.reference = if (registration.receiver.reference) |reference| switch (reference) {
                                .placement => |placement| .{ .placement = .{ .call = placement.call, .path = plan.steps.items[child_index].path } },
                                else => null,
                            } else null;
                            try receiver.putField("value", value);
                            try receiver.putField("page", registration.receiver.getField("page"));
                            try receiver.putField("document", registration.receiver.getField("document"));
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
                        try receiver.putField("page", registration.receiver.getField("page"));
                        try receiver.putField("document", registration.receiver.getField("document"));
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
                return summary.value;
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
        if (!self.checking_display) try self.const_values.put(resolved.key, .{ .value = value, .places_objects = self.effect_frames.items[frame_index].places_objects });
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
        defer self.key_allocator.free(key);
        if (self.capture_keys.get(key)) |existing| return existing;
        label.lambda.capture_id = self.capture_keys.count() + 1;
        try self.lambda_exprs.put(label.lambda, lambda);
        try self.lambda_captures.put(label.lambda, captured);
        try self.capture_keys.put(try self.allocator.dupe(u8, key), label);
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
        const children = try allocator.alloc(input_facts.Value, value.children.len);
        for (value.children, children) |child, *output| output.* = try self.exportInput(child, allocator, closures);
        const reference: ?input_facts.Value.Reference = if (value.unknown_reference or value.unknown_objects or value.objects.count() != 0) .unknown else if (value.reference) |reference| switch (reference) {
            .placement => |placement| .{ .placement = .{ .call = placement.call, .path = try allocator.dupe(usize, placement.path) } },
            else => reference,
        } else null;
        const selected_types = try allocator.alloc(ast.Type, value.selected_types.len);
        for (value.selected_types, selected_types) |ty, *output| output.* = try ty.clone(allocator);
        return .{ .selected_types = selected_types, .unknown = value.unknown, .candidates = candidates, .fields = fields, .children = children, .reference = reference, .string_literal = if (value.string_literal) |literal| try allocator.dupe(u8, literal) else null };
    }

    fn activationKey(self: *Analyzer, activation: Activation) ![]const u8 {
        const measure_start = profile.start();
        defer profile.recordAnalysis(.semantics_call_keys, measure_start);
        var scratch = KeyScratch{};
        defer scratch.deinit(self.key_allocator);
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.key_allocator);
        try self.appendLabel(&out, activation.label);
        try self.appendBindings(&out, &scratch, &activation.env.values);
        return try out.toOwnedSlice(self.key_allocator);
    }

    fn appendBindings(self: *Analyzer, out: *std.ArrayList(u8), scratch: *KeyScratch, bindings: anytype) anyerror!void {
        const start = scratch.bindings.items.len;
        defer scratch.bindings.shrinkRetainingCapacity(start);
        const count = bindings.count();
        try scratch.bindings.ensureUnusedCapacity(self.key_allocator, count);
        var iterator = bindings.iterator();
        while (iterator.next()) |binding| scratch.bindings.appendAssumeCapacity(.{
            .name = binding.key_ptr.*,
            .value = binding.value_ptr,
        });
        if (count > 1) std.mem.sortUnstable(KeyScratch.Binding, scratch.bindings.items[start..], {}, KeyScratch.Binding.lessThan);
        try self.appendInteger(out, count);
        for (0..count) |index| {
            // Recursive calls may reallocate scratch.bindings. Copy this entry
            // and access the next one by index after the call returns.
            const binding = scratch.bindings.items[start + index];
            try self.appendBytes(out, binding.name);
            try self.appendValue(out, scratch, binding.value);
        }
    }

    // Keys are exact, length-delimited binary encodings, local to this analysis.
    // Formatting every scalar into an arena retained large temporary strings.
    fn appendInteger(self: *Analyzer, out: *std.ArrayList(u8), value: usize) !void {
        try out.appendSlice(self.key_allocator, std.mem.asBytes(&value));
    }

    fn appendBytes(self: *Analyzer, out: *std.ArrayList(u8), value: []const u8) !void {
        try self.appendInteger(out, value.len);
        try out.appendSlice(self.key_allocator, value);
    }

    fn appendValue(self: *Analyzer, out: *std.ArrayList(u8), scratch: *KeyScratch, value: *const ValueFacts) anyerror!void {
        const allocator = self.key_allocator;
        try out.appendSlice(self.key_allocator, &.{
            @intFromBool(value.unknown),        @intFromBool(value.unknown_objects),
            @intFromBool(value.unknown_string), @intFromBool(value.unknown_reference),
        });
        if (value.reference) |reference| {
            try out.append(self.key_allocator, @as(u8, @intFromEnum(reference)) + 1);
            if (reference == .placement) {
                try self.appendInteger(out, @intCast(reference.placement.call));
                try self.appendInteger(out, reference.placement.path.len);
                for (reference.placement.path) |position| try self.appendInteger(out, position);
            }
        } else try out.append(self.key_allocator, 0);
        try out.append(self.key_allocator, @intFromBool(value.string_literal != null));
        if (value.string_literal) |literal| try self.appendBytes(out, literal);

        // Intern exact types, including defining modules and type arguments.
        // Sort sets so insertion order does not change closure identity.
        scratch.integers.clearRetainingCapacity();
        for (value.selected_types) |ty| {
            const key = for (self.input_type_keys.items, 0..) |existing, index| {
                if (ast.Type.eql(ty, existing)) break index;
            } else blk: {
                const index = self.input_type_keys.items.len;
                try self.input_type_keys.append(self.allocator, ty);
                break :blk index;
            };
            try scratch.integers.append(allocator, key);
        }
        if (scratch.integers.items.len > 1) std.mem.sortUnstable(usize, scratch.integers.items, {}, std.sort.asc(usize));
        try self.appendInteger(out, scratch.integers.items.len);
        for (scratch.integers.items) |key| try self.appendInteger(out, key);
        scratch.labels.clearRetainingCapacity();
        var iterator = value.labels.keyIterator();
        while (iterator.next()) |label| try scratch.labels.append(allocator, label.*);
        if (scratch.labels.items.len > 1) std.mem.sortUnstable(Label, scratch.labels.items, {}, Label.lessThan);
        try self.appendInteger(out, scratch.labels.items.len);
        for (scratch.labels.items) |label| try self.appendLabel(out, label);
        try self.appendBindings(out, scratch, value.fields);
        try self.appendInteger(out, value.children.len);
        for (value.children) |*child| try self.appendValue(out, scratch, child);
        scratch.integers.clearRetainingCapacity();
        var objects = value.objects.keyIterator();
        while (objects.next()) |id| try scratch.integers.append(allocator, id.*);
        if (scratch.integers.items.len > 1) std.mem.sortUnstable(usize, scratch.integers.items, {}, std.sort.asc(usize));
        try self.appendInteger(out, scratch.integers.items.len);
        for (scratch.integers.items) |id| try self.appendInteger(out, id);
    }

    fn appendLabel(self: *Analyzer, out: *std.ArrayList(u8), label: Label) !void {
        try out.append(self.key_allocator, @intFromEnum(label));
        switch (label) {
            .function => |key| {
                try self.appendInteger(out, key.module_id);
                try self.appendBytes(out, key.name);
                try out.append(self.key_allocator, @intFromBool(key.declaration_start != null));
                if (key.declaration_start) |start| try self.appendInteger(out, start);
                try out.append(self.key_allocator, @intFromBool(key.instance_id != null));
                if (key.instance_id) |id| try self.appendInteger(out, @intCast(id));
            },
            .lambda => |key| {
                try self.appendInteger(out, key.module_id);
                try self.appendInteger(out, key.span.start);
                try self.appendInteger(out, key.span.end);
                try self.appendInteger(out, key.capture_id);
                try out.append(self.key_allocator, @intFromBool(key.analysis_id != null));
                if (key.analysis_id) |id| try self.appendInteger(out, @intCast(id));
            },
        }
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
    // These checks share no facts. Release each one's temporary store before
    // starting the next, rather than retaining all three until analysis ends.
    const Pass = enum { declarations, displays, roots };
    for ([_]Pass{ .declarations, .displays, .roots }) |pass| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var analyzer = Analyzer.init(arena.allocator(), allocator, state, sema);
        analyzer.types_checked = types_checked;
        switch (pass) {
            .declarations => try analyzer.checkDeclarations(),
            .displays => try analyzer.checkDeclaredDisplays(),
            .roots => try analyzer.checkExecutedRoots(),
        }
    }
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
