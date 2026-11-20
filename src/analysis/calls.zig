const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const profile = @import("utils").profile;

const registry = @import("../language/registry.zig");
const language_names = @import("../language/names.zig");
const semantic_env = @import("../language/env.zig");
const analysis_env = @import("env.zig");
const control = @import("flow.zig");
const scheduled_bindings = @import("scheduled_bindings.zig");

const SemanticEnv = semantic_env.SemanticEnv;
const placement_inputs = core.placement_inputs;
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

// Function candidates follow the runtime value shape. Optional values use the
// same facts as their present value; none contributes no function candidates.
// Unknown facts also describe unspecified record fields. Explicit fields can
// refine them, for example after a record update.
//
// Collection storage is immutable and belongs to one analysis pass arena.
// Copying a value shares its collections; updates publish new storage for the
// changed collection and retain unchanged subtrees. No value owns its storage
// independently of that arena, including values saved by closures and caches.
const AbstractValue = struct {
    const Labels = LabelMap.Unmanaged;
    const Fields = std.StringHashMapUnmanaged(AbstractValue);
    const Objects = std.AutoHashMapUnmanaged(usize, void);

    allocator: std.mem.Allocator,
    labels: *const Labels = &.{},
    path: placement_inputs.ReadPath = .{},
    truth: placement_inputs.Alternatives = .bottom,
    present: placement_inputs.Alternatives = .bottom,
    fields: *const Fields = &.{},
    children: []const AbstractValue = &.{},
    objects: *const Objects = &.{},
    unknown_objects: bool = false,
    unknown: bool = false,
    selected_types: []const ast.Type = &.{},
    reference: ?placement_inputs.Value.Reference = null,
    string_literal: ?[]const u8 = null,
    unknown_string: bool = false,
    unknown_reference: bool = false,

    fn init(allocator: std.mem.Allocator) AbstractValue {
        return .{ .allocator = allocator };
    }

    fn presentValue(allocator: std.mem.Allocator) AbstractValue {
        return .{ .allocator = allocator, .present = .yes };
    }

    fn unknownValue(allocator: std.mem.Allocator) AbstractValue {
        var value = init(allocator);
        value.truth = .either;
        value.present = .either;
        value.unknown = true;
        value.path = .{ .unknown_target = true, .items = .either };
        value.unknown_objects = true;
        value.unknown_string = true;
        value.unknown_reference = true;
        return value;
    }

    fn singleton(allocator: std.mem.Allocator, label: Label) !AbstractValue {
        var value = presentValue(allocator);
        var labels: Labels = .empty;
        try labels.put(allocator, label, {});
        value.labels = try value.freeze(labels);
        return value;
    }

    fn freeze(self: AbstractValue, value: anytype) !*const @TypeOf(value) {
        const stored = try self.allocator.create(@TypeOf(value));
        stored.* = value;
        return stored;
    }

    fn isEmpty(self: AbstractValue) bool {
        return self.path.eql(.{}) and self.truth == .bottom and self.present == .bottom and !self.unknown and !self.unknown_objects and !self.unknown_string and !self.unknown_reference and self.labels.count() == 0 and
            self.objects.count() == 0 and self.fields.count() == 0 and self.children.len == 0 and
            self.reference == null and self.string_literal == null and self.selected_types.len == 0;
    }

    fn sameSnapshot(self: AbstractValue, other: AbstractValue) bool {
        return self.path.eql(other.path) and self.truth == other.truth and self.present == other.present and self.labels == other.labels and self.fields == other.fields and self.objects == other.objects and
            self.children.ptr == other.children.ptr and self.children.len == other.children.len and
            self.selected_types.ptr == other.selected_types.ptr and self.selected_types.len == other.selected_types.len and
            self.unknown == other.unknown and self.unknown_objects == other.unknown_objects and
            self.unknown_string == other.unknown_string and self.unknown_reference == other.unknown_reference and
            referenceEql(self.reference, other.reference) and optionalStringEql(self.string_literal, other.string_literal);
    }

    fn unionWith(self: *AbstractValue, other: AbstractValue) anyerror!void {
        _ = try self.join(other);
    }

    // Join snapshots without modifying facts retained by another environment.
    // Unchanged joins allocate nothing; only changed collections are copied.
    fn join(self: *AbstractValue, other: AbstractValue) anyerror!bool {
        if (other.isEmpty() or self.sameSnapshot(other)) return false;
        if (self.isEmpty() or (self.path.no_value and !other.path.no_value)) {
            self.* = other;
            return true;
        }
        if (other.path.no_value) return false;
        if (placement_inputs.ReadPath.emptyOperand(self.path, other.path)) |empty| {
            var next = if (empty == .left) other else self.*;
            const collection = if (empty == .left) self.* else other;
            next.path.items = next.path.items.join(collection.path.items);
            next.present = next.present.join(collection.present);
            for (collection.selected_types) |ty| _ = try next.addSelectedType(ty);
            const changed = !self.sameSnapshot(next);
            self.* = next;
            return changed;
        }
        var next = self.*;
        next.path = self.path.join(other.path);
        next.truth = self.truth.join(other.truth);
        next.present = self.present.join(other.present);
        var changed = !next.path.eql(self.path) or next.truth != self.truth or next.present != self.present;
        for (other.selected_types) |ty| {
            if (try next.addSelectedType(ty)) changed = true;
        }
        const pages = self.reference != null and other.reference != null and self.reference.? == .page and other.reference.? == .page;
        // A missing field in a partial value is bottom. Only conflicting
        // constants or an explicitly unknown input widen that field to top.
        next.unknown_reference = self.unknown_reference or other.unknown_reference or
            (self.reference != null and other.reference != null and !pages and !referenceEql(self.reference, other.reference));
        next.unknown_string = self.unknown_string or other.unknown_string or
            (self.string_literal != null and other.string_literal != null and !optionalStringEql(self.string_literal, other.string_literal));
        next.reference = if (next.unknown_reference) null else if (pages and !referenceEql(self.reference, other.reference)) .{ .page = null } else self.reference orelse other.reference;
        next.string_literal = if (next.unknown_string) null else self.string_literal orelse other.string_literal;
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

        var updated_children: ?[]AbstractValue = null;
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
                updated_children = try self.allocator.alloc(AbstractValue, child_count);
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

    fn asElement(self: AbstractValue) AbstractValue {
        var result = self;
        result.selected_types = &.{};
        result.path = self.path.element();
        if (result.path.no_value) return .{ .allocator = self.allocator, .path = result.path };
        // The collection exists even before discovery has seen any of its
        // elements. Do not join a fictitious placement into later receivers:
        // it would erase the real registration's identity.
        result.present = .bottom;
        if (!result.isEmpty()) result.present = .yes;
        return result;
    }

    fn addSelectedType(self: *AbstractValue, ty: ast.Type) !bool {
        for (self.selected_types) |existing| if (ast.Type.eql(ty, existing)) return false;
        const types = try self.allocator.alloc(ast.Type, self.selected_types.len + 1);
        @memcpy(types[0..self.selected_types.len], self.selected_types);
        types[self.selected_types.len] = ty;
        self.selected_types = types;
        return true;
    }

    fn collectFunctions(self: AbstractValue, out: *LabelMap) anyerror!void {
        var labels = self.labels.keyIterator();
        while (labels.next()) |label| try out.put(label.*, {});
        var fields = self.fields.valueIterator();
        while (fields.next()) |field| try field.collectFunctions(out);
        for (self.children) |child| try child.collectFunctions(out);
    }

    fn forgetFunctions(self: *AbstractValue) anyerror!void {
        var next = self.*;
        next.labels = &.{};
        next.unknown = true;
        next.path.unknown_target = true;
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
        var updated_children: ?[]AbstractValue = null;
        for (self.children, 0..) |child, index| {
            var value = child;
            try value.forgetFunctions();
            if (value.sameSnapshot(child)) continue;
            if (updated_children == null) updated_children = try self.allocator.dupe(AbstractValue, self.children);
            updated_children.?[index] = value;
        }
        if (updated_children) |children| next.children = children;
        self.* = next;
    }

    fn getField(self: AbstractValue, name: []const u8) AbstractValue {
        return self.fields.get(name) orelse if (self.unknown) unknownValue(self.allocator) else init(self.allocator);
    }

    fn putField(self: *AbstractValue, name: []const u8, value: AbstractValue) !void {
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

    fn updatePath(self: *AbstractValue, path: []const ast.RecordPathSegment, value: AbstractValue) !void {
        std.debug.assert(path.len != 0);
        if (path.len == 1) return self.putField(path[0].name, value);
        var nested = self.getField(path[0].name);
        try nested.updatePath(path[1..], value);
        try self.putField(path[0].name, nested);
    }
};

// Binding maps are copied for branches and captures. Their values share
// immutable collections in the analysis pass arena.
const FunctionEnv = analysis_env.ValueEnv(AbstractValue);

const Activation = struct {
    label: Label,
    env: FunctionEnv,
    owner: ?ast.FunctionDecl,
};

const CallSummary = struct { value: AbstractValue, places_objects: bool };
const ActivationState = union(enum) { active, complete: CallSummary };
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
        value: *const AbstractValue,

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

// Immutable bindings retain their values, lexical environment, and readers
// together. The pass arena owns all entries and worklist storage.
const BindingPropagation = struct {
    const Entry = struct {
        value: AbstractValue,
        environment: ?FunctionEnv = null,
        names: ?[]const []const u8 = null,
        readers: std.array_hash_map.Auto(u32, void) = .empty,
    };

    allocator: std.mem.Allocator,
    entries: []Entry = &.{},
    active: ?u32 = null,
    pending: std.array_hash_map.Auto(u32, void) = .empty,

    fn allocate(self: *BindingPropagation, count: usize) !void {
        self.entries = try self.allocator.alloc(Entry, count);
        @memset(self.entries, .{ .value = AbstractValue.init(self.allocator) });
    }

    fn beginPass(self: *BindingPropagation) void {
        for (self.entries) |*entry| entry.environment = null;
    }

    fn read(self: *BindingPropagation, id: u32) !AbstractValue {
        const entry = &self.entries[id];
        if (self.active) |reader| try entry.readers.put(self.allocator, reader, {});
        return entry.value;
    }

    fn publish(self: *BindingPropagation, id: u32, value: AbstractValue) !bool {
        const entry = &self.entries[id];
        if (!try entry.value.join(value)) return false;
        for (entry.readers.keys()) |reader| {
            if (self.entries[reader].environment != null) try self.pending.put(self.allocator, reader, {});
        }
        return true;
    }

    fn capture(self: *BindingPropagation, id: u32, initializer: ast.Expr, env: *const FunctionEnv, index: *captures.Index) !FunctionEnv {
        const entry = &self.entries[id];
        const names = entry.names orelse blk: {
            const names = try index.expressionNames(initializer, &.{});
            entry.names = names;
            break :blk names;
        };
        var captured = FunctionEnv.init(self.allocator);
        captured.scheduled = env.scheduled;
        for (names) |name| if (env.get(name)) |value| try captured.bind(name, value);
        entry.environment = captured;
        return captured;
    }

    fn next(self: *BindingPropagation) ?u32 {
        return if (self.pending.pop()) |entry| entry.key else null;
    }
};

// Type identities live for the analysis pass. Encoded keys and sorting buffers
// use the caller's allocator and are released after each lookup.
const CallKeys = struct {
    allocator: std.mem.Allocator,
    key_allocator: std.mem.Allocator,
    input_type_keys: std.ArrayList(ast.Type) = .empty,

    fn free(self: *CallKeys, key: []const u8) void {
        self.key_allocator.free(key);
    }

    fn encode(self: *CallKeys, activation: Activation, page: ?placement_inputs.PageKey) ![]const u8 {
        const measure_start = profile.start();
        defer profile.recordAnalysis(.semantics_call_keys, measure_start);
        var scratch = KeyScratch{};
        defer scratch.deinit(self.key_allocator);
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.key_allocator);
        try self.appendPage(&out, page);
        try self.appendLabel(&out, activation.label);
        try self.appendBindings(&out, &scratch, &activation.env.values.unmanaged);
        try self.appendScheduledBindings(&out, activation.env.scheduled);
        return try out.toOwnedSlice(self.key_allocator);
    }

    fn appendScheduledBindings(self: *CallKeys, out: *std.ArrayList(u8), scope: ?*const scheduled_bindings.Scope) !void {
        try self.appendInteger(out, if (scope) |bindings| bindings.count() else 0);
        const bindings = scope orelse return;
        const Entry = struct {
            name: []const u8,
            id: u32,

            fn lessThan(_: void, left: @This(), right: @This()) bool {
                return std.mem.lessThan(u8, left.name, right.name);
            }
        };
        const entries = try self.key_allocator.alloc(Entry, bindings.count());
        defer self.key_allocator.free(entries);
        var iterator = bindings.iterator();
        var index: usize = 0;
        while (iterator.next()) |binding| : (index += 1) entries[index] = .{ .name = binding.key_ptr.*, .id = binding.value_ptr.* };
        std.mem.sort(Entry, entries, {}, Entry.lessThan);
        for (entries) |binding| {
            try self.appendBytes(out, binding.name);
            try self.appendInteger(out, binding.id);
        }
    }

    fn appendPage(self: *CallKeys, out: *std.ArrayList(u8), page: ?placement_inputs.PageKey) !void {
        try out.append(self.key_allocator, @intFromBool(page != null));
        if (page) |key| {
            try self.appendInteger(out, key.module_id);
            try self.appendInteger(out, key.index);
        }
    }

    fn appendBindings(self: *CallKeys, out: *std.ArrayList(u8), scratch: *KeyScratch, bindings: *const AbstractValue.Fields) anyerror!void {
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
    fn appendInteger(self: *CallKeys, out: *std.ArrayList(u8), value: usize) !void {
        try out.appendSlice(self.key_allocator, std.mem.asBytes(&value));
    }

    fn appendBytes(self: *CallKeys, out: *std.ArrayList(u8), value: []const u8) !void {
        try self.appendInteger(out, value.len);
        try out.appendSlice(self.key_allocator, value);
    }

    fn appendValue(self: *CallKeys, out: *std.ArrayList(u8), scratch: *KeyScratch, value: *const AbstractValue) anyerror!void {
        const allocator = self.key_allocator;
        try out.appendSlice(self.key_allocator, &.{
            @intFromBool(value.unknown),             @intFromBool(value.unknown_objects),
            @backingInt(value.path.items),           @intFromBool(value.path.no_value),
            @intFromBool(value.path.unknown_target), @intFromBool(value.unknown_string),
            @intFromBool(value.unknown_reference),   @backingInt(value.truth),
            @backingInt(value.present),
        });
        if (value.reference) |reference| {
            try out.append(self.key_allocator, @as(u8, @backingInt(reference)) + 1);
            if (reference == .page) try self.appendPage(out, reference.page);
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

    fn appendLabel(self: *CallKeys, out: *std.ArrayList(u8), label: Label) !void {
        try out.append(self.key_allocator, @backingInt(label));
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
};

// Syntax and its captured environment form one entry. All entries and their
// immutable captures belong to the analysis pass arena.
const Closures = struct {
    const Entry = struct {
        lambda: ast.LambdaExpr,
        environment: FunctionEnv,
    };

    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(LambdaKey, Entry),
    keys: std.StringHashMap(Label),

    fn init(allocator: std.mem.Allocator) Closures {
        return .{ .allocator = allocator, .entries = .init(allocator), .keys = .init(allocator) };
    }

    fn register(self: *Closures, module_id: core.SourceModuleId, lambda: ast.LambdaExpr, env: *const FunctionEnv, references: []const []const u8, keys: *CallKeys) !Label {
        var label = Label{ .lambda = .{ .module_id = module_id, .span = lambda.span, .analysis_id = lambda.analysis_id } };
        const captured = try self.capture(env, references);
        const key = try keys.encode(.{ .label = label, .env = captured, .owner = null }, null);
        defer keys.free(key);
        if (self.keys.get(key)) |existing| return existing;
        label.lambda.capture_id = self.keys.count() + 1;
        try self.entries.put(label.lambda, .{ .lambda = lambda, .environment = captured });
        try self.keys.put(try self.allocator.dupe(u8, key), label);
        return label;
    }

    fn capture(self: *Closures, env: *const FunctionEnv, references: []const []const u8) !FunctionEnv {
        var captured = FunctionEnv.init(self.allocator);
        var scheduled: scheduled_bindings.Scope = .{};
        for (references) |name| {
            if (env.get(name)) |value| {
                try captured.bind(name, value);
                continue;
            }
            const outer = env.scheduled orelse continue;
            const id = outer.get(name) orelse continue;
            try scheduled.put(self.allocator, name, id);
        }
        if (scheduled.count() != 0) {
            const scope = try self.allocator.create(scheduled_bindings.Scope);
            scope.* = scheduled;
            captured.scheduled = scope;
        }
        return captured;
    }
};

// Copy pass-local facts into the generation-owned input store. Recursive
// captures share one exported closure, registered before its fields are visited.
const InputExporter = struct {
    allocator: std.mem.Allocator,
    closures: *const Closures,
    seen: std.AutoHashMap(LambdaKey, *placement_inputs.Closure),

    fn exportInput(self: *InputExporter, value: AbstractValue) anyerror!placement_inputs.Value {
        const allocator = self.allocator;
        const candidates = try allocator.alloc(placement_inputs.Value.Callable, value.labels.count());
        var labels = value.labels.keyIterator();
        var index: usize = 0;
        while (labels.next()) |label| : (index += 1) candidates[index] = switch (label.*) {
            .function => |key| .{ .function = key },
            .lambda => |key| .{ .closure = try self.exportClosure(key) },
        };
        const fields = try self.exportFields(value.fields);
        const children = try allocator.alloc(placement_inputs.Value, value.children.len);
        for (value.children, children) |child, *output| output.* = try self.exportInput(child);
        const reference: ?placement_inputs.Value.Reference = if (value.unknown_reference or value.unknown_objects or value.objects.count() != 0) .unknown else if (value.reference) |reference| switch (reference) {
            .placement => |placement| .{ .placement = .{ .call = placement.call, .path = try allocator.dupe(usize, placement.path) } },
            else => reference,
        } else null;
        const selected_types = try allocator.alloc(ast.Type, value.selected_types.len);
        for (value.selected_types, selected_types) |ty, *output| output.* = try ty.clone(allocator);
        return .{
            .path = value.path,
            .truth = value.truth,
            .present = value.present,
            .selected_types = selected_types,
            .unknown = value.unknown,
            .candidates = candidates,
            .fields = fields,
            .children = children,
            .reference = reference,
            .string_literal = if (value.string_literal) |literal| try allocator.dupe(u8, literal) else null,
        };
    }

    fn exportFields(self: *InputExporter, fields: *const AbstractValue.Fields) anyerror![]const placement_inputs.Value.Field {
        const allocator = self.allocator;
        const exported = try allocator.alloc(placement_inputs.Value.Field, fields.count());
        var iterator = fields.iterator();
        var index: usize = 0;
        while (iterator.next()) |field| : (index += 1) exported[index] = .{
            .name = try allocator.dupe(u8, field.key_ptr.*),
            .value = try self.exportInput(field.value_ptr.*),
        };
        return exported;
    }

    fn exportClosure(self: *InputExporter, key: LambdaKey) !*const placement_inputs.Closure {
        const allocator = self.allocator;
        if (self.seen.get(key)) |existing| return existing;
        const closure = try allocator.create(placement_inputs.Closure);
        // Register before exporting captures so recursive closures share one
        // stored instance instead of recursively copying their environments.
        try self.seen.put(key, closure);
        const captured = self.closures.entries.get(key).?;
        const env = captured.environment;
        closure.* = .{
            .module_id = key.module_id,
            .lambda = captured.lambda,
            .bindings = try self.exportFields(&env.values.unmanaged),
        };
        if (env.scheduled) |scope| {
            const bindings = try allocator.alloc(placement_inputs.Closure.ScheduledBinding, scope.count());
            var iterator = scope.iterator();
            var index: usize = 0;
            while (iterator.next()) |binding| : (index += 1) bindings[index] = .{
                .name = try allocator.dupe(u8, binding.key_ptr.*),
                .id = binding.value_ptr.*,
            };
            closure.scheduled = bindings;
        }
        return closure;
    }
};

const Analyzer = struct {
    allocator: std.mem.Allocator,
    keys: CallKeys,
    state: *core.DocumentState,
    sema: SemanticEnv,
    activations: std.StringHashMap(ActivationState),
    effect_frames: std.ArrayList(EffectFrame) = .empty,
    const_visiting: ConstVisitSet,
    const_values: std.HashMap(core.FunctionKey, CallSummary, core.FunctionKeyContext, std.hash_map.default_max_load_percentage),
    closures: Closures,
    capture_index: captures.Index,
    require_known_calls: bool = false,
    current_origin: ?core.SourceOrigin = null,
    current_page: ?placement_inputs.PageKey = null,
    call_depth: usize = 0,
    checking_display: bool = false,
    object_properties: std.ArrayList(AbstractValue) = .empty,
    unknown_properties: AbstractValue,
    collecting_inputs: bool = false,
    inputs_complete: bool = false,
    bindings: BindingPropagation,
    inputs_changed: bool = false,
    typed_inputs: std.ArrayList(struct { input: ast.Type, receiver: AbstractValue }) = .empty,
    typed_displays: std.ArrayList(struct { call: u64, plan: usize, receiver: AbstractValue, origin: ?core.SourceOrigin }) = .empty,

    fn init(allocator: std.mem.Allocator, key_allocator: std.mem.Allocator, state: *core.DocumentState, sema: *const SemanticEnv) Analyzer {
        return .{
            .allocator = allocator,
            .keys = .{ .allocator = allocator, .key_allocator = key_allocator },
            .state = state,
            .sema = sema.*,
            .activations = .init(allocator),
            .const_visiting = ConstVisitSet.init(allocator),
            .const_values = .init(allocator),
            .closures = .init(allocator),
            .bindings = .{ .allocator = allocator },
            .capture_index = captures.Index.init(allocator),
            .unknown_properties = AbstractValue.init(allocator),
        };
    }

    fn checkDeclarations(self: *Analyzer) !void {
        var const_it = self.state.constants.declarations.iterator();
        while (const_it.next()) |entry| {
            _ = try self.constantValue(.{
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
            for (func.params.items) |param| try env.bind(param.name, AbstractValue.unknownValue(self.allocator));
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
            for (func.params.items) |param| try env.bind(param.name, AbstractValue.unknownValue(self.allocator));
            _ = try self.enter(.{ .label = self.namedLabel(entry.key_ptr.*), .env = env, .owner = func });
        }
    }

    fn checkExecutedRoots(self: *Analyzer) !void {
        // Actual arguments are checked independently of open declarations.
        const count = self.state.scheduled_bindings.items.len;
        try self.bindings.allocate(count);
        if (count != 0 or self.state.displays.call_targets.count() != 0 or self.state.displays.adoptions.count() != 0)
            try self.collectPlacementInputs();
        self.state.displays.inputs.clear();
        self.require_known_calls = true;
        self.clearPass();
        try self.checkRoots();
        try self.checkDisplayFunctions();
        try self.publishInputs();
    }

    fn clearPass(self: *Analyzer) void {
        self.activations.clearRetainingCapacity();
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
            self.bindings.beginPass();
            self.clearPass();
            try self.checkRoots();
            try self.propagateBindingValues();
            try self.checkDisplayFunctions();
            if (!self.inputs_changed) {
                if (self.inputs_complete) return;
                // Only a converged producer set can prove a selection empty.
                // Propagate that fact through the same binding worklist before
                // validating executed calls.
                self.inputs_complete = true;
            }
        }
        return self.placementInputLimit();
    }

    fn placementInputLimit(self: *Analyzer) anyerror!void {
        try self.state.addValidationDiagnostic(.@"error", null, null, self.current_origin, .{
            .user_report = .{ .code = "FunctionAnalysisLimitExceeded", .message = try self.state.allocator.dupe(u8, "cannot establish a finite set of function candidates in placement inputs") },
        });
        return error.FunctionAnalysisLimitExceeded;
    }

    fn bindingValue(self: *Analyzer, id: u32, env: *const FunctionEnv) anyerror!AbstractValue {
        const previous = self.bindings.active;
        self.bindings.active = id;
        defer self.bindings.active = previous;
        const target = self.state.scheduled_bindings.items[id];
        const previous_page = self.current_page;
        self.current_page = if (target.page_index) |index| .{ .module_id = target.module_id, .index = index } else null;
        defer self.current_page = previous_page;
        return self.expressionValue(target.initializer.*, env, null);
    }

    fn discoverBinding(self: *Analyzer, id: u32, env: *const FunctionEnv) !AbstractValue {
        const target = self.state.scheduled_bindings.items[id];
        const capture = try self.bindings.capture(id, target.initializer.*, env, &self.capture_index);
        const value = try self.bindingValue(id, &capture);
        if (try self.bindings.publish(id, value)) self.inputs_changed = true;
        return value;
    }

    fn propagateBindingValues(self: *Analyzer) !void {
        // Bound growth of genuinely recursive abstract values without imposing
        // a depth limit on a finite chain of independent execution units.
        const limit = max_call_analysis_depth *| self.bindings.entries.len;
        var steps: usize = 0;
        while (self.bindings.next()) |id| {
            if (steps >= limit) return self.placementInputLimit();
            steps += 1;
            try self.state.checkAnalysisCanceled();
            const target = self.state.scheduled_bindings.items[id];
            const previous = self.sema;
            self.sema = self.sema.forModule(target.module_id);
            defer self.sema = previous;
            self.current_origin = self.state.sourceOrigin(target.module_id, target.name_span orelse .{ .start = 0, .end = 0 });
            const value = try self.bindingValue(id, &self.bindings.entries[id].environment.?);
            if (try self.bindings.publish(id, value)) self.inputs_changed = true;
        }
    }

    fn rememberInput(self: *Analyzer, input: ast.Type, receiver: AbstractValue) !void {
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

    fn selectedInput(self: *Analyzer, input: ast.Type) !AbstractValue {
        var result = AbstractValue.init(self.allocator);
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
                try self.scanRoot(module.syntax.document_statements.items);
                for (module.syntax.pages.items, 0..) |page, index| {
                    self.current_page = .{ .module_id = module_id, .index = index };
                    defer self.current_page = null;
                    try self.scanRoot(page.statements.items);
                }
            }
        }
    }

    fn scanRoot(self: *Analyzer, statements: []const ast.Statement) !void {
        var env = FunctionEnv.init(self.allocator);
        const scope = try self.allocator.create(scheduled_bindings.Scope);
        scope.* = try scheduled_bindings.scopeFor(self.allocator, statements);
        env.scheduled = scope;
        var returns = AbstractValue.init(self.allocator);
        var pass = CallFlow{ .analyzer = self, .env = &env, .returns = &returns, .owner = null };
        for (statements) |*stmt| {
            _ = try pass.visit(stmt.*, false);
        }
    }

    fn namedLabel(_: *Analyzer, key: core.FunctionKey) Label {
        return .{ .function = key };
    }

    fn enter(self: *Analyzer, activation: Activation) anyerror!AbstractValue {
        if (self.call_depth >= max_call_analysis_depth) {
            try self.state.addValidationDiagnostic(.@"error", null, null, activationOrigin(self.state, activation), .{
                .user_report = .{ .code = "FunctionAnalysisLimitExceeded", .message = try self.state.allocator.dupe(u8, "cannot establish termination within the function analysis depth limit") },
            });
            return error.FunctionAnalysisLimitExceeded;
        }
        self.call_depth += 1;
        defer self.call_depth -= 1;
        const key = try self.keys.encode(activation, self.current_page);
        defer self.keys.free(key);
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
            _ = self.activations.remove(key);
        };
        if (self.activations.get(key)) |state| switch (state) {
            .active => {
                try self.reportRecursiveActivation(activation);
                return error.RecursiveFunction;
            },
            .complete => |cached| {
                if (cached.places_objects) {
                    // The cached activation already checked its own body. Its
                    // effect must still be checked in the current caller.
                    self.effect_frames.items[frame_index].forwarding_depth += 1;
                    defer self.effect_frames.items[frame_index].forwarding_depth -= 1;
                    try self.recordPlacement();
                }
                return cached.value;
            },
        };

        const previous = self.sema;
        self.sema = self.sema.forModule(activation.label.moduleId());
        defer self.sema = previous;

        const stored_key = if (memoize) try self.allocator.dupe(u8, key) else key;
        try self.activations.put(stored_key, .active);
        var result = AbstractValue.init(self.allocator);
        switch (activation.label) {
            .function => |function_key| {
                const func = self.sema.functions.get(function_key) orelse return AbstractValue.init(self.allocator);
                // Every activation owns its parameter environment. Captures
                // are copied when the activation is created, not again here.
                var env = activation.env;
                _ = try self.analyzeStatements(func.statements.items, &env, &result, func);
            },
            .lambda => |lambda_key| {
                const captured = self.closures.entries.get(lambda_key) orelse return AbstractValue.init(self.allocator);
                const previous_origin = self.current_origin;
                self.current_origin = self.state.sourceOrigin(lambda_key.module_id, lambda_key.span);
                defer self.current_origin = previous_origin;
                const body_labels = try self.expressionValue(captured.lambda.body.*, &activation.env, activation.owner);
                try result.unionWith(body_labels);
            },
        }
        if (memoize) {
            try self.activations.put(stored_key, .{ .complete = .{ .value = result, .places_objects = self.effect_frames.items[frame_index].places_objects } });
        }
        return result;
    }

    fn analyzeStatements(
        self: *Analyzer,
        statements: []const ast.Statement,
        env: *FunctionEnv,
        returns: *AbstractValue,
        owner: ?ast.FunctionDecl,
    ) anyerror!control.Exits {
        var pass = CallFlow{ .analyzer = self, .env = env, .returns = returns, .owner = owner };
        return control.block(&pass, statements);
    }

    const CallFlow = struct {
        analyzer: *Analyzer,
        env: *FunctionEnv,
        returns: *AbstractValue,
        owner: ?ast.FunctionDecl,

        pub fn visit(pass: *@This(), stmt: ast.Statement, _: bool) anyerror!control.Exits {
            const self = pass.analyzer;
            const previous = self.current_origin;
            self.current_origin = self.state.sourceOrigin(self.sema.module_id, stmt.span);
            defer self.current_origin = previous;
            return control.statement(pass, stmt);
        }

        pub fn onReturn(pass: *@This(), value: ?ast.Expr) !void {
            if (value) |expr| try pass.returns.unionWith(try pass.analyzer.expressionValue(expr, pass.env, pass.owner));
        }

        pub fn condition(pass: *@This(), expr: ast.Expr) !control.Alternatives {
            const truth = (try pass.analyzer.expressionValue(expr, pass.env, pass.owner)).truth;
            return if (pass.analyzer.collecting_inputs) truth else truth.orUnknown();
        }

        pub fn arm(pass: *@This(), body: []const ast.Statement, _: usize) anyerror!control.Exits {
            var env = try pass.env.clone();
            var branch = pass.*;
            branch.env = &env;
            return control.block(&branch, body);
        }

        pub fn simple(pass: *@This(), stmt: ast.Statement) !void {
            const self = pass.analyzer;
            const env = pass.env;
            const owner = pass.owner;
            switch (stmt.kind) {
                .hole => {},
                .let_binding => |binding| {
                    const value = if (self.collecting_inputs and binding.binding_id != null)
                        try self.discoverBinding(binding.binding_id.?, env)
                    else
                        try self.expressionValue(binding.expr, env, owner);
                    if (binding.binding_id == null and !language_names.isDiscardBindingName(binding.name)) try env.bind(binding.name, value);
                },
                .property_set => |assignment| {
                    if (self.checking_display) return self.rejectDisplayWrite();
                    const target = try self.expressionValue(assignment.target, env, owner);
                    const value = try self.expressionValue(assignment.value, env, owner);
                    try self.writeProperty(target, assignment.path.items, value);
                },
                .constrain => |decl| {
                    if (self.checking_display) return self.rejectDisplayWrite();
                    if (decl.offset) |expr| _ = try self.expressionValue(expr, env, owner);
                },
                .expr_stmt => |expr| _ = try self.expressionValue(expr, env, owner),
                .return_expr, .return_void, .if_stmt => unreachable,
            }
        }
    };

    fn localValue(self: *Analyzer, env: *const FunctionEnv, name: ast.CallableName) !?AbstractValue {
        if (name.isQualified() or name.resolution != .lexical) return null;
        if (env.get(name.name)) |value| return value;
        const scope = env.scheduled orelse return null;
        const id = scope.get(name.name) orelse return null;
        return try self.bindings.read(id);
    }

    fn expressionValue(self: *Analyzer, expr: ast.Expr, env: *const FunctionEnv, owner: ?ast.FunctionDecl) anyerror!AbstractValue {
        try self.state.checkAnalysisCanceled();
        switch (expr) {
            .hole => return AbstractValue.init(self.allocator),
            .ident => |ident| {
                switch (try self.sema.resolveValue(AbstractValue, ident.reference(), try self.localValue(env, ident.reference()))) {
                    .local => |labels| return labels,
                    .constant => |resolved| return try self.constantValue(resolved),
                    .function => |resolved| return try AbstractValue.singleton(self.allocator, self.namedLabel(resolved.key)),
                    .primitive, .unknown => return AbstractValue.unknownValue(self.allocator),
                }
            },
            .string => |literal| {
                var value = AbstractValue.presentValue(self.allocator);
                value.string_literal = literal.text;
                return value;
            },
            .boolean => |flag| return .{ .allocator = self.allocator, .truth = .from(flag), .present = .yes },
            .none => return .{ .allocator = self.allocator, .present = .no },
            .color, .number, .enum_case => return AbstractValue.presentValue(self.allocator),
            .lambda => |lambda| {
                const references = try self.capture_index.lambdaNames(lambda);
                const label = try self.closures.register(self.sema.module_id, lambda, env, references, &self.keys);
                return try AbstractValue.singleton(self.allocator, label);
            },
            .record => |record| {
                var value = AbstractValue.init(self.allocator);
                // Build the unpublished field table once. Persistent updates
                // are needed only after a value has been shared.
                var fields: AbstractValue.Fields = .empty;
                const resolved = self.sema.recordConstruction(record) orelse return AbstractValue.unknownValue(self.allocator);
                const previous = self.sema;
                {
                    self.sema = self.sema.forModule(resolved.module_id);
                    defer self.sema = previous;
                    const default_env = FunctionEnv.init(self.allocator);
                    for (resolved.decl.fields.items) |field| {
                        if (resolved.decl.type_params.items.len != 0) continue;
                        if (record.hasField(field.name)) continue;
                        if (field.default_value) |expr_value| {
                            const default = try self.expressionValue(expr_value.*, &default_env, owner);
                            if (!default.isEmpty()) try fields.put(self.allocator, field.name, default);
                        }
                    }
                }
                for (record.fields.items) |field| {
                    const provided = try self.expressionValue(field.value, env, owner);
                    if (provided.isEmpty()) {
                        _ = fields.remove(field.name);
                    } else {
                        try fields.put(self.allocator, field.name, provided);
                    }
                }
                value.present = .yes;
                if (fields.count() != 0) value.fields = try value.freeze(fields);
                return value;
            },
            .record_update => |update| {
                var value = try self.expressionValue(update.target.*, env, owner);
                for (update.fields.items) |field| {
                    try value.updatePath(field.path.items, try self.expressionValue(field.value, env, owner));
                }
                return value;
            },
            .call => |call| return try self.callValue(call, env, owner),
            .apply => |apply| {
                const callee_labels = try self.expressionValue(apply.callee.*, env, owner);
                const arg_labels = try self.argumentValues(apply.args.items, env, owner);
                return try self.invokeValue(callee_labels, arg_labels.items, owner);
            },
            .member => |member| {
                // Borrow locals without losing optional access on an intermediate receiver.
                const target = borrowLocalValue(env, member.target.*) orelse try self.expressionValue(member.target.*, env, owner);
                if (target.path.no_value) return target;
                if (member.optional and target.present == .no) return .{ .allocator = self.allocator, .present = .no };
                var value = try self.memberValue(target, member.name);
                value.present = control.memberPresence(target.present, value.present, member.optional);
                return value;
            },
            .optional_check => |check| {
                return .{ .allocator = self.allocator, .truth = (try self.expressionValue(check.target.*, env, owner)).present, .present = .yes };
            },
            .coalesce => |coalesce| {
                var target = try self.expressionValue(coalesce.target.*, env, owner);
                switch (control.coalesce(if (self.collecting_inputs) target.present else target.present.orUnknown())) {
                    .pending => return AbstractValue.init(self.allocator),
                    .left => return target,
                    .right => return self.expressionValue(coalesce.fallback.*, env, owner),
                    .both => {
                        target.present = .yes;
                        try target.unionWith(try self.expressionValue(coalesce.fallback.*, env, owner));
                    },
                }
                return target;
            },
        }
    }

    fn borrowLocalValue(env: *const FunctionEnv, expr: ast.Expr) ?AbstractValue {
        if (env.scheduled != null) return null;
        return switch (expr) {
            .ident => |ident| if (!ident.reference().isQualified()) env.get(ident.name) else null,
            .member => |member| if (member.optional) null else (borrowLocalValue(env, member.target.*) orelse return null).fields.get(member.name),
            else => null,
        };
    }

    fn callValue(self: *Analyzer, call: ast.CallExpr, env: *const FunctionEnv, owner: ?ast.FunctionDecl) anyerror!AbstractValue {
        if (call.callee.name_hole != null) return AbstractValue.init(self.allocator);
        switch (try self.sema.resolveValue(AbstractValue, call.callee, try self.localValue(env, call.callee))) {
            .local => |labels| {
                const args = try self.argumentValues(call.args.items, env, owner);
                return try self.invokeValue(labels, args.items, owner);
            },
            .constant => |resolved| {
                const labels = try self.constantValue(resolved);
                const args = try self.argumentValues(call.args.items, env, owner);
                return try self.invokeValue(labels, args.items, owner);
            },
            .unknown => {
                _ = try self.argumentValues(call.args.items, env, owner);
                // Name resolution reports undefined names during type checking.
                return AbstractValue.unknownValue(self.allocator);
            },
            .function => |resolved| {
                const key = if (call.callee.call_id) |id| self.state.instantiations.call_targets.get(id) orelse resolved.key else resolved.key;
                const func = self.state.functions.get(key) orelse resolved.decl;
                const label = self.namedLabel(key);
                const arg_labels = try self.argumentValues(call.args.items, env, owner);
                return try self.invokeNamed(label, resolved.module_id, func, arg_labels.items);
            },
            .primitive => |primitive| {
                if (self.checking_display and !registry.primitiveAllowsDisplayEvaluation(primitive.op)) return self.rejectDisplayWrite();
                const arg_labels = try self.argumentValues(call.args.items, env, owner);
                if (primitive.places_objects or (primitive.op == .group and call.callee.call_id != null and self.state.displays.adoptions.contains(call.callee.call_id.?))) try self.recordPlacement();
                if (primitive.callback) |callback_spec| {
                    if (arg_labels.items.len <= callback_spec.function_arg_index) return AbstractValue.unknownValue(self.allocator);
                    const items = arg_labels.items[0];
                    if (primitive.op != .draw_when and self.collecting_inputs and
                        (items.present == .bottom or items.path.items == .bottom)) return AbstractValue.init(self.allocator);
                    if (primitive.op != .draw_when and items.path.items == .no) {
                        if (primitive.op == .fold) return arg_labels.items[1];
                        return self.primitiveValue(primitive, call, arg_labels.items);
                    }
                    const callback = arg_labels.items[callback_spec.function_arg_index];
                    var accumulator = if (primitive.op == .fold) arg_labels.items[1] else AbstractValue.init(self.allocator);
                    for (0..max_call_analysis_depth) |_| {
                        var callback_args = std.ArrayList(AbstractValue).empty;
                        for (0..callback_spec.supplied_arg_count) |index| {
                            const value = if (primitive.op == .fold and index == 0)
                                accumulator
                            else if ((primitive.op == .fold and index == 1) or index == 0)
                                items.asElement()
                            else
                                AbstractValue.init(self.allocator);
                            try callback_args.append(self.allocator, value);
                        }
                        try callback_args.appendSlice(self.allocator, arg_labels.items[callback_spec.function_arg_index + 1 ..]);
                        const returned = try self.invokeValue(callback, callback_args.items, owner);
                        if (primitive.op == .selection_filter) {
                            if (self.collecting_inputs and returned.truth == .bottom) return AbstractValue.init(self.allocator);
                            var filtered = items;
                            filtered.path = items.path.filtered(returned.truth);
                            return filtered;
                        }
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
                return self.primitiveValue(primitive, call, arg_labels.items);
            },
        }
    }

    fn primitiveValue(self: *Analyzer, primitive: registry.PrimitiveDescriptor, call: ast.CallExpr, argument_values: []const AbstractValue) !AbstractValue {
        const args = argument_values[0 .. argument_values.len - @intFromBool(call.callee.composition != null)];
        if (primitive.op == .group_placed or (primitive.op == .group and call.callee.call_id != null and self.state.displays.adoptions.contains(call.callee.call_id.?))) {
            var receiver = AbstractValue.presentValue(self.allocator);
            if (call.callee.call_id) |id| receiver.reference = .{ .placement = .{ .call = id, .path = &.{} } };
            var input = AbstractValue.init(self.allocator);
            const group_type = if (call.callee.call_id) |id| self.state.displays.adoptions.get(id) else null;
            if (group_type != null and group_type.?.arguments.len == 0) {
                // A dynamic selection does not define a child tuple. Expanding
                // its membership here would recursively embed a group's own
                // collection facts before the execution graph can reject it.
                input.unknown = true;
                const children = try self.allocator.alloc(AbstractValue, args.len);
                receiver.children = children;
                for (args, children) |arg, *output| {
                    // Retain the original registration, without recursively
                    // embedding the selected group's own child/input facts.
                    var child = AbstractValue.init(self.allocator);
                    child.reference = arg.reference;
                    child.unknown_reference = arg.unknown_reference;
                    child.unknown = arg.unknown;
                    output.* = child;
                }
            } else {
                receiver.children = try self.allocator.dupe(AbstractValue, args);
                const children = try self.allocator.alloc(AbstractValue, args.len);
                for (args, children) |arg, *child| child.* = arg.getField("value");
                input.children = children;
            }
            try receiver.putField("value", input);
            if (args.len != 0) try receiver.putField("page", args[0].getField("page"));
            var document = AbstractValue.presentValue(self.allocator);
            document.reference = .document;
            try receiver.putField("document", document);
            if (self.collecting_inputs) if (call.callee.call_id) |id| if (self.state.displays.adoptions.get(id)) |ty| try self.rememberInput(ty, receiver);
            return receiver;
        }
        if (primitive.op == .group) {
            var value = AbstractValue.presentValue(self.allocator);
            value.children = try self.allocator.dupe(AbstractValue, args);
            return value;
        }
        switch (primitive.op) {
            .concat => {
                // Bottom is an unfinished input, not an unknown string. Keeping
                // it distinct lets forward aliases converge to a literal.
                for (args) |arg| if (arg.isEmpty()) return AbstractValue.init(self.allocator);
                var value = AbstractValue.presentValue(self.allocator);
                value.string_literal = try @import("types.zig").concatStringLiterals(self.allocator, args[0].string_literal, args[1].string_literal);
                value.unknown_string = value.string_literal == null;
                return value;
            },
            .selection_empty => {
                if (self.collecting_inputs and args[0].path.items == .bottom) return AbstractValue.init(self.allocator);
                return .{ .allocator = self.allocator, .present = .yes, .truth = args[0].path.membership().negate() };
            },
            .logical_not => return .{ .allocator = self.allocator, .present = .yes, .truth = args[0].truth.negate() },
            .docctx, .pagectx, .new_page => {
                var value = AbstractValue.presentValue(self.allocator);
                value.reference = if (primitive.op == .docctx) .document else .{ .page = if (primitive.op == .pagectx) self.current_page else null };
                return value;
            },
            .select => {
                if (call.type_args.items.len == 1) {
                    var result = try self.selectedInput(call.type_args.items[0]);
                    const membership: placement_inputs.Alternatives = if (!result.isEmpty()) .either else if (self.inputs_complete or !self.state.displays.canProduce(call.type_args.items[0])) .no else .bottom;
                    result.path = result.path.selection(membership);
                    result.present = .yes;
                    _ = try result.addSelectedType(call.type_args.items[0]);
                    return result;
                }
                if (args.len > 1) if (args[1].string_literal) |name| {
                    if (registry.lookupQueryOp(name)) |query| if (query.op == .self_placement) {
                        var result = args[0];
                        result.path = result.path.selection(.yes);
                        return result;
                    };
                };
            },
            .selection_union, .selection_intersection, .sub => if (args.len == 2) {
                if (self.collecting_inputs and (args[0].path.items == .bottom or args[1].path.items == .bottom)) return AbstractValue.init(self.allocator);
                var combined = args[0];
                if (primitive.op != .sub) try combined.unionWith(args[1]);
                combined.path = combined.path.selection(placement_inputs.ReadPath.setMembership(switch (primitive.op) {
                    .selection_union => .sum,
                    .selection_intersection => .intersection,
                    else => .difference,
                }, args[0].path, args[1].path));
                return combined;
            },
            else => {},
        }
        switch (primitive.result_policy) {
            .placement => {
                if (call.callee.call_id) |id| if (self.state.displays.call_targets.get(id)) |plan| {
                    var receiver = AbstractValue.presentValue(self.allocator);
                    receiver.reference = .{ .placement = .{ .call = id, .path = &.{} } };
                    try receiver.putField("value", args[primitive.result_arg_index]);
                    try receiver.putField("page", args[0]);
                    var document = AbstractValue.presentValue(self.allocator);
                    document.reference = .document;
                    try receiver.putField("document", document);
                    if (self.collecting_inputs or self.require_known_calls) try self.typed_displays.append(self.allocator, .{ .plan = plan, .receiver = receiver, .origin = self.current_origin, .call = id });
                    return receiver;
                };
                if (args.len > primitive.result_arg_index) return args[primitive.result_arg_index];
            },
            .first_selection_item => if (args.len >= 1) {
                if (self.collecting_inputs and args[0].path.items == .bottom) return AbstractValue.init(self.allocator);
                return args[0].asElement();
            },
            .first_arg => if (args.len >= 1) return args[0],
            else => {},
        }
        if (primitive.result_type) |ty| if (primitive.result_policy == .declared and !control.needsValueFlow(ty) or ty.kind == .boolean) {
            return .{ .allocator = self.allocator, .present = control.presence(ty), .truth = if (ty.kind == .boolean) .either else .bottom, .unknown_string = ty.kind == .string };
        };
        return AbstractValue.unknownValue(self.allocator);
    }

    fn writeProperty(self: *Analyzer, target: AbstractValue, path: []const ast.RecordPathSegment, value: AbstractValue) !void {
        if (!self.require_known_calls or path.len == 0) return;
        // Property definitions in alternative branches are joined. References
        // point into this store, so later definitions are visible to displays.
        var written = AbstractValue.init(self.allocator);
        try written.updatePath(path, value);
        try self.mergeProperties(target, written);
    }

    fn mergeProperties(self: *Analyzer, target: AbstractValue, written: AbstractValue) !void {
        if (target.unknown_objects) try self.unknown_properties.unionWith(written);
        var objects = target.objects.keyIterator();
        while (objects.next()) |id| try self.object_properties.items[id.*].unionWith(written);
    }

    fn memberValue(self: *Analyzer, target: AbstractValue, name: []const u8) !AbstractValue {
        // Explicit record updates refine even an otherwise unknown record.
        if (target.fields.get(name)) |field| return field;
        if (target.unknown_objects) return AbstractValue.unknownValue(self.allocator);
        if (target.reference) |ref| if ((ref == .page or ref == .document) and self.sema.settingsField(name) != null) return AbstractValue.unknownValue(self.allocator);
        if (target.objects.count() == 0) return target.getField(name);
        // Construction units are scheduled independently of source order. Only
        // display checking can read the completed store as a fixed set of facts.
        if (!self.checking_display) return AbstractValue.unknownValue(self.allocator);
        var result = AbstractValue.init(self.allocator);
        var objects = target.objects.keyIterator();
        while (objects.next()) |id| {
            const properties = self.object_properties.items[id.*];
            const value = properties.fields.get(name) orelse AbstractValue.unknownValue(self.allocator);
            try result.unionWith(value);
        }
        if (self.unknown_properties.fields.get(name)) |value| {
            try result.unionWith(value);
        } else if (self.unknown_properties.unknown) {
            try result.unionWith(AbstractValue.unknownValue(self.allocator));
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
        self.activations.clearRetainingCapacity();
        for (self.typed_displays.items) |registration| {
            self.current_origin = registration.origin;
            const page = registration.receiver.getField("page").reference;
            const previous_page = self.current_page;
            self.current_page = if (page != null and page.? == .page) page.?.page else null;
            defer self.current_page = previous_page;
            const plan = self.state.displays.plans.items[registration.plan];
            const receivers = try self.allocator.alloc(AbstractValue, plan.steps.items.len);
            defer self.allocator.free(receivers);
            receivers[0] = registration.receiver;
            for (plan.steps.items, 0..) |step, index| {
                if (self.collecting_inputs) try self.rememberInput(step.input, receivers[index]);
                switch (step.target) {
                    .native => |native| if (native.resolve) |key| {
                        _ = try self.invokeNamed(self.namedLabel(key), key.module_id, self.state.functions.get(key).?, &.{receivers[index]});
                    },
                    .group => {
                        const input = receivers[index].getField("value");
                        for (step.children.items, 0..) |child_index, position| {
                            var receiver = AbstractValue.presentValue(self.allocator);
                            const value = if (position < input.children.len) input.children[position] else AbstractValue.unknownValue(self.allocator);
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
                        var receiver = AbstractValue.presentValue(self.allocator);
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

    fn argumentValues(
        self: *Analyzer,
        args: []const ast.Expr,
        env: *const FunctionEnv,
        owner: ?ast.FunctionDecl,
    ) !std.ArrayList(AbstractValue) {
        var labels = std.ArrayList(AbstractValue).empty;
        for (args) |arg| {
            try labels.append(self.allocator, try self.expressionValue(arg, env, owner));
        }
        return labels;
    }

    fn invokeValue(
        self: *Analyzer,
        labels: AbstractValue,
        args: []const AbstractValue,
        owner: ?ast.FunctionDecl,
    ) anyerror!AbstractValue {
        if (labels.unknown and self.require_known_calls) {
            try self.state.addValidationDiagnostic(.@"error", null, null, self.current_origin, .{
                .user_report = .{ .code = "UnresolvedFunctionCall", .message = try self.state.allocator.dupe(u8, "cannot establish termination: function call candidates are unknown") },
            });
            return error.UnresolvedFunctionCall;
        }
        var result = if (labels.unknown) AbstractValue.unknownValue(self.allocator) else AbstractValue.init(self.allocator);
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
        args: []const AbstractValue,
        owner: ?ast.FunctionDecl,
    ) anyerror!AbstractValue {
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
                const func = self.sema.functions.get(key) orelse break :blk AbstractValue.init(self.allocator);
                break :blk try self.invokeNamed(label, key.module_id, func, args);
            },
            .lambda => |lambda_key| blk: {
                const captured = self.closures.entries.get(lambda_key) orelse break :blk AbstractValue.unknownValue(self.allocator);
                var env = try captured.environment.clone();
                try self.bindParams(&env, captured.lambda.params.items, args);
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
        args: []const AbstractValue,
    ) anyerror!AbstractValue {
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
                        const labels = try self.expressionValue(default_value.*, &env, func);
                        try env.bind(param.name, labels);
                    }
                }
            }
        }
        return try self.enter(.{ .label = label, .env = env, .owner = func });
    }

    fn constantValue(self: *Analyzer, resolved: semantic_env.ResolvedConst) anyerror!AbstractValue {
        // Runtime constants retain their first value, including object identity.
        // Check initializer purity again in displays, independently of whether
        // an ordinary construction call has already forced the constant.
        const memoize = !self.checking_display and self.bindings.active == null;
        if (memoize) {
            if (self.const_values.get(resolved.key)) |summary| {
                if (summary.places_objects) try self.recordPlacement();
                return summary.value;
            }
        }
        if (self.const_visiting.contains(resolved.key)) return AbstractValue.init(self.allocator);
        try self.const_visiting.put(resolved.key, {});
        defer _ = self.const_visiting.remove(resolved.key);

        const previous = self.sema;
        self.sema = self.sema.forModule(resolved.module_id);
        defer self.sema = previous;

        // Constant initializers execute in document scope, even when first used by a page.
        const previous_page = self.current_page;
        self.current_page = null;
        defer self.current_page = previous_page;
        const env = FunctionEnv.init(self.allocator);
        const frame_index = self.effect_frames.items.len;
        try self.effect_frames.append(self.allocator, .{});
        defer _ = self.effect_frames.pop();
        const before_displays = self.typed_displays.items.len;
        const value = try self.expressionValue(resolved.decl.value, &env, null);
        const unit_effect = before_displays != self.typed_displays.items.len;
        if (memoize and !unit_effect) try self.const_values.put(resolved.key, .{ .value = value, .places_objects = self.effect_frames.items[frame_index].places_objects });
        return value;
    }

    fn bindParams(self: *Analyzer, env: *FunctionEnv, params: []const ast.ParamDecl, args: []const AbstractValue) !void {
        _ = self;
        var index: usize = 0;
        while (index < params.len and index < args.len) : (index += 1) {
            try env.bind(params[index].name, args[index]);
        }
    }

    fn publishInputs(self: *Analyzer) !void {
        const store = &self.state.displays.inputs;
        const allocator = store.arena.allocator();
        var exporter = InputExporter{ .allocator = allocator, .closures = &self.closures, .seen = .init(self.allocator) };
        const bindings = try allocator.alloc(placement_inputs.Value, self.bindings.entries.len);
        for (self.bindings.entries, bindings) |entry, *out| out.* = try exporter.exportInput(entry.value);
        store.bindings = bindings;
        for (self.typed_inputs.items) |entry| try store.entries.append(allocator, .{
            .input = try entry.input.clone(allocator),
            .receiver = try exporter.exportInput(entry.receiver),
        });
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

pub fn checkFunctionCallGraph(allocator: std.mem.Allocator, state: *core.DocumentState, sema: *const SemanticEnv) anyerror!void {
    // These checks share no facts. Release each one's temporary store before
    // starting the next, rather than retaining all three until analysis ends.
    const Pass = enum { declarations, displays, roots };
    for ([_]Pass{ .declarations, .displays, .roots }) |pass| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var analyzer = Analyzer.init(arena.allocator(), allocator, state, sema);
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

fn referenceEql(left: ?placement_inputs.Value.Reference, right: ?placement_inputs.Value.Reference) bool {
    if (left) |value| {
        const other = right orelse return false;
        if (std.meta.activeTag(value) != std.meta.activeTag(other)) return false;
        return switch (value) {
            .unknown, .document => true,
            .page => |key| std.meta.eql(key, other.page),
            .placement => |placement| placement.call == other.placement.call and std.mem.eql(usize, placement.path, other.placement.path),
        };
    }
    return right == null;
}
