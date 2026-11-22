const control = @import("flow.zig");
const settings = @import("defined_settings.zig");
const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const semantic_types = @import("types.zig");
const analysis_cache = @import("cache.zig");
const registry = @import("../language/registry.zig");
const semantic_env = @import("../language/env.zig");
const names = @import("../language/names.zig");
const captures = @import("captures.zig");

const SemanticEnv = semantic_env.SemanticEnv;
const FunctionVisitSet = std.HashMap(core.FunctionKey, void, core.FunctionKeyContext, std.hash_map.default_max_load_percentage);

const resource_model = @import("resources.zig");
pub const ObjectIdentity = resource_model.ObjectIdentity;
pub const ObjectOwner = resource_model.ObjectOwner;
pub const PropertyOwner = resource_model.PropertyOwner;
pub const PropertyKey = resource_model.PropertyKey;
pub const ResourceScope = resource_model.ResourceScope;
pub const PlacementScope = resource_model.PlacementScope;
pub const Resource = resource_model.Resource;

pub const AccessSummary = struct {
    allocator: std.mem.Allocator,
    // Reads still needed on entry, writes possible on any path, and settings
    // defined on every successful exit of this execution unit or function.
    reads: std.ArrayList(Resource),
    writes: std.ArrayList(Resource),
    defined_settings: settings.Definitions = .{},
    // Entry reads that can also precede an overlapping write on the same path.
    // All entry reads still depend on writers in other execution units.
    reads_before_write: std.ArrayList(Resource) = .empty,
    selection_reads: std.ArrayList(Resource),
    escaped_objects: std.ArrayList(ObjectIdentity) = .empty,
    placements: std.ArrayList(PlacementDefinition) = .empty,
    drawings: std.ArrayList(DrawingDefinition) = .empty,

    depends_on_caller_scope: bool = false,
    writes_layout_input: bool = false,
    places_objects: bool = false,
    invalid_selection_mutation: ?InvalidSelectionMutation = null,
    invalid_drawing_condition: ?core.SourceOrigin = null,

    pub const DrawingDefinition = struct {
        key: u64,
        origin: core.SourceOrigin,
        condition: *AccessSummary,
    };

    pub const PlacementDefinition = struct {
        call_id: u64,
        steps: std.ArrayList(AccessSummary),
        page_scope: ResourceScope,
    };

    pub const InvalidSelectionMutation = struct {
        resource: Resource,
        origin: ast.Span,
    };

    pub fn init(allocator: std.mem.Allocator) AccessSummary {
        return .{
            .allocator = allocator,
            .reads = .empty,
            .writes = .empty,
            .selection_reads = .empty,
        };
    }

    pub fn deinit(self: *AccessSummary) void {
        for (self.drawings.items) |drawing| {
            drawing.condition.deinit();
            self.allocator.destroy(drawing.condition);
        }
        self.drawings.deinit(self.allocator);
        for (self.placements.items) |*placement| {
            for (placement.steps.items) |*step| step.deinit();
            placement.steps.deinit(self.allocator);
        }
        self.placements.deinit(self.allocator);
        self.escaped_objects.deinit(self.allocator);
        self.reads.deinit(self.allocator);
        self.writes.deinit(self.allocator);
        self.defined_settings.deinit(self.allocator);
        self.reads_before_write.deinit(self.allocator);
        self.selection_reads.deinit(self.allocator);
    }

    pub fn addRead(self: *AccessSummary, resource: Resource) !void {
        try appendUnique(self.allocator, &self.reads, resource);
    }

    fn closeSettingReads(self: *AccessSummary, prior: settings.Definitions) void {
        if (prior.entries.items.len == 0) return;
        closeReads(&self.reads, prior);
        closeReads(&self.reads_before_write, prior);
    }

    fn closeReads(list: *std.ArrayList(Resource), prior: settings.Definitions) void {
        var kept: usize = 0;
        for (list.items) |read| {
            if (prior.satisfies(read)) continue;
            list.items[kept] = read;
            kept += 1;
        }
        list.shrinkRetainingCapacity(kept);
    }

    fn checkLaterWrite(self: *AccessSummary, write: Resource, reads: []const Resource) !void {
        if (write != .property or write.property.owner == .object) return;
        for (reads) |read| {
            if (read.intersects(write) and settings.Key.fromResource(read) != null)
                try appendUnique(self.allocator, &self.reads_before_write, read);
        }
    }

    pub fn needsOwnWrite(self: AccessSummary, read: Resource) bool {
        // Broad owners and objects retain the conservative graph rule.
        if (settings.Key.fromResource(read) == null) return true;
        for (self.reads_before_write.items) |pending| if (pending.eql(read)) return true;
        return false;
    }

    // Along alternative paths, may-effects are unioned and must facts intersect.
    fn mergeArm(self: *AccessSummary, other: AccessSummary, first: bool) !void {
        if (first) try self.defined_settings.include(self.allocator, other.defined_settings) else self.defined_settings.intersect(other.defined_settings);
        try self.mergeEffects(other);
    }

    pub fn addWrite(self: *AccessSummary, resource: Resource) !void {
        try self.checkLaterWrite(resource, self.reads.items);
        try appendUnique(self.allocator, &self.writes, resource);
    }

    pub fn addSelectionRead(self: *AccessSummary, resource: Resource) !void {
        try appendUnique(self.allocator, &self.selection_reads, resource);
        try self.addRead(resource);
    }

    fn addEscapedObject(self: *AccessSummary, identity: ObjectIdentity) !void {
        for (self.escaped_objects.items) |existing| if (existing.eql(identity)) return;
        try self.escaped_objects.append(self.allocator, identity);
    }

    pub fn applyBindingReads(self: *AccessSummary, state: *const core.DocumentState, unit: core.placement_inputs.ReadUnit) !void {
        if (state.displays.inputs.reads.get(unit)) |reads| for (reads.ids) |id| {
            try self.addRead(.{ .placement_binding = .{ .id = id, .name = state.scheduled_bindings.items[id].name } });
        };
        for (self.placements.items) |def| {
            for (def.steps.items, 0..) |*step, i| try step.applyBindingReads(state, unit.display(def.call_id, i));
        }
        for (self.drawings.items) |def| try def.condition.applyBindingReads(state, unit.drawing(def.key));
    }

    pub fn addDrawing(self: *AccessSummary, key: u64, origin: core.SourceOrigin, condition: AccessSummary) std.mem.Allocator.Error!void {
        for (self.drawings.items) |*existing| if (existing.key == key) {
            try existing.condition.mergeArm(condition, false);
            return;
        };
        const copy = try self.allocator.create(AccessSummary);
        errdefer self.allocator.destroy(copy);
        copy.* = try condition.clone(self.allocator);
        errdefer copy.deinit();
        try self.drawings.append(self.allocator, .{ .key = key, .origin = origin, .condition = copy });
    }

    pub fn merge(self: *AccessSummary, other: AccessSummary) !void {
        // No evaluation order is promised by this composition.
        for (self.writes.items) |write| try self.checkLaterWrite(write, other.reads.items);
        for (other.writes.items) |write| try self.checkLaterWrite(write, self.reads.items);
        try self.defined_settings.include(self.allocator, other.defined_settings);
        try self.mergeEffects(other);
    }

    // Only use for operations that the evaluator executes in this order.
    fn appendSequential(self: *AccessSummary, other: AccessSummary) !void {
        for (other.writes.items) |write| try self.checkLaterWrite(write, self.reads.items);
        try self.mergeEffectsAfter(other, self.defined_settings);
        try self.defined_settings.include(self.allocator, other.defined_settings);
    }

    // Union effects of alternative paths, or of fragments whose order has
    // already been accounted for. Do not manufacture a read/write pair here.
    fn mergeEffects(self: *AccessSummary, other: AccessSummary) !void {
        try self.mergeEffectsAfter(other, .{});
    }

    fn mergeEffectsAfter(self: *AccessSummary, other: AccessSummary, prior: settings.Definitions) !void {
        for (other.drawings.items) |drawing| try self.addDrawing(drawing.key, drawing.origin, drawing.condition.*);
        for (other.placements.items) |placement| try self.addPlacement(placement);
        for (other.escaped_objects.items) |identity| try self.addEscapedObject(identity);
        try self.reads.ensureUnusedCapacity(self.allocator, other.reads.items.len);
        try self.writes.ensureUnusedCapacity(self.allocator, other.writes.items.len);
        try self.selection_reads.ensureUnusedCapacity(self.allocator, other.selection_reads.items.len);
        for (other.reads.items) |resource| if (!prior.satisfies(resource)) try self.addRead(resource);
        for (other.reads_before_write.items) |read| {
            if (!prior.satisfies(read)) try appendUnique(self.allocator, &self.reads_before_write, read);
        }
        for (other.writes.items) |resource| try appendUnique(self.allocator, &self.writes, resource);
        for (other.selection_reads.items) |resource| try self.addSelectionRead(resource);
        self.depends_on_caller_scope = self.depends_on_caller_scope or other.depends_on_caller_scope;
        self.writes_layout_input = self.writes_layout_input or other.writes_layout_input;
        self.places_objects = self.places_objects or other.places_objects;
        if (self.invalid_selection_mutation == null) self.invalid_selection_mutation = other.invalid_selection_mutation;
        if (self.invalid_drawing_condition == null) self.invalid_drawing_condition = other.invalid_drawing_condition;
    }

    fn hasConcreteScope(self: AccessSummary) bool {
        if (self.depends_on_caller_scope) return true;
        for ([_][]const Resource{ self.reads.items, self.writes.items, self.selection_reads.items }) |resources| {
            for (resources) |resource| {
                if (resource == .property and resource.property.owner == .page and resource.property.owner.page != null) return true;
                if (resource == .objects and (resource.objects.page_scope != .any or !resource.objects.placement.eql(.{}))) return true;
            }
        }
        for (self.drawings.items) |drawing| if (drawing.condition.hasConcreteScope()) return true;
        for (self.placements.items) |placement| {
            if (placement.page_scope != .any) return true;
            for (placement.steps.items) |step| if (step.hasConcreteScope()) return true;
        }
        return false;
    }

    pub fn clone(self: AccessSummary, allocator: std.mem.Allocator) std.mem.Allocator.Error!AccessSummary {
        var copied = AccessSummary.init(allocator);
        errdefer copied.deinit();
        for (self.drawings.items) |drawing| try copied.addDrawing(drawing.key, drawing.origin, drawing.condition.*);
        for (self.placements.items) |placement| try copied.addPlacement(placement);
        try copied.reads.ensureTotalCapacity(allocator, @intCast(self.reads.items.len));
        try copied.writes.ensureTotalCapacity(allocator, @intCast(self.writes.items.len));
        try copied.selection_reads.ensureTotalCapacity(allocator, @intCast(self.selection_reads.items.len));
        copied.reads.appendSliceAssumeCapacity(self.reads.items);
        copied.writes.appendSliceAssumeCapacity(self.writes.items);
        try copied.reads_before_write.appendSlice(allocator, self.reads_before_write.items);
        try copied.defined_settings.entries.appendSlice(allocator, self.defined_settings.entries.items);
        copied.selection_reads.appendSliceAssumeCapacity(self.selection_reads.items);
        try copied.escaped_objects.appendSlice(allocator, self.escaped_objects.items);
        copied.depends_on_caller_scope = self.depends_on_caller_scope;
        copied.writes_layout_input = self.writes_layout_input;
        copied.places_objects = self.places_objects;
        copied.invalid_selection_mutation = self.invalid_selection_mutation;
        copied.invalid_drawing_condition = self.invalid_drawing_condition;
        return copied;
    }

    fn addPlacement(self: *AccessSummary, definition: PlacementDefinition) std.mem.Allocator.Error!void {
        for (self.placements.items) |*existing| {
            if (existing.call_id != definition.call_id) continue;
            std.debug.assert(existing.steps.items.len == definition.steps.items.len);
            for (existing.steps.items, definition.steps.items) |*step, other| try step.mergeArm(other, false);
            if (!resourceScopeEql(existing.page_scope, definition.page_scope)) existing.page_scope = .any;
            return;
        }
        var copied = std.ArrayList(AccessSummary).empty;
        errdefer {
            for (copied.items) |*step| step.deinit();
            copied.deinit(self.allocator);
        }
        try copied.ensureTotalCapacity(self.allocator, definition.steps.items.len);
        for (definition.steps.items) |step| copied.appendAssumeCapacity(try step.clone(self.allocator));
        try self.placements.append(self.allocator, .{ .call_id = definition.call_id, .steps = copied, .page_scope = definition.page_scope });
    }
};

pub const ScopeDisplayName = union(enum) {
    document: []const u8,
    page: []const u8,
    caller,
};

pub const ScopeDisplay = struct {
    scope: ResourceScope,
    name: ScopeDisplayName,
};

pub const AccessSummaryFormatOptions = struct {
    variable_scope_displays: []const ScopeDisplay = &.{},
    pages_scope_displays: []const ScopeDisplay = &.{},
};

pub fn formatAccessSummaryWithOptions(
    allocator: std.mem.Allocator,
    summary: AccessSummary,
    options: AccessSummaryFormatOptions,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "DependencyQuery:");
    var wrote_item = false;
    for (summary.reads.items) |resource| {
        try appendAccessLine(allocator, &out, "read", resource, options);
        wrote_item = true;
    }
    for (summary.writes.items) |resource| {
        try appendAccessLine(allocator, &out, "write", resource, options);
        wrote_item = true;
    }
    if (summary.writes_layout_input) {
        try appendFlagLine(allocator, &out, "writes_layout_input");
        wrote_item = true;
    }
    if (summary.places_objects) {
        try appendFlagLine(allocator, &out, "places_objects");
        wrote_item = true;
    }
    if (summary.invalid_selection_mutation != null) {
        try appendFlagLine(allocator, &out, "invalid_selection_mutation");
        wrote_item = true;
    }
    if (!wrote_item) try out.appendSlice(allocator, "\n  no reads, writes, or flags");
    return try out.toOwnedSlice(allocator);
}

fn appendAccessLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    access: []const u8,
    resource: Resource,
    options: AccessSummaryFormatOptions,
) !void {
    try out.appendSlice(allocator, "\n  ");
    try out.appendSlice(allocator, access);
    try out.appendSlice(allocator, " ");
    try appendResource(allocator, out, resource, options);
}

fn appendFlagLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), flag: []const u8) !void {
    try out.appendSlice(allocator, "\n  flag ");
    try out.appendSlice(allocator, flag);
}

pub fn appendResource(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    resource: Resource,
    options: AccessSummaryFormatOptions,
) !void {
    switch (resource) {
        .placement_binding => |binding| try out.print(allocator, "PlacementBinding({s}, {d})", .{ binding.name, binding.id }),
        .variable => |variable| {
            try out.appendSlice(allocator, "Variable(");
            try out.appendSlice(allocator, "scope=");
            try appendScope(allocator, out, variable.scope, options.variable_scope_displays);
            try out.appendSlice(allocator, ", name=");
            try out.appendSlice(allocator, variable.name);
            try out.append(allocator, ')');
        },
        .pages => |scope| {
            try out.appendSlice(allocator, "Pages(");
            try out.appendSlice(allocator, "scope=");
            try appendScope(allocator, out, scope, options.pages_scope_displays);
            try out.append(allocator, ')');
        },
        .objects => |members| {
            try out.appendSlice(allocator, "Objects(");
            try out.appendSlice(allocator, "type=");
            if (members.input_type) |ty| {
                try ty.formatInto(allocator, out);
            } else try out.appendSlice(allocator, "*");
            if (members.placement.call) |id| {
                const text = try std.fmt.allocPrint(allocator, "{d}", .{id});
                defer allocator.free(text);
                try out.appendSlice(allocator, ", placement=");
                try out.appendSlice(allocator, text);
            }
            if (members.placement.path.len != 0) {
                try out.appendSlice(allocator, ", path=");
                for (members.placement.path, 0..) |position, index| {
                    const segment = try std.fmt.allocPrint(allocator, "{s}{d}", .{ if (index == 0) "" else "/", position });
                    defer allocator.free(segment);
                    try out.appendSlice(allocator, segment);
                }
            }
            if (!members.placement.depth.eql(.{})) {
                const range = if (members.placement.depth.max) |limit|
                    try std.fmt.allocPrint(allocator, ", depth={d}..{d}", .{ members.placement.depth.min, limit })
                else
                    try std.fmt.allocPrint(allocator, ", depth={d}..", .{members.placement.depth.min});
                defer allocator.free(range);
                try out.appendSlice(allocator, range);
            }
            try out.appendSlice(allocator, ", owner=");
            try appendPropertyOwner(allocator, out, .{ .object = members.owner }, options);
            try out.appendSlice(allocator, ", page=");
            try appendScope(allocator, out, members.page_scope, options.pages_scope_displays);
            try out.append(allocator, ')');
        },
        .property => |property| {
            try out.appendSlice(allocator, "Property(");
            try out.appendSlice(allocator, "owner=");
            try appendPropertyOwner(allocator, out, property.owner, options);
            try out.appendSlice(allocator, ", key=");
            try appendOptionalNameOrAny(allocator, out, property.key.displayName());
            if (property.unless_defined_on) |id| {
                try out.appendSlice(allocator, ", unless defined on ");
                try appendScope(allocator, out, .{ .page = id }, options.pages_scope_displays);
            }
            try out.append(allocator, ')');
        },
    }
}

