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
pub const ResourceKind = resource_model.ResourceKind;
pub const ObjectIdentity = resource_model.ObjectIdentity;
pub const ObjectOwner = resource_model.ObjectOwner;
pub const PropertyOwner = resource_model.PropertyOwner;
pub const PropertyKey = resource_model.PropertyKey;
pub const ResourceScope = resource_model.ResourceScope;
pub const Resource = resource_model.Resource;

pub const AccessSummary = struct {
    allocator: std.mem.Allocator,
    reads: std.ArrayList(Resource),
    writes: std.ArrayList(Resource),
    selection_reads: std.ArrayList(Resource),
    escaped_objects: std.ArrayList(ObjectIdentity) = .empty,
    display_reads: std.ArrayList(PropertyOwner) = .empty,
    display_definitions: std.ArrayList(DisplayDefinition) = .empty,
    placements: std.ArrayList(PlacementDefinition) = .empty,
    reads_layout: bool = false,
    writes_layout_input: bool = false,
    places_objects: bool = false,
    invalid_selection_mutation: ?InvalidSelectionMutation = null,

    pub const DisplayDefinition = struct {
        owner: PropertyOwner,
        reads: *AccessSummary,
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
        for (self.placements.items) |*placement| {
            for (placement.steps.items) |*step| step.deinit();
            placement.steps.deinit(self.allocator);
        }
        self.placements.deinit(self.allocator);
        for (self.display_definitions.items) |definition| {
            definition.reads.deinit();
            self.allocator.destroy(definition.reads);
        }
        self.display_definitions.deinit(self.allocator);
        self.escaped_objects.deinit(self.allocator);
        self.display_reads.deinit(self.allocator);
        self.reads.deinit(self.allocator);
        self.writes.deinit(self.allocator);
        self.selection_reads.deinit(self.allocator);
    }

    pub fn addRead(self: *AccessSummary, resource: Resource) !void {
        try appendUnique(self.allocator, &self.reads, resource);
    }

    pub fn addWrite(self: *AccessSummary, resource: Resource) !void {
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

    pub fn addDisplayDefinition(self: *AccessSummary, owner: PropertyOwner, reads: AccessSummary) !void {
        const owned = try self.allocator.create(AccessSummary);
        errdefer self.allocator.destroy(owned);
        owned.* = try reads.clone(self.allocator);
        errdefer owned.deinit();
        try self.display_definitions.append(self.allocator, .{ .owner = owner, .reads = owned });
    }

    pub fn merge(self: *AccessSummary, other: AccessSummary) !void {
        for (other.placements.items) |placement| try self.addPlacement(placement);
        for (other.escaped_objects.items) |identity| try self.addEscapedObject(identity);
        try self.display_reads.appendSlice(self.allocator, other.display_reads.items);
        for (other.display_definitions.items) |definition| try self.addDisplayDefinition(definition.owner, definition.reads.*);
        try self.reads.ensureUnusedCapacity(self.allocator, other.reads.items.len);
        try self.writes.ensureUnusedCapacity(self.allocator, other.writes.items.len);
        try self.selection_reads.ensureUnusedCapacity(self.allocator, other.selection_reads.items.len);
        for (other.reads.items) |resource| try self.addRead(resource);
        for (other.writes.items) |resource| try self.addWrite(resource);
        for (other.selection_reads.items) |resource| try self.addSelectionRead(resource);
        self.reads_layout = self.reads_layout or other.reads_layout;
        self.writes_layout_input = self.writes_layout_input or other.writes_layout_input;
        self.places_objects = self.places_objects or other.places_objects;
        if (self.invalid_selection_mutation == null) self.invalid_selection_mutation = other.invalid_selection_mutation;
    }

    fn hasConcreteMembershipScope(self: AccessSummary) bool {
        for ([_][]const Resource{ self.reads.items, self.writes.items, self.selection_reads.items }) |resources| {
            for (resources) |resource| {
                if (resource == .objects and (resource.objects.page_scope != .any or resource.objects.placement_call != null)) return true;
            }
        }
        for (self.display_definitions.items) |definition| if (definition.reads.hasConcreteMembershipScope()) return true;
        for (self.placements.items) |placement| {
            if (placement.page_scope != .any) return true;
            for (placement.steps.items) |step| if (step.hasConcreteMembershipScope()) return true;
        }
        return false;
    }

    pub fn clone(self: AccessSummary, allocator: std.mem.Allocator) std.mem.Allocator.Error!AccessSummary {
        var copied = AccessSummary.init(allocator);
        errdefer copied.deinit();
        for (self.placements.items) |placement| try copied.addPlacement(placement);
        try copied.reads.ensureTotalCapacity(allocator, @intCast(self.reads.items.len));
        try copied.writes.ensureTotalCapacity(allocator, @intCast(self.writes.items.len));
        try copied.selection_reads.ensureTotalCapacity(allocator, @intCast(self.selection_reads.items.len));
        copied.reads.appendSliceAssumeCapacity(self.reads.items);
        copied.writes.appendSliceAssumeCapacity(self.writes.items);
        copied.selection_reads.appendSliceAssumeCapacity(self.selection_reads.items);
        try copied.escaped_objects.appendSlice(allocator, self.escaped_objects.items);
        try copied.display_reads.appendSlice(allocator, self.display_reads.items);
        for (self.display_definitions.items) |definition| try copied.addDisplayDefinition(definition.owner, definition.reads.*);
        copied.reads_layout = self.reads_layout;
        copied.writes_layout_input = self.writes_layout_input;
        copied.places_objects = self.places_objects;
        copied.invalid_selection_mutation = self.invalid_selection_mutation;
        return copied;
    }

    fn addPlacement(self: *AccessSummary, definition: PlacementDefinition) std.mem.Allocator.Error!void {
        for (self.placements.items) |*existing| {
            if (existing.call_id != definition.call_id) continue;
            std.debug.assert(existing.steps.items.len == definition.steps.items.len);
            for (existing.steps.items, definition.steps.items) |*step, other| try step.merge(other);
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

pub fn formatAccessSummary(allocator: std.mem.Allocator, summary: AccessSummary) ![]u8 {
    return formatAccessSummaryWithOptions(allocator, summary, .{});
}

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
    if (summary.reads_layout) {
        try appendFlagLine(allocator, &out, "reads_layout");
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
        .objects => |role_name| {
            try out.appendSlice(allocator, "Objects(");
            try out.appendSlice(allocator, "role=");
            try appendOptionalNameOrAny(allocator, out, role_name.role);
            if (role_name.input_type) |ty| {
                try out.appendSlice(allocator, ", type=");
                try ty.formatInto(allocator, out);
            }
            if (role_name.placement_call) |id| {
                const text = try std.fmt.allocPrint(allocator, "{d}", .{id});
                defer allocator.free(text);
                try out.appendSlice(allocator, ", placement=");
                try out.appendSlice(allocator, text);
            }
            try out.appendSlice(allocator, ", owner=");
            try appendPropertyOwner(allocator, out, .{ .object = role_name.owner }, options);
            try out.appendSlice(allocator, ", page=");
            try appendScope(allocator, out, role_name.page_scope, options.pages_scope_displays);
            try out.append(allocator, ')');
        },
        .property => |property| {
            try out.appendSlice(allocator, "Property(");
            try out.appendSlice(allocator, "owner=");
            try appendPropertyOwner(allocator, out, property.owner, options);
            try out.appendSlice(allocator, ", key=");
            try appendOptionalNameOrAny(allocator, out, property.key.displayName());
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
        .page => try out.appendSlice(allocator, "page"),
        .object => |object_owner| {
            try out.appendSlice(allocator, "object:");
            try appendOptionalNameOrAny(allocator, out, if (object_owner.class_id) |id| id.name else null);
            if (object_owner.identity) |identity| {
                try out.append(allocator, '#');
                try appendObjectIdentity(allocator, out, identity, options);
            } else {
                try out.appendSlice(allocator, ".*");
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

fn mergeOptionalNames(left: ?[]const u8, right: ?[]const u8) ?[]const u8 {
    if (left == null or right == null) return null;
    if (std.mem.eql(u8, left.?, right.?)) return left;
    return null;
}

fn appendUnique(allocator: std.mem.Allocator, list: *std.ArrayList(Resource), resource: Resource) !void {
    for (list.items) |existing| {
        if (existing.eql(resource)) return;
    }
    try list.append(allocator, resource);
}

const SummaryCache = std.StringHashMap(AccessSummary);
const ReturnFact = union(enum) { string_literal: ?[]const u8, object_role: ?[]const u8, property_target: ?PropertyTarget };

pub const RunCache = struct {
    allocator: std.mem.Allocator,
    name_resolution: analysis_cache.NameResolutionCache,
    summaries: SummaryCache,
    return_facts: std.StringHashMap(ReturnFact),
    // Borrowed from the graph; cached and returned summaries share these bytes.
    string_allocator: std.mem.Allocator,
    return_body_analyses: usize = 0,
    next_value_fact_id: usize = 1,
    next_local_object_id: usize = 1,

    pub fn init(allocator: std.mem.Allocator, string_allocator: std.mem.Allocator) RunCache {
        return .{
            .allocator = allocator,
            .name_resolution = analysis_cache.NameResolutionCache.init(allocator),
            .summaries = SummaryCache.init(allocator),
            .return_facts = .init(allocator),
            .string_allocator = string_allocator,
        };
    }

    pub fn deinit(self: *RunCache) void {
        var iter = self.summaries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.summaries.deinit();
        var fact_keys = self.return_facts.keyIterator();
        while (fact_keys.next()) |key| self.allocator.free(key.*);
        self.return_facts.deinit();
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

    fn page() PropertyTarget {
        return .{ .owner = .page };
    }

    fn object(class_id: ?core.NominalId) PropertyTarget {
        return .{ .owner = .{ .object = .{ .class_id = class_id } } };
    }

    fn freshObject(class_id: ?core.NominalId) PropertyTarget {
        return .{ .owner = .{ .object = .{ .class_id = class_id } }, .fresh = true };
    }

    fn objectWithIdentity(class_id: ?core.NominalId, scope: ResourceScope, name: []const u8) PropertyTarget {
        return .{ .owner = .{ .object = .{
            .class_id = class_id,
            .identity = .{ .scope = scope, .name = name },
        } } };
    }
};

const CallbackArgBinding = struct {
    values: ValueFacts = .{},
    string_literal: ?[]const u8 = null,
    object_role: ?[]const u8 = null,
    property_target: ?PropertyTarget = null,
};

// Immutable value facts carry callable candidates and object identities through
// records and captures. Storage lives until the owning analyzer is destroyed.
const max_value_fact_depth = 128;
const max_effect_analysis_depth = 128;
const ValueFacts = struct {
    id: usize = 0,
    candidates: []const Callable = &.{},
    fields: []const Field = &.{},
    property_target: ?PropertyTarget = null,
    object_role: ?[]const u8 = null,
    // Null means the subtree is unknown; an empty slice proves a leaf.
    children: ?[]const ValueFacts = null,
    page_scope: ResourceScope = .any,
    placement_call: ?u64 = null,
    const Field = struct { name: []const u8, value: ValueFacts };
    const Callable = union(enum) {
        named: semantic_env.ResolvedFunction,
        closure: struct { module_id: core.SourceModuleId, lambda: ast.LambdaExpr, bindings: []const CapturedBinding },
    };
    fn field(self: ValueFacts, name: []const u8) ValueFacts {
        for (self.fields) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
        return .{};
    }
};

const CapturedBinding = struct {
    name: []const u8,
    policy: LetPolicy,
    values: ValueFacts,
    string_literal: ?[]const u8,
    object_role: ?[]const u8,
    property_target: ?PropertyTarget,
    selection_reads: []const Resource,
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    sema: SemanticEnv,
    variable_scope: ResourceScope,
    visiting: FunctionVisitSet,
    string_bindings: std.StringHashMap([]const u8),
    object_role_bindings: std.StringHashMap([]const u8),
    property_target_bindings: std.StringHashMap(PropertyTarget),
    selection_read_bindings: std.StringHashMap(std.ArrayList(Resource)),
    owned_strings: std.ArrayList([]const u8),
    variable_bindings: std.StringHashMap(LetPolicy),
    run_cache: ?*RunCache,
    value_bindings: std.StringHashMap(ValueFacts),
    value_storage: std.heap.ArenaAllocator,
    capture_index: captures.Index,
    value_fact_depth: usize = 0,
    effect_analysis_depth: usize = 0,
    return_fact_recursions: usize = 0,
    next_value_fact_id: usize = 1,
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
            .string_bindings = std.StringHashMap([]const u8).init(allocator),
            .object_role_bindings = std.StringHashMap([]const u8).init(allocator),
            .property_target_bindings = std.StringHashMap(PropertyTarget).init(allocator),
            .selection_read_bindings = std.StringHashMap(std.ArrayList(Resource)).init(allocator),
            .owned_strings = .empty,
            .variable_bindings = std.StringHashMap(LetPolicy).init(allocator),
            .run_cache = run_cache,
            .value_bindings = .init(allocator),
            .value_storage = std.heap.ArenaAllocator.init(allocator),
            .capture_index = captures.Index.init(allocator),
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.capture_index.deinit();
        self.value_bindings.deinit();
        self.value_storage.deinit();
        self.variable_bindings.deinit();
        for (self.owned_strings.items) |value| self.allocator.free(value);
        self.owned_strings.deinit(self.allocator);
        self.deinitSelectionReadBindings(&self.selection_read_bindings);
        self.property_target_bindings.deinit();
        self.object_role_bindings.deinit();
        self.string_bindings.deinit();
        self.visiting.deinit();
    }

    pub fn documentStatements(self: *Analyzer, items: []const ast.Statement) anyerror!AccessSummary {
        return try self.analyzeStatements(items, .scheduled);
    }

    pub fn page(self: *Analyzer, page_decl: ast.PageDecl) anyerror!AccessSummary {
        return try self.analyzeStatements(page_decl.statements.items, .scheduled);
    }

    pub fn functionBody(self: *Analyzer, func: ast.FunctionDecl) anyerror!AccessSummary {
        return try self.withFunctionLocals(func, AccessSummary.init(self.allocator));
    }

    pub fn statement(self: *Analyzer, stmt: ast.Statement) anyerror!AccessSummary {
        return try self.analyzeStatement(stmt, .scheduled);
    }

    fn valueBinding(self: *Analyzer, callee: ast.CallableName) !@import("../language/name_resolution.zig").ValueResolution(LetPolicy, semantic_env.ResolvedConst, semantic_env.ResolvedFunction) {
        const local = self.variable_bindings.get(callee.name);
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

    pub fn bindPrecedingStatements(self: *Analyzer, statements: []const ast.Statement) !void {
        for (statements) |stmt| {
            if (stmt.kind == .let_binding and !names.isDiscardBindingName(stmt.kind.let_binding.name)) {
                var preceding = try self.analyzeStatement(stmt, .scheduled);
                preceding.deinit();
            }
        }
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

    fn analyzeStatements(self: *Analyzer, items: []const ast.Statement, let_policy: LetPolicy) anyerror!AccessSummary {
        const first_local = self.localObjectCounter().*;
        var parts = std.ArrayList(AccessSummary).empty;
        defer {
            for (parts.items) |*part| part.deinit();
            parts.deinit(self.allocator);
        }
        for (items) |stmt| {
            var nested = try self.analyzeStatement(stmt, let_policy);
            errdefer nested.deinit();
            try parts.append(self.allocator, nested);
        }
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
        for (parts.items) |part| try summary.merge(part);
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

    fn analyzeStatement(self: *Analyzer, stmt: ast.Statement, let_policy: LetPolicy) anyerror!AccessSummary {
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        switch (stmt.kind) {
            .hole => {},
            .let_binding => |binding| {
                var expr = try self.analyzeExpr(binding.expr);
                defer expr.deinit();
                try summary.merge(expr);
                if (!names.isDiscardBindingName(binding.name)) {
                    const values = try self.valueFacts(binding.expr);
                    try self.value_bindings.put(binding.name, values);
                    switch (let_policy) {
                        .scheduled => try summary.addWrite(Resource.makeVariable(self.variable_scope, binding.name)),
                        .local => {},
                    }
                    if (try literalStringExpr(self, binding.expr)) |value| {
                        try self.string_bindings.put(binding.name, value);
                    } else {
                        _ = self.string_bindings.remove(binding.name);
                    }
                    try self.bindSelectionReads(binding.name, expr.selection_reads.items);
                    const role_name = (try self.objectRoleExpr(binding.expr)) orelse values.object_role;
                    if (role_name) |name| {
                        try self.object_role_bindings.put(binding.name, name);
                    } else {
                        _ = self.object_role_bindings.remove(binding.name);
                    }
                    const target: ?PropertyTarget = blk: {
                        const expr_target = try self.propertyTargetExpr(binding.expr);
                        if (role_name) |name| {
                            if (expr_target == null or expr_target.?.owner.isUnknown()) {
                                var refined = PropertyTarget.object(self.objectClassForRole(name));
                                refined.fresh = if (expr_target) |value| value.fresh else false;
                                break :blk refined;
                            }
                        }
                        if (expr_target) |value| break :blk value;
                        break :blk null;
                    };
                    if (try self.bindingPropertyTarget(binding.name, target, let_policy)) |value| {
                        try self.property_target_bindings.put(binding.name, value);
                        try self.value_bindings.put(binding.name, try self.withPropertyTarget(values, value));
                    } else {
                        _ = self.property_target_bindings.remove(binding.name);
                    }
                    try self.variable_bindings.put(binding.name, let_policy);
                }
            },
            .return_expr => |expr| {
                var nested = try self.analyzeExpr(expr);
                defer nested.deinit();
                try summary.merge(nested);
                try self.addEscapedObjects(&summary, try self.valueFacts(expr));
            },
            .return_void => {},
            .property_set => |property_set| {
                var target_expr = try self.analyzeExpr(property_set.target);
                defer target_expr.deinit();
                try summary.merge(target_expr);
                var value_expr = try self.analyzeExpr(property_set.value);
                defer value_expr.deinit();
                try summary.merge(value_expr);
                try self.addEscapedObjects(&summary, try self.valueFacts(property_set.value));
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
                try summary.addWrite(Resource.makeProperty((target orelse PropertyTarget.any()).owner, property_name));
                summary.writes_layout_input = true;
            },
            .if_stmt => |if_stmt| {
                var condition = try self.analyzeExpr(if_stmt.condition);
                defer condition.deinit();
                try summary.merge(condition);
                var then_summary = try self.withLocalSnapshot(if_stmt.then_statements.items);
                defer then_summary.deinit();
                try summary.merge(then_summary);
                var else_summary = try self.withLocalSnapshot(if_stmt.else_statements.items);
                defer else_summary.deinit();
                try summary.merge(else_summary);
            },
            .expr_stmt => |expr| {
                var nested = try self.analyzeExpr(expr);
                defer nested.deinit();
                try summary.merge(nested);
            },
            .constrain => |decl| {
                try self.addAnchorReads(&summary, decl.target);
                if (decl.source) |source| try self.addAnchorReads(&summary, source);
                if (decl.offset) |offset| {
                    var nested = try self.analyzeExpr(offset);
                    defer nested.deinit();
                    try summary.merge(nested);
                }
                summary.writes_layout_input = true;
            },
        }
        return summary;
    }

    fn withLocalSnapshot(self: *Analyzer, statements: []const ast.Statement) !AccessSummary {
        var state = try self.pushLocalFacts();
        defer state.restore();
        return try self.analyzeStatements(statements, .local);
    }

    fn bindingPropertyTarget(self: *Analyzer, name: []const u8, target: ?PropertyTarget, let_policy: LetPolicy) !?PropertyTarget {
        const value = target orelse return null;
        return switch (value.owner) {
            .object => |owner| blk: {
                if (owner.identity != null or !value.fresh) break :blk value;
                var bound = PropertyTarget.objectWithIdentity(owner.class_id, self.variable_scope, name);
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

    fn analyzeExpr(self: *Analyzer, value: ast.Expr) anyerror!AccessSummary {
        if (self.sema.state) |state| try state.checkAnalysisCanceled();
        return switch (value) {
            .hole => AccessSummary.init(self.allocator),
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
                    if (self.variable_bindings.contains(name)) try self.addVariableRead(&summary, name);
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
                        var facts = self.pushFreshValueFacts();
                        defer facts.restore();
                        const previous = self.sema;
                        self.sema = self.sema.forModule(decl.module_id);
                        defer self.sema = previous;
                        var nested = try self.analyzeExpr(default.*);
                        defer nested.deinit();
                        try summary.merge(nested);
                    }
                }
                for (record.fields.items) |field| {
                    var nested = try self.analyzeExpr(field.value);
                    defer nested.deinit();
                    try summary.merge(nested);
                }
                break :blk summary;
            },
            .record_update => |update| blk: {
                var summary = try self.analyzeExpr(update.target.*);
                errdefer summary.deinit();
                for (update.fields.items) |field| {
                    var nested = try self.analyzeExpr(field.value);
                    defer nested.deinit();
                    try summary.merge(nested);
                }
                break :blk summary;
            },
            .apply => |apply| blk: {
                var summary = try self.analyzeExpr(apply.callee.*);
                errdefer summary.deinit();
                const callable = try self.valueFacts(apply.callee.*);
                var args = try self.argumentFacts(apply.args.items);
                defer self.deinitCallArgFacts(&args);
                for (args.items) |arg| try summary.merge(arg.summary);
                var invoked = try self.invokeValueFacts(callable, args.items);
                defer invoked.deinit();
                try summary.merge(invoked);
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
                    try summary.addRead(Resource.makeProperty(read.target.owner, read.key));
                    break :blk summary;
                }
                var summary = try self.analyzeExpr(member.target.*);
                errdefer summary.deinit();
                if (try self.propertyTargetExpr(member.target.*)) |target| {
                    try summary.addRead(Resource.makeProperty(target.owner, member.name));
                }
                break :blk summary;
            },
            .optional_check => |check| try self.analyzeExpr(check.target.*),
            .coalesce => |coalesce| blk: {
                var summary = try self.analyzeExpr(coalesce.target.*);
                errdefer summary.deinit();
                var fallback = try self.analyzeExpr(coalesce.fallback.*);
                defer fallback.deinit();
                try summary.merge(fallback);
                break :blk summary;
            },
            .call => |call| try self.analyzeCall(call),
        };
    }

    fn addVariableRead(self: *Analyzer, summary: *AccessSummary, name: []const u8) !void {
        switch (try self.valueBinding(ast.CallableName.bare(name))) {
            .local => |policy| {
                if (policy == .scheduled) try summary.addRead(Resource.makeVariable(self.variable_scope, name));
                try self.addBoundSelectionReads(summary, name);
            },
            .constant => |resolved| {
                var nested = try self.constValue(resolved);
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

    fn newValueFacts(self: *Analyzer, candidates: []const ValueFacts.Callable, fields: []const ValueFacts.Field) !ValueFacts {
        var field_count: usize = 0;
        for (fields) |field| if (field.value.id != 0) {
            field_count += 1;
        };
        if (candidates.len == 0 and field_count == 0) return .{};
        const counter = if (self.run_cache) |cache| &cache.next_value_fact_id else &self.next_value_fact_id;
        const id = counter.*;
        counter.* += 1;
        const allocator = self.value_storage.allocator();
        const kept_fields = try allocator.alloc(ValueFacts.Field, field_count);
        var field_index: usize = 0;
        for (fields) |field| {
            if (field.value.id == 0) continue;
            kept_fields[field_index] = field;
            field_index += 1;
        }
        return .{ .id = id, .candidates = try allocator.dupe(ValueFacts.Callable, candidates), .fields = kept_fields };
    }

    fn addEscapedObjects(self: *Analyzer, summary: *AccessSummary, facts: ValueFacts) anyerror!void {
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
                try self.addEscapedObjects(summary, binding.values);
            },
        };
    }

    fn withPropertyTarget(self: *Analyzer, facts: ValueFacts, target: ?PropertyTarget) !ValueFacts {
        const value = target orelse return facts;
        if (facts.property_target) |existing| {
            if (existing.owner.eql(value.owner) and existing.fresh == value.fresh) return facts;
        }
        var result = facts;
        const counter = if (self.run_cache) |cache| &cache.next_value_fact_id else &self.next_value_fact_id;
        result.id = counter.*;
        counter.* += 1;
        result.property_target = value;
        return result;
    }

    fn joinValueFacts(self: *Analyzer, left: ValueFacts, right: ValueFacts) anyerror!ValueFacts {
        if (left.id == 0) return right;
        if (right.id == 0 or left.id == right.id) return left;
        const allocator = self.value_storage.allocator();
        var candidates = std.ArrayList(ValueFacts.Callable).empty;
        try candidates.appendSlice(allocator, left.candidates);
        try candidates.appendSlice(allocator, right.candidates);
        var fields = std.ArrayList(ValueFacts.Field).empty;
        for (left.fields) |field| try fields.append(allocator, .{ .name = field.name, .value = try self.joinValueFacts(field.value, right.field(field.name)) });
        for (right.fields) |field| {
            var found = false;
            for (left.fields) |other| if (std.mem.eql(u8, field.name, other.name)) {
                found = true;
                break;
            };
            if (!found) try fields.append(allocator, field);
        }
        var result = try self.withPropertyTarget(try self.newValueFacts(candidates.items, fields.items), joinPropertyTargets(left.property_target, right.property_target));
        result.object_role = mergeOptionalNames(left.object_role, right.object_role);
        result.page_scope = if (resourceScopeEql(left.page_scope, right.page_scope)) left.page_scope else .any;
        result.placement_call = if (left.placement_call == right.placement_call) left.placement_call else null;
        if (left.children) |left_children| if (right.children) |right_children| {
            result.children = try std.mem.concat(allocator, ValueFacts, &.{ left_children, right_children });
        };
        return result;
    }

    fn updateValueField(self: *Analyzer, value: ValueFacts, path: []const ast.RecordPathSegment, replacement: ValueFacts) anyerror!ValueFacts {
        if (path.len == 0) return replacement;
        var fields = std.ArrayList(ValueFacts.Field).empty;
        const allocator = self.value_storage.allocator();
        for (value.fields) |field| {
            if (!std.mem.eql(u8, field.name, path[0].name)) try fields.append(allocator, field);
        }
        try fields.append(allocator, .{ .name = path[0].name, .value = try self.updateValueField(value.field(path[0].name), path[1..], replacement) });
        return self.newValueFacts(value.candidates, fields.items);
    }

    fn callableValue(self: *Analyzer, name: ast.CallableName) anyerror!ValueFacts {
        return switch (try self.valueBinding(name)) {
            .local => self.value_bindings.get(name.name) orelse .{},
            .function => |resolved| try self.newValueFacts(&.{.{ .named = resolved }}, &.{}),
            .constant => |resolved| blk: {
                if (self.visiting.contains(resolved.key)) break :blk .{};
                try self.visiting.put(resolved.key, {});
                defer _ = self.visiting.remove(resolved.key);
                var facts = self.pushFreshValueFacts();
                defer facts.restore();
                const previous = self.sema;
                self.sema = self.sema.forModule(resolved.module_id);
                defer self.sema = previous;
                break :blk try self.valueFacts(resolved.decl.value);
            },
            else => .{},
        };
    }

    fn valueFacts(self: *Analyzer, expr: ast.Expr) anyerror!ValueFacts {
        if (self.value_fact_depth >= max_value_fact_depth) return error.FunctionAnalysisLimitExceeded;
        self.value_fact_depth += 1;
        defer self.value_fact_depth -= 1;
        return switch (expr) {
            .ident => |ident| try self.withPropertyTarget(try self.callableValue(ast.CallableName.bare(ident.name)), self.property_target_bindings.get(ident.name)),
            .lambda => |lambda| blk: {
                const allocator = self.value_storage.allocator();
                var bindings = std.ArrayList(CapturedBinding).empty;
                for (try self.capture_index.lambdaNames(lambda)) |name| {
                    const policy = self.variable_bindings.get(name) orelse continue;
                    try bindings.append(allocator, .{
                        .name = name,
                        .policy = policy,
                        .values = self.value_bindings.get(name) orelse .{},
                        .string_literal = self.string_bindings.get(name),
                        .object_role = self.object_role_bindings.get(name),
                        .property_target = self.property_target_bindings.get(name),
                        .selection_reads = if (self.selection_read_bindings.get(name)) |reads| try allocator.dupe(Resource, reads.items) else &.{},
                    });
                }
                break :blk try self.newValueFacts(&.{.{ .closure = .{ .module_id = self.sema.module_id, .lambda = lambda, .bindings = bindings.items } }}, &.{});
            },
            .coalesce => |value| try self.joinValueFacts(try self.valueFacts(value.target.*), try self.valueFacts(value.fallback.*)),
            .member => |member| try self.memberValueFacts(member),
            .record => |record| blk: {
                var fields = std.ArrayList(ValueFacts.Field).empty;
                const allocator = self.value_storage.allocator();
                for (record.fields.items) |field| try fields.append(allocator, .{ .name = field.name, .value = try self.valueFacts(field.value) });
                if (self.sema.recordConstruction(record)) |decl| {
                    for (decl.decl.fields.items) |field| {
                        if (record.hasField(field.name)) continue;
                        if (field.default_value) |default| {
                            var facts = self.pushFreshValueFacts();
                            defer facts.restore();
                            const previous = self.sema;
                            self.sema = self.sema.forModule(decl.module_id);
                            defer self.sema = previous;
                            try fields.append(allocator, .{ .name = field.name, .value = try self.valueFacts(default.*) });
                        }
                    }
                }
                break :blk try self.newValueFacts(&.{}, fields.items);
            },
            .record_update => |update| blk: {
                var result = try self.valueFacts(update.target.*);
                for (update.fields.items) |field| result = try self.updateValueField(result, field.path.items, try self.valueFacts(field.value));
                break :blk result;
            },
            .call => |call| blk: {
                switch (try self.valueBinding(call.callee)) {
                    .primitive => |primitive| break :blk try self.primitiveValueFacts(call, primitive),
                    .unknown => break :blk .{},
                    .function => |named| switch (named.decl.result_type.kind) {
                        .function, .record, .optional, .any, .placed, .placement, .page => {},
                        .object => {
                            const role = try self.objectRoleCall(call);
                            if (role != null and !std.mem.eql(u8, role.?, core.GroupRole)) {
                                var result = try self.withPropertyTarget(.{}, try self.propertyTargetCall(call));
                                result.object_role = role;
                                result.children = &.{};
                                break :blk result;
                            }
                        },
                        else => break :blk try self.withPropertyTarget(.{}, try self.propertyTargetCall(call)),
                    },
                    else => {},
                }
                const value = try self.callableValue(call.callee);
                if (value.id == 0) break :blk .{};
                var args = try self.argumentFacts(call.args.items);
                defer self.deinitCallArgFacts(&args);
                break :blk try self.returnedValueFacts(value, args.items);
            },
            .apply => |apply| blk: {
                const value = try self.valueFacts(apply.callee.*);
                var args = try self.argumentFacts(apply.args.items);
                defer self.deinitCallArgFacts(&args);
                break :blk try self.returnedValueFacts(value, args.items);
            },
            else => .{},
        };
    }

    fn primitiveValueFacts(self: *Analyzer, call: ast.CallExpr, primitive: registry.PrimitiveDescriptor) anyerror!ValueFacts {
        var result = try self.withPropertyTarget(.{}, try self.propertyTargetCall(call));
        switch (primitive.op) {
            .pagectx => result.page_scope = if (self.variable_scope == .page) self.variable_scope else .any,
            .select => if (call.type_args.items.len == 1 and call.args.items.len == 1) {
                const scope = try self.valueFacts(call.args.items[0]);
                result.page_scope = scope.page_scope;
                result.placement_call = scope.placement_call;
            },
            .first => if (call.args.items.len > 0) {
                const selection = try self.valueFacts(call.args.items[0]);
                result.page_scope = selection.page_scope;
                result.placement_call = selection.placement_call;
            },
            .selection_union, .selection_intersection, .selection_difference, .sub => if (call.args.items.len == 2) {
                const left = try self.valueFacts(call.args.items[0]);
                const right = try self.valueFacts(call.args.items[1]);
                const combined = if (primitive.op == .selection_difference or primitive.op == .sub) left else try self.joinValueFacts(left, right);
                result.page_scope = combined.page_scope;
                result.placement_call = combined.placement_call;
            },
            .new => {
                result.object_role = try literalStringArg(self, call, 1);
                result.children = &.{};
            },
            .group => {
                result.object_role = core.GroupRole;
                const children = try self.value_storage.allocator().alloc(ValueFacts, call.args.items.len);
                for (call.args.items, children) |arg, *child| child.* = try self.valueFacts(arg);
                result.children = children;
            },
            .place_on => if (call.args.items.len > 1) {
                const input = try self.valueFacts(call.args.items[1]);
                if (self.sema.state != null and call.callee.call_id != null and self.sema.state.?.displays.call_targets.contains(call.callee.call_id.?)) {
                    result = try self.newValueFacts(&.{}, &.{
                        .{ .name = "value", .value = input },
                        .{ .name = "page", .value = try self.valueFacts(call.args.items[0]) },
                    });
                    result = try self.withPropertyTarget(result, PropertyTarget.freshObject(null));
                    result.page_scope = (try self.valueFacts(call.args.items[0])).page_scope;
                    result.placement_call = call.callee.call_id;
                } else result = input;
            },
            .set_prop, .set_content, .set_repr, .require_asset_exists, .extend_render_env => if (call.args.items.len > 0) {
                result = try self.valueFacts(call.args.items[0]);
            },
            else => {},
        }
        return result;
    }

    fn addPlacementWrites(self: *Analyzer, summary: *AccessSummary, facts: ValueFacts, page_scope: ResourceScope) anyerror!void {
        const owner = if (facts.property_target) |target| switch (target.owner) {
            .object => |object| object,
            else => ObjectOwner{},
        } else ObjectOwner{};
        try summary.addWrite(.{ .objects = .{ .owner = owner, .role = facts.object_role, .page_scope = page_scope } });
        if (facts.children) |children| {
            for (children) |child| try self.addPlacementWrites(summary, child, page_scope);
        } else {
            // Unknown subtrees can contribute descendants of any role or class.
            try summary.addWrite(.{ .objects = .{ .page_scope = page_scope } });
        }
    }

    fn memberValueFacts(self: *Analyzer, member: ast.MemberExpr) anyerror!ValueFacts {
        const receiver = try self.valueFacts(member.target.*);
        const field_facts = receiver.field(member.name);
        if (field_facts.id != 0) return field_facts;
        const target = receiver.property_target orelse return .{};
        const class_id = switch (target.owner) {
            .any => null,
            .object => |object| object.class_id,
            .document => self.sema.builtinClass("Doc"),
            .page => self.sema.builtinClass("PageContext"),
        };
        const field = if (class_id) |id|
            self.sema.field(id, member.name)
        else
            self.sema.fieldByName(member.name);
        return if (field) |descriptor| try self.valueFactsForType(descriptor.value_type, 0) else .{};
    }

    fn restoreCapturedBindings(self: *Analyzer, bindings: []const CapturedBinding) !void {
        for (bindings) |binding| {
            try self.variable_bindings.put(binding.name, binding.policy);
            try self.value_bindings.put(binding.name, binding.values);
            if (binding.string_literal) |value| try self.string_bindings.put(binding.name, value);
            if (binding.object_role) |value| try self.object_role_bindings.put(binding.name, value);
            if (binding.property_target) |value| try self.property_target_bindings.put(binding.name, value);
            try self.bindSelectionReads(binding.name, binding.selection_reads);
        }
    }

    fn valueFactsForType(self: *Analyzer, ty: ast.Type, depth: usize) anyerror!ValueFacts {
        if (depth >= max_value_fact_depth) return error.FunctionAnalysisLimitExceeded;
        if (self.propertyTargetForType(ty)) |target| return self.withPropertyTarget(.{}, target);
        if (ty.kind == .optional) return if (ty.optional_child) |child| self.valueFactsForType(child.*, depth + 1) else .{};
        if (ty.kind != .record) return .{};
        const record = self.sema.record(ty.nominal_module_id, ty.class_name orelse return .{}) orelse return .{};
        var fields = std.ArrayList(ValueFacts.Field).empty;
        const allocator = self.value_storage.allocator();
        for (record.decl.fields.items) |field| {
            var field_type = (try self.sema.recordFieldType(allocator, ty, field.name)) orelse continue;
            defer field_type.deinit(allocator);
            try fields.append(allocator, .{ .name = field.name, .value = try self.valueFactsForType(field_type, depth + 1) });
        }
        return self.newValueFacts(&.{}, fields.items);
    }

    fn bindParamFacts(self: *Analyzer, param: ast.ParamDecl, facts: anytype) !void {
        const Facts = @TypeOf(facts);
        if (facts.string_literal) |value| try self.string_bindings.put(param.name, value) else _ = self.string_bindings.remove(param.name);
        const role: ?[]const u8 = if (@hasField(Facts, "object_role")) facts.object_role else null;
        if (role) |value| try self.object_role_bindings.put(param.name, value) else _ = self.object_role_bindings.remove(param.name);
        var target: ?PropertyTarget = if (@hasField(Facts, "property_target")) facts.property_target else null;
        if (role) |name| {
            if (target == null or target.?.owner.isUnknown()) {
                var refined = PropertyTarget.object(self.objectClassForRole(name));
                refined.fresh = if (target) |value| value.fresh else false;
                target = refined;
            }
        }
        if (target) |value| try self.property_target_bindings.put(param.name, value) else _ = self.property_target_bindings.remove(param.name);
        const value_facts: ValueFacts = if (@hasField(Facts, "values")) facts.values else .{};
        try self.value_bindings.put(param.name, if (value_facts.id != 0) value_facts else try self.valueFactsForType(param.ty, 0));
        if (@hasField(Facts, "summary")) {
            try self.bindSelectionReads(param.name, facts.summary.selection_reads.items);
        } else {
            self.removeSelectionReads(param.name);
        }
        try self.bindLocalParams(&.{param});
    }

    fn bindValueParams(self: *Analyzer, params: []const ast.ParamDecl, args: []const CallArgFacts) anyerror!AccessSummary {
        var defaults = AccessSummary.init(self.allocator);
        errdefer defaults.deinit();
        for (params, 0..) |param, i| {
            if (i < args.len) {
                try self.bindParamFacts(param, args[i]);
            } else if (param.default_value) |default| {
                // The definition module and only preceding parameters are visible.
                // Defaults execute even when the function body ignores the value.
                var facts = try self.analyzeCallArgFacts(default.*);
                defer facts.deinit();
                try defaults.merge(facts.summary);
                try self.bindParamFacts(param, facts);
            } else {
                try self.bindParamFacts(param, CallArgFacts{ .summary = AccessSummary.init(self.allocator) });
            }
        }
        return defaults;
    }

    fn invokeValueFacts(self: *Analyzer, value: ValueFacts, args: []const CallArgFacts) anyerror!AccessSummary {
        if (self.effect_analysis_depth >= max_effect_analysis_depth) return error.FunctionAnalysisLimitExceeded;
        self.effect_analysis_depth += 1;
        defer self.effect_analysis_depth -= 1;
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        for (value.candidates) |candidate| {
            var body = switch (candidate) {
                .named => |named| try self.functionCall(named.key, named.module_id, named.decl, args, AccessSummary.init(self.allocator)),
                .closure => |closure| blk: {
                    var facts = self.pushFreshValueFacts();
                    defer facts.restore();
                    try self.restoreCapturedBindings(closure.bindings);
                    const previous = self.sema;
                    self.sema = self.sema.forModule(closure.module_id);
                    defer self.sema = previous;
                    var defaults = try self.bindValueParams(closure.lambda.params.items, args);
                    errdefer defaults.deinit();
                    var body = try self.analyzeExpr(closure.lambda.body.*);
                    defer body.deinit();
                    try defaults.merge(body);
                    break :blk defaults;
                },
            };
            defer body.deinit();
            try summary.merge(body);
        }
        return summary;
    }

    fn returnedValueFacts(self: *Analyzer, value: ValueFacts, args: []const CallArgFacts) anyerror!ValueFacts {
        var result = ValueFacts{};
        for (value.candidates) |candidate| {
            var facts = self.pushFreshValueFacts();
            defer facts.restore();
            const previous = self.sema;
            defer self.sema = previous;
            const returned = switch (candidate) {
                .named => |named| blk: {
                    // Scalar results contain neither callables nor object identities.
                    switch (named.decl.result_type.kind) {
                        .function, .record, .optional, .any, .object, .placed, .placement, .page, .document, .selection => {},
                        else => break :blk ValueFacts{},
                    }
                    const already_visiting = self.visiting.contains(named.key);
                    if (!already_visiting) try self.visiting.put(named.key, {});
                    defer if (!already_visiting) {
                        _ = self.visiting.remove(named.key);
                    };
                    self.sema = self.sema.forModule(named.module_id);
                    var defaults = try self.bindValueParams(named.decl.params.items, args);
                    defer defaults.deinit();
                    var returned = ValueFacts{};
                    _ = try self.collectValueReturns(named.decl.statements.items, &returned);
                    break :blk returned;
                },
                .closure => |closure| blk: {
                    self.sema = self.sema.forModule(closure.module_id);
                    try self.restoreCapturedBindings(closure.bindings);
                    var defaults = try self.bindValueParams(closure.lambda.params.items, args);
                    defer defaults.deinit();
                    break :blk try self.valueFacts(closure.lambda.body.*);
                },
            };
            result = try self.joinValueFacts(result, returned);
        }
        return result;
    }

    fn collectValueReturns(self: *Analyzer, statements: []const ast.Statement, result: *ValueFacts) anyerror!bool {
        for (statements) |stmt| switch (stmt.kind) {
            .return_expr => |expr| {
                result.* = try self.joinValueFacts(result.*, try self.valueFacts(expr));
                return false;
            },
            .return_void => return false,
            .if_stmt => |branch| {
                const then_continues = blk: {
                    var facts = try self.pushLocalFacts();
                    defer facts.restore();
                    break :blk try self.collectValueReturns(branch.then_statements.items, result);
                };
                const else_continues = blk: {
                    var facts = try self.pushLocalFacts();
                    defer facts.restore();
                    break :blk try self.collectValueReturns(branch.else_statements.items, result);
                };
                if (!then_continues and !else_continues) return false;
            },
            .let_binding => |binding| {
                const values = try self.valueFacts(binding.expr);
                const string = try literalStringExpr(self, binding.expr);
                const target = try self.propertyTargetExpr(binding.expr);
                const role = try self.objectRoleExpr(binding.expr);
                try self.value_bindings.put(binding.name, values);
                if (string) |value| try self.string_bindings.put(binding.name, value);
                if (target) |value| try self.property_target_bindings.put(binding.name, value);
                if (role) |value| try self.object_role_bindings.put(binding.name, value);
                try self.variable_bindings.put(binding.name, .local);
            },
            else => {},
        };
        return true;
    }

    fn analyzeCall(self: *Analyzer, call: ast.CallExpr) anyerror!AccessSummary {
        if (call.callee.name_hole != null) return try self.callArgs(call);
        return switch (try self.valueBinding(call.callee)) {
            .local, .constant => blk: {
                var args = try self.collectCallArgFacts(call);
                defer self.deinitCallArgFacts(&args);
                var summary = try self.callArgFactsSummary(args.items);
                errdefer summary.deinit();
                switch (try self.valueBinding(call.callee)) {
                    .constant => |resolved| {
                        var initialization = try self.constValue(resolved);
                        defer initialization.deinit();
                        try summary.merge(initialization);
                    },
                    else => try self.addVariableRead(&summary, call.callee.name),
                }
                const value = try self.callableValue(call.callee);
                var invoked = try self.invokeValueFacts(value, args.items);
                defer invoked.deinit();
                try summary.merge(invoked);
                break :blk summary;
            },
            .function => |resolved| blk: {
                var arg_facts = try self.collectCallArgFacts(call);
                defer self.deinitCallArgFacts(&arg_facts);
                var summary = try self.callArgFactsSummary(arg_facts.items);
                errdefer summary.deinit();
                break :blk try self.functionCall(resolved.key, resolved.module_id, resolved.decl, arg_facts.items, summary);
            },
            .primitive => |primitive| try self.primitiveCall(call, primitive),
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

    const CallArgFacts = struct {
        summary: AccessSummary,
        values: ValueFacts = .{},
        string_literal: ?[]const u8 = null,
        object_role: ?[]const u8 = null,
        property_target: ?PropertyTarget = null,

        fn deinit(self: *CallArgFacts) void {
            self.summary.deinit();
        }
    };

    const StringArgFacts = struct {
        string_literal: ?[]const u8 = null,
    };

    const StringRoleArgFacts = struct {
        string_literal: ?[]const u8 = null,
        object_role: ?[]const u8 = null,
    };

    const StaticCallArgFacts = struct {
        string_literal: ?[]const u8 = null,
        object_role: ?[]const u8 = null,
        property_target: ?PropertyTarget = null,
    };

    const IndexedCallArgFacts = struct {
        index: usize,
        facts: CallArgFacts,

        fn deinit(self: *IndexedCallArgFacts) void {
            self.facts.deinit();
        }
    };

    fn analyzeCallArgFacts(self: *Analyzer, arg: ast.Expr) anyerror!CallArgFacts {
        var facts = CallArgFacts{ .summary = try self.analyzeExpr(arg) };
        errdefer facts.deinit();
        facts.values = try self.valueFacts(arg);
        facts.string_literal = try literalStringExpr(self, arg);
        facts.object_role = try self.objectRoleExpr(arg);
        facts.property_target = try self.propertyTargetExpr(arg);
        return facts;
    }

    fn analyzeStringArgFacts(self: *Analyzer, arg: ast.Expr) anyerror!StringArgFacts {
        return .{ .string_literal = try literalStringExpr(self, arg) };
    }

    fn analyzeStringRoleArgFacts(self: *Analyzer, arg: ast.Expr) anyerror!StringRoleArgFacts {
        return .{
            .string_literal = try literalStringExpr(self, arg),
            .object_role = try self.objectRoleExpr(arg),
        };
    }

    fn analyzeStaticCallArgFacts(self: *Analyzer, arg: ast.Expr) anyerror!StaticCallArgFacts {
        return .{
            .string_literal = try literalStringExpr(self, arg),
            .object_role = try self.objectRoleExpr(arg),
            .property_target = try self.propertyTargetExpr(arg),
        };
    }

    fn collectCallArgFacts(self: *Analyzer, call: ast.CallExpr) anyerror!std.ArrayList(CallArgFacts) {
        return self.argumentFacts(call.args.items);
    }

    fn argumentFacts(self: *Analyzer, args: []const ast.Expr) anyerror!std.ArrayList(CallArgFacts) {
        var facts = std.ArrayList(CallArgFacts).empty;
        errdefer self.deinitCallArgFacts(&facts);
        try facts.ensureTotalCapacity(self.allocator, args.len);
        for (args) |arg| {
            facts.appendAssumeCapacity(try self.analyzeCallArgFacts(arg));
        }
        return facts;
    }

    fn collectCallArgFactsSkipping(self: *Analyzer, call: ast.CallExpr, skip_index: usize) anyerror!std.ArrayList(IndexedCallArgFacts) {
        var facts = std.ArrayList(IndexedCallArgFacts).empty;
        errdefer self.deinitIndexedCallArgFacts(&facts);
        try facts.ensureTotalCapacity(self.allocator, call.args.items.len);
        for (call.args.items, 0..) |arg, index| {
            if (index == skip_index) continue;
            facts.appendAssumeCapacity(.{
                .index = index,
                .facts = try self.analyzeCallArgFacts(arg),
            });
        }
        return facts;
    }

    fn collectStringArgFacts(self: *Analyzer, call: ast.CallExpr) anyerror!std.ArrayList(StringArgFacts) {
        var facts = std.ArrayList(StringArgFacts).empty;
        errdefer facts.deinit(self.allocator);
        for (call.args.items) |arg| try facts.append(self.allocator, try self.analyzeStringArgFacts(arg));
        return facts;
    }

    fn collectStringRoleArgFacts(self: *Analyzer, call: ast.CallExpr) anyerror!std.ArrayList(StringRoleArgFacts) {
        var facts = std.ArrayList(StringRoleArgFacts).empty;
        errdefer facts.deinit(self.allocator);
        for (call.args.items) |arg| try facts.append(self.allocator, try self.analyzeStringRoleArgFacts(arg));
        return facts;
    }

    fn collectStaticCallArgFacts(self: *Analyzer, call: ast.CallExpr) anyerror!std.ArrayList(StaticCallArgFacts) {
        var facts = std.ArrayList(StaticCallArgFacts).empty;
        errdefer facts.deinit(self.allocator);
        for (call.args.items) |arg| try facts.append(self.allocator, try self.analyzeStaticCallArgFacts(arg));
        return facts;
    }

    fn deinitCallArgFacts(self: *Analyzer, facts: *std.ArrayList(CallArgFacts)) void {
        for (facts.items) |*fact| fact.deinit();
        facts.deinit(self.allocator);
    }

    fn deinitIndexedCallArgFacts(self: *Analyzer, facts: *std.ArrayList(IndexedCallArgFacts)) void {
        for (facts.items) |*fact| fact.deinit();
        facts.deinit(self.allocator);
    }

    fn callArgFactsSummary(self: *Analyzer, facts: []const CallArgFacts) !AccessSummary {
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        for (facts) |fact| try summary.merge(fact.summary);
        return summary;
    }

    fn indexedCallArgFactsSummary(self: *Analyzer, facts: []const IndexedCallArgFacts) !AccessSummary {
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        for (facts) |fact| try summary.merge(fact.facts.summary);
        return summary;
    }

    fn findIndexedCallArgFacts(facts: []const IndexedCallArgFacts, index: usize) ?*const CallArgFacts {
        for (facts) |*item| {
            if (item.index == index) return &item.facts;
        }
        return null;
    }

    fn functionCall(
        self: *Analyzer,
        key: core.FunctionKey,
        module_id: core.SourceModuleId,
        func: ast.FunctionDecl,
        arg_facts: []const CallArgFacts,
        initial_summary: AccessSummary,
    ) anyerror!AccessSummary {
        var summary = initial_summary;
        errdefer summary.deinit();
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
            if (try self.run_cache.?.cachedSummary(owned, self.allocator)) |cached_body| {
                var body = cached_body;
                defer body.deinit();
                try summary.merge(body);
                return summary;
            }
        };

        // Re-entering a higher-order function with a different callback can be
        // finite. The termination pass validates calls before scheduling.
        const already_visiting = self.visiting.contains(key);
        if (!already_visiting) try self.visiting.put(key, {});
        defer if (!already_visiting) {
            _ = self.visiting.remove(key);
        };

        var state = self.pushFreshValueFacts();
        defer state.restore();

        const previous = self.sema;
        self.sema = self.sema.forModule(module_id);
        defer self.sema = previous;
        var body = try self.bindValueParams(func.params.items, arg_facts);
        defer body.deinit();
        var statements = try self.analyzeStatements(func.statements.items, .local);
        defer statements.deinit();
        try body.merge(statements);
        // Pure value helpers and page-independent effects can be shared across
        // pages; only concrete membership scopes require the caller-page key.
        if (cache_key) |owned| try self.run_cache.?.putSummary(if (body.hasConcreteMembershipScope()) owned else shared_key.?, body);
        try summary.merge(body);
        return summary;
    }

    fn constValue(self: *Analyzer, resolved: semantic_env.ResolvedConst) anyerror!AccessSummary {
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        if (self.visiting.contains(resolved.key)) return summary;

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

        var state = self.pushFreshValueFacts();
        defer state.restore();

        const previous = self.sema;
        self.sema = self.sema.forModule(resolved.module_id);
        defer self.sema = previous;

        var nested = try self.analyzeExpr(resolved.decl.value);
        defer nested.deinit();
        try summary.merge(nested);
        if (cache_key) |owned| try self.run_cache.?.putSummary(owned, summary);
        return summary;
    }

    fn withFunctionLocals(self: *Analyzer, func: ast.FunctionDecl, initial_summary: AccessSummary) !AccessSummary {
        var summary = initial_summary;
        errdefer summary.deinit();
        var state = try self.pushLocalFacts();
        defer state.restore();
        try self.bindLocalParams(func.params.items);
        var body = try self.analyzeStatements(func.statements.items, .local);
        defer body.deinit();
        try summary.merge(body);
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
        try self.variable_bindings.ensureUnusedCapacity(@intCast(params.len));
        for (params) |param| {
            try self.variable_bindings.put(param.name, .local);
            if (!self.value_bindings.contains(param.name)) {
                try self.value_bindings.put(param.name, try self.valueFactsForType(param.ty, 0));
            }
            if (!self.property_target_bindings.contains(param.name)) {
                if (self.propertyTargetForType(param.ty)) |target| {
                    try self.property_target_bindings.put(param.name, target);
                }
            }
        }
    }

    fn bindStaticParams(self: *Analyzer, comptime Facts: type, params: []const ast.ParamDecl, args: []const Facts) anyerror!void {
        for (params, 0..) |param, index| {
            const facts = if (index < args.len)
                args[index]
            else if (param.default_value) |default|
                if (Facts == StaticCallArgFacts)
                    try self.analyzeStaticCallArgFacts(default.*)
                else if (Facts == StringRoleArgFacts)
                    try self.analyzeStringRoleArgFacts(default.*)
                else
                    try self.analyzeStringArgFacts(default.*)
            else
                Facts{};
            try self.bindParamFacts(param, facts);
        }
    }

    const ValueFactsSnapshot = struct {
        analyzer: *Analyzer,
        value_bindings: std.StringHashMap(ValueFacts),
        string_bindings: std.StringHashMap([]const u8),
        variable_bindings: std.StringHashMap(LetPolicy),
        object_role_bindings: std.StringHashMap([]const u8),
        property_target_bindings: std.StringHashMap(PropertyTarget),
        selection_read_bindings: std.StringHashMap(std.ArrayList(Resource)),

        fn restore(self: *ValueFactsSnapshot) void {
            var values = self.analyzer.value_bindings;
            self.analyzer.value_bindings = self.value_bindings;
            values.deinit();
            var string_snapshot = self.analyzer.string_bindings;
            self.analyzer.string_bindings = self.string_bindings;
            string_snapshot.deinit();

            var local_snapshot = self.analyzer.variable_bindings;
            self.analyzer.variable_bindings = self.variable_bindings;
            local_snapshot.deinit();

            var role_snapshot = self.analyzer.object_role_bindings;
            self.analyzer.object_role_bindings = self.object_role_bindings;
            role_snapshot.deinit();

            var property_target_snapshot = self.analyzer.property_target_bindings;
            self.analyzer.property_target_bindings = self.property_target_bindings;
            property_target_snapshot.deinit();

            var selection_snapshot = self.analyzer.selection_read_bindings;
            self.analyzer.selection_read_bindings = self.selection_read_bindings;
            self.analyzer.deinitSelectionReadBindings(&selection_snapshot);
        }
    };

    fn pushFreshValueFacts(self: *Analyzer) ValueFactsSnapshot {
        const snapshot = ValueFactsSnapshot{
            .analyzer = self,
            .value_bindings = self.value_bindings,
            .string_bindings = self.string_bindings,
            .variable_bindings = self.variable_bindings,
            .object_role_bindings = self.object_role_bindings,
            .property_target_bindings = self.property_target_bindings,
            .selection_read_bindings = self.selection_read_bindings,
        };
        self.value_bindings = .init(self.allocator);
        self.string_bindings = std.StringHashMap([]const u8).init(self.allocator);
        self.variable_bindings = std.StringHashMap(LetPolicy).init(self.allocator);
        self.object_role_bindings = std.StringHashMap([]const u8).init(self.allocator);
        self.property_target_bindings = std.StringHashMap(PropertyTarget).init(self.allocator);
        self.selection_read_bindings = std.StringHashMap(std.ArrayList(Resource)).init(self.allocator);
        return snapshot;
    }

    const LocalFactsSnapshot = struct {
        analyzer: *Analyzer,
        value_bindings: std.StringHashMap(ValueFacts),
        string_bindings: std.StringHashMap([]const u8),
        variable_bindings: std.StringHashMap(LetPolicy),
        object_role_bindings: std.StringHashMap([]const u8),
        property_target_bindings: std.StringHashMap(PropertyTarget),
        selection_read_bindings: std.StringHashMap(std.ArrayList(Resource)),

        fn restore(self: *LocalFactsSnapshot) void {
            var values = self.analyzer.value_bindings;
            self.analyzer.value_bindings = self.value_bindings;
            values.deinit();
            var strings = self.analyzer.string_bindings;
            self.analyzer.string_bindings = self.string_bindings;
            strings.deinit();

            var local_snapshot = self.analyzer.variable_bindings;
            self.analyzer.variable_bindings = self.variable_bindings;
            local_snapshot.deinit();

            var role_snapshot = self.analyzer.object_role_bindings;
            self.analyzer.object_role_bindings = self.object_role_bindings;
            role_snapshot.deinit();

            var property_target_snapshot = self.analyzer.property_target_bindings;
            self.analyzer.property_target_bindings = self.property_target_bindings;
            property_target_snapshot.deinit();

            var selection_snapshot = self.analyzer.selection_read_bindings;
            self.analyzer.selection_read_bindings = self.selection_read_bindings;
            self.analyzer.deinitSelectionReadBindings(&selection_snapshot);
        }
    };

    fn pushLocalFacts(self: *Analyzer) !LocalFactsSnapshot {
        var value_clone = try self.value_bindings.clone();
        errdefer value_clone.deinit();
        var string_clone = try self.cloneStringBindings();
        errdefer string_clone.deinit();
        var local_clone = try self.cloneVariableBindings();
        errdefer local_clone.deinit();
        var role_clone = try self.cloneObjectRoles();
        errdefer role_clone.deinit();
        var property_target_clone = try self.clonePropertyTargets();
        errdefer property_target_clone.deinit();
        var selection_clone = try self.cloneSelectionReadBindings();
        errdefer self.deinitSelectionReadBindings(&selection_clone);

        const snapshot = LocalFactsSnapshot{
            .analyzer = self,
            .value_bindings = self.value_bindings,
            .string_bindings = self.string_bindings,
            .variable_bindings = self.variable_bindings,
            .object_role_bindings = self.object_role_bindings,
            .property_target_bindings = self.property_target_bindings,
            .selection_read_bindings = self.selection_read_bindings,
        };
        self.value_bindings = value_clone;
        self.string_bindings = string_clone;
        self.variable_bindings = local_clone;
        self.object_role_bindings = role_clone;
        self.property_target_bindings = property_target_clone;
        self.selection_read_bindings = selection_clone;
        return snapshot;
    }

    fn cloneVariableBindings(self: *Analyzer) !std.StringHashMap(LetPolicy) {
        var clone = std.StringHashMap(LetPolicy).init(self.allocator);
        errdefer clone.deinit();
        try clone.ensureTotalCapacity(@intCast(self.variable_bindings.count()));
        var iter = self.variable_bindings.iterator();
        while (iter.next()) |entry| try clone.put(entry.key_ptr.*, entry.value_ptr.*);
        return clone;
    }

    fn cloneStringBindings(self: *Analyzer) !std.StringHashMap([]const u8) {
        var clone = std.StringHashMap([]const u8).init(self.allocator);
        errdefer clone.deinit();
        try clone.ensureTotalCapacity(@intCast(self.string_bindings.count()));
        var iter = self.string_bindings.iterator();
        while (iter.next()) |entry| try clone.put(entry.key_ptr.*, entry.value_ptr.*);
        return clone;
    }

    fn cloneObjectRoles(self: *Analyzer) !std.StringHashMap([]const u8) {
        var clone = std.StringHashMap([]const u8).init(self.allocator);
        errdefer clone.deinit();
        try clone.ensureTotalCapacity(@intCast(self.object_role_bindings.count()));
        var iter = self.object_role_bindings.iterator();
        while (iter.next()) |entry| try clone.put(entry.key_ptr.*, entry.value_ptr.*);
        return clone;
    }

    fn clonePropertyTargets(self: *Analyzer) !std.StringHashMap(PropertyTarget) {
        var clone = std.StringHashMap(PropertyTarget).init(self.allocator);
        errdefer clone.deinit();
        try clone.ensureTotalCapacity(@intCast(self.property_target_bindings.count()));
        var iter = self.property_target_bindings.iterator();
        while (iter.next()) |entry| try clone.put(entry.key_ptr.*, entry.value_ptr.*);
        return clone;
    }

    fn cloneSelectionReadBindings(self: *Analyzer) !std.StringHashMap(std.ArrayList(Resource)) {
        var clone = std.StringHashMap(std.ArrayList(Resource)).init(self.allocator);
        errdefer self.deinitSelectionReadBindings(&clone);
        try clone.ensureTotalCapacity(@intCast(self.selection_read_bindings.count()));
        var iter = self.selection_read_bindings.iterator();
        while (iter.next()) |entry| {
            var resources = std.ArrayList(Resource).empty;
            errdefer resources.deinit(self.allocator);
            for (entry.value_ptr.items) |resource| try appendUnique(self.allocator, &resources, resource);
            try clone.put(entry.key_ptr.*, resources);
        }
        return clone;
    }

    fn deinitSelectionReadBindings(self: *Analyzer, bindings: *std.StringHashMap(std.ArrayList(Resource))) void {
        var iter = bindings.valueIterator();
        while (iter.next()) |resources| resources.deinit(self.allocator);
        bindings.deinit();
    }

    fn bindSelectionReads(self: *Analyzer, name: []const u8, resources: []const Resource) !void {
        if (resources.len == 0) {
            self.removeSelectionReads(name);
            return;
        }
        var copy = std.ArrayList(Resource).empty;
        errdefer copy.deinit(self.allocator);
        for (resources) |resource| try appendUnique(self.allocator, &copy, resource);

        const gop = try self.selection_read_bindings.getOrPut(name);
        if (gop.found_existing) gop.value_ptr.deinit(self.allocator);
        gop.value_ptr.* = copy;
    }

    fn removeSelectionReads(self: *Analyzer, name: []const u8) void {
        if (self.selection_read_bindings.fetchRemove(name)) |entry| {
            var resources = entry.value;
            resources.deinit(self.allocator);
        }
    }

    fn addBoundSelectionReads(self: *Analyzer, summary: *AccessSummary, name: []const u8) !void {
        const resources = self.selection_read_bindings.get(name) orelse return;
        for (resources.items) |resource| try summary.addSelectionRead(resource);
    }

    fn callbackArgBindingsFromFacts(
        self: *Analyzer,
        descriptor: registry.PrimitiveDescriptor,
        callback_spec: registry.PrimitiveCallbackSpec,
        call_arg_count: usize,
        arg_facts: []const IndexedCallArgFacts,
    ) !std.ArrayList(CallbackArgBinding) {
        var bindings = std.ArrayList(CallbackArgBinding).empty;
        errdefer bindings.deinit(self.allocator);

        const item_target = callbackSelectionElementTargetFromFacts(arg_facts);
        const item_index = callbackSelectionArgIndex(descriptor.op);
        for (0..callback_spec.supplied_arg_count) |index| {
            var binding = CallbackArgBinding{};
            if (item_index != null and index == item_index.?) {
                binding.property_target = item_target orelse PropertyTarget.any();
            }
            try bindings.append(self.allocator, binding);
        }

        const extra_start = callback_spec.function_arg_index + 1;
        var index = extra_start;
        while (index < call_arg_count) : (index += 1) {
            const facts = findIndexedCallArgFacts(arg_facts, index) orelse continue;
            try bindings.append(self.allocator, callbackBindingForFacts(self, facts.*));
        }
        return bindings;
    }

    fn callbackBindingForFacts(self: *Analyzer, facts: CallArgFacts) CallbackArgBinding {
        var binding = CallbackArgBinding{};
        binding.values = facts.values;
        binding.string_literal = facts.string_literal;
        binding.object_role = facts.object_role;
        if (facts.property_target) |target| {
            binding.property_target = target;
        } else if (facts.object_role) |role_name| {
            binding.property_target = PropertyTarget.object(self.objectClassForRole(role_name));
        }
        return binding;
    }

    fn callbackSelectionElementTargetFromFacts(arg_facts: []const IndexedCallArgFacts) ?PropertyTarget {
        const facts = findIndexedCallArgFacts(arg_facts, 0) orelse return null;
        return facts.property_target orelse PropertyTarget.any();
    }

    fn callbackSelectionArgIndex(op: registry.PrimitiveCall) ?usize {
        return switch (op) {
            .foreach,
            .foreach_enumerate,
            .join,
            => 0,
            .fold => 1,
            else => null,
        };
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
    ) anyerror!AccessSummary {
        if (descriptor.callback != null) return try self.primitiveCallbackCall(call, descriptor);
        if (primitiveNeedsArgFacts(descriptor.op)) {
            var arg_facts = try self.collectCallArgFacts(call);
            defer self.deinitCallArgFacts(&arg_facts);
            if (descriptor.op == .place_on) {
                if (self.sema.state) |state| if (call.callee.call_id) |id| {
                    if (state.displays.call_targets.get(id)) |plan| return self.typedPlacementCall(id, state.displays.plans.items[plan], arg_facts.items);
                };
            }
            if (descriptor.op == .select and call.type_args.items.len == 1) {
                var summary = try self.callArgFactsSummary(arg_facts.items);
                errdefer summary.deinit();
                const scope = arg_facts.items[0].values;
                try summary.addSelectionRead(.{ .objects = .{
                    .input_type = call.type_args.items[0],
                    .page_scope = scope.page_scope,
                    .placement_call = scope.placement_call,
                } });
                return summary;
            }
            return try self.primitiveCallWithFacts(descriptor, arg_facts.items);
        }

        var summary = try self.callArgs(call);
        errdefer summary.deinit();
        if (descriptor.places_objects) summary.places_objects = true;
        switch (descriptor.op) {
            .page_index, .page_count => try summary.addRead(Resource.makePages(null)),
            .frame_x, .frame_y, .frame_width, .frame_height => {
                summary.reads_layout = true;
            },
            .group => {
                summary.writes_layout_input = true;
            },
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

    fn typedPlacementCall(self: *Analyzer, call_id: u64, plan: core.native_display.Plan, args: []const CallArgFacts) anyerror!AccessSummary {
        var summary = try self.callArgFactsSummary(args);
        errdefer summary.deinit();
        const page_scope = args[0].values.page_scope;
        try summary.addWrite(.{ .objects = .{ .input_type = plan.steps.items[0].input, .page_scope = page_scope, .placement_call = call_id } });
        summary.places_objects = true;
        summary.writes_layout_input = true;
        var steps = std.ArrayList(AccessSummary).empty;
        defer {
            for (steps.items) |*step| step.deinit();
            steps.deinit(self.allocator);
        }
        try steps.ensureTotalCapacity(self.allocator, plan.steps.items.len);
        var input = args[1].values;
        for (plan.steps.items) |step| {
            switch (step.target) {
                .native => steps.appendAssumeCapacity(AccessSummary.init(self.allocator)),
                .function => |key| {
                    const state = self.sema.state.?;
                    const function = try self.newValueFacts(&.{.{ .named = .{ .key = key, .module_id = key.module_id, .decl = state.functions.get(key).? } }}, &.{});
                    var receiver = try self.newValueFacts(&.{}, &.{
                        .{ .name = "value", .value = input },
                        .{ .name = "page", .value = args[0].values },
                        .{ .name = "document", .value = try self.withPropertyTarget(.{}, PropertyTarget.document()) },
                    });
                    receiver.page_scope = page_scope;
                    receiver.placement_call = call_id;
                    var argument = CallArgFacts{ .summary = AccessSummary.init(self.allocator), .values = receiver };
                    defer argument.deinit();
                    steps.appendAssumeCapacity(try self.invokeValueFacts(function, &.{argument}));
                    input = try self.returnedValueFacts(function, &.{argument});
                },
            }
        }
        try summary.addPlacement(.{ .call_id = call_id, .steps = steps, .page_scope = page_scope });
        return summary;
    }

    fn primitiveCallWithFacts(
        self: *Analyzer,
        descriptor: registry.PrimitiveDescriptor,
        arg_facts: []const CallArgFacts,
    ) anyerror!AccessSummary {
        var summary = try self.callArgFactsSummary(arg_facts);
        errdefer summary.deinit();
        if (descriptor.places_objects) summary.places_objects = true;
        switch (descriptor.op) {
            .select => try self.applySelectSummaryFromFacts(&summary, arg_facts),
            .page_index, .page_count => try summary.addRead(Resource.makePages(null)),
            .frame_x, .frame_y, .frame_width, .frame_height => {
                summary.reads_layout = true;
            },
            .content => try summary.addRead(Resource.makeContentProperty(propertyOwnerFromArgFacts(arg_facts, 0))),
            .repr => {
                const owner = propertyOwnerFromArgFacts(arg_facts, 0);
                try summary.addRead(Resource.makeContentProperty(owner));
                try summary.addRead(Resource.makeProperty(owner, "repr"));
                try summary.display_reads.append(self.allocator, owner);
            },
            .prop, .has_prop, .prop_eq => try summary.addRead(Resource.makeProperty(
                propertyOwnerFromArgFacts(arg_facts, 0),
                literalStringFromArgFacts(arg_facts, 1),
            )),
            .set_content => {
                try summary.addWrite(Resource.makeContentProperty(propertyOwnerFromArgFacts(arg_facts, 0)));
                summary.writes_layout_input = true;
            },
            .set_repr => {
                const owner = propertyOwnerFromArgFacts(arg_facts, 0);
                try summary.addWrite(Resource.makeProperty(owner, "repr"));
                summary.writes_layout_input = true;
                if (arg_facts.len >= 2) {
                    var reads = try self.invokeValueFacts(arg_facts[1].values, arg_facts[0..1]);
                    defer reads.deinit();
                    // Registration captures a verified display; its reads occur
                    // when repr is evaluated, not while the callback is stored.
                    try summary.addDisplayDefinition(owner, reads);
                }
            },
            .group => {
                for (arg_facts) |arg| try self.addEscapedObjects(&summary, arg.values);
                summary.writes_layout_input = true;
            },
            .new_page => {
                try summary.addWrite(Resource.makePages(null));
                summary.writes_layout_input = true;
            },
            .new => {
                summary.writes_layout_input = true;
            },
            .place_on => {
                if (arg_facts.len > 1) try self.addEscapedObjects(&summary, arg_facts[1].values);
                if (arg_facts.len > 1) try self.addPlacementWrites(&summary, arg_facts[1].values, arg_facts[0].values.page_scope);
                summary.writes_layout_input = true;
            },
            .set_prop => {
                if (arg_facts.len > 2) try self.addEscapedObjects(&summary, arg_facts[2].values);
                try summary.addWrite(Resource.makeProperty(
                    propertyOwnerFromArgFacts(arg_facts, 0),
                    literalStringFromArgFacts(arg_facts, 1),
                ));
                summary.writes_layout_input = true;
            },
            .constrain_on => {
                summary.writes_layout_input = true;
            },
            .extend_render_env,
            .report_error,
            .report_warning,
            .readlines,
            .require_asset_exists,
            => {},
            else => {},
        }
        return summary;
    }

    fn primitiveNeedsArgFacts(op: registry.PrimitiveCall) bool {
        return switch (op) {
            .select,
            .content,
            .repr,
            .prop,
            .has_prop,
            .prop_eq,
            .set_content,
            .set_repr,
            .new,
            .group,
            .place_on,
            .set_prop,
            => true,
            else => false,
        };
    }

    fn primitiveCallbackCall(self: *Analyzer, call: ast.CallExpr, descriptor: registry.PrimitiveDescriptor) anyerror!AccessSummary {
        const callback_spec = descriptor.callback orelse unreachable;
        var arg_facts = try self.collectCallArgFactsSkipping(call, callback_spec.function_arg_index);
        defer self.deinitIndexedCallArgFacts(&arg_facts);

        var summary = try self.indexedCallArgFactsSummary(arg_facts.items);
        errdefer summary.deinit();
        var callback_arg_bindings = try self.callbackArgBindingsFromFacts(descriptor, callback_spec, call.args.items.len, arg_facts.items);
        defer callback_arg_bindings.deinit(self.allocator);

        var callback_summary = AccessSummary.init(self.allocator);
        defer callback_summary.deinit();
        if (call.args.items.len > callback_spec.function_arg_index) {
            const expr = call.args.items[callback_spec.function_arg_index];
            var evaluation = try self.analyzeExpr(expr);
            defer evaluation.deinit();
            try summary.merge(evaluation);
            const value = try self.valueFacts(expr);
            var args = std.ArrayList(CallArgFacts).empty;
            defer self.deinitCallArgFacts(&args);
            for (callback_arg_bindings.items) |binding| try args.append(self.allocator, .{
                .summary = AccessSummary.init(self.allocator),
                .values = binding.values,
                .string_literal = binding.string_literal,
                .object_role = binding.object_role,
                .property_target = binding.property_target,
            });
            callback_summary = try self.invokeValueFacts(value, args.items);
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
        try summary.merge(callback_summary);
        return summary;
    }

    fn applySelectSummaryFromFacts(self: *Analyzer, summary: *AccessSummary, arg_facts: []const CallArgFacts) !void {
        _ = self;
        const query_name = literalStringFromArgFacts(arg_facts, 1) orelse {
            try summary.addRead(Resource.makeObjects(null));
            try summary.addSelectionRead(Resource.makeObjects(null));
            return;
        };
        const query = registry.lookupQueryOp(query_name) orelse {
            try summary.addRead(Resource.makeObjects(null));
            return;
        };
        switch (query.op) {
            .document_pages => try summary.addSelectionRead(Resource.makePages(null)),
            .document_objects_by_role => try summary.addSelectionRead(Resource.makeObjects(literalStringFromArgFacts(arg_facts, 2))),
            .page_objects_by_role => try summary.addSelectionRead(.{ .objects = .{
                .role = literalStringFromArgFacts(arg_facts, 2),
                .page_scope = if (arg_facts.len > 0) arg_facts[0].values.page_scope else .any,
            } }),
            // Containment is fixed when the group value is constructed.
            .children, .descendants => {},
            // A singleton snapshots the supplied identity, not a collection.
            // Its argument dependencies have already been collected.
            .self_object => {},
            .previous_page => try summary.addRead(Resource.makePages(null)),
            .parent_page => {
                const owner = propertyOwnerFromArgFacts(arg_facts, 0);
                try summary.addRead(.{ .objects = .{ .owner = if (owner == .object) owner.object else .{} } });
            },
        }
    }

    fn literalStringFromArgFacts(arg_facts: []const CallArgFacts, index: usize) ?[]const u8 {
        if (index >= arg_facts.len) return null;
        return arg_facts[index].string_literal;
    }

    fn objectRoleFromArgFacts(arg_facts: []const CallArgFacts, index: usize) ?[]const u8 {
        if (index >= arg_facts.len) return null;
        return arg_facts[index].object_role;
    }

    fn propertyOwnerFromArgFacts(arg_facts: []const CallArgFacts, index: usize) PropertyOwner {
        if (index >= arg_facts.len) return .any;
        const target = arg_facts[index].property_target orelse return .any;
        return target.owner;
    }

    fn propertyOwnerArg(self: *Analyzer, call: ast.CallExpr, index: usize) !PropertyOwner {
        if (index >= call.args.items.len) return .any;
        const target = (try self.propertyTargetExpr(call.args.items[index])) orelse return .any;
        return target.owner;
    }

    fn propertyTargetExpr(self: *Analyzer, expr: ast.Expr) anyerror!?PropertyTarget {
        return switch (expr) {
            .ident => |ident| blk: {
                const name = ident.name;
                if (self.property_target_bindings.get(name)) |target| break :blk target;
                switch (try self.valueBinding(ast.CallableName.bare(name))) {
                    .constant => |resolved| break :blk try self.propertyTargetConst(resolved),
                    else => {},
                }
                break :blk null;
            },
            .call => |call| try self.propertyTargetCall(call),
            .member, .apply => (try self.valueFacts(expr)).property_target,
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
                .pagectx, .new_page => PropertyTarget.page(),
                .new => PropertyTarget.freshObject(self.objectClassForRole(try literalStringArg(self, call, 1))),
                .group => PropertyTarget.freshObject(self.objectClassForRole(core.GroupRole)),
                .place_on => if (call.args.items.len > 1)
                    try self.propertyTargetExpr(call.args.items[1])
                else
                    PropertyTarget.any(),
                .set_content, .set_repr, .require_asset_exists => if (call.args.items.len > 0)
                    try self.propertyTargetExpr(call.args.items[0])
                else
                    PropertyTarget.any(),
                .set_prop, .extend_render_env, .foreach, .foreach_enumerate => if (call.args.items.len > 0)
                    try self.propertyTargetExpr(call.args.items[0])
                else
                    PropertyTarget.any(),
                .first => if (call.args.items.len > 0)
                    (try self.propertyTargetExpr(call.args.items[0])) orelse PropertyTarget.any()
                else
                    PropertyTarget.any(),
                .selection_union, .selection_intersection, .selection_difference => try self.propertyTargetSelectionAlgebra(call, primitive.op),
                .sub => try self.propertyTargetSelectionAlgebra(call, .selection_difference),
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
            .selection_difference => left,
            .selection_intersection => if (left) |target|
                if (!target.owner.isUnknown()) target else right
            else
                right,
            else => unreachable,
        };
    }

    fn propertyTargetSelect(self: *Analyzer, call: ast.CallExpr) !?PropertyTarget {
        if (call.type_args.items.len != 0) return PropertyTarget.object(null);
        const query_name = (try literalStringArg(self, call, 1)) orelse return PropertyTarget.any();
        const query = registry.lookupQueryOp(query_name) orelse return PropertyTarget.any();
        return switch (query.op) {
            .document_pages, .previous_page, .parent_page => PropertyTarget.page(),
            .page_objects_by_role,
            .document_objects_by_role,
            => PropertyTarget.object(self.objectClassForRole(try literalStringArg(self, call, 2))),
            .children, .descendants => PropertyTarget.object(null),
            .self_object => if (call.args.items.len > 0)
                (try self.propertyTargetExpr(call.args.items[0])) orelse PropertyTarget.any()
            else
                PropertyTarget.any(),
        };
    }

    fn propertyTargetConst(self: *Analyzer, resolved: semantic_env.ResolvedConst) anyerror!?PropertyTarget {
        if (self.visiting.contains(resolved.key)) return null;
        try self.visiting.put(resolved.key, {});
        defer _ = self.visiting.remove(resolved.key);

        var state = self.pushFreshValueFacts();
        defer state.restore();

        const previous = self.sema;
        self.sema = self.sema.forModule(resolved.module_id);
        defer self.sema = previous;

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

    const ReturnFactKind = enum { string_literal, object_role, property_target };

    fn FactValue(comptime kind: ReturnFactKind) type {
        return if (kind == .property_target) PropertyTarget else []const u8;
    }

    // The outer optional means no return was reached; value = null means unknown.
    fn ReturnedFact(comptime kind: ReturnFactKind) type {
        return struct { value: ?FactValue(kind) };
    }

    fn returnExprFact(self: *Analyzer, comptime kind: ReturnFactKind, expr: ast.Expr) anyerror!?FactValue(kind) {
        if (self.sema.state) |state| try state.checkAnalysisCanceled();
        return switch (kind) {
            .string_literal => try literalStringExpr(self, expr),
            .object_role => try self.objectRoleExpr(expr),
            .property_target => try self.propertyTargetExpr(expr),
        };
    }

    fn collectReturnFacts(self: *Analyzer, comptime kind: ReturnFactKind, statements: []const ast.Statement, result: *?ReturnedFact(kind)) anyerror!bool {
        for (statements) |stmt| {
            switch (stmt.kind) {
                .return_expr => |expr| {
                    const value = try self.returnExprFact(kind, expr);
                    const joined = if (result.*) |previous|
                        if (kind == .property_target) joinPropertyTargets(previous.value, value) else semantic_types.joinStringLiteral(previous.value, value)
                    else
                        value;
                    result.* = .{ .value = joined };
                    return false;
                },
                .return_void => {
                    result.* = .{ .value = null };
                    return false;
                },
                .if_stmt => |branch| {
                    const then_continues = blk: {
                        var snapshot = try self.pushLocalFacts();
                        defer snapshot.restore();
                        break :blk try self.collectReturnFacts(kind, branch.then_statements.items, result);
                    };
                    const else_continues = blk: {
                        var snapshot = try self.pushLocalFacts();
                        defer snapshot.restore();
                        break :blk try self.collectReturnFacts(kind, branch.else_statements.items, result);
                    };
                    if (!then_continues and !else_continues) return false;
                },
                .let_binding => |binding| {
                    if (names.isDiscardBindingName(binding.name)) continue;
                    const string = try literalStringExpr(self, binding.expr);
                    const role = if (kind != .string_literal) try self.objectRoleExpr(binding.expr) else null;
                    const target = if (kind == .property_target) try self.propertyTargetExpr(binding.expr) else null;
                    if (string) |value| try self.string_bindings.put(binding.name, value) else _ = self.string_bindings.remove(binding.name);
                    if (role) |value| try self.object_role_bindings.put(binding.name, value) else _ = self.object_role_bindings.remove(binding.name);
                    if (target) |value| try self.property_target_bindings.put(binding.name, value) else _ = self.property_target_bindings.remove(binding.name);
                    try self.variable_bindings.put(binding.name, .local);
                },
                else => {},
            }
        }
        return true;
    }

    fn propertyTargetFunctionCall(
        self: *Analyzer,
        resolved: semantic_env.ResolvedFunction,
        call: ast.CallExpr,
    ) anyerror!?PropertyTarget {
        return self.functionReturnFact(.property_target, resolved, call);
    }

    fn functionReturnFact(self: *Analyzer, comptime kind: ReturnFactKind, resolved: semantic_env.ResolvedFunction, call: ast.CallExpr) anyerror!?FactValue(kind) {
        const fallback = if (kind == .property_target) self.propertyTargetForType(resolved.decl.result_type) else null;
        if (self.visiting.contains(resolved.key)) {
            self.return_fact_recursions += 1;
            return fallback;
        }
        try self.visiting.put(resolved.key, {});
        defer _ = self.visiting.remove(resolved.key);
        const recursions_before = self.return_fact_recursions;
        var arg_facts = switch (kind) {
            .property_target => try self.collectStaticCallArgFacts(call),
            .object_role => try self.collectStringRoleArgFacts(call),
            .string_literal => try self.collectStringArgFacts(call),
        };
        defer arg_facts.deinit(self.allocator);
        const key = if (self.run_cache != null) try buildReturnFactKey(self.allocator, kind, resolved.key, arg_facts.items) else null;
        defer if (key) |value| self.allocator.free(value);
        if (key) |value| if (self.run_cache.?.return_facts.get(value)) |cached| return @field(cached, @tagName(kind));

        var facts = self.pushFreshValueFacts();
        defer facts.restore();
        const previous = self.sema;
        self.sema = self.sema.forModule(resolved.module_id);
        defer self.sema = previous;
        try self.bindStaticParams(std.meta.Child(@TypeOf(arg_facts.items)), resolved.decl.params.items, arg_facts.items);
        if (self.run_cache) |cache| cache.return_body_analyses += 1;
        var result: ?ReturnedFact(kind) = null;
        _ = try self.collectReturnFacts(kind, resolved.decl.statements.items, &result);
        const value = if (result) |fact| fact.value orelse fallback else fallback;
        // Recursive fallbacks depend on the active call chain, not just arguments.
        if (key) |cache_key| if (self.return_fact_recursions == recursions_before) {
            const cache = self.run_cache.?;
            const owned_key = try cache.allocator.dupe(u8, cache_key);
            errdefer cache.allocator.free(owned_key);
            try cache.return_facts.putNoClobber(owned_key, @unionInit(ReturnFact, @tagName(kind), value));
        };
        return value;
    }

    fn propertyTargetForType(self: *Analyzer, ty: ast.Type) ?PropertyTarget {
        return switch (ty.kind) {
            .document => PropertyTarget.document(),
            .page => PropertyTarget.page(),
            .object => PropertyTarget.object(ty.nominalId()),
            .placed, .placement => PropertyTarget.object(null),
            .selection => switch (ty.selectionItem().kind) {
                .page => PropertyTarget.page(),
                .object, .any => PropertyTarget.object(ty.selectionItemId()),
                .placed, .placement => PropertyTarget.object(null),
                else => null,
            },
            .optional => if (ty.optional_child) |child| self.propertyTargetForType(child.*) else null,
            else => null,
        };
    }

    fn objectClassForRole(self: *Analyzer, role_name: ?[]const u8) ?core.NominalId {
        const name = role_name orelse return null;
        return self.sema.roleClass(name);
    }

    fn objectRoleArg(self: *Analyzer, call: ast.CallExpr, index: usize) !?[]const u8 {
        if (index >= call.args.items.len) return null;
        return try self.objectRoleExpr(call.args.items[index]);
    }

    fn objectRoleExpr(self: *Analyzer, expr: ast.Expr) anyerror!?[]const u8 {
        return switch (expr) {
            .ident => |ident| blk: {
                const name = ident.name;
                if (self.object_role_bindings.get(name)) |role_name| break :blk role_name;
                switch (try self.valueBinding(ast.CallableName.bare(name))) {
                    .constant => |resolved| break :blk try self.objectRoleConst(resolved),
                    else => {},
                }
                break :blk null;
            },
            .call => |call| try self.objectRoleCall(call),
            else => null,
        };
    }

    fn objectRoleCall(self: *Analyzer, call: ast.CallExpr) anyerror!?[]const u8 {
        const descriptor = (try self.callCallee(call.callee)) orelse return null;
        return switch (descriptor) {
            .primitive => |primitive| switch (primitive.op) {
                .new => try literalStringArg(self, call, 1),
                .group => core.GroupRole,
                .place_on => try self.objectRoleArg(call, 1),
                else => null,
            },
            .function => |resolved| try self.objectRoleFunctionCall(resolved, call),
        };
    }

    fn objectRoleConst(self: *Analyzer, resolved: semantic_env.ResolvedConst) anyerror!?[]const u8 {
        if (self.visiting.contains(resolved.key)) return null;
        try self.visiting.put(resolved.key, {});
        defer _ = self.visiting.remove(resolved.key);

        const previous = self.sema;
        self.sema = self.sema.forModule(resolved.module_id);
        defer self.sema = previous;

        return try self.objectRoleExpr(resolved.decl.value);
    }

    fn objectRoleFunctionCall(
        self: *Analyzer,
        resolved: semantic_env.ResolvedFunction,
        call: ast.CallExpr,
    ) anyerror!?[]const u8 {
        return self.functionReturnFact(.object_role, resolved, call);
    }
};

fn buildReturnFactKey(allocator: std.mem.Allocator, comptime kind: Analyzer.ReturnFactKind, key: core.FunctionKey, facts: anytype) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendKeyBytes(allocator, &out, @tagName(kind));
    try appendFunctionKey(allocator, &out, key);
    try appendKeyInt(allocator, &out, facts.len);
    for (facts) |fact| {
        try appendOptionalBytesKey(allocator, &out, fact.string_literal);
        if (@hasField(@TypeOf(fact), "object_role")) try appendOptionalBytesKey(allocator, &out, fact.object_role);
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
    facts: []const Analyzer.CallArgFacts,
    scope: ResourceScope,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendKeyBytes(allocator, &out, "call");
    try appendResourceScopeKey(allocator, &out, scope);
    try appendFunctionKey(allocator, &out, key);
    try appendKeyInt(allocator, &out, facts.len);
    for (facts) |fact| {
        try appendKeyInt(allocator, &out, if (fact.values.candidates.len != 0 or fact.values.fields.len != 0) fact.values.id else 0);
        try appendOptionalBytesKey(allocator, &out, fact.string_literal);
        try appendOptionalBytesKey(allocator, &out, fact.object_role);
        try appendResourceScopeKey(allocator, &out, fact.values.page_scope);
        try appendOptionalPlacementCallKey(allocator, &out, fact.values.placement_call);
        try appendCompositionKey(allocator, &out, fact.values);
        try appendOptionalPropertyTargetKey(allocator, &out, fact.property_target);
        try appendResourceListKey(allocator, &out, fact.summary.selection_reads.items);
    }
    return try out.toOwnedSlice(allocator);
}

fn appendCompositionKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: ValueFacts) anyerror!void {
    try appendOptionalBytesKey(allocator, out, value.object_role);
    if (value.children) |children| {
        try out.append(allocator, 'c');
        try appendKeyInt(allocator, out, children.len);
        for (children) |child| {
            try appendOptionalPropertyTargetKey(allocator, out, child.property_target);
            try appendCompositionKey(allocator, out, child);
        }
    } else try out.append(allocator, '?');
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
        .variable => |variable| {
            try out.append(allocator, 'v');
            try appendResourceScopeKey(allocator, out, variable.scope);
            try appendKeyBytes(allocator, out, variable.name);
        },
        .pages => |scope| {
            try out.append(allocator, 'g');
            try appendResourceScopeKey(allocator, out, scope);
        },
        .objects => |role_name| {
            try out.append(allocator, 'o');
            try appendOptionalPlacementCallKey(allocator, out, role_name.placement_call);
            try appendOptionalBytesKey(allocator, out, role_name.role);
            if (role_name.input_type) |ty| {
                try out.append(allocator, 't');
                try appendTypeKey(allocator, out, ty);
            } else try out.append(allocator, '*');
            try appendPropertyOwnerKey(allocator, out, .{ .object = role_name.owner });
            try appendResourceScopeKey(allocator, out, role_name.page_scope);
        },
        .property => |property| {
            try out.append(allocator, 'p');
            try appendPropertyOwnerKey(allocator, out, property.owner);
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
        .page => try out.append(allocator, 'p'),
        .object => |object_owner| {
            try out.append(allocator, 'o');
            if (object_owner.class_id) |id| {
                try out.append(allocator, 's');
                try out.appendSlice(allocator, std.mem.asBytes(&id.module_id));
                try appendKeyBytes(allocator, out, id.name);
            } else try out.append(allocator, 'n');
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
        .content => try out.append(allocator, 'c'),
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
            if (self.string_bindings.get(ident.name)) |value| break :blk value;
            switch (try self.valueBinding(ast.CallableName.bare(ident.name))) {
                .constant => |resolved| {
                    if (self.visiting.contains(resolved.key)) break :blk null;
                    try self.visiting.put(resolved.key, {});
                    defer _ = self.visiting.remove(resolved.key);
                    var facts = self.pushFreshValueFacts();
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
    return self.functionReturnFact(.string_literal, resolved, call);
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

pub fn callableNamePlacesObjects(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "!");
}