fn appendScope(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    scope: ResourceScope,
    displays: []const ScopeDisplay,
) !void {
    for (displays) |display| {
        if (resourceScopeEql(scope, display.scope)) {
            try appendScopeDisplayName(allocator, out, display.name);
            return;
        }
    }
    switch (scope) {
        .any => try out.appendSlice(allocator, "*"),
        .document => |id| {
            const text = try std.fmt.allocPrint(allocator, "document:{d}", .{id});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .page => |id| {
            const text = try std.fmt.allocPrint(allocator, "page:{d}", .{id});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
    }
}

fn appendScopeDisplayName(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: ScopeDisplayName) !void {
    switch (name) {
        .document => |value| {
            try out.appendSlice(allocator, "document:");
            try out.appendSlice(allocator, value);
        },
        .page => |value| {
            try out.appendSlice(allocator, "page:");
            try out.appendSlice(allocator, value);
        },
        .caller => try out.appendSlice(allocator, "caller"),
    }
}

fn resourceScopeEql(left: ResourceScope, right: ResourceScope) bool {
    return switch (left) {
        .any => right == .any,
        .document => |left_id| switch (right) {
            .document => |right_id| left_id == right_id,
            else => false,
        },
        .page => |left_id| switch (right) {
            .page => |right_id| left_id == right_id,
            else => false,
        },
    };
}

fn appendOptionalNameOrAny(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: ?[]const u8) !void {
    try out.appendSlice(allocator, value orelse "*");
}

fn appendPropertyOwner(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    owner: PropertyOwner,
    options: AccessSummaryFormatOptions,
) !void {
    switch (owner) {
        .any => try out.appendSlice(allocator, "*"),
        .document => try out.appendSlice(allocator, "document"),
        .page => |id| if (id) |n| try appendScope(allocator, out, .{ .page = n }, options.variable_scope_displays) else try out.appendSlice(allocator, "page"),
        .object => |object_owner| {
            try out.appendSlice(allocator, "object");
            if (object_owner.identity) |identity| {
                try out.append(allocator, '#');
                try appendObjectIdentity(allocator, out, identity, options);
            } else {
                try out.appendSlice(allocator, ":*");
            }
        },
    }
}

fn appendObjectIdentity(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    identity: ObjectIdentity,
    options: AccessSummaryFormatOptions,
) !void {
    if (identity.origin == .constant) try out.appendSlice(allocator, "const:");
    try appendScope(allocator, out, identity.scope, options.variable_scope_displays);
    try out.append(allocator, '.');
    try out.appendSlice(allocator, identity.name);
}

fn appendUnique(allocator: std.mem.Allocator, list: *std.ArrayList(Resource), resource: Resource) !void {
    for (list.items) |existing| {
        if (existing.eql(resource)) return;
    }
    try list.append(allocator, resource);
}

const SummaryCache = std.StringHashMap(AccessSummary);
const ReturnProperty = union(enum) { string_literal: ?[]const u8, property_target: ?PropertyTarget };

const TypeValueKey = struct {
    module_id: core.SourceModuleId,
    ty: ast.Type,
    depth: usize,
};

const TypeValueContext = struct {
    pub fn hash(_: TypeValueContext, key: TypeValueKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, key.module_id);
        std.hash.autoHash(&hasher, key.depth);
        key.ty.hashInto(&hasher);
        return hasher.final();
    }

    pub fn eql(_: TypeValueContext, left: TypeValueKey, right: TypeValueKey) bool {
        return left.module_id == right.module_id and left.depth == right.depth and ast.Type.eql(left.ty, right.ty);
    }
};

const ConstantValueKey = struct {
    declaration: core.FunctionKey,
    value_depth: usize,
    effect_depth: usize,
};

const ConstantValueContext = struct {
    pub fn hash(_: @This(), key: ConstantValueKey) u64 {
        var hasher = std.hash.Wyhash.init(core.FunctionKeyContext.hash(.{}, key.declaration));
        std.hash.autoHash(&hasher, key.value_depth);
        std.hash.autoHash(&hasher, key.effect_depth);
        return hasher.final();
    }

    pub fn eql(_: @This(), left: ConstantValueKey, right: ConstantValueKey) bool {
        return left.declaration.eql(right.declaration) and left.value_depth == right.value_depth and left.effect_depth == right.effect_depth;
    }
};

pub const RunCache = struct {
    allocator: std.mem.Allocator,
    name_resolution: analysis_cache.NameResolutionCache,
    summaries: SummaryCache,
    return_properties: std.StringHashMap(ReturnProperty),
    type_values: std.HashMap(TypeValueKey, AbstractValue, TypeValueContext, std.hash_map.default_max_load_percentage),
    constant_values: std.HashMap(ConstantValueKey, AbstractValue, ConstantValueContext, std.hash_map.default_max_load_percentage),
    value_storage: std.heap.ArenaAllocator,
    constant_body_analyses: usize = 0,
    page_ids: std.AutoHashMapUnmanaged(core.placement_inputs.PageKey, ?core.NodeId) = .{},
    // Borrowed from the graph; cached and returned summaries share these bytes.
    string_allocator: std.mem.Allocator,
    return_body_analyses: usize = 0,
    type_body_analyses: usize = 0,
    next_value_id: usize = 1,
    next_local_object_id: usize = 1,

    pub fn init(allocator: std.mem.Allocator, string_allocator: std.mem.Allocator) RunCache {
        return .{
            .allocator = allocator,
            .name_resolution = analysis_cache.NameResolutionCache.init(allocator),
            .summaries = SummaryCache.init(allocator),
            .return_properties = .init(allocator),
            .type_values = .init(allocator),
            .value_storage = .init(allocator),
            .constant_values = .init(allocator),
            .string_allocator = string_allocator,
        };
    }

    pub fn deinit(self: *RunCache) void {
        self.page_ids.deinit(self.allocator);
        self.type_values.deinit();
        self.constant_values.deinit();
        self.value_storage.deinit();
        var iter = self.summaries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.summaries.deinit();
        var property_keys = self.return_properties.keyIterator();
        while (property_keys.next()) |key| self.allocator.free(key.*);
        self.return_properties.deinit();
        self.name_resolution.deinit();
    }

    pub fn reserve(self: *RunCache, state: *const core.DocumentState) !void {
        try self.name_resolution.reserve(state);
        try self.summaries.ensureTotalCapacity(@intCast((state.functions.count() * 8) + (state.constants.declarations.count() * 2)));
    }

    pub fn cachedSummary(self: *RunCache, key: []const u8, allocator: std.mem.Allocator) !?AccessSummary {
        const summary = self.summaries.get(key) orelse return null;
        return try summary.clone(allocator);
    }

    pub fn putSummary(self: *RunCache, key: []const u8, summary: AccessSummary) !void {
        if (self.summaries.contains(key)) return;
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_summary = try summary.clone(self.allocator);
        errdefer {
            var copy = owned_summary;
            copy.deinit();
        }
        try self.summaries.putNoClobber(owned_key, owned_summary);
    }
};

const LetPolicy = enum {
    scheduled,
    local,
};

const PropertyTarget = struct {
    owner: PropertyOwner,
    // Only a proven allocation may acquire a new binding identity.
    fresh: bool = false,

    fn any() PropertyTarget {
        return .{ .owner = .any };
    }

    fn document() PropertyTarget {
        return .{ .owner = .document };
    }

    fn page(id: ?core.NodeId) PropertyTarget {
        return .{ .owner = .{ .page = id } };
    }

    fn object() PropertyTarget {
        return .{ .owner = .{ .object = .{} } };
    }

    fn freshObject() PropertyTarget {
        return .{ .owner = .{ .object = .{} }, .fresh = true };
    }

    fn objectWithIdentity(scope: ResourceScope, name: []const u8) PropertyTarget {
        return .{ .owner = .{ .object = .{
            .identity = .{ .scope = scope, .name = name },
        } } };
    }
};

// Immutable value facts carry callable candidates and object identities through
// records and captures. Type-derived facts live in the run cache when present.
const max_value_depth = 128;
const max_effect_analysis_depth = 128;
const Alternatives = control.Alternatives;
const AbstractValue = struct {
    truth: Alternatives = .bottom,
    present: Alternatives = .bottom,
    id: usize = 0,
    candidates: []const Callable = &.{},
    targets: core.placement_inputs.BindingTargets = .{},
    path: core.placement_inputs.ReadPath = .{},
    fields: []const Field = &.{},
    property_target: ?PropertyTarget = null,
    // Null means the subtree is unknown; an empty slice proves a leaf.
    children: ?[]const AbstractValue = null,
    page_scope: ResourceScope = .any,
    placement: resource_model.PlacementScope = .{},
    const Field = struct { name: []const u8, value: AbstractValue };
    const Callable = union(enum) {
        named: semantic_env.ResolvedFunction,
        closure: struct { module_id: core.SourceModuleId, lambda: ast.LambdaExpr, bindings: []const CapturedBinding },
    };
    // Syntax and interned resource names outlive the run cache. Own all value
    // trees, reference sets and captured environments allocated by an analyzer.
    // The destination is an arena, which also owns partially built copies.
    fn clone(self: AbstractValue, allocator: std.mem.Allocator) std.mem.Allocator.Error!AbstractValue {
        var copy = self;
        copy.targets.ids = try allocator.dupe(u32, self.targets.ids);
        copy.placement.path = try allocator.dupe(usize, self.placement.path);
        const fields = try allocator.alloc(Field, self.fields.len);
        for (self.fields, fields) |field_value, *target| {
            target.* = .{ .name = field_value.name, .value = try field_value.value.clone(allocator) };
        }
        copy.fields = fields;
        const candidates = try allocator.dupe(Callable, self.candidates);
        for (candidates) |*candidate| switch (candidate.*) {
            .named => {},
            .closure => |*closure| {
                const bindings = try allocator.dupe(CapturedBinding, closure.bindings);
                for (bindings) |*binding| {
                    binding.binding = try binding.binding.clone(allocator);
                    binding.binding.values = try binding.binding.values.clone(allocator);
                }
                closure.bindings = bindings;
            },
        };
        copy.candidates = candidates;
        if (self.children) |children| {
            const owned = try allocator.alloc(AbstractValue, children.len);
            for (children, owned) |child, *target| target.* = try child.clone(allocator);
            copy.children = owned;
        }
        return copy;
    }

    fn field(self: AbstractValue, name: []const u8) AbstractValue {
        for (self.fields) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
        return if (self.path.unknown_target) .{ .id = self.id, .path = .{ .unknown_target = true, .items = .either }, .present = .either, .truth = .either } else .{};
    }

    fn eql(left: AbstractValue, right: AbstractValue, depth: usize) bool {
        if (depth >= max_value_depth) return false;
        if (left.truth != right.truth or left.present != right.present) return false;
        if (!left.path.eql(right.path) or !left.targets.eql(right.targets)) return false;
        if (left.candidates.len != right.candidates.len or left.fields.len != right.fields.len or
            !resourceScopeEql(left.page_scope, right.page_scope) or !left.placement.eql(right.placement)) return false;
        if (!sameTarget(left.property_target, right.property_target)) return false;
        for (left.candidates) |candidate| {
            var found = false;
            for (right.candidates) |other| if (callableEql(candidate, other, depth + 1)) {
                found = true;
                break;
            };
            if (!found) return false;
        }
        for (left.fields) |field_value| if (!field_value.value.eql(right.field(field_value.name), depth + 1)) return false;
        if (left.children) |children| {
            const other = right.children orelse return false;
            if (children.len != other.len) return false;
            for (children, other) |a, b| if (!a.eql(b, depth + 1)) return false;
        } else if (right.children != null) return false;
        return true;
    }

    fn sameTarget(left: ?PropertyTarget, right: ?PropertyTarget) bool {
        if (left) |target| {
            const other = right orelse return false;
            return target.owner.eql(other.owner) and target.fresh == other.fresh;
        }
        return right == null;
    }

    fn sameName(left: ?[]const u8, right: ?[]const u8) bool {
        if (left) |value| return if (right) |other| std.mem.eql(u8, value, other) else false;
        return right == null;
    }

    fn callableEql(left: Callable, right: Callable, depth: usize) bool {
        if (depth >= max_value_depth or std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .named => |named| named.key.eql(right.named.key),
            .closure => |closure| blk: {
                const other = right.closure;
                if (closure.module_id != other.module_id or closure.lambda.body != other.lambda.body or closure.bindings.len != other.bindings.len) break :blk false;
                for (closure.bindings, other.bindings) |a, b| {
                    if (!std.mem.eql(u8, a.name, b.name) or a.binding.policy != b.binding.policy or a.binding_id != b.binding_id or !sameName(a.binding.string_literal, b.binding.string_literal) or
                        !sameTarget(a.binding.property_target, b.binding.property_target) or !a.binding.values.eql(b.binding.values, depth + 1) or
                        a.binding.selection_reads.len != b.binding.selection_reads.len) break :blk false;
                    for (a.binding.selection_reads, b.binding.selection_reads) |x, y| if (!x.eql(y)) break :blk false;
                }
                break :blk true;
            },
        };
    }
};

const Binding = struct {
    policy: LetPolicy = .local,
    values: AbstractValue = .{},
    string_literal: ?[]const u8 = null,
    property_target: ?PropertyTarget = null,
    selection_reads: []const Resource = &.{},

    fn clone(self: Binding, allocator: std.mem.Allocator) !Binding {
        var copy = self;
        copy.selection_reads = try allocator.dupe(Resource, self.selection_reads);
        return copy;
    }
};

// One lexical binding owns its selection reads and borrows immutable value
// facts. Replacing or restoring an environment always updates all facts together.
pub const BindingEnvironment = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(Binding),

    pub fn init(allocator: std.mem.Allocator) BindingEnvironment {
        return .{ .allocator = allocator, .entries = .init(allocator) };
    }

    pub fn deinit(self: *BindingEnvironment) void {
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |binding| self.allocator.free(binding.selection_reads);
        self.entries.deinit();
    }

    pub fn get(self: *const BindingEnvironment, name: []const u8) ?Binding {
        return self.entries.get(name);
    }

    pub fn put(self: *BindingEnvironment, name: []const u8, binding: Binding) !void {
        const copy = try binding.clone(self.allocator);
        errdefer self.allocator.free(copy.selection_reads);
        const entry = try self.entries.getOrPut(name);
        if (entry.found_existing) self.allocator.free(entry.value_ptr.selection_reads);
        entry.value_ptr.* = copy;
    }

    pub fn clone(self: *const BindingEnvironment) !BindingEnvironment {
        var copy = BindingEnvironment.init(self.allocator);
        errdefer copy.deinit();
        try copy.entries.ensureTotalCapacity(self.entries.count());
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            copy.entries.putAssumeCapacity(entry.key_ptr.*, try entry.value_ptr.clone(self.allocator));
        }
        return copy;
    }

    pub const Scope = struct {
        environment: *BindingEnvironment,
        saved: BindingEnvironment,

        pub fn restore(self: *Scope) void {
            self.environment.deinit();
            self.environment.* = self.saved;
        }
    };

    pub fn pushFresh(self: *BindingEnvironment) Scope {
        return self.replace(.init(self.allocator));
    }

    pub fn pushClone(self: *BindingEnvironment) !Scope {
        return self.replace(try self.clone());
    }

    fn replace(self: *BindingEnvironment, next: BindingEnvironment) Scope {
        const scope = Scope{ .environment = self, .saved = self.* };
        self.* = next;
        return scope;
    }
};

const CapturedBinding = struct {
    name: []const u8,
    binding_id: ?u32 = null,
    binding: Binding = .{},
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    sema: SemanticEnv,
    variable_scope: ResourceScope,
    visiting: FunctionVisitSet,
    environment: BindingEnvironment,
    owned_strings: std.ArrayList([]const u8),
    run_cache: ?*RunCache,
    value_storage: std.heap.ArenaAllocator,
    binding_inputs: std.AutoHashMapUnmanaged(u32, AbstractValue) = .empty,
    capture_index: captures.Index,
    value_depth: usize = 0,
    effect_analysis_depth: usize = 0,
    recursive_fallbacks: usize = 0,
    next_value_id: usize = 1,
    next_local_object_id: usize = 1,

    pub fn init(allocator: std.mem.Allocator, sema: *const SemanticEnv) Analyzer {
        return initWithScope(allocator, sema, .{ .document = sema.module_id });
    }

    pub fn initWithScope(allocator: std.mem.Allocator, sema: *const SemanticEnv, variable_scope: ResourceScope) Analyzer {
        return initWithScopeAndCache(allocator, sema, variable_scope, null);
    }

    pub fn initWithScopeAndCache(
        allocator: std.mem.Allocator,
        sema: *const SemanticEnv,
        variable_scope: ResourceScope,
        run_cache: ?*RunCache,
    ) Analyzer {
        return .{
            .allocator = allocator,
            .sema = sema.*,
            .variable_scope = variable_scope,
            .visiting = FunctionVisitSet.init(allocator),
            .environment = .init(allocator),
            .owned_strings = .empty,
            .run_cache = run_cache,
            .value_storage = std.heap.ArenaAllocator.init(allocator),
            .capture_index = captures.Index.init(allocator),
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.capture_index.deinit();
        self.environment.deinit();
        self.value_storage.deinit();
        for (self.owned_strings.items) |value| self.allocator.free(value);
        self.owned_strings.deinit(self.allocator);
        self.visiting.deinit();
    }

    pub fn documentStatements(self: *Analyzer, items: []const ast.Statement) anyerror!AccessSummary {
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        for (items) |stmt| {
            var unit = try self.statement(stmt);
            defer unit.deinit();
            try summary.merge(unit);
        }
        return summary;
    }

    pub fn statement(self: *Analyzer, stmt: ast.Statement) anyerror!AccessSummary {
        var summary = try self.analyzeStatement(stmt, .scheduled);
        self.closeRegisteredStructureReads(&summary);
        return summary;
    }

    fn valueBinding(self: *Analyzer, callee: ast.CallableName) !@import("../language/name_resolution.zig").ValueResolution(LetPolicy, semantic_env.ResolvedConst, semantic_env.ResolvedFunction) {
        const local = if (self.environment.get(callee.name)) |binding| binding.policy else null;
        if (self.run_cache) |cache| return cache.name_resolution.resolveValue(&self.sema, LetPolicy, callee, local);
        return self.sema.resolveValue(LetPolicy, callee, local);
    }

    fn callCallee(self: *Analyzer, callee: ast.CallableName) !?semantic_env.CallDescriptor {
        return switch (try self.valueBinding(callee)) {
            .function => |func| .{ .function = func },
            .primitive => |primitive| .{ .primitive = primitive },
            else => null,
        };
    }

    pub fn bindScheduledStatements(self: *Analyzer, statements: []const ast.Statement) !void {
        const state = self.sema.state orelse return;
        for (statements) |stmt| if (stmt.kind == .let_binding) {
            const binding = stmt.kind.let_binding;
            const id = binding.binding_id orelse continue;
            // Standalone dependency queries may run before closed call facts.
            if (id >= state.displays.inputs.bindings.len) continue;
            try self.bindInput(binding.name, id, .scheduled);
        };
    }

    fn bindingInput(self: *Analyzer, id: u32) !AbstractValue {
        if (self.binding_inputs.get(id)) |value| return value;
        const value = try self.importPlacementInput(self.sema.state.?.displays.inputs.bindings[id], 0);
        try self.binding_inputs.put(self.value_storage.allocator(), id, value);
        return value;
    }

    fn bindInput(self: *Analyzer, name: []const u8, id: u32, policy: LetPolicy) !void {
        const input = self.sema.state.?.displays.inputs.bindings[id];
        var binding = self.environment.get(name) orelse Binding{};
        binding.policy = policy;
        binding.values = try self.bindingInput(id);
        if (input.string_literal) |literal| binding.string_literal = literal;
        if (binding.values.property_target) |target| binding.property_target = target;
        var reads = std.ArrayList(Resource).empty;
        try self.importSelectionReads(&reads, input);
        binding.selection_reads = reads.items;
        try self.environment.put(name, binding);
    }

    fn localObjectCounter(self: *Analyzer) *usize {
        return if (self.run_cache) |cache| &cache.next_local_object_id else &self.next_local_object_id;
    }

    fn isLocalResource(resource: Resource, first: usize, end: usize) bool {
        const owner: ObjectOwner = switch (resource) {
            .property => |property| if (property.owner == .object) property.owner.object else return false,
            .objects => |members| members.owner,
            else => return false,
        };
        const identity = owner.identity orelse return false;
        return identity.origin == .local and identity.local_id >= first and identity.local_id < end;
    }

    fn closeRegisteredStructureReads(self: *Analyzer, summary: *AccessSummary) void {
        var index: usize = 0;
        while (index < summary.reads.items.len) {
            if (self.isRegisteredStructureRead(summary.reads.items[index])) {
                _ = summary.reads.orderedRemove(index);
            } else index += 1;
        }
    }

    fn isRegisteredStructureRead(self: *Analyzer, read: Resource) bool {
        if (read != .objects) return false;
        const call = read.objects.placement.call orelse return false;
        const state = self.sema.state orelse return false;
        const plan_index = state.displays.call_targets.get(call) orelse return false;
        const plan = state.displays.plans.items[plan_index];
        // Once a root reference exists, all of its input-group structure is
        // registered. A user display is the only source of later children.
        for (plan.steps.items) |step| {
            const member = Resource{ .objects = .{
                .input_type = step.input,
                .placement = .exact(call, step.path),
            } };
            if (!member.intersects(read)) continue;
            var ancestor = step.parent;
            while (ancestor) |parent| {
                if (plan.steps.items[parent].target != .group) return false;
                ancestor = plan.steps.items[parent].parent;
            }
        }
        return true;
    }

    const ReturnedValues = struct {
        collect: bool = true,
        values: AbstractValue = .{},
        exits: control.Exits = .{},
    };

    fn analyzeStatementsWithReturns(self: *Analyzer, items: []const ast.Statement, let_policy: LetPolicy, returned: ?*ReturnedValues, entry: settings.Definitions, exits_out: ?*SettingExits) anyerror!AccessSummary {
        const first_local = self.localObjectCounter().*;
        var parts = std.ArrayList(AccessSummary).empty;
        defer {
            for (parts.items) |*part| part.deinit();
            parts.deinit(self.allocator);
        }
        var pass = AccessBlock{ .analyzer = self, .let_policy = let_policy, .returned = returned, .parts = &parts };
        defer pass.fallthrough.deinit(self.allocator);
        defer pass.open_reads.deinit(self.allocator);
        defer pass.returns.deinit(self.allocator);
        try pass.fallthrough.include(self.allocator, entry);
        const exits = try control.block(&pass, items);
        if (returned) |result| result.exits = exits;
        const end_local = self.localObjectCounter().*;
        // A fresh local object's defaults are closed only while the object stays
        // inside this execution unit. Escaping objects may receive definitions
        // from other units, so their reads require an earlier covering definition.
        for (parts.items, 0..) |*part, i| {
            if (self.sema.state) |state| try state.checkAnalysisCanceled();
            var read_index: usize = 0;
            while (read_index < part.reads.items.len) {
                const read = part.reads.items[read_index];
                if (!isLocalResource(read, first_local, end_local)) {
                    read_index += 1;
                    continue;
                }
                const identity = if (read == .objects) read.objects.owner.identity.? else read.property.owner.object.identity.?;
                const escapes = blk: {
                    for (parts.items) |other| for (other.escaped_objects.items) |escaped| {
                        if (identity.eql(escaped)) break :blk true;
                    };
                    break :blk false;
                };
                const pending = blk: {
                    for (parts.items[i..]) |later| {
                        for (later.writes.items) |write| if (write.intersects(read)) break :blk true;
                    }
                    break :blk false;
                };
                const covered = blk: {
                    for (parts.items[0..i]) |earlier| for (earlier.writes.items) |write| {
                        if (read == .objects) {
                            if (write == .objects and write.objects.owner.eql(read.objects.owner)) break :blk true;
                            continue;
                        }
                        if (write != .property or !write.property.owner.eql(read.property.owner)) continue;
                        const defined = write.property.key.displayName() orelse continue;
                        const required = read.property.key.displayName() orelse continue;
                        if (core.PropertyPath.contains(defined, required)) break :blk true;
                    };
                    break :blk false;
                };
                if (!pending and (!escapes or covered)) {
                    _ = part.reads.orderedRemove(read_index);
                } else {
                    // Local allocation identities do not name the caller's binding.
                    // Keep unresolved escaping reads conservative at that boundary.
                    if (escapes) {
                        if (read == .objects) part.reads.items[read_index].objects.owner.identity = null else part.reads.items[read_index].property.owner.object.identity = null;
                    }
                    read_index += 1;
                }
            }
        }
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        for (parts.items) |part| try summary.mergeEffects(part);
        if (exits_out) |out| {
            if (exits.next) {
                try out.next.add(self.allocator, pass.fallthrough);
                try addOpenReads(self.allocator, &out.next_reads, pass.open_reads.items, .{});
            }
            if (exits.returned) try out.returned.add(self.allocator, pass.returns.definitions);
        } else {
            if (exits.next) try pass.returns.add(self.allocator, pass.fallthrough);
            try summary.defined_settings.include(self.allocator, pass.returns.definitions);
        }
        self.closeRegisteredStructureReads(&summary);
        var write_index: usize = 0;
        while (write_index < summary.writes.items.len) {
            const write = summary.writes.items[write_index];
            if (write == .objects) {
                if (isLocalResource(write, first_local, end_local)) summary.writes.items[write_index].objects.owner.identity = null;
                write_index += 1;
                continue;
            }
            const escapes = blk: {
                if (!isLocalResource(write, first_local, end_local)) break :blk true;
                for (summary.reads.items) |read| if (write.intersects(read)) break :blk true;
                break :blk false;
            };
            if (escapes) write_index += 1 else _ = summary.writes.orderedRemove(write_index);
        }
        return summary;
    }

    const SettingExits = struct {
        // Only continuing paths reach the next source statement. Both kinds of
        // exit count when publishing the postcondition of a function call.
        next: settings.Join = .{},
        returned: settings.Join = .{},
        next_reads: std.ArrayList(Resource) = .empty,

        fn deinit(self: *SettingExits, allocator: std.mem.Allocator) void {
            self.next.deinit(allocator);
            self.returned.deinit(allocator);
            self.next_reads.deinit(allocator);
        }
    };

    fn addOpenReads(allocator: std.mem.Allocator, open: *std.ArrayList(Resource), reads: []const Resource, prior: settings.Definitions) !void {
        for (reads) |read| {
            if (settings.Key.fromResource(read) != null and !prior.satisfies(read)) try appendUnique(allocator, open, read);
        }
    }

    const AccessBlock = struct {
        analyzer: *Analyzer,
        let_policy: LetPolicy,
        returned: ?*ReturnedValues,
        parts: *std.ArrayList(AccessSummary),
        fallthrough: settings.Definitions = .{},
        open_reads: std.ArrayList(Resource) = .empty,
        returns: settings.Join = .{},

        pub fn visit(pass: *@This(), stmt: ast.Statement, _: bool) anyerror!control.Exits {
            const allocator = pass.analyzer.allocator;
            var effects = AccessSummary.init(pass.analyzer.allocator);
            errdefer effects.deinit();
            var paths = SettingExits{};
            defer paths.deinit(allocator);
            const exits = try pass.analyzer.statementEffects(stmt, pass.let_policy, pass.returned, &effects, pass.fallthrough, &paths);
            effects.closeSettingReads(pass.fallthrough);
            for (effects.writes.items) |write| try effects.checkLaterWrite(write, pass.open_reads.items);
            if (exits.next) try addOpenReads(allocator, &pass.open_reads, if (stmt.kind == .if_stmt) paths.next_reads.items else effects.reads.items, pass.fallthrough);
            if (stmt.kind == .if_stmt) {
                if (exits.returned) try pass.returns.add(allocator, paths.returned.definitions);
                std.mem.swap(settings.Definitions, &pass.fallthrough, &paths.next.definitions);
            } else {
                try pass.fallthrough.include(allocator, effects.defined_settings);
                if (exits.returned) try pass.returns.add(allocator, pass.fallthrough);
            }
            try pass.parts.append(allocator, effects);
            return exits;
        }
    };

    fn analyzeStatement(self: *Analyzer, stmt: ast.Statement, let_policy: LetPolicy) anyerror!AccessSummary {
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        var paths = SettingExits{};
        defer paths.deinit(self.allocator);
        const exits = try self.statementEffects(stmt, let_policy, null, &summary, .{}, &paths);
        if (stmt.kind == .if_stmt) {
            if (exits.next) try paths.returned.add(self.allocator, paths.next.definitions);
            std.mem.swap(settings.Definitions, &summary.defined_settings, &paths.returned.definitions);
        }
        return summary;
    }

    fn statementEffects(self: *Analyzer, stmt: ast.Statement, policy: LetPolicy, returned: ?*ReturnedValues, effects: *AccessSummary, entry: settings.Definitions, paths: *SettingExits) anyerror!control.Exits {
        var arms = AccessSummary.init(self.allocator);
        defer arms.deinit();
        var pass = AccessFlow{ .analyzer = self, .policy = policy, .returned = returned, .effects = effects, .arms = &arms, .entry = entry, .paths = paths };
        defer pass.arm_entry.deinit(self.allocator);
        const exits = try control.statement(&pass, stmt);
        if (stmt.kind == .if_stmt) {
            if (exits.next) try addOpenReads(self.allocator, &paths.next_reads, effects.reads.items, entry);
            try effects.appendSequential(arms);
        }
        return exits;
    }

    const AccessFlow = struct {
        analyzer: *Analyzer,
        policy: LetPolicy,
        returned: ?*ReturnedValues,
        effects: *AccessSummary,
        arms: *AccessSummary,
        entry: settings.Definitions,
        arm_entry: settings.Definitions = .{},
        paths: *SettingExits,

        pub fn condition(pass: *@This(), expr: ast.Expr) !Alternatives {
            var facts = try pass.analyzer.analyzeArgument(expr);
            defer facts.deinit();
            try pass.effects.merge(facts.summary);
            try pass.arm_entry.include(pass.analyzer.allocator, pass.entry);
            try pass.arm_entry.include(pass.analyzer.allocator, facts.summary.defined_settings);
            return facts.values.truth.orUnknown();
        }

        pub fn arm(pass: *@This(), body: []const ast.Statement, _: usize) anyerror!control.Exits {
            var branch = ReturnedValues{ .collect = if (pass.returned) |result| result.collect else false };
            var snapshot = try pass.analyzer.environment.pushClone();
            defer snapshot.restore();
            var effects = try pass.analyzer.analyzeStatementsWithReturns(body, .local, &branch, pass.arm_entry, pass.paths);
            defer effects.deinit();
            try pass.arms.mergeEffects(effects);
            if (pass.returned) |result| result.values = try pass.analyzer.joinValues(result.values, branch.values);
            return branch.exits;
        }

        pub fn onReturn(pass: *@This(), value: ?ast.Expr) !void {
            const expr = value orelse return;
            var facts = try pass.analyzer.analyzeArgument(expr);
            defer facts.deinit();
            try pass.effects.merge(facts.summary);
            try pass.analyzer.addEscapedObjects(pass.effects, facts.values);
            if (pass.returned) |result| if (result.collect) {
                result.values = try pass.analyzer.joinValues(result.values, facts.values);
            };
        }

        pub fn simple(pass: *@This(), stmt: ast.Statement) !void {
            return pass.analyzer.simpleStatement(stmt, pass.policy, pass.effects);
        }
    };

    fn simpleStatement(self: *Analyzer, stmt: ast.Statement, let_policy: LetPolicy, summary: *AccessSummary) !void {
        switch (stmt.kind) {
            .hole => {},
            .let_binding => |binding| {
                var facts = try self.analyzeArgument(binding.expr);
                defer facts.deinit();
                try summary.merge(facts.summary);
                if (!names.isDiscardBindingName(binding.name)) {
                    if (binding.binding_id) |id| try summary.addWrite(.{ .placement_binding = .{ .id = id, .name = binding.name } });
                    if (let_policy == .scheduled) try summary.addWrite(Resource.makeVariable(self.variable_scope, binding.name));
                    const target = try self.bindingPropertyTarget(binding.name, facts.property_target, let_policy);
                    try self.environment.put(binding.name, .{
                        .policy = let_policy,
                        .values = if (target) |value| try self.withPropertyTarget(facts.values, value) else facts.values,
                        .string_literal = facts.string_literal,
                        .property_target = target,
                        .selection_reads = facts.summary.selection_reads.items,
                    });
                }
            },
            .property_set => |property_set| {
                var target_expr = try self.analyzeExpr(property_set.target);
                defer target_expr.deinit();
                try summary.merge(target_expr);
                var value_facts = try self.analyzeArgument(property_set.value);
                defer value_facts.deinit();
                try summary.appendSequential(value_facts.summary);
                try self.addEscapedObjects(summary, value_facts.values);
                var base = property_set.target;
                var path = property_set.path.items;
                var target = try self.propertyTargetExpr(base);
                while (target == null and path.len > 1) {
                    const parent = try self.value_storage.allocator().create(ast.Expr);
                    parent.* = base;
                    base = .{ .member = .{ .target = parent, .name = path[0].name } };
                    path = path[1..];
                    target = try self.propertyTargetExpr(base);
                }
                const property_name = if (path.len == 0) null else try ownString(self, try ast.formatRecordPath(self.allocator, path));
                const owner = (target orelse PropertyTarget.any()).owner;
                try summary.addWrite(Resource.makeProperty(owner, property_name));
                if (property_name) |name| try summary.defined_settings.define(self.allocator, owner, name, value_facts.values.present == .yes);
                summary.writes_layout_input = true;
            },
            .if_stmt, .return_expr, .return_void => unreachable,
            .expr_stmt => |expr| {
                var nested = try self.analyzeExpr(expr);
                defer nested.deinit();
                try summary.merge(nested);
            },
            .constrain => |decl| {
                try self.addAnchorReads(summary, decl.target);
                if (decl.source) |source| try self.addAnchorReads(summary, source);
                if (decl.offset) |offset| {
                    var nested = try self.analyzeExpr(offset);
                    defer nested.deinit();
                    try summary.merge(nested);
                }
                summary.writes_layout_input = true;
            },
        }
    }

    fn bindingPropertyTarget(self: *Analyzer, name: []const u8, target: ?PropertyTarget, let_policy: LetPolicy) !?PropertyTarget {
        const value = target orelse return null;
        return switch (value.owner) {
            .object => |owner| blk: {
                if (owner.identity != null or !value.fresh) break :blk value;
                var bound = PropertyTarget.objectWithIdentity(self.variable_scope, name);
                if (let_policy == .local) {
                    const counter = self.localObjectCounter();
                    bound.owner.object.identity.?.origin = .local;
                    bound.owner.object.identity.?.local_id = counter.*;
                    counter.* += 1;
                }
                break :blk bound;
            },
            .any, .document, .page => value,
        };
    }

    fn guardFallback(self: *Analyzer, target: ast.Expr, fallback: *AccessSummary) !void {
        if (target != .member) return;
        const read = (try self.propertyMemberRead(target.member)) orelse return;
        if (read.target.owner != .page or read.target.owner.page == null or self.sema.settingsField(read.key) == null) return;
        for ([_][]Resource{ fallback.reads.items, fallback.reads_before_write.items }) |reads| for (reads) |*item| {
            if (item.* != .property or item.property.owner != .document or item.property.unless_defined_on != null) continue;
            if (item.property.key.displayName()) |key| if (std.mem.eql(u8, key, read.key)) {
                item.property.unless_defined_on = read.target.owner.page;
            };
        };
    }

    fn analyzeExpr(self: *Analyzer, value: ast.Expr) anyerror!AccessSummary {
        if (self.sema.state) |state| try state.checkAnalysisCanceled();
        return switch (value) {
            .hole, .binding_ref => AccessSummary.init(self.allocator),
            .dereference => |operand| blk: {
                var result = try self.analyzeExpr(operand.target.*);
                errdefer result.deinit();
                // The closed call analysis has already recorded all reads for
                // scheduled units. Open dependency queries may still have local evidence.
                if (self.run_cache == null) if (self.sema.state) |state| {
                    const handle = try self.expressionValue(operand.target.*);
                    for (handle.targets.ids) |id|
                        try result.addRead(.{ .placement_binding = .{ .id = id, .name = state.scheduled_bindings.items[id].name } });
                };
                break :blk result;
            },
            .ident => |ident| blk: {
                const name = ident.name;
                var summary = AccessSummary.init(self.allocator);
                errdefer summary.deinit();
                try self.addVariableRead(&summary, name);
                break :blk summary;
            },
            .string, .color, .number, .boolean, .none, .enum_case => AccessSummary.init(self.allocator),
            .lambda => |lambda| blk: {
                var summary = AccessSummary.init(self.allocator);
                errdefer summary.deinit();
                for (try self.capture_index.lambdaNames(lambda)) |name| {
                    if (self.environment.get(name) != null) try self.addVariableRead(&summary, name);
                }
                break :blk summary;
            },
            .record => |record| blk: {
                var summary = AccessSummary.init(self.allocator);
                errdefer summary.deinit();
                if (self.sema.recordConstruction(record)) |decl| {
                    for (decl.decl.fields.items) |field| {
                        if (record.hasField(field.name)) continue;
                        const default = field.default_value orelse continue;
                        var facts = self.environment.pushFresh();
                        defer facts.restore();
                        const previous = self.sema;
                        self.sema = self.sema.forModule(decl.module_id);
                        defer self.sema = previous;
                        var nested = try self.analyzeExpr(default.*);
                        defer nested.deinit();
                        try summary.appendSequential(nested);
                    }
                }
                for (record.fields.items) |field| {
                    var nested = try self.analyzeExpr(field.value);
                    defer nested.deinit();
                    try summary.appendSequential(nested);
                }
                break :blk summary;
            },
            .record_update => |update| blk: {
                var summary = try self.analyzeExpr(update.target.*);
                errdefer summary.deinit();
                for (update.fields.items) |field| {
                    var nested = try self.analyzeExpr(field.value);
                    defer nested.deinit();
                    try summary.appendSequential(nested);
                }
                break :blk summary;
            },
            .apply => |apply| blk: {
                var summary = try self.analyzeExpr(apply.callee.*);
                errdefer summary.deinit();
                const callable = try self.expressionValue(apply.callee.*);
                var args = try self.analyzeArguments(apply.args.items);
                defer self.deinitArguments(&args);
                for (args.items) |arg| try summary.appendSequential(arg.summary);
                var invoked = try self.invokeValue(callable, args.items);
                defer invoked.deinit();
                try summary.appendSequential(invoked);
                break :blk summary;
            },
            .member => |member| blk: {
                if (names.parseAnchorName(member.name) != null) {
                    if (try self.propertyTargetExpr(member.target.*)) |target| {
                        if (target.owner == .object or target.owner == .page) break :blk try self.analyzeExpr(member.target.*);
                    }
                }
                if (try self.propertyMemberRead(member)) |read| {
                    var summary = try self.analyzeExpr(read.base);
                    errdefer summary.deinit();
                    const resource = Resource.makeProperty(read.target.owner, read.key);
                    if (!summary.defined_settings.satisfies(resource)) try summary.addRead(resource);
                    break :blk summary;
                }
                var summary = try self.analyzeExpr(member.target.*);
                errdefer summary.deinit();
                if (try self.propertyTargetExpr(member.target.*)) |target| {
                    const resource = Resource.makeProperty(target.owner, member.name);
                    if (!summary.defined_settings.satisfies(resource)) try summary.addRead(resource);
                }
                break :blk summary;
            },
            .optional_check => |check| try self.analyzeExpr(check.target.*),
            .coalesce => |coalesce| blk: {
                var summary = try self.analyzeExpr(coalesce.target.*);
                errdefer summary.deinit();
                const route = control.coalesce((try self.expressionValue(coalesce.target.*)).present.orUnknown());
                if (route == .left) break :blk summary;
                var fallback = try self.analyzeExpr(coalesce.fallback.*);
                defer fallback.deinit();
                try self.guardFallback(coalesce.target.*, &fallback);
                if (route == .both) fallback.defined_settings.clear();
                try summary.appendSequential(fallback);
                break :blk summary;
            },
            .call => |call| try self.analyzeCall(call),
        };
    }

    fn addVariableRead(self: *Analyzer, summary: *AccessSummary, name: []const u8) !void {
        switch (try self.valueBinding(ast.CallableName.fromText(name))) {
            .local => |policy| {
                if (policy == .scheduled) try summary.addRead(Resource.makeVariable(self.variable_scope, name));
                try self.addBoundSelectionReads(summary, name);
            },
            .constant => |resolved| {
                var nested = try self.constantSummary(resolved);
                defer nested.deinit();
                try summary.merge(nested);
            },
            .function, .primitive => {},
            .unknown => {
                try summary.addRead(Resource.makeVariable(self.variable_scope, name));
                try self.addBoundSelectionReads(summary, name);
            },
        }
    }

    fn newValue(self: *Analyzer, candidates: []const AbstractValue.Callable, fields: []const AbstractValue.Field) !AbstractValue {
        return self.newValueIn(self.value_storage.allocator(), candidates, fields);
    }

    fn newValueIn(self: *Analyzer, allocator: std.mem.Allocator, candidates: []const AbstractValue.Callable, fields: []const AbstractValue.Field) !AbstractValue {
        var field_count: usize = 0;
        for (fields) |field| if (field.value.id != 0) {
            field_count += 1;
        };
        if (candidates.len == 0 and field_count == 0) return .{};
        const counter = if (self.run_cache) |cache| &cache.next_value_id else &self.next_value_id;
        const id = counter.*;
        counter.* += 1;
        const kept_fields = try allocator.alloc(AbstractValue.Field, field_count);
        var field_index: usize = 0;
        for (fields) |field| {
            if (field.value.id == 0) continue;
            kept_fields[field_index] = field;
            field_index += 1;
        }
        return .{ .id = id, .present = if (candidates.len != 0) .yes else .bottom, .candidates = try allocator.dupe(AbstractValue.Callable, candidates), .fields = kept_fields };
    }

    fn addEscapedObjects(self: *Analyzer, summary: *AccessSummary, facts: AbstractValue) anyerror!void {
        if (facts.property_target) |target| {
            if (target.owner == .object) {
                if (target.owner.object.identity) |identity| {
                    if (identity.origin == .local) try summary.addEscapedObject(identity);
                }
            }
        }
        if (facts.children) |children| for (children) |child| try self.addEscapedObjects(summary, child);
        for (facts.fields) |field| try self.addEscapedObjects(summary, field.value);
        for (facts.candidates) |candidate| switch (candidate) {
            .named => {},
            .closure => |closure| for (closure.bindings) |binding| {
                try self.addEscapedObjects(summary, binding.binding.values);
            },
        };
    }

    fn withPropertyTarget(self: *Analyzer, facts: AbstractValue, target: ?PropertyTarget) !AbstractValue {
        const value = target orelse return facts;
        if (facts.property_target) |existing| {
            if (existing.owner.eql(value.owner) and existing.fresh == value.fresh) return facts;
        }
        var result = facts;
        const counter = if (self.run_cache) |cache| &cache.next_value_id else &self.next_value_id;
        result.id = counter.*;
        counter.* += 1;
        result.property_target = value;
        return result;
    }

    fn joinValues(self: *Analyzer, left: AbstractValue, right: AbstractValue) anyerror!AbstractValue {
        if (left.id == 0 or right.id != 0 and left.path.no_value) return right;
        if (right.id == 0 or right.path.no_value or left.eql(right, 0)) return left;
        if (core.placement_inputs.ReadPath.emptyOperand(left.path, right.path)) |empty| {
            const elements = if (empty == .left) right else left;
            return self.withPath(self.withAlternatives(elements, elements.truth, left.present.join(right.present)), elements.path.selection(left.path.items.join(right.path.items)));
        }
        const allocator = self.value_storage.allocator();
        var candidates = std.ArrayList(AbstractValue.Callable).empty;
        try candidates.appendSlice(allocator, left.candidates);
        for (right.candidates) |candidate| {
            var found = false;
            for (candidates.items) |existing| if (AbstractValue.callableEql(candidate, existing, 0)) {
                found = true;
                break;
            };
            if (!found) try candidates.append(allocator, candidate);
        }
        var fields = std.ArrayList(AbstractValue.Field).empty;
        for (left.fields) |field| try fields.append(allocator, .{ .name = field.name, .value = try self.joinValues(field.value, right.field(field.name)) });
        for (right.fields) |field| {
            var found = false;
            for (left.fields) |other| if (std.mem.eql(u8, field.name, other.name)) {
                found = true;
                break;
            };
            if (!found) try fields.append(allocator, .{ .name = field.name, .value = try self.joinValues(left.field(field.name), field.value) });
        }
        var result = try self.withPropertyTarget(try self.newValue(candidates.items, fields.items), joinPropertyTargets(left.property_target, right.property_target));
        result = self.withAlternatives(result, left.truth.join(right.truth), left.present.join(right.present));
        result = self.withPath(result, left.path.join(right.path));
        result = self.withBindingTargets(result, try left.targets.merge(right.targets, allocator));
        result.page_scope = if (resourceScopeEql(left.page_scope, right.page_scope)) left.page_scope else .any;
        result.placement = left.placement.join(right.placement);
        if (left.children) |left_children| if (right.children) |right_children| {
            var children = std.ArrayList(AbstractValue).empty;
            try children.appendSlice(allocator, left_children);
            for (right_children) |child| {
                var found = false;
                for (children.items) |existing| if (child.eql(existing, 0)) {
                    found = true;
                    break;
                };
                if (!found) try children.append(allocator, child);
            }
            result.children = children.items;
        };
        return result;
    }

    fn updateValueField(self: *Analyzer, value: AbstractValue, path: []const ast.RecordPathSegment, replacement: AbstractValue) anyerror!AbstractValue {
        if (path.len == 0) return replacement;
        var fields = std.ArrayList(AbstractValue.Field).empty;
        const allocator = self.value_storage.allocator();
        for (value.fields) |field| {
            if (!std.mem.eql(u8, field.name, path[0].name)) try fields.append(allocator, field);
        }
        try fields.append(allocator, .{ .name = path[0].name, .value = try self.updateValueField(value.field(path[0].name), path[1..], replacement) });
        var result = try self.newValue(value.candidates, fields.items);
        result.children = value.children;
        return self.withAlternatives(result, .bottom, .yes);
    }

    fn callableValue(self: *Analyzer, name: ast.CallableName) anyerror!AbstractValue {
        return switch (try self.valueBinding(name)) {
            .local => (self.environment.get(name.name) orelse Binding{}).values,
            .function => |resolved| try self.newValue(&.{.{ .named = resolved }}, &.{}),
            .constant => |resolved| try self.constantValue(resolved),
            else => .{},
        };
    }

    fn constantValue(self: *Analyzer, resolved: semantic_env.ResolvedConst) anyerror!AbstractValue {
        if (self.visiting.contains(resolved.key)) {
            self.recursive_fallbacks += 1;
            return .{};
        }
        // Initializers have a fresh lexical environment and document scope.
        // Include both budgets so reuse cannot bypass an analysis depth limit.
        const key = ConstantValueKey{
            .declaration = resolved.key,
            .value_depth = self.value_depth,
            .effect_depth = self.effect_analysis_depth,
        };
        if (self.run_cache) |cache| if (cache.constant_values.get(key)) |value| return value;
        try self.visiting.put(resolved.key, {});
        defer _ = self.visiting.remove(resolved.key);
        const before = self.recursive_fallbacks;
        var facts = self.environment.pushFresh();
        defer facts.restore();
        const previous = self.sema;
        self.sema = self.sema.forModule(resolved.module_id);
        defer self.sema = previous;
        const caller = self.variable_scope;
        self.variable_scope = .{ .document = resolved.module_id };
        defer self.variable_scope = caller;
        const value = try self.expressionValue(resolved.decl.value);
        if (self.run_cache) |cache| {
            cache.constant_body_analyses += 1;
            // A recursive fallback depends on the active call chain.
            if (self.recursive_fallbacks == before) {
                const stored = try value.clone(cache.value_storage.allocator());
                try cache.constant_values.put(key, stored);
                return stored;
            }
        }
        return value;
    }

    fn withAlternatives(self: *Analyzer, value: AbstractValue, truth: Alternatives, present: Alternatives) AbstractValue {
        if (value.truth == truth and value.present == present) return value;
        const counter = if (self.run_cache) |cache| &cache.next_value_id else &self.next_value_id;
        var result = value;
        result.id = counter.*;
        counter.* += 1;
        result.truth = truth;
        result.present = present;
        return result;
    }

    fn withPath(self: *Analyzer, value: AbstractValue, path: core.placement_inputs.ReadPath) AbstractValue {
        if (value.path.eql(path)) return value;
        var result = value;
        const counter = if (self.run_cache) |cache| &cache.next_value_id else &self.next_value_id;
        result.id = counter.*;
        counter.* += 1;
        result.path = path;
        return result;
    }

    fn withBindingTargets(self: *Analyzer, value: AbstractValue, targets: core.placement_inputs.BindingTargets) AbstractValue {
        if (targets.ids.len == 0 or value.targets.eql(targets)) return value;
        var result = value;
        const counter = if (self.run_cache) |cache| &cache.next_value_id else &self.next_value_id;
        result.id = counter.*;
        counter.* += 1;
        result.targets = targets;
        return result;
    }

    fn expressionValue(self: *Analyzer, expr: ast.Expr) anyerror!AbstractValue {
        if (self.value_depth >= max_value_depth) return error.FunctionAnalysisLimitExceeded;
        self.value_depth += 1;
        defer self.value_depth -= 1;
        return switch (expr) {
            .boolean => |flag| self.withAlternatives(.{}, .from(flag), .yes),
            .number, .color, .enum_case, .string => self.withAlternatives(.{}, .bottom, .yes),
            .none => self.withAlternatives(.{}, .bottom, .no),
            .optional_check => |check| self.withAlternatives(.{}, (try self.expressionValue(check.target.*)).present, .yes),
            .binding_ref => |ref| if (ref.binding_id) |id| self.withBindingTargets(self.withAlternatives(.{}, .bottom, .yes), try core.placement_inputs.BindingTargets.one(self.value_storage.allocator(), id)) else .{},
            .dereference => |operand| blk: {
                const state = self.sema.state orelse break :blk .{};
                const handle = try self.expressionValue(operand.target.*);
                if (handle.path.no_value) break :blk handle;
                var result = AbstractValue{};
                for (handle.targets.ids) |id| {
                    if (id >= state.displays.inputs.bindings.len) continue;
                    result = try self.joinValues(result, try self.bindingInput(id));
                }
                break :blk result;
            },
            .ident => |ident| try self.withPropertyTarget(try self.callableValue(ident.reference()), (self.environment.get(ident.name) orelse Binding{}).property_target),
            .lambda => |lambda| blk: {
                const allocator = self.value_storage.allocator();
                var bindings = std.ArrayList(CapturedBinding).empty;
                for (try self.capture_index.lambdaNames(lambda)) |name| {
                    const binding = self.environment.get(name) orelse continue;
                    try bindings.append(allocator, .{ .name = name, .binding = try binding.clone(allocator) });
                }
                break :blk try self.newValue(&.{.{ .closure = .{ .module_id = self.sema.module_id, .lambda = lambda, .bindings = bindings.items } }}, &.{});
            },
            .coalesce => |value| blk: {
                const target = try self.expressionValue(value.target.*);
                const route = control.coalesce(target.present.orUnknown());
                if (route == .left) break :blk target;
                const fallback = try self.expressionValue(value.fallback.*);
                break :blk if (route == .right) fallback else try self.joinValues(self.withAlternatives(target, target.truth, .yes), fallback);
            },
            .member => |member| try self.memberValue(member),
            .record => |record| blk: {
                var fields = std.ArrayList(AbstractValue.Field).empty;
                const allocator = self.value_storage.allocator();
                for (record.fields.items) |field| {
                    const value = try self.expressionValue(field.value);
                    if (value.id != 0) try fields.append(allocator, .{ .name = field.name, .value = value });
                }
                if (self.sema.recordConstruction(record)) |decl| {
                    for (decl.decl.fields.items) |field| {
                        if (record.hasField(field.name)) continue;
                        if (field.default_value) |default| {
                            var facts = self.environment.pushFresh();
                            defer facts.restore();
                            const previous = self.sema;
                            self.sema = self.sema.forModule(decl.module_id);
                            defer self.sema = previous;
                            const value = try self.expressionValue(default.*);
                            if (value.id != 0) try fields.append(allocator, .{ .name = field.name, .value = value });
                        }
                    }
                }
                break :blk self.withAlternatives(try self.newValue(&.{}, fields.items), .bottom, .yes);
            },
            .record_update => |update| blk: {
                var result = try self.expressionValue(update.target.*);
                for (update.fields.items) |field| result = try self.updateValueField(result, field.path.items, try self.expressionValue(field.value));
                break :blk result;
            },
            .call => |call| blk: {
                switch (try self.valueBinding(call.callee)) {
                    .primitive => |primitive| break :blk try self.primitiveValue(call, primitive, null),
                    .unknown => break :blk .{},
                    .function => |named| if (!control.needsValueFlow(named.decl.result_type))
                        break :blk self.withAlternatives(.{}, .bottom, control.presence(named.decl.result_type)),
                    else => {},
                }
                const value = try self.callableValue(call.callee);
                if (value.id == 0) break :blk .{};
                var args = try self.analyzeArguments(call.args.items);
                defer self.deinitArguments(&args);
                break :blk try self.returnedValue(value, args.items);
            },
            .apply => |apply| blk: {
                const value = try self.expressionValue(apply.callee.*);
                var args = try self.analyzeArguments(apply.args.items);
                defer self.deinitArguments(&args);
                break :blk try self.returnedValue(value, args.items);
            },
            else => .{},
        };
    }

    fn importPlacementInput(self: *Analyzer, input: core.placement_inputs.Value, depth: usize) anyerror!AbstractValue {
        if (depth >= max_value_depth) return error.FunctionAnalysisLimitExceeded;
        const allocator = self.value_storage.allocator();
        const candidates = try allocator.alloc(AbstractValue.Callable, input.candidates.len);
        for (input.candidates, candidates) |candidate, *output| output.* = switch (candidate) {
            .function => |key| .{ .named = .{ .key = key, .module_id = key.module_id, .decl = self.sema.functions.get(key).? } },
            .closure => |closure| .{ .closure = .{
                .module_id = closure.module_id,
                .lambda = closure.lambda,
                .bindings = try self.importCapturedBindings(closure, depth),
            } },
        };
        var fields = std.ArrayList(AbstractValue.Field).empty;
        for (input.fields) |field| {
            const value = try self.importPlacementInput(field.value, depth + 1);
            if (value.id != 0) try fields.append(allocator, .{ .name = field.name, .value = value });
        }
        var result = try self.newValue(candidates, fields.items);
        result = self.withAlternatives(result, input.truth, input.present);
        result = self.withBindingTargets(result, input.targets);
        result = self.withPath(result, input.path);
        if (input.reference) |reference| switch (reference) {
            .unknown => result = try self.withPropertyTarget(result, PropertyTarget.any()),
            .document => result = try self.withPropertyTarget(result, PropertyTarget.document()),
            .page => |page| {
                const id: ?core.NodeId = if (self.run_cache != null and page != null) self.run_cache.?.page_ids.get(page.?) orelse null else null;
                result = try self.withPropertyTarget(result, PropertyTarget.page(id));
                if (id) |n| result.page_scope = .{ .page = n };
            },
            .placement => |placement| {
                result = try self.withPropertyTarget(result, PropertyTarget.object());
                result.placement = .exact(placement.call, placement.path);
                result.page_scope = result.field("page").page_scope;
            },
        };
        const children = try allocator.alloc(AbstractValue, input.children.len);
        for (input.children, children) |child, *output| output.* = try self.importPlacementInput(child, depth + 1);
        // Closed call facts do not prove that a placement has no display
        // children. Only explicit group members describe its structure here.
        if (!input.unknown and children.len != 0) result.children = children;
        return result;
    }

    fn importCapturedBindings(self: *Analyzer, closure: *const core.placement_inputs.Closure, depth: usize) ![]const CapturedBinding {
        const allocator = self.value_storage.allocator();
        const bindings = try allocator.alloc(CapturedBinding, closure.bindings.len + closure.scheduled.len);
        for (closure.bindings, bindings[0..closure.bindings.len]) |binding, *captured| {
            const values = try self.importPlacementInput(binding.value, depth + 1);
            var reads = std.ArrayList(Resource).empty;
            try self.importSelectionReads(&reads, binding.value);
            captured.* = .{
                .name = binding.name,
                .binding = .{
                    .values = values,
                    .string_literal = binding.value.string_literal,
                    .property_target = values.property_target,
                    .selection_reads = reads.items,
                },
            };
        }
        for (closure.scheduled, bindings[closure.bindings.len..]) |binding, *captured| {
            captured.* = .{ .name = binding.name, .binding_id = binding.id };
        }
        return bindings;
    }

    fn importSelectionReads(self: *Analyzer, reads: *std.ArrayList(Resource), input: core.placement_inputs.Value) anyerror!void {
        for (input.selected_types) |ty| try appendUnique(self.value_storage.allocator(), reads, .{ .objects = .{ .input_type = ty } });
        for (input.fields) |field| try self.importSelectionReads(reads, field.value);
        for (input.children) |child| try self.importSelectionReads(reads, child);
    }

    fn callArgumentValue(self: *Analyzer, call: ast.CallExpr, facts: ?[]const CallArgument, index: usize) anyerror!AbstractValue {
        if (facts) |arguments| return arguments[index].values;
        return self.expressionValue(call.args.items[index]);
    }

    fn primitiveValue(self: *Analyzer, call: ast.CallExpr, primitive: registry.PrimitiveDescriptor, arg_facts: ?[]const CallArgument) anyerror!AbstractValue {
        var result = try self.withPropertyTarget(.{}, try self.propertyTargetCall(call));
        var result_type = primitive.result_type;
        switch (primitive.op) {
            .selection_empty => result = self.withAlternatives(result, (try self.callArgumentValue(call, arg_facts, 0)).path.membership().negate(), .yes),
            .logical_not => result = self.withAlternatives(result, (try self.callArgumentValue(call, arg_facts, 0)).truth.negate(), .yes),
            .pagectx => result.page_scope = if (self.variable_scope == .page) self.variable_scope else .any,
            .select => if (call.args.items.len > 0) {
                // Named queries have their own result types, including optionals.
                result_type = if (call.type_args.items.len != 0) primitive.result_type else ast.Type.any;
                const scope = try self.callArgumentValue(call, arg_facts, 0);
                if (call.type_args.items.len == 1 and call.args.items.len == 1) {
                    if (self.sema.state) |state| {
                        var candidates = AbstractValue{};
                        for (state.displays.inputs.entries.items) |entry| {
                            const wanted = call.type_args.items[0];
                            if (!ast.Type.accepts(wanted, entry.input) and !ast.Type.accepts(entry.input, wanted)) continue;
                            candidates = try self.joinValues(candidates, try self.importPlacementInput(entry.receiver, 0));
                        }
                        const possible = if (self.run_cache != null) candidates.id != 0 else state.displays.canProduce(call.type_args.items[0]);
                        result = try self.withPropertyTarget(candidates, result.property_target);
                        result = self.withPath(result, result.path.selection(if (possible) .either else .no));
                    }
                    result.page_scope = scope.page_scope;
                    result.placement = if (scope.placement.call != null) scope.placement.descendants() else .{};
                } else if (try literalStringArg(self, call, 1)) |name| {
                    if (registry.lookupQueryOp(name)) |query| {
                        result_type = query.output_type;
                        switch (query.op) {
                            .self_placement => result = self.withPath(scope, scope.path.selection(.yes)),
                            else => {},
                        }
                    }
                }
            },
            .fold => {
                if (arg_facts) |args| return self.foldValues(args, null);
                var args = try self.callArguments(call);
                defer self.deinitArguments(&args);
                return self.foldValues(args.items, null);
            },
            .first => if (call.args.items.len > 0) {
                const selection = try self.callArgumentValue(call, arg_facts, 0);
                result = self.withPath(selection, selection.path.element());
            },
            .selection_filter => {
                var summary = try self.primitiveCallbackCall(call, primitive, &result);
                summary.deinit();
                return result;
            },
            .draw_when => if (call.args.items.len > 0) {
                result = try self.callArgumentValue(call, arg_facts, 0);
            },
            .selection_union, .selection_intersection, .sub => if (call.args.items.len == 2) {
                const left = try self.callArgumentValue(call, arg_facts, 0);
                const right = try self.callArgumentValue(call, arg_facts, 1);
                const combined = if (primitive.op == .sub) left else try self.joinValues(left, right);
                result = self.withPath(combined, combined.path.selection(core.placement_inputs.ReadPath.setMembership(switch (primitive.op) {
                    .selection_union => .sum,
                    .selection_intersection => .intersection,
                    else => .difference,
                }, left.path, right.path)));
            },
            .group, .group_placed => {
                const child_count = call.args.items.len - @intFromBool(call.callee.composition != null);
                const children = try self.value_storage.allocator().alloc(AbstractValue, child_count);
                for (children, 0..) |*child, index| child.* = try self.callArgumentValue(call, arg_facts, index);
                result.children = children;
                if (self.isAdoption(call)) {
                    result = try self.withPropertyTarget(result, PropertyTarget.freshObject());
                    if (call.callee.call_id) |id| result.placement = .exact(id, &.{});
                    if (children.len != 0) result.page_scope = children[0].page_scope;
                }
            },
            .place_on => if (call.args.items.len > 1) {
                const input = try self.callArgumentValue(call, arg_facts, 1);
                if (self.sema.state != null and call.callee.call_id != null and self.sema.state.?.displays.call_targets.contains(call.callee.call_id.?)) {
                    result = try self.newValue(&.{}, &.{
                        .{ .name = "value", .value = input },
                        .{ .name = "page", .value = try self.callArgumentValue(call, arg_facts, 0) },
                    });
                    result = try self.withPropertyTarget(result, PropertyTarget.freshObject());
                    result.page_scope = (try self.callArgumentValue(call, arg_facts, 0)).page_scope;
                    result.placement = .exact(call.callee.call_id.?, &.{});
                } else result = input;
            },
            else => {},
        }
        if (result_type) |ty| {
            if (ty.kind == .selection and result.path.items == .bottom)
                result = self.withPath(result, result.path.selection(.either));
            if (ty.kind == .boolean and result.truth == .bottom) return self.withAlternatives(result, .either, .yes);
            if (result.present == .bottom) return self.withAlternatives(result, result.truth, control.presence(ty));
        }
        return result;
    }

    fn addPlacementWrites(self: *Analyzer, summary: *AccessSummary, facts: AbstractValue, page_scope: ResourceScope) anyerror!void {
        const owner = if (facts.property_target) |target| switch (target.owner) {
            .object => |object| object,
            else => ObjectOwner{},
        } else ObjectOwner{};
        try summary.addWrite(.{ .objects = .{ .owner = owner, .page_scope = page_scope } });
        if (facts.children) |children| {
            for (children) |child| try self.addPlacementWrites(summary, child, page_scope);
        } else {
            // Unknown subtrees can contribute descendants of any input type.
            try summary.addWrite(.{ .objects = .{ .page_scope = page_scope } });
        }
    }

    fn memberValue(self: *Analyzer, member: ast.MemberExpr) anyerror!AbstractValue {
        const receiver = try self.expressionValue(member.target.*);
        if (receiver.path.no_value) return receiver;
        if (member.optional and receiver.present == .no) return self.withAlternatives(.{}, .bottom, .no);
        var field = receiver.field(member.name);
        if (field.id == 0) {
            field = self.withPath(self.withAlternatives(.{}, .either, .either), .{ .unknown_target = true, .items = .either });
            if (receiver.property_target) |target| if (target.owner == .document or target.owner == .page) {
                if (self.sema.settingsField(member.name)) |descriptor| field = try self.typeValue(descriptor.value_type, 0);
            };
        }
        return self.withAlternatives(field, field.truth, control.memberPresence(receiver.present, field.present, member.optional));
    }

    fn restoreCapturedBindings(self: *Analyzer, bindings: []const CapturedBinding) !void {
        for (bindings) |binding| {
            if (binding.binding_id) |id| {
                try self.bindInput(binding.name, id, binding.binding.policy);
                continue;
            }
            try self.environment.put(binding.name, binding.binding);
        }
    }

    fn typeValue(self: *Analyzer, ty: ast.Type, depth: usize) anyerror!AbstractValue {
        if (depth >= max_value_depth) return error.FunctionAnalysisLimitExceeded;
        const cache = self.run_cache orelse return self.buildTypeValue(ty, depth, self.value_storage.allocator());
        // Include the lexical module for unresolved nominal types, and the
        // depth so a cached subtree cannot bypass the analysis depth limit.
        const key = TypeValueKey{ .module_id = self.sema.module_id, .ty = ty, .depth = depth };
        if (cache.type_values.get(key)) |value| return value;
        const allocator = cache.value_storage.allocator();
        const value = try self.buildTypeValue(ty, depth, allocator);
        try cache.type_values.put(.{ .module_id = key.module_id, .ty = try ty.clone(allocator), .depth = depth }, value);
        cache.type_body_analyses += 1;
        return value;
    }

    fn buildTypeValue(self: *Analyzer, ty: ast.Type, depth: usize, allocator: std.mem.Allocator) anyerror!AbstractValue {
        if (ty.kind == .boolean) return self.withAlternatives(.{}, .either, .yes);
        if (ty.kind == .optional) {
            const child = ty.optional_child orelse return .{};
            const payload = try self.typeValue(child.*, depth + 1);
            return self.withAlternatives(payload, payload.truth, .either);
        }
        const scalar = self.withAlternatives(.{}, .bottom, control.presence(ty));
        if (self.propertyTargetForType(ty)) |target| return self.withPropertyTarget(scalar, target);
        if (ty.kind != .record) return scalar;
        const record = self.sema.record(ty.nominal_module_id, ty.class_name orelse return .{}) orelse return .{};
        var fields = std.ArrayList(AbstractValue.Field).empty;
        for (record.decl.fields.items) |field| {
            var field_type = (try self.sema.recordFieldType(allocator, ty, field.name)) orelse continue;
            defer field_type.deinit(allocator);
            const value = try self.typeValue(field_type, depth + 1);
            if (value.id != 0) try fields.append(allocator, .{ .name = field.name, .value = value });
        }
        return self.withAlternatives(try self.newValueIn(allocator, &.{}, fields.items), .bottom, .yes);
    }

    fn bindArgument(self: *Analyzer, param: ast.ParamDecl, facts: anytype) !void {
        const Argument = @TypeOf(facts);
        const target: ?PropertyTarget = if (@hasField(Argument, "property_target")) facts.property_target else null;
        const value: AbstractValue = if (@hasField(Argument, "values")) facts.values else .{};
        try self.environment.put(param.name, .{
            .policy = .local,
            .values = if (value.id != 0) value else try self.typeValue(param.ty, 0),
            .string_literal = facts.string_literal,
            .property_target = target orelse self.propertyTargetForType(param.ty),
            .selection_reads = if (@hasField(Argument, "summary")) facts.summary.selection_reads.items else &.{},
        });
    }

    fn bindValueParams(self: *Analyzer, params: []const ast.ParamDecl, args: []const CallArgument) anyerror!AccessSummary {
        var defaults = AccessSummary.init(self.allocator);
        errdefer defaults.deinit();
        for (params, 0..) |param, i| {
            if (i < args.len) {
                try self.bindArgument(param, args[i]);
            } else if (param.default_value) |default| {
                // The definition module and only preceding parameters are visible.
                // Defaults execute even when the function body ignores the value.
                var facts = try self.analyzeArgument(default.*);
                defer facts.deinit();
                try defaults.appendSequential(facts.summary);
                try self.bindArgument(param, facts);
            } else {
                try self.bindArgument(param, CallArgument{ .summary = AccessSummary.init(self.allocator) });
            }
        }
        return defaults;
    }

    fn invokeValue(self: *Analyzer, value: AbstractValue, args: []const CallArgument) anyerror!AccessSummary {
        return self.invokeValueWithReturns(value, args, null);
    }

    fn invokeValueWithReturns(self: *Analyzer, value: AbstractValue, args: []const CallArgument, returned: ?*AbstractValue) anyerror!AccessSummary {
        if (self.effect_analysis_depth >= max_effect_analysis_depth) return error.FunctionAnalysisLimitExceeded;
        self.effect_analysis_depth += 1;
        defer self.effect_analysis_depth -= 1;
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        for (value.candidates, 0..) |candidate, index| {
            var body = switch (candidate) {
                .named => |named| try self.functionCallWithReturns(named.key, named.module_id, named.decl, args, returned),
                .closure => |closure| blk: {
                    var facts = self.environment.pushFresh();
                    defer facts.restore();
                    try self.restoreCapturedBindings(closure.bindings);
                    const previous = self.sema;
                    self.sema = self.sema.forModule(closure.module_id);
                    defer self.sema = previous;
                    var defaults = try self.bindValueParams(closure.lambda.params.items, args);
                    errdefer defaults.deinit();
                    if (returned) |output| {
                        var body = try self.analyzeArgument(closure.lambda.body.*);
                        defer body.deinit();
                        try defaults.appendSequential(body.summary);
                        output.* = try self.joinValues(output.*, body.values);
                    } else {
                        var body = try self.analyzeExpr(closure.lambda.body.*);
                        defer body.deinit();
                        try defaults.appendSequential(body);
                    }
                    break :blk defaults;
                },
            };
            defer body.deinit();
            try summary.mergeArm(body, index == 0);
        }
        return summary;
    }

    fn returnedValue(self: *Analyzer, value: AbstractValue, args: []const CallArgument) anyerror!AbstractValue {
        var result = AbstractValue{};
        for (value.candidates) |candidate| {
            var facts = self.environment.pushFresh();
            defer facts.restore();
            const previous = self.sema;
            defer self.sema = previous;
            const returned = switch (candidate) {
                .named => |named| blk: {
                    if (!control.needsValueFlow(named.decl.result_type))
                        break :blk self.withAlternatives(.{}, .bottom, control.presence(named.decl.result_type));
                    const already_visiting = self.visiting.contains(named.key);
                    if (!already_visiting) try self.visiting.put(named.key, {});
                    defer if (!already_visiting) {
                        _ = self.visiting.remove(named.key);
                    };
                    self.sema = self.sema.forModule(named.module_id);
                    var defaults = try self.bindValueParams(named.decl.params.items, args);
                    defer defaults.deinit();
                    var returned = AbstractValue{};
                    _ = try self.scanReturns(.value, named.decl.statements.items, &returned);
                    break :blk returned;
                },
                .closure => |closure| blk: {
                    self.sema = self.sema.forModule(closure.module_id);
                    try self.restoreCapturedBindings(closure.bindings);
                    var defaults = try self.bindValueParams(closure.lambda.params.items, args);
                    defer defaults.deinit();
                    break :blk try self.expressionValue(closure.lambda.body.*);
                },
            };
            result = try self.joinValues(result, returned);
        }
        return result;
    }

    fn analyzeCall(self: *Analyzer, call: ast.CallExpr) anyerror!AccessSummary {
        return self.analyzeCallWithReturns(call, null);
    }

    fn analyzeCallWithReturns(self: *Analyzer, call: ast.CallExpr, returned: ?*AbstractValue) anyerror!AccessSummary {
        if (call.callee.name_hole != null) return try self.callArgs(call);
        return switch (try self.valueBinding(call.callee)) {
            .local, .constant => blk: {
                var args = try self.callArguments(call);
                defer self.deinitArguments(&args);
                var summary = AccessSummary.init(self.allocator);
                errdefer summary.deinit();
                switch (try self.valueBinding(call.callee)) {
                    .constant => |resolved| {
                        var initialization = try self.constantSummary(resolved);
                        defer initialization.deinit();
                        try summary.merge(initialization);
                    },
                    else => try self.addVariableRead(&summary, call.callee.name),
                }
                for (args.items) |arg| try summary.appendSequential(arg.summary);
                const value = try self.callableValue(call.callee);
                var invoked = try self.invokeValueWithReturns(value, args.items, returned);
                defer invoked.deinit();
                try summary.appendSequential(invoked);
                break :blk summary;
            },
            .function => |resolved| blk: {
                var arg_facts = try self.callArguments(call);
                defer self.deinitArguments(&arg_facts);
                var summary = try self.argumentSummary(arg_facts.items);
                errdefer summary.deinit();
                var invoked = try self.functionCallWithReturns(resolved.key, resolved.module_id, resolved.decl, arg_facts.items, returned);
                defer invoked.deinit();
                try summary.appendSequential(invoked);
                break :blk summary;
            },
            .primitive => |primitive| try self.primitiveCall(call, primitive, returned),
            .unknown => try self.callArgs(call),
        };
    }

    fn callArgs(self: *Analyzer, call: ast.CallExpr) anyerror!AccessSummary {
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        for (call.args.items) |arg| {
            var nested = try self.analyzeExpr(arg);
            defer nested.deinit();
            try summary.merge(nested);
        }
        return summary;
    }

    const CallArgument = struct {
        summary: AccessSummary,
        values: AbstractValue = .{},
        string_literal: ?[]const u8 = null,
        property_target: ?PropertyTarget = null,

        fn deinit(self: *CallArgument) void {
            self.summary.deinit();
        }
    };

    const StringArgument = struct {
        values: AbstractValue = .{},
        string_literal: ?[]const u8 = null,
    };

    const StaticArgument = struct {
        values: AbstractValue = .{},
        string_literal: ?[]const u8 = null,
        property_target: ?PropertyTarget = null,
    };

    fn analyzeArgument(self: *Analyzer, arg: ast.Expr) anyerror!CallArgument {
        if (self.sema.state) |state| try state.checkAnalysisCanceled();
        var facts = CallArgument{ .summary = AccessSummary.init(self.allocator) };
        errdefer facts.deinit();
        switch (arg) {
            .call => |call| facts.summary = try self.analyzeCallWithReturns(call, &facts.values),
            .apply => |apply| {
                var callee = try self.analyzeArgument(apply.callee.*);
                defer callee.deinit();
                try facts.summary.merge(callee.summary);
                var args = try self.analyzeArguments(apply.args.items);
                defer self.deinitArguments(&args);
                for (args.items) |argument| try facts.summary.appendSequential(argument.summary);
                var invoked = try self.invokeValueWithReturns(callee.values, args.items, &facts.values);
                defer invoked.deinit();
                try facts.summary.appendSequential(invoked);
            },
            .record => |record| {
                var fields = std.ArrayList(AbstractValue.Field).empty;
                const allocator = self.value_storage.allocator();
                if (self.sema.recordConstruction(record)) |decl| {
                    for (decl.decl.fields.items) |field| {
                        if (record.hasField(field.name)) continue;
                        const default = field.default_value orelse continue;
                        var snapshot = self.environment.pushFresh();
                        defer snapshot.restore();
                        const previous = self.sema;
                        self.sema = self.sema.forModule(decl.module_id);
                        defer self.sema = previous;
                        var nested = try self.analyzeArgument(default.*);
                        defer nested.deinit();
                        try facts.summary.appendSequential(nested.summary);
                        if (nested.values.id != 0) try fields.append(allocator, .{ .name = field.name, .value = nested.values });
                    }
                }
                for (record.fields.items) |field| {
                    var nested = try self.analyzeArgument(field.value);
                    defer nested.deinit();
                    try facts.summary.appendSequential(nested.summary);
                    if (nested.values.id != 0) try fields.append(allocator, .{ .name = field.name, .value = nested.values });
                }
                facts.values = self.withAlternatives(try self.newValue(&.{}, fields.items), .bottom, .yes);
            },
            .record_update => |update| {
                var original = try self.analyzeArgument(update.target.*);
                defer original.deinit();
                try facts.summary.merge(original.summary);
                facts.values = original.values;
                for (update.fields.items) |field| {
                    var nested = try self.analyzeArgument(field.value);
                    defer nested.deinit();
                    try facts.summary.appendSequential(nested.summary);
                    facts.values = try self.updateValueField(facts.values, field.path.items, nested.values);
                }
            },
            .coalesce => |coalesce| {
                var target = try self.analyzeArgument(coalesce.target.*);
                defer target.deinit();
                try facts.summary.merge(target.summary);
                const route = control.coalesce(target.values.present.orUnknown());
                if (route == .left) {
                    facts.values = target.values;
                } else {
                    var fallback = try self.analyzeArgument(coalesce.fallback.*);
                    defer fallback.deinit();
                    try self.guardFallback(coalesce.target.*, &fallback.summary);
                    if (route == .both) fallback.summary.defined_settings.clear();
                    try facts.summary.appendSequential(fallback.summary);
                    facts.values = if (route == .right) fallback.values else try self.joinValues(self.withAlternatives(target.values, target.values.truth, .yes), fallback.values);
                }
            },
            else => {
                facts.summary = try self.analyzeExpr(arg);
                facts.values = try self.expressionValue(arg);
            },
        }
        facts.string_literal = try literalStringExpr(self, arg);
        facts.property_target = try self.propertyTargetExpr(arg);
        return facts;
    }

    fn stringArgument(self: *Analyzer, arg: ast.Expr) anyerror!StringArgument {
        return .{ .values = self.conditionValue(arg), .string_literal = try literalStringExpr(self, arg) };
    }

    // Return-fact queries need only the control discriminant, not a second
    // recursive analysis of every argument of a value-producing call.
    fn conditionValue(self: *Analyzer, arg: ast.Expr) AbstractValue {
        return switch (arg) {
            .boolean => |flag| self.withAlternatives(.{}, .from(flag), .yes),
            .ident => |ident| (self.environment.get(ident.name) orelse Binding{}).values,
            else => .{},
        };
    }

    fn staticArgument(self: *Analyzer, arg: ast.Expr) anyerror!StaticArgument {
        return .{
            .values = self.conditionValue(arg),
            .string_literal = try literalStringExpr(self, arg),
            .property_target = try self.propertyTargetExpr(arg),
        };
    }

    fn callArguments(self: *Analyzer, call: ast.CallExpr) anyerror!std.ArrayList(CallArgument) {
        return self.analyzeArguments(call.args.items);
    }

    fn analyzeArguments(self: *Analyzer, args: []const ast.Expr) anyerror!std.ArrayList(CallArgument) {
        var facts = std.ArrayList(CallArgument).empty;
        errdefer self.deinitArguments(&facts);
        try facts.ensureTotalCapacity(self.allocator, args.len);
        for (args) |arg| {
            facts.appendAssumeCapacity(try self.analyzeArgument(arg));
        }
        return facts;
    }

    fn stringArguments(self: *Analyzer, call: ast.CallExpr) anyerror!std.ArrayList(StringArgument) {
        var facts = std.ArrayList(StringArgument).empty;
        errdefer facts.deinit(self.allocator);
        for (call.args.items) |arg| try facts.append(self.allocator, try self.stringArgument(arg));
        return facts;
    }

    fn staticArguments(self: *Analyzer, call: ast.CallExpr) anyerror!std.ArrayList(StaticArgument) {
        var facts = std.ArrayList(StaticArgument).empty;
        errdefer facts.deinit(self.allocator);
        for (call.args.items) |arg| try facts.append(self.allocator, try self.staticArgument(arg));
        return facts;
    }

    fn deinitArguments(self: *Analyzer, facts: *std.ArrayList(CallArgument)) void {
        for (facts.items) |*fact| fact.deinit();
        facts.deinit(self.allocator);
    }

    fn argumentSummary(self: *Analyzer, facts: []const CallArgument) !AccessSummary {
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        for (facts) |fact| try summary.appendSequential(fact.summary);
        return summary;
    }

    fn functionCallWithReturns(
        self: *Analyzer,
        key: core.FunctionKey,
        module_id: core.SourceModuleId,
        func: ast.FunctionDecl,
        arg_facts: []const CallArgument,
        returned: ?*AbstractValue,
    ) anyerror!AccessSummary {
        const needs_returns = returned != null and control.needsValueFlow(func.result_type);
        if (returned) |result| if (!needs_returns) {
            result.* = try self.joinValues(result.*, self.withAlternatives(.{}, .bottom, control.presence(func.result_type)));
        };
        if (self.effect_analysis_depth >= max_effect_analysis_depth) return error.FunctionAnalysisLimitExceeded;
        self.effect_analysis_depth += 1;
        defer self.effect_analysis_depth -= 1;

        const cache_key = if (self.run_cache != null)
            try buildFunctionCallSummaryKey(self.allocator, key, arg_facts, self.variable_scope)
        else
            null;
        defer if (cache_key) |owned| self.allocator.free(owned);
        const shared_key = if (self.run_cache != null)
            try buildFunctionCallSummaryKey(self.allocator, key, arg_facts, .any)
        else
            null;
        defer if (shared_key) |owned| self.allocator.free(owned);
        for ([_]?[]const u8{ shared_key, cache_key }) |maybe_key| if (maybe_key) |owned| {
            if (try self.run_cache.?.cachedSummary(owned, self.allocator)) |cached| {
                var body = cached;
                errdefer body.deinit();
                if (needs_returns) {
                    const callable = try self.newValue(&.{.{ .named = .{ .key = key, .module_id = module_id, .decl = func } }}, &.{});
                    returned.?.* = try self.joinValues(returned.?.*, try self.returnedValue(callable, arg_facts));
                }
                return body;
            }
        };

        // Re-entering a higher-order function with a different callback can be
        // finite. The termination pass validates calls before scheduling.
        const already_visiting = self.visiting.contains(key);
        if (!already_visiting) try self.visiting.put(key, {});
        defer if (!already_visiting) {
            _ = self.visiting.remove(key);
        };

        var state = self.environment.pushFresh();
        defer state.restore();

        const previous = self.sema;
        self.sema = self.sema.forModule(module_id);
        defer self.sema = previous;
        var body = try self.bindValueParams(func.params.items, arg_facts);
        errdefer body.deinit();
        var result = ReturnedValues{};
        var statements = try self.analyzeStatementsWithReturns(func.statements.items, .local, if (needs_returns) &result else null, body.defined_settings, null);
        defer statements.deinit();
        try body.appendSequential(statements);
        if (returned) |output| output.* = try self.joinValues(output.*, result.values);
        // Pure value helpers and page-independent effects can be shared across
        // pages; only concrete membership scopes require the caller-page key.
        if (cache_key) |owned| try self.run_cache.?.putSummary(if (body.hasConcreteScope()) owned else shared_key.?, body);
        return body;
    }

    fn constantSummary(self: *Analyzer, resolved: semantic_env.ResolvedConst) anyerror!AccessSummary {
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        if (self.visiting.contains(resolved.key)) {
            self.recursive_fallbacks += 1;
            return summary;
        }

        const cache_key = if (self.run_cache != null)
            try buildConstSummaryKey(self.allocator, resolved.key)
        else
            null;
        defer if (cache_key) |owned| self.allocator.free(owned);
        if (cache_key) |owned| {
            if (try self.run_cache.?.cachedSummary(owned, self.allocator)) |cached| return cached;
        }

        try self.visiting.put(resolved.key, {});
        defer _ = self.visiting.remove(resolved.key);

        var state = self.environment.pushFresh();
        defer state.restore();

        const previous = self.sema;
        self.sema = self.sema.forModule(resolved.module_id);
        defer self.sema = previous;

        const caller = self.variable_scope;
        self.variable_scope = .{ .document = resolved.module_id };
        defer self.variable_scope = caller;
        var nested = try self.analyzeExpr(resolved.decl.value);
        defer nested.deinit();
        try summary.merge(nested);
        summary.defined_settings.clear();
        if (cache_key) |owned| try self.run_cache.?.putSummary(owned, summary);
        return summary;
    }

    const PropertyMemberRead = struct {
        base: ast.Expr,
        target: PropertyTarget,
        key: []const u8,
    };

    fn propertyMemberRead(self: *Analyzer, member: ast.MemberExpr) !?PropertyMemberRead {
        var current = member;
        var path = std.ArrayList([]const u8).empty;
        defer path.deinit(self.allocator);
        while (true) {
            try path.append(self.allocator, current.name);
            const receiver = current.target.*;
            if (try self.propertyTargetExpr(receiver)) |target| {
                std.mem.reverse([]const u8, path.items);
                return .{
                    .base = receiver,
                    .target = target,
                    .key = try ownString(self, try std.mem.join(self.allocator, ".", path.items)),
                };
            }
            if (receiver != .member) return null;
            current = receiver.member;
        }
    }

    fn bindLocalParams(self: *Analyzer, params: []const ast.ParamDecl) !void {
        for (params) |param| {
            var binding = self.environment.get(param.name) orelse Binding{ .values = try self.typeValue(param.ty, 0) };
            binding.policy = .local;
            if (binding.property_target == null) binding.property_target = self.propertyTargetForType(param.ty);
            try self.environment.put(param.name, binding);
        }
    }

    fn bindStaticParams(self: *Analyzer, comptime Argument: type, params: []const ast.ParamDecl, args: []const Argument) anyerror!void {
        for (params, 0..) |param, index| {
            const facts = if (index < args.len)
                args[index]
            else if (param.default_value) |default|
                if (Argument == StaticArgument)
                    try self.staticArgument(default.*)
                else
                    try self.stringArgument(default.*)
            else
                Argument{};
            try self.bindArgument(param, facts);
        }
    }

    fn addBoundSelectionReads(self: *Analyzer, summary: *AccessSummary, name: []const u8) !void {
        const binding = self.environment.get(name) orelse return;
        for (binding.selection_reads) |resource| try summary.addSelectionRead(resource);
    }

    // Each selection callback receives an item, any other supplied parameters
    // (e.g. the enumeration index), and the caller's extra arguments. The
    // returned slice borrows summaries from args and must only free the slice.
    fn selectionCallbackArgs(
        self: *Analyzer,
        spec: registry.PrimitiveCallbackSpec,
        args: []const CallArgument,
    ) ![]CallArgument {
        const extras = args[spec.function_arg_index + 1 ..];
        const params = try self.allocator.alloc(CallArgument, spec.supplied_arg_count + extras.len);
        @memset(params[0..spec.supplied_arg_count], .{ .summary = AccessSummary.init(self.allocator) });
        params[0] = args[0];
        params[0].values = self.withPath(args[0].values, args[0].values.path.element());
        params[0].string_literal = null;
        params[0].property_target = args[0].property_target orelse PropertyTarget.any();
        @memcpy(params[spec.supplied_arg_count..], extras);
        return params;
    }

    fn addAnchorReads(self: *Analyzer, summary: *AccessSummary, anchor: ast.AnchorRef) !void {
        if (anchor.kind == .page) return;
        const path = anchor.node_path orelse anchor.node_name orelse return;
        var parts = std.mem.splitScalar(u8, path, '.');
        try self.addVariableRead(summary, parts.first());
    }

    fn primitiveCall(
        self: *Analyzer,
        call: ast.CallExpr,
        descriptor: registry.PrimitiveDescriptor,
        returned: ?*AbstractValue,
    ) anyerror!AccessSummary {
        if (descriptor.op == .draw_when) return self.drawingCall(call, returned);
        if (descriptor.callback != null) return try self.primitiveCallbackCall(call, descriptor, returned);
        if (primitiveNeedsArguments(descriptor.op)) {
            var arg_facts = try self.callArguments(call);
            defer self.deinitArguments(&arg_facts);
            if (returned) |output| output.* = try self.primitiveValue(call, descriptor, arg_facts.items);
            if (descriptor.op == .group or descriptor.op == .group_placed) {
                var summary = try self.argumentSummary(arg_facts.items);
                errdefer summary.deinit();
                if (self.isAdoption(call)) {
                    const ty = self.sema.state.?.displays.adoptions.get(call.callee.call_id.?).?;
                    try summary.addWrite(.{ .objects = .{ .input_type = ty, .placement = .exact(call.callee.call_id.?, &.{}), .page_scope = self.variable_scope } });
                    summary.places_objects = true;
                    summary.writes_layout_input = true;
                }
                return summary;
            }
            if (descriptor.op == .place_on) {
                if (self.sema.state) |state| if (call.callee.call_id) |id| {
                    if (state.displays.call_targets.get(id)) |plan| return self.typedPlacementCall(id, state.displays.plans.items[plan], arg_facts.items);
                };
            }
            if (descriptor.op == .select and call.type_args.items.len == 1) {
                var summary = try self.argumentSummary(arg_facts.items);
                errdefer summary.deinit();
                const scope = arg_facts.items[0].values;
                try self.addScopedPlacementRead(&summary, scope, call.type_args.items[0], false);
                return summary;
            }
            return try self.primitiveCallWithArguments(descriptor, arg_facts.items);
        }

        if (returned) |output| output.* = try self.primitiveValue(call, descriptor, null);
        var summary = try self.callArgs(call);
        errdefer summary.deinit();
        if (descriptor.places_objects) summary.places_objects = true;
        switch (descriptor.op) {
            .pagectx => summary.depends_on_caller_scope = true,
            .define_theme => {
                summary.depends_on_caller_scope = true;
                const owner: PropertyOwner = switch (self.variable_scope) {
                    .document => .document,
                    .page => |n| .{ .page = n },
                    .any => .any,
                };
                try summary.addWrite(Resource.makeProperty(owner, "theme"));
                try summary.defined_settings.define(self.allocator, owner, "theme", true);
                summary.writes_layout_input = true;
            },
            .page_index, .page_count => try summary.addRead(Resource.makePages(null)),
            .new_page => {
                try summary.addWrite(Resource.makePages(null));
                summary.writes_layout_input = true;
            },
            .constrain_on => {
                summary.writes_layout_input = true;
            },
            else => {},
        }
        return summary;
    }

    fn drawingCall(self: *Analyzer, call: ast.CallExpr, returned: ?*AbstractValue) anyerror!AccessSummary {
        var operand = try self.analyzeArgument(call.args.items[0]);
        defer operand.deinit();
        var predicate = try self.analyzeArgument(call.args.items[1]);
        defer predicate.deinit();
        var condition = try self.invokeValue(predicate.values, &.{});
        defer condition.deinit();
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        try summary.merge(operand.summary);
        try summary.merge(predicate.summary);
        summary.places_objects = true;
        const origin: core.SourceOrigin = if (self.sema.state) |state| state.sourceOrigin(self.sema.module_id, call.callee.span orelse .{ .start = 0, .end = 0 }) else .{};
        if (condition.places_objects or condition.writes_layout_input or condition.writes.items.len != 0 or condition.drawings.items.len != 0) {
            summary.invalid_drawing_condition = origin;
        }
        if (call.callee.call_id) |id| try summary.addDrawing(id, origin, condition);
        if (returned) |output| output.* = operand.values;
        return summary;
    }

    fn isAdoption(self: *Analyzer, call: ast.CallExpr) bool {
        const state = self.sema.state orelse return false;
        const id = call.callee.call_id orelse return false;
        return state.displays.adoptions.contains(id);
    }

    /// Adoption registers the direct members with its result binding. Reads of
    /// their displays still depend on each original registration/display tree.
    fn addScopedPlacementRead(self: *Analyzer, summary: *AccessSummary, scope: AbstractValue, input: ?ast.Type, inclusive: bool) anyerror!void {
        var visiting = std.AutoHashMap(u64, void).init(self.allocator);
        defer visiting.deinit();
        try self.addScopedPlacementReadImpl(summary, scope, input, inclusive, &visiting);
    }

    fn addScopedPlacementReadImpl(self: *Analyzer, summary: *AccessSummary, scope: AbstractValue, input: ?ast.Type, inclusive: bool, visiting: *std.AutoHashMap(u64, void)) anyerror!void {
        if (scope.children) |children| {
            for (children) |child| try self.addScopedPlacementReadImpl(summary, child, input, true, visiting);
            return;
        }
        var region = if (scope.placement.call != null) scope.placement else resource_model.PlacementScope{};
        if (self.sema.state) |state| if (region.call) |id| if (state.displays.adoptions.contains(id)) {
            // Selected groups retain registration references, not recursively
            // embedded trees. Follow those references with a cycle guard.
            if (!visiting.contains(id)) {
                try visiting.put(id, {});
                defer _ = visiting.remove(id);
                for (state.displays.inputs.entries.items) |entry| {
                    const reference = entry.receiver.reference orelse continue;
                    if (reference != .placement or reference.placement.call != id) continue;
                    const registered = try self.importPlacementInput(entry.receiver, 0);
                    if (registered.children != null) {
                        try self.addScopedPlacementReadImpl(summary, registered, input, inclusive, visiting);
                        return;
                    }
                }
            }
            // Unknown or cyclic origins must conservatively include possible
            // original producers rather than a nonexistent new display tree.
            region = .{};
        };
        if (inclusive) region.depth.max = null else if (region.call != null) region = region.descendants();
        try summary.addSelectionRead(.{ .objects = .{ .input_type = input, .page_scope = scope.page_scope, .placement = region } });
    }

    fn typedPlacementCall(self: *Analyzer, call_id: u64, plan: core.native_display.Plan, args: []const CallArgument) anyerror!AccessSummary {
        var summary = try self.argumentSummary(args);
        errdefer summary.deinit();
        const page_scope = args[0].values.page_scope;
        try summary.addWrite(.{ .objects = .{ .input_type = plan.steps.items[0].input, .page_scope = page_scope, .placement = .exact(call_id, &.{}) } });
        summary.places_objects = true;
        summary.writes_layout_input = true;
        var steps = std.ArrayList(AccessSummary).empty;
        defer {
            for (steps.items) |*step| step.deinit();
            steps.deinit(self.allocator);
        }
        try steps.ensureTotalCapacity(self.allocator, plan.steps.items.len);
        const inputs = try self.allocator.alloc(AbstractValue, plan.steps.items.len);
        defer self.allocator.free(inputs);
        inputs[0] = args[1].values;
        for (plan.steps.items, 0..) |step, index| {
            switch (step.target) {
                .group => {
                    steps.appendAssumeCapacity(AccessSummary.init(self.allocator));
                    for (step.children.items, 0..) |child_index, position| {
                        inputs[child_index] = if (inputs[index].children) |children| if (position < children.len) children[position] else .{} else .{};
                    }
                },
                .native, .function => {
                    const key = if (step.target == .function) step.target.function else step.target.native.resolve orelse {
                        steps.appendAssumeCapacity(AccessSummary.init(self.allocator));
                        continue;
                    };
                    const state = self.sema.state.?;
                    const function = try self.newValue(&.{.{ .named = .{ .key = key, .module_id = key.module_id, .decl = state.functions.get(key).? } }}, &.{});
                    var receiver = try self.newValue(&.{}, &.{
                        .{ .name = "value", .value = inputs[index] },
                        .{ .name = "page", .value = args[0].values },
                        .{ .name = "document", .value = try self.withPropertyTarget(.{}, PropertyTarget.document()) },
                    });
                    receiver.page_scope = page_scope;
                    receiver.placement = .exact(call_id, step.path);
                    var argument = CallArgument{ .summary = AccessSummary.init(self.allocator), .values = receiver };
                    defer argument.deinit();
                    const caller = self.variable_scope;
                    self.variable_scope = page_scope;
                    defer self.variable_scope = caller;
                    var output = AbstractValue{};
                    steps.appendAssumeCapacity(try self.invokeValueWithReturns(function, &.{argument}, &output));
                    if (step.target == .native) continue;
                    std.debug.assert(step.children.items.len == 1);
                    inputs[step.children.items[0]] = output;
                },
            }
        }
        try summary.addPlacement(.{ .call_id = call_id, .steps = steps, .page_scope = page_scope });
        return summary;
    }

    fn primitiveCallWithArguments(
        self: *Analyzer,
        descriptor: registry.PrimitiveDescriptor,
        arg_facts: []const CallArgument,
    ) anyerror!AccessSummary {
        var summary = try self.argumentSummary(arg_facts);
        errdefer summary.deinit();
        if (descriptor.places_objects) summary.places_objects = true;
        switch (descriptor.op) {
            .select => try self.applySelectSummary(&summary, arg_facts),
            .page_index, .page_count => try summary.addRead(Resource.makePages(null)),
            .new_page => {
                try summary.addWrite(Resource.makePages(null));
                summary.writes_layout_input = true;
            },
            .place_on => {
                if (arg_facts.len > 1) try self.addEscapedObjects(&summary, arg_facts[1].values);
                if (arg_facts.len > 1) try self.addPlacementWrites(&summary, arg_facts[1].values, arg_facts[0].values.page_scope);
                summary.writes_layout_input = true;
            },
            .constrain_on => {
                summary.writes_layout_input = true;
            },
            .report_error,
            .report_warning,
            .readlines,
            => {},
            else => {},
        }
        return summary;
    }

    fn primitiveNeedsArguments(op: registry.PrimitiveCall) bool {
        return switch (op) {
            .select,
            .group,
            .group_placed,
            .place_on,
            => true,
            else => false,
        };
    }

    fn foldValues(self: *Analyzer, supplied: []const CallArgument, summary: ?*AccessSummary) anyerror!AbstractValue {
        if (supplied.len < 3) return .{};
        if (supplied[0].values.path.items == .no) return supplied[1].values;
        const callback = supplied[2].values;
        // Callback arguments borrow the already evaluated inputs. Only the
        // accumulator's selection reads change during iteration.
        const args = try self.allocator.alloc(CallArgument, supplied.len - 1);
        defer self.allocator.free(args);
        args[0] = supplied[1];
        args[0].summary = AccessSummary.init(self.allocator);
        defer args[0].summary.deinit();
        for (supplied[1].summary.selection_reads.items) |read| try args[0].summary.addSelectionRead(read);
        args[1] = supplied[0];
        args[1].values = self.withPath(args[1].values, args[1].values.path.element());
        @memcpy(args[2..], supplied[3..]);
        for (0..max_value_depth) |_| {
            var returned = AbstractValue{};
            var invoked = try self.invokeValueWithReturns(callback, args, &returned);
            defer invoked.deinit();
            if (summary) |effects| try effects.mergeEffects(invoked);
            const previous_reads = args[0].summary.selection_reads.items.len;
            for (invoked.selection_reads.items) |resource| try args[0].summary.addSelectionRead(resource);
            const combined = try self.joinValues(args[0].values, returned);
            if (combined.eql(args[0].values, 0) and previous_reads == args[0].summary.selection_reads.items.len) return combined;
            args[0].values = combined;
            args[0].property_target = combined.property_target;
            args[0].string_literal = null;
        }
        return error.FunctionAnalysisLimitExceeded;
    }

    fn primitiveCallbackCall(self: *Analyzer, call: ast.CallExpr, descriptor: registry.PrimitiveDescriptor, returned: ?*AbstractValue) anyerror!AccessSummary {
        const callback_spec = descriptor.callback orelse unreachable;
        var arg_facts = try self.callArguments(call);
        defer self.deinitArguments(&arg_facts);

        var summary = try self.argumentSummary(arg_facts.items);
        errdefer summary.deinit();

        var callback_summary = AccessSummary.init(self.allocator);
        defer callback_summary.deinit();
        var predicate = AbstractValue{};
        if (descriptor.op == .fold) {
            const values = try self.foldValues(arg_facts.items, &callback_summary);
            if (returned) |output| output.* = values;
        } else if (call.args.items.len > callback_spec.function_arg_index and arg_facts.items[0].values.path.items != .no) {
            const params = try self.selectionCallbackArgs(callback_spec, arg_facts.items);
            defer self.allocator.free(params);
            callback_summary = try self.invokeValueWithReturns(arg_facts.items[callback_spec.function_arg_index].values, params, if (descriptor.op == .selection_filter) &predicate else null);
        }

        if (descriptor.op != .fold) {
            if (returned) |output| output.* = if (descriptor.op == .selection_filter and call.args.items.len > 0)
                self.withPath(arg_facts.items[0].values, arg_facts.items[0].values.path.filtered(predicate.truth))
            else
                try self.primitiveValue(call, descriptor, arg_facts.items);
        }

        for (summary.selection_reads.items) |selection_resource| {
            for (callback_summary.writes.items) |write_resource| {
                if (selection_resource.intersects(write_resource)) {
                    summary.invalid_selection_mutation = .{
                        .resource = selection_resource,
                        .origin = .{ .start = 0, .end = 0 },
                    };
                    break;
                }
            }
            if (summary.invalid_selection_mutation != null) break;
        }
        // A selection may be empty, or it may invoke the callback repeatedly.
        // Reads in one invocation can precede writes in a later invocation.
        for (callback_summary.writes.items) |write| try callback_summary.checkLaterWrite(write, callback_summary.reads.items);
        callback_summary.defined_settings.clear();
        try summary.appendSequential(callback_summary);
        return summary;
    }

    fn applySelectSummary(_: *Analyzer, summary: *AccessSummary, arg_facts: []const CallArgument) !void {
        const query_name = argumentString(arg_facts, 1) orelse {
            try summary.addRead(Resource.makeObjects());
            try summary.addSelectionRead(Resource.makeObjects());
            return;
        };
        const query = registry.lookupQueryOp(query_name) orelse {
            try summary.addRead(Resource.makeObjects());
            return;
        };
        switch (query.op) {
            .document_pages => try summary.addSelectionRead(Resource.makePages(null)),
            // A singleton snapshots the supplied identity, not a collection.
            // Its argument dependencies have already been collected.
            .self_placement => {},
            .previous_page => try summary.addRead(Resource.makePages(null)),
        }
    }

    fn argumentString(arg_facts: []const CallArgument, index: usize) ?[]const u8 {
        if (index >= arg_facts.len) return null;
        return arg_facts[index].string_literal;
    }

    fn propertyTargetExpr(self: *Analyzer, expr: ast.Expr) anyerror!?PropertyTarget {
        return switch (expr) {
            .ident => |ident| blk: {
                const name = ident.name;
                if ((self.environment.get(name) orelse Binding{}).property_target) |target| break :blk target;
                switch (try self.valueBinding(ast.CallableName.fromText(name))) {
                    .constant => |resolved| break :blk try self.propertyTargetConst(resolved),
                    else => {},
                }
                break :blk null;
            },
            .call => |call| try self.propertyTargetCall(call),
            .member, .apply, .dereference => (try self.expressionValue(expr)).property_target,
            .coalesce => |coalesce| blk: {
                const target = try self.propertyTargetExpr(coalesce.target.*);
                const fallback = try self.propertyTargetExpr(coalesce.fallback.*);
                break :blk joinPropertyTargets(target, fallback);
            },
            else => null,
        };
    }

    fn propertyTargetCall(self: *Analyzer, call: ast.CallExpr) anyerror!?PropertyTarget {
        const descriptor = (try self.callCallee(call.callee)) orelse return null;
        return switch (descriptor) {
            .primitive => |primitive| switch (primitive.op) {
                .docctx => PropertyTarget.document(),
                .pagectx => PropertyTarget.page(if (self.variable_scope == .page) self.variable_scope.page else null),
                .new_page => PropertyTarget.page(null),
                .group, .group_placed => if (self.isAdoption(call)) PropertyTarget.freshObject() else null,
                .place_on => PropertyTarget.freshObject(),
                .foreach, .selection_filter, .foreach_enumerate, .draw_when => if (call.args.items.len > 0)
                    try self.propertyTargetExpr(call.args.items[0])
                else
                    PropertyTarget.any(),
                .first => if (call.args.items.len > 0)
                    (try self.propertyTargetExpr(call.args.items[0])) orelse PropertyTarget.any()
                else
                    PropertyTarget.any(),
                .selection_union, .selection_intersection, .sub => try self.propertyTargetSelectionAlgebra(call, primitive.op),
                .select => try self.propertyTargetSelect(call),
                else => if (primitive.result_type) |ty| self.propertyTargetForType(ty) else null,
            },
            .function => |resolved| try self.propertyTargetFunctionCall(resolved, call),
        };
    }

    fn propertyTargetSelectionAlgebra(self: *Analyzer, call: ast.CallExpr, op: registry.PrimitiveCall) !?PropertyTarget {
        if (call.args.items.len < 2) return PropertyTarget.any();
        const left = try self.propertyTargetExpr(call.args.items[0]);
        const right = try self.propertyTargetExpr(call.args.items[1]);
        return switch (op) {
            .selection_union => joinPropertyTargets(left, right),
            .sub => left,
            .selection_intersection => if (left) |target|
                if (!target.owner.isUnknown()) target else right
            else
                right,
            else => unreachable,
        };
    }

    fn propertyTargetSelect(self: *Analyzer, call: ast.CallExpr) !?PropertyTarget {
        if (call.type_args.items.len != 0) return PropertyTarget.object();
        const query_name = (try literalStringArg(self, call, 1)) orelse return PropertyTarget.any();
        const query = registry.lookupQueryOp(query_name) orelse return PropertyTarget.any();
        return switch (query.op) {
            .document_pages, .previous_page => PropertyTarget.page(null),
            .self_placement => if (call.args.items.len > 0)
                (try self.propertyTargetExpr(call.args.items[0])) orelse PropertyTarget.any()
            else
                PropertyTarget.any(),
        };
    }

    fn propertyTargetConst(self: *Analyzer, resolved: semantic_env.ResolvedConst) anyerror!?PropertyTarget {
        if (self.visiting.contains(resolved.key)) {
            self.recursive_fallbacks += 1;
            return null;
        }
        try self.visiting.put(resolved.key, {});
        defer _ = self.visiting.remove(resolved.key);

        var state = self.environment.pushFresh();
        defer state.restore();

        const previous = self.sema;
        self.sema = self.sema.forModule(resolved.module_id);
        defer self.sema = previous;

        const caller = self.variable_scope;
        self.variable_scope = .{ .document = resolved.module_id };
        defer self.variable_scope = caller;
        var target = (try self.propertyTargetExpr(resolved.decl.value)) orelse return null;
        if (target.owner == .object and target.fresh) {
            target.owner.object.identity = .{
                .origin = .constant,
                .scope = .{ .document = resolved.module_id },
                .name = resolved.decl.name,
            };
            target.fresh = false;
        }
        return target;
    }

    const ReturnPropertyKind = enum { string_literal, property_target };

    fn PropertyValue(comptime kind: ReturnPropertyKind) type {
        return if (kind == .property_target) PropertyTarget else []const u8;
    }

    // The outer optional means no return was reached; value = null means unknown.
    fn ReturnedProperty(comptime kind: ReturnPropertyKind) type {
        return struct { value: ?PropertyValue(kind) };
    }

    fn returnProperty(self: *Analyzer, comptime kind: ReturnPropertyKind, expr: ast.Expr) anyerror!?PropertyValue(kind) {
        if (self.sema.state) |state| try state.checkAnalysisCanceled();
        return switch (kind) {
            .string_literal => try literalStringExpr(self, expr),
            .property_target => try self.propertyTargetExpr(expr),
        };
    }

    const ReturnQuery = enum { value, string_literal, property_target };

    fn Result(comptime query: ReturnQuery) type {
        return switch (query) {
            .value => AbstractValue,
            .string_literal => ?ReturnedProperty(.string_literal),
            .property_target => ?ReturnedProperty(.property_target),
        };
    }

    fn scanReturns(self: *Analyzer, comptime query: ReturnQuery, body: []const ast.Statement, result: *Result(query)) anyerror!control.Exits {
        var pass = ReturnFlow(query){ .analyzer = self, .result = result };
        return control.block(&pass, body);
    }

    fn ReturnFlow(comptime query: ReturnQuery) type {
        return struct {
            analyzer: *Analyzer,
            result: *Result(query),

            pub fn visit(pass: *@This(), stmt: ast.Statement, _: bool) anyerror!control.Exits {
                return control.statement(pass, stmt);
            }

            pub fn condition(pass: *@This(), expr: ast.Expr) !Alternatives {
                const truth = (try pass.analyzer.expressionValue(expr)).truth;
                return truth.orUnknown();
            }

            pub fn arm(pass: *@This(), body: []const ast.Statement, _: usize) anyerror!control.Exits {
                var snapshot = try pass.analyzer.environment.pushClone();
                defer snapshot.restore();
                return control.block(pass, body);
            }

            pub fn onReturn(pass: *@This(), expr: ?ast.Expr) !void {
                const self = pass.analyzer;
                if (query == .value) {
                    if (expr) |value| pass.result.* = try self.joinValues(pass.result.*, try self.expressionValue(value));
                } else {
                    const kind: ReturnPropertyKind = if (query == .property_target) .property_target else .string_literal;
                    const found = if (expr) |value| try self.returnProperty(kind, value) else null;
                    const joined = if (pass.result.*) |old|
                        if (kind == .property_target) joinPropertyTargets(old.value, found) else semantic_types.joinStringLiteral(old.value, found)
                    else
                        found;
                    pass.result.* = .{ .value = joined };
                }
            }

            pub fn simple(pass: *@This(), stmt: ast.Statement) !void {
                if (stmt.kind != .let_binding) return;
                const binding = stmt.kind.let_binding;
                if (names.isDiscardBindingName(binding.name)) return;
                const self = pass.analyzer;
                const value = if (query == .value) try self.expressionValue(binding.expr) else self.conditionValue(binding.expr);
                const string = try literalStringExpr(self, binding.expr);
                const target = if (query != .string_literal) try self.propertyTargetExpr(binding.expr) else null;
                var facts = self.environment.get(binding.name) orelse Binding{};
                facts.policy = .local;
                facts.values = value;
                facts.string_literal = string;
                facts.property_target = target;
                try self.environment.put(binding.name, facts);
            }
        };
    }

    fn propertyTargetFunctionCall(
        self: *Analyzer,
        resolved: semantic_env.ResolvedFunction,
        call: ast.CallExpr,
    ) anyerror!?PropertyTarget {
        return self.functionReturnProperty(.property_target, resolved, call);
    }

    fn mayReturnProperty(comptime kind: ReturnPropertyKind, ty: ast.Type) bool {
        return switch (ty.kind) {
            .any, .parameter, .unresolved, .hole => true,
            .optional => if (ty.optional_child) |child| mayReturnProperty(kind, child.*) else true,
            .string, .color, .enum_type => kind == .string_literal,
            .page, .document, .placed, .selection => kind == .property_target,
            else => false,
        };
    }

    fn functionReturnProperty(self: *Analyzer, comptime kind: ReturnPropertyKind, resolved: semantic_env.ResolvedFunction, call: ast.CallExpr) anyerror!?PropertyValue(kind) {
        // Effects are computed separately. A type that cannot carry the queried
        // fact needs no traversal, environment or cache entry.
        if (!mayReturnProperty(kind, resolved.decl.result_type)) return null;
        const fallback = if (kind == .property_target) self.propertyTargetForType(resolved.decl.result_type) else null;
        if (self.visiting.contains(resolved.key)) {
            self.recursive_fallbacks += 1;
            return fallback;
        }
        try self.visiting.put(resolved.key, {});
        defer _ = self.visiting.remove(resolved.key);
        const recursions_before = self.recursive_fallbacks;
        var arg_facts = switch (kind) {
            .property_target => try self.staticArguments(call),
            .string_literal => try self.stringArguments(call),
        };
        defer arg_facts.deinit(self.allocator);
        const key = if (self.run_cache != null) try buildReturnPropertyKey(self.allocator, kind, resolved.key, arg_facts.items, self.variable_scope) else null;
        defer if (key) |value| self.allocator.free(value);
        if (key) |value| if (self.run_cache.?.return_properties.get(value)) |cached| return @field(cached, @tagName(kind));

        var facts = self.environment.pushFresh();
        defer facts.restore();
        const previous = self.sema;
        self.sema = self.sema.forModule(resolved.module_id);
        defer self.sema = previous;
        try self.bindStaticParams(std.meta.Child(@TypeOf(arg_facts.items)), resolved.decl.params.items, arg_facts.items);
        if (self.run_cache) |cache| cache.return_body_analyses += 1;
        var result: ?ReturnedProperty(kind) = null;
        _ = try self.scanReturns(if (kind == .property_target) .property_target else .string_literal, resolved.decl.statements.items, &result);
        const value = if (result) |fact| fact.value orelse fallback else fallback;
        // Recursive fallbacks depend on the active call chain, not just arguments.
        if (key) |cache_key| if (self.recursive_fallbacks == recursions_before) {
            const cache = self.run_cache.?;
            const owned_key = try cache.allocator.dupe(u8, cache_key);
            errdefer cache.allocator.free(owned_key);
            try cache.return_properties.putNoClobber(owned_key, @unionInit(ReturnProperty, @tagName(kind), value));
        };
        return value;
    }

    fn propertyTargetForType(self: *Analyzer, ty: ast.Type) ?PropertyTarget {
        return switch (ty.kind) {
            .document => PropertyTarget.document(),
            .page => PropertyTarget.page(null),
            .placed => PropertyTarget.object(),
            .selection => switch (ty.selectionItem().kind) {
                .page => PropertyTarget.page(null),
                .any => PropertyTarget.object(),
                .placed => PropertyTarget.object(),
                else => null,
            },
            .optional => if (ty.optional_child) |child| self.propertyTargetForType(child.*) else null,
            else => null,
        };
    }
};

fn buildReturnPropertyKey(allocator: std.mem.Allocator, comptime kind: Analyzer.ReturnPropertyKind, key: core.FunctionKey, facts: anytype, scope: ResourceScope) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendResourceScopeKey(allocator, &out, scope);
    try appendKeyBytes(allocator, &out, @tagName(kind));
    try appendFunctionKey(allocator, &out, key);
    try appendKeyInt(allocator, &out, facts.len);
    for (facts) |fact| {
        try appendCompositionKey(allocator, &out, fact.values);
        try appendOptionalBytesKey(allocator, &out, fact.string_literal);
        if (@hasField(@TypeOf(fact), "property_target")) try appendOptionalPropertyTargetKey(allocator, &out, fact.property_target);
    }
    return out.toOwnedSlice(allocator);
}

fn buildConstSummaryKey(
    allocator: std.mem.Allocator,
    key: core.FunctionKey,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendKeyBytes(allocator, &out, "const");
    try appendFunctionKey(allocator, &out, key);
    return try out.toOwnedSlice(allocator);
}

fn buildFunctionCallSummaryKey(
    allocator: std.mem.Allocator,
    key: core.FunctionKey,
    facts: []const Analyzer.CallArgument,
    scope: ResourceScope,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendKeyBytes(allocator, &out, "call");
    try appendResourceScopeKey(allocator, &out, scope);
    try appendFunctionKey(allocator, &out, key);
    try appendKeyInt(allocator, &out, facts.len);
    for (facts) |fact| {
        try appendOptionalBytesKey(allocator, &out, fact.string_literal);
        try appendCompositionKey(allocator, &out, fact.values);
        try appendOptionalPropertyTargetKey(allocator, &out, fact.property_target);
        try appendResourceListKey(allocator, &out, fact.summary.selection_reads.items);
    }
    return try out.toOwnedSlice(allocator);
}

fn appendCompositionKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: AbstractValue) anyerror!void {
    try appendKeyInt(allocator, out, if (value.candidates.len != 0 or value.fields.len != 0) value.id else 0);
    try appendResourceScopeKey(allocator, out, value.page_scope);
    try appendPlacementScopeKey(allocator, out, value.placement);
    try out.appendSlice(allocator, &.{ @backingInt(value.truth), @backingInt(value.present) });
    try out.appendSlice(allocator, &.{ @backingInt(value.path.items), @intFromBool(value.path.no_value), @intFromBool(value.path.unknown_target) });
    try appendKeyInt(allocator, out, value.targets.ids.len);
    for (value.targets.ids) |id| try appendKeyInt(allocator, out, id);
    if (value.children) |children| {
        try out.append(allocator, 'c');
        try appendKeyInt(allocator, out, children.len);
        for (children) |child| {
            try appendOptionalPropertyTargetKey(allocator, out, child.property_target);
            try appendCompositionKey(allocator, out, child);
        }
    } else try out.append(allocator, '?');
}

fn appendPlacementScopeKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), scope: resource_model.PlacementScope) !void {
    try appendOptionalPlacementCallKey(allocator, out, scope.call);
    try appendKeyInt(allocator, out, scope.path.len);
    for (scope.path) |position| try appendKeyInt(allocator, out, position);
    try appendKeyInt(allocator, out, scope.depth.min);
    if (scope.depth.max) |limit| {
        try out.append(allocator, 'd');
        try appendKeyInt(allocator, out, limit);
    } else try out.append(allocator, '*');
}

fn appendOptionalPlacementCallKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), id: ?u64) !void {
    if (id) |value| {
        try out.append(allocator, 'c');
        try appendKeyInt(allocator, out, value);
    } else try out.append(allocator, '*');
}

fn appendFunctionKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: core.FunctionKey) !void {
    try appendKeyInt(allocator, out, key.module_id);
    try appendKeyBytes(allocator, out, key.name);
    if (key.instance_id) |id| {
        try out.append(allocator, 'i');
        try appendKeyInt(allocator, out, id);
    } else try out.append(allocator, 'd');
}

fn appendResourceListKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), resources: []const Resource) !void {
    try appendKeyInt(allocator, out, resources.len);
    for (resources) |resource| try appendResourceKey(allocator, out, resource);
}

fn appendResourceKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), resource: Resource) !void {
    switch (resource) {
        .placement_binding => |binding| {
            try out.append(allocator, 'b');
            try appendKeyInt(allocator, out, binding.id);
        },
        .variable => |variable| {
            try out.append(allocator, 'v');
            try appendResourceScopeKey(allocator, out, variable.scope);
            try appendKeyBytes(allocator, out, variable.name);
        },
        .pages => |scope| {
            try out.append(allocator, 'g');
            try appendResourceScopeKey(allocator, out, scope);
        },
        .objects => |members| {
            try out.append(allocator, 'o');
            try appendPlacementScopeKey(allocator, out, members.placement);
            if (members.input_type) |ty| {
                try out.append(allocator, 't');
                try appendTypeKey(allocator, out, ty);
            } else try out.append(allocator, '*');
            try appendPropertyOwnerKey(allocator, out, .{ .object = members.owner });
            try appendResourceScopeKey(allocator, out, members.page_scope);
        },
        .property => |property| {
            try out.append(allocator, 'p');
            try appendPropertyOwnerKey(allocator, out, property.owner);
            try appendResourceScopeKey(allocator, out, if (property.unless_defined_on) |n| .{ .page = n } else .any);
            try appendPropertyKeyKey(allocator, out, property.key);
        },
    }
}

// Encode the full identity rather than a display name or a hash: names from
// different modules and nested generic arguments must not share a cache entry.
fn appendTypeKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ty: ast.Type) anyerror!void {
    try appendKeyBytes(allocator, out, @tagName(ty.kind));
    try appendKeyInt(allocator, out, ty.arguments.len);
    for (ty.arguments) |arg| try appendTypeKey(allocator, out, arg);
    switch (ty.kind) {
        .hole => {
            try out.append(allocator, if (ty.hole_id != null) 's' else 'n');
            if (ty.hole_id) |id| try appendKeyInt(allocator, out, id);
        },
        .parameter => {
            try out.append(allocator, if (ty.parameter_id != null) 's' else 'n');
            if (ty.parameter_id) |id| {
                try appendKeyInt(allocator, out, id.module_id);
                try appendKeyInt(allocator, out, id.declaration_start);
                try appendKeyInt(allocator, out, id.index);
            }
        },
        .function => {
            try appendKeyInt(allocator, out, ty.fn_params.len);
            for (ty.fn_params) |param| try appendTypeKey(allocator, out, param);
            try out.append(allocator, if (ty.fn_result != null) 's' else 'n');
            if (ty.fn_result) |result| try appendTypeKey(allocator, out, result.*);
        },
        .optional => {
            try out.append(allocator, if (ty.optional_child != null) 's' else 'n');
            if (ty.optional_child) |child| try appendTypeKey(allocator, out, child.*);
        },
        else => {
            try out.append(allocator, if (ty.nominal_module_id != null) 's' else 'n');
            if (ty.nominal_module_id) |id| try appendKeyInt(allocator, out, id);
            try appendOptionalBytesKey(allocator, out, ty.class_name);
            try appendOptionalBytesKey(allocator, out, ty.enum_name);
        },
    }
}

fn appendResourceScopeKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), scope: ResourceScope) !void {
    switch (scope) {
        .any => try out.append(allocator, '*'),
        .document => |module_id| {
            try out.append(allocator, 'd');
            try appendKeyInt(allocator, out, module_id);
        },
        .page => |page_id| {
            try out.append(allocator, 'p');
            try appendKeyInt(allocator, out, page_id);
        },
    }
}

fn appendOptionalPropertyTargetKey(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    target: ?PropertyTarget,
) !void {
    if (target) |value| {
        try out.append(allocator, 's');
        try out.append(allocator, if (value.fresh) 'f' else 'a');
        try appendPropertyOwnerKey(allocator, out, value.owner);
    } else {
        try out.append(allocator, 'n');
    }
}

fn appendPropertyOwnerKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), owner: PropertyOwner) !void {
    switch (owner) {
        .any => try out.append(allocator, '*'),
        .document => try out.append(allocator, 'd'),
        .page => |id| {
            try out.append(allocator, 'p');
            try appendResourceScopeKey(allocator, out, if (id) |n| .{ .page = n } else .any);
        },
        .object => |object_owner| {
            try out.append(allocator, 'o');
            if (object_owner.identity) |identity| {
                try out.append(allocator, switch (identity.origin) {
                    .constant => 'c',
                    .binding => 'i',
                    .local => 'l',
                });
                try appendKeyInt(allocator, out, identity.local_id);
                try appendResourceScopeKey(allocator, out, identity.scope);
                try appendKeyBytes(allocator, out, identity.name);
            } else {
                try out.append(allocator, 'n');
            }
        },
    }
}

fn appendPropertyKeyKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: PropertyKey) !void {
    switch (key) {
        .any => try out.append(allocator, '*'),
        .named => |name| {
            try out.append(allocator, 'n');
            try appendKeyBytes(allocator, out, name);
        },
    }
}

fn appendOptionalBytesKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: ?[]const u8) !void {
    if (value) |bytes| {
        try out.append(allocator, 's');
        try appendKeyBytes(allocator, out, bytes);
    } else {
        try out.append(allocator, 'n');
    }
}

fn appendKeyBytes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    try appendKeyInt(allocator, out, bytes.len);
    try out.append(allocator, ':');
    try out.appendSlice(allocator, bytes);
    try out.append(allocator, ';');
}

fn appendKeyInt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try out.appendSlice(allocator, text);
    try out.append(allocator, ';');
}

fn joinPropertyTargets(left: ?PropertyTarget, right: ?PropertyTarget) ?PropertyTarget {
    if (left == null or right == null) return null;
    return .{ .owner = left.?.owner.merge(right.?.owner), .fresh = left.?.fresh and right.?.fresh };
}

fn literalStringArg(self: *Analyzer, call: ast.CallExpr, index: usize) !?[]const u8 {
    if (index >= call.args.items.len) return null;
    return try literalStringExpr(self, call.args.items[index]);
}

fn literalStringExpr(self: *Analyzer, expr: ast.Expr) anyerror!?[]const u8 {
    return switch (expr) {
        .string => |literal| literal.text,
        .color => |value| value,
        .ident => |ident| blk: {
            if ((self.environment.get(ident.name) orelse Binding{}).string_literal) |value| break :blk value;
            switch (try self.valueBinding(ident.reference())) {
                .constant => |resolved| {
                    if (self.visiting.contains(resolved.key)) {
                        self.recursive_fallbacks += 1;
                        break :blk null;
                    }
                    try self.visiting.put(resolved.key, {});
                    defer _ = self.visiting.remove(resolved.key);
                    var facts = self.environment.pushFresh();
                    defer facts.restore();
                    const previous = self.sema;
                    self.sema = self.sema.forModule(resolved.module_id);
                    defer self.sema = previous;
                    break :blk try literalStringExpr(self, resolved.decl.value);
                },
                else => break :blk null,
            }
        },
        .call => |call| try literalStringCall(self, call),
        else => null,
    };
}

fn literalStringCall(self: *Analyzer, call: ast.CallExpr) anyerror!?[]const u8 {
    const descriptor = (try self.callCallee(call.callee)) orelse return null;
    return switch (descriptor) {
        .primitive => |primitive| switch (primitive.op) {
            .concat => try literalConcat(self, call),
            .draw_when => try literalStringExpr(self, call.args.items[0]),
            else => null,
        },
        .function => |resolved| try literalStringFunctionCall(self, resolved, call),
    };
}

fn literalConcat(self: *Analyzer, call: ast.CallExpr) !?[]const u8 {
    if (call.args.items.len != 2) return null;
    const left = (try literalStringExpr(self, call.args.items[0])) orelse return null;
    const right = (try literalStringExpr(self, call.args.items[1])) orelse return null;
    const value = (try semantic_types.concatStringLiterals(self.allocator, left, right)) orelse return null;
    return try ownString(self, value);
}

fn literalStringFunctionCall(
    self: *Analyzer,
    resolved: semantic_env.ResolvedFunction,
    call: ast.CallExpr,
) !?[]const u8 {
    return self.functionReturnProperty(.string_literal, resolved, call);
}

fn ownString(self: *Analyzer, value: []const u8) ![]const u8 {
    if (self.run_cache) |cache| {
        defer self.allocator.free(value);
        return cache.string_allocator.dupe(u8, value);
    }
    errdefer self.allocator.free(value);
    try self.owned_strings.append(self.allocator, value);
    return value;
}
