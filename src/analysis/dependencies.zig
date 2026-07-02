const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const analysis_cache = @import("cache.zig");
const registry = @import("../language/registry.zig");
const semantic_env = @import("../language/env.zig");
const names = @import("../language/names.zig");

const SemanticEnv = semantic_env.SemanticEnv;
const FunctionVisitSet = std.HashMap(core.FunctionKey, void, core.FunctionKeyContext, std.hash_map.default_max_load_percentage);

pub const ResourceKind = enum {
    variable,
    pages,
    objects,
    property,
};

pub const ObjectIdentity = struct {
    scope: ResourceScope,
    name: []const u8,

    pub fn eql(self: ObjectIdentity, other: ObjectIdentity) bool {
        return resourceScopeEql(self.scope, other.scope) and std.mem.eql(u8, self.name, other.name);
    }
};

pub const ObjectOwner = struct {
    class_name: ?[]const u8 = null,
    identity: ?ObjectIdentity = null,

    pub fn intersects(self: ObjectOwner, other: ObjectOwner) bool {
        if (self.identity != null and other.identity != null) {
            return self.identity.?.eql(other.identity.?);
        }
        return optionalNameIntersects(self.class_name, other.class_name);
    }

    pub fn merge(self: ObjectOwner, other: ObjectOwner) ObjectOwner {
        return .{
            .class_name = mergeOptionalNames(self.class_name, other.class_name),
            .identity = if (self.identity != null and other.identity != null and self.identity.?.eql(other.identity.?))
                self.identity
            else
                null,
        };
    }

    pub fn isUnknown(self: ObjectOwner) bool {
        return self.class_name == null and self.identity == null;
    }
};

pub const PropertyOwner = union(enum) {
    any,
    document,
    page,
    object: ObjectOwner,

    pub fn intersects(self: PropertyOwner, other: PropertyOwner) bool {
        return switch (self) {
            .any => true,
            .document => switch (other) {
                .any, .document => true,
                .page, .object => false,
            },
            .page => switch (other) {
                .any, .page => true,
                .document, .object => false,
            },
            .object => |left| switch (other) {
                .any => true,
                .object => |right| left.intersects(right),
                .document, .page => false,
            },
        };
    }

    pub fn merge(self: PropertyOwner, other: PropertyOwner) PropertyOwner {
        return switch (self) {
            .any => .any,
            .document => switch (other) {
                .any => .any,
                .document => .document,
                .page, .object => .any,
            },
            .page => switch (other) {
                .any => .any,
                .page => .page,
                .document, .object => .any,
            },
            .object => |left| switch (other) {
                .any => .any,
                .object => |right| .{ .object = left.merge(right) },
                .document, .page => .any,
            },
        };
    }

    pub fn isUnknown(self: PropertyOwner) bool {
        return switch (self) {
            .any => true,
            .object => |owner| owner.isUnknown(),
            .document, .page => false,
        };
    }
};

pub const PropertyKey = union(enum) {
    any,
    content,
    named: []const u8,

    const content_name = "content";

    pub fn fromName(maybe_name: ?[]const u8) PropertyKey {
        const value = maybe_name orelse return .any;
        if (std.mem.eql(u8, value, content_name)) return .content;
        return .{ .named = value };
    }

    pub fn intersects(self: PropertyKey, other: PropertyKey) bool {
        return switch (self) {
            .any => true,
            .content => switch (other) {
                .any, .content => true,
                .named => |named_value| std.mem.eql(u8, named_value, content_name),
            },
            .named => |left| switch (other) {
                .any => true,
                .content => std.mem.eql(u8, left, content_name),
                .named => |right| std.mem.eql(u8, left, right),
            },
        };
    }

    pub fn displayName(self: PropertyKey) ?[]const u8 {
        return switch (self) {
            .any => null,
            .content => content_name,
            .named => |value| value,
        };
    }
};

pub const ResourceScope = union(enum) {
    any,
    document: core.SourceModuleId,
    page: core.NodeId,

    pub fn intersects(self: ResourceScope, other: ResourceScope) bool {
        return switch (self) {
            .any => true,
            .document => |left| switch (other) {
                .any => true,
                .document => |right| left == right,
                .page => false,
            },
            .page => |left| switch (other) {
                .any => true,
                .document => false,
                .page => |right| left == right,
            },
        };
    }
};

pub const Resource = union(ResourceKind) {
    variable: struct {
        scope: ResourceScope,
        name: []const u8,
    },
    pages: ResourceScope,
    objects: ?[]const u8,
    property: struct {
        owner: PropertyOwner,
        key: PropertyKey,
    },

    pub fn intersects(self: Resource, other: Resource) bool {
        return switch (self) {
            .variable => |left| switch (other) {
                .variable => |right| left.scope.intersects(right.scope) and std.mem.eql(u8, left.name, right.name),
                else => false,
            },
            .pages => |left| switch (other) {
                .pages => |right| left.intersects(right),
                else => false,
            },
            .objects => |left| switch (other) {
                .objects => |right| optionalNameIntersects(left, right),
                else => false,
            },
            .property => |left| switch (other) {
                .property => |right| left.owner.intersects(right.owner) and left.key.intersects(right.key),
                else => false,
            },
        };
    }

    pub fn makeVariable(scope: ResourceScope, name: []const u8) Resource {
        return .{ .variable = .{ .scope = scope, .name = name } };
    }

    pub fn makeObjects(role_name: ?[]const u8) Resource {
        return .{ .objects = role_name };
    }

    pub fn makeProperty(owner: PropertyOwner, key: ?[]const u8) Resource {
        return .{ .property = .{ .owner = owner, .key = PropertyKey.fromName(key) } };
    }

    pub fn makeContentProperty(owner: PropertyOwner) Resource {
        return .{ .property = .{ .owner = owner, .key = .content } };
    }

    pub fn makePages(page_id: ?core.NodeId) Resource {
        return .{ .pages = if (page_id) |id| .{ .page = id } else .any };
    }
};

pub const AccessSummary = struct {
    allocator: std.mem.Allocator,
    reads: std.ArrayList(Resource),
    writes: std.ArrayList(Resource),
    selection_reads: std.ArrayList(Resource),
    reads_layout: bool = false,
    writes_layout_input: bool = false,
    places_objects: bool = false,
    invalid_selection_mutation: ?InvalidSelectionMutation = null,

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

    pub fn merge(self: *AccessSummary, other: AccessSummary) !void {
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

    pub fn clone(self: AccessSummary, allocator: std.mem.Allocator) !AccessSummary {
        var copied = AccessSummary.init(allocator);
        errdefer copied.deinit();
        try copied.reads.ensureTotalCapacity(allocator, @intCast(self.reads.items.len));
        try copied.writes.ensureTotalCapacity(allocator, @intCast(self.writes.items.len));
        try copied.selection_reads.ensureTotalCapacity(allocator, @intCast(self.selection_reads.items.len));
        copied.reads.appendSliceAssumeCapacity(self.reads.items);
        copied.writes.appendSliceAssumeCapacity(self.writes.items);
        copied.selection_reads.appendSliceAssumeCapacity(self.selection_reads.items);
        copied.reads_layout = self.reads_layout;
        copied.writes_layout_input = self.writes_layout_input;
        copied.places_objects = self.places_objects;
        copied.invalid_selection_mutation = self.invalid_selection_mutation;
        return copied;
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

fn appendResource(
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
            try appendOptionalNameOrAny(allocator, out, role_name);
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
            try appendOptionalNameOrAny(allocator, out, object_owner.class_name);
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
    try appendScope(allocator, out, identity.scope, options.variable_scope_displays);
    try out.append(allocator, '.');
    try out.appendSlice(allocator, identity.name);
}

fn optionalNameIntersects(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return true;
    return std.mem.eql(u8, left.?, right.?);
}

fn mergeOptionalNames(left: ?[]const u8, right: ?[]const u8) ?[]const u8 {
    if (left == null or right == null) return null;
    if (std.mem.eql(u8, left.?, right.?)) return left;
    return null;
}

fn appendUnique(allocator: std.mem.Allocator, list: *std.ArrayList(Resource), resource: Resource) !void {
    for (list.items) |existing| {
        if (existing.intersects(resource)) return;
    }
    try list.append(allocator, resource);
}

const SummaryCache = std.StringHashMap(AccessSummary);

pub const RunCache = struct {
    allocator: std.mem.Allocator,
    name_resolution: analysis_cache.NameResolutionCache,
    summaries: SummaryCache,

    pub fn init(allocator: std.mem.Allocator) RunCache {
        return .{
            .allocator = allocator,
            .name_resolution = analysis_cache.NameResolutionCache.init(allocator),
            .summaries = SummaryCache.init(allocator),
        };
    }

    pub fn deinit(self: *RunCache) void {
        var iter = self.summaries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.summaries.deinit();
        self.name_resolution.deinit();
    }

    pub fn reserve(self: *RunCache, ir: *const core.Ir) !void {
        try self.name_resolution.reserve(ir);
        try self.summaries.ensureTotalCapacity(@intCast((ir.functions.count() * 8) + (ir.constants.count() * 2)));
    }

    pub fn resolvedFunction(self: *RunCache, sema: *const SemanticEnv, callee: ast.CallableName) !?semantic_env.ResolvedFunction {
        return try self.name_resolution.resolvedFunction(sema, callee);
    }

    pub fn resolvedConst(self: *RunCache, sema: *const SemanticEnv, callee: ast.CallableName) !?semantic_env.ResolvedConst {
        return try self.name_resolution.resolvedConst(sema, callee);
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

fn singleObjectWriteRole(summary: AccessSummary) ?[]const u8 {
    var role_name: ?[]const u8 = null;
    for (summary.writes.items) |resource| {
        switch (resource) {
            .objects => |name| {
                const concrete = name orelse return null;
                if (role_name) |existing| {
                    if (!std.mem.eql(u8, existing, concrete)) return null;
                } else {
                    role_name = concrete;
                }
            },
            else => {},
        }
    }
    return role_name;
}

const LetPolicy = enum {
    scheduled,
    local,
};

const PropertyTarget = struct {
    owner: PropertyOwner,

    fn any() PropertyTarget {
        return .{ .owner = .any };
    }

    fn document() PropertyTarget {
        return .{ .owner = .document };
    }

    fn page() PropertyTarget {
        return .{ .owner = .page };
    }

    fn object(class_name: ?[]const u8) PropertyTarget {
        return .{ .owner = .{ .object = .{ .class_name = class_name } } };
    }

    fn objectWithIdentity(class_name: ?[]const u8, scope: ResourceScope, name: []const u8) PropertyTarget {
        return .{ .owner = .{ .object = .{
            .class_name = class_name,
            .identity = .{ .scope = scope, .name = name },
        } } };
    }
};

const CallbackArgBinding = struct {
    string_literal: ?[]const u8 = null,
    object_role: ?[]const u8 = null,
    property_target: ?PropertyTarget = null,
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
    local_variables: std.StringHashMap(void),
    run_cache: ?*RunCache,

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
            .local_variables = std.StringHashMap(void).init(allocator),
            .run_cache = run_cache,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.local_variables.deinit();
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

    fn resolvedFunction(self: *Analyzer, callee: ast.CallableName) !?semantic_env.ResolvedFunction {
        if (self.run_cache) |cache| return try cache.resolvedFunction(&self.sema, callee);
        return self.sema.resolvedFunction(callee);
    }

    fn resolvedConst(self: *Analyzer, callee: ast.CallableName) !?semantic_env.ResolvedConst {
        if (self.run_cache) |cache| return try cache.resolvedConst(&self.sema, callee);
        return self.sema.resolvedConst(callee);
    }

    fn callCallee(self: *Analyzer, callee: ast.CallableName) !?semantic_env.CallDescriptor {
        if (callee.name_hole != null) return null;
        if (try self.resolvedFunction(callee)) |func| return .{ .function = func };
        if (!callee.isQualified()) {
            if (self.sema.primitive(callee.name)) |descriptor| return .{ .primitive = descriptor };
        }
        return null;
    }

    fn analyzeStatements(self: *Analyzer, items: []const ast.Statement, let_policy: LetPolicy) anyerror!AccessSummary {
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        for (items) |stmt| {
            var nested = try self.analyzeStatement(stmt, let_policy);
            defer nested.deinit();
            try summary.merge(nested);
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
                    switch (let_policy) {
                        .scheduled => try summary.addWrite(Resource.makeVariable(self.variable_scope, binding.name)),
                        .local => try self.local_variables.put(binding.name, {}),
                    }
                    if (try literalStringExpr(self, binding.expr)) |value| {
                        try self.string_bindings.put(binding.name, value);
                    } else {
                        _ = self.string_bindings.remove(binding.name);
                    }
                    try self.bindSelectionReads(binding.name, expr.selection_reads.items);
                    const role_name = (try self.objectRoleExpr(binding.expr)) orelse singleObjectWriteRole(expr);
                    if (role_name) |name| {
                        try self.object_role_bindings.put(binding.name, name);
                    } else {
                        _ = self.object_role_bindings.remove(binding.name);
                    }
                    const target: ?PropertyTarget = blk: {
                        const expr_target = try self.propertyTargetExpr(binding.expr);
                        if (role_name) |name| {
                            if (expr_target == null or expr_target.?.owner.isUnknown()) {
                                break :blk PropertyTarget.object(self.objectClassForRole(name));
                            }
                        }
                        if (expr_target) |value| break :blk value;
                        break :blk null;
                    };
                    if (self.bindingPropertyTarget(binding.name, target, let_policy)) |value| {
                        try self.property_target_bindings.put(binding.name, value);
                    } else {
                        _ = self.property_target_bindings.remove(binding.name);
                    }
                }
            },
            .return_expr => |expr| {
                var nested = try self.analyzeExpr(expr);
                defer nested.deinit();
                try summary.merge(nested);
            },
            .return_void => {},
            .property_set => |property_set| {
                try self.addVariableRead(&summary, property_set.object_name);
                var expr = try self.analyzeExpr(property_set.value);
                defer expr.deinit();
                try summary.merge(expr);
                const maybe_target = self.property_target_bindings.get(property_set.object_name);
                const target = maybe_target orelse PropertyTarget.any();
                const property_name = if (property_set.path.items.len == 0)
                    null
                else if (maybe_target != null)
                    property_set.path.items[0].name
                else
                    property_set.path.items[property_set.path.items.len - 1].name;
                try summary.addWrite(Resource.makeProperty(target.owner, property_name));
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

    fn bindingPropertyTarget(self: *Analyzer, name: []const u8, target: ?PropertyTarget, let_policy: LetPolicy) ?PropertyTarget {
        const value = target orelse return null;
        return switch (value.owner) {
            .object => |owner| blk: {
                if (owner.identity != null or let_policy == .local) break :blk value;
                break :blk PropertyTarget.objectWithIdentity(owner.class_name, self.variable_scope, name);
            },
            .any, .document, .page => value,
        };
    }

    fn analyzeExpr(self: *Analyzer, value: ast.Expr) anyerror!AccessSummary {
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
            .lambda => |lambda| try self.withLambdaLocals(lambda),
            .record => |record| blk: {
                var summary = AccessSummary.init(self.allocator);
                errdefer summary.deinit();
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
                for (apply.args.items) |arg| {
                    var nested = try self.analyzeExpr(arg);
                    defer nested.deinit();
                    try summary.merge(nested);
                }
                break :blk summary;
            },
            .member => |member| blk: {
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
        if (self.local_variables.contains(name)) {
            try self.addBoundSelectionReads(summary, name);
            return;
        }
        if (try self.resolvedConst(ast.CallableName.bare(name))) |resolved| {
            var nested = try self.constValue(resolved);
            defer nested.deinit();
            try summary.merge(nested);
            return;
        }
        if ((try self.resolvedFunction(ast.CallableName.bare(name))) != null) return;
        try summary.addRead(Resource.makeVariable(self.variable_scope, name));
        try self.addBoundSelectionReads(summary, name);
    }

    fn analyzeCall(self: *Analyzer, call: ast.CallExpr) anyerror!AccessSummary {
        if (call.callee.name_hole != null) return try self.callArgs(call);
        if (try self.resolvedConst(call.callee)) |resolved| {
            var summary = try self.callArgs(call);
            errdefer summary.deinit();
            var const_summary = try self.constValue(resolved);
            defer const_summary.deinit();
            try summary.merge(const_summary);
            return summary;
        }
        const descriptor = (try self.callCallee(call.callee)) orelse return try self.callArgs(call);
        return switch (descriptor) {
            .function => |resolved| blk: {
                var arg_facts = try self.collectCallArgFacts(call);
                defer self.deinitCallArgFacts(&arg_facts);
                var summary = try self.callArgFactsSummary(arg_facts.items);
                errdefer summary.deinit();
                if (callableNamePlacesObjects(call.callee.name)) summary.places_objects = true;
                break :blk try self.functionCall(resolved.key, resolved.module_id, resolved.decl, arg_facts.items, summary);
            },
            .primitive => |primitive| try self.primitiveCall(call, primitive),
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
        var facts = std.ArrayList(CallArgFacts).empty;
        errdefer self.deinitCallArgFacts(&facts);
        for (call.args.items) |arg| {
            try facts.append(self.allocator, try self.analyzeCallArgFacts(arg));
        }
        return facts;
    }

    fn collectCallArgFactsSkipping(self: *Analyzer, call: ast.CallExpr, skip_index: usize) anyerror!std.ArrayList(IndexedCallArgFacts) {
        var facts = std.ArrayList(IndexedCallArgFacts).empty;
        errdefer self.deinitIndexedCallArgFacts(&facts);
        for (call.args.items, 0..) |arg, index| {
            if (index == skip_index) continue;
            try facts.append(self.allocator, .{
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
        if (self.visiting.contains(key)) return summary;

        const cache_key = if (self.run_cache != null)
            try buildFunctionCallSummaryKey(self.allocator, key, self.variable_scope, arg_facts)
        else
            null;
        defer if (cache_key) |owned| self.allocator.free(owned);
        if (cache_key) |owned| {
            if (try self.run_cache.?.cachedSummary(owned, self.allocator)) |cached_body| {
                var body = cached_body;
                defer body.deinit();
                try summary.merge(body);
                return summary;
            }
        }

        try self.visiting.put(key, {});
        defer _ = self.visiting.remove(key);

        var state = self.pushFreshFunctionFacts();
        defer state.restore();
        try self.bindFunctionParamsFromFacts(func, arg_facts);

        const previous = self.sema;
        self.sema = self.sema.forModule(module_id);
        defer self.sema = previous;

        try self.bindLocalParams(func.params.items);
        var body = try self.analyzeStatements(func.statements.items, .local);
        defer body.deinit();
        if (cache_key) |owned| try self.run_cache.?.putSummary(owned, body);
        try summary.merge(body);
        return summary;
    }

    fn constValue(self: *Analyzer, resolved: semantic_env.ResolvedConst) anyerror!AccessSummary {
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        if (self.visiting.contains(resolved.key)) return summary;

        const cache_key = if (self.run_cache != null)
            try buildConstSummaryKey(self.allocator, resolved.key, self.variable_scope)
        else
            null;
        defer if (cache_key) |owned| self.allocator.free(owned);
        if (cache_key) |owned| {
            if (try self.run_cache.?.cachedSummary(owned, self.allocator)) |cached| return cached;
        }

        try self.visiting.put(resolved.key, {});
        defer _ = self.visiting.remove(resolved.key);

        var state = self.pushFreshFunctionFacts();
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

    fn withLambdaLocals(self: *Analyzer, lambda: ast.LambdaExpr) !AccessSummary {
        var state = try self.pushLocalFacts();
        defer state.restore();
        try self.bindLocalParams(lambda.params.items);
        return try self.analyzeExpr(lambda.body.*);
    }

    fn bindLocalParams(self: *Analyzer, params: []const ast.ParamDecl) !void {
        try self.local_variables.ensureUnusedCapacity(@intCast(params.len));
        for (params) |param| {
            try self.local_variables.put(param.name, {});
            if (!self.property_target_bindings.contains(param.name)) {
                if (self.propertyTargetForType(param.ty)) |target| {
                    try self.property_target_bindings.put(param.name, target);
                }
            }
        }
    }

    fn propertyTargetForArgFacts(self: *Analyzer, arg_facts: []const CallArgFacts, index: usize, param_type: ast.Type) ?PropertyTarget {
        if (index >= arg_facts.len) return self.propertyTargetForType(param_type);
        const fact = arg_facts[index];
        if (fact.object_role) |role_name| {
            if (fact.property_target == null or fact.property_target.?.owner.isUnknown()) {
                return PropertyTarget.object(self.objectClassForRole(role_name));
            }
        }
        return fact.property_target;
    }

    fn bindFunctionParamsFromFacts(self: *Analyzer, func: ast.FunctionDecl, arg_facts: []const CallArgFacts) !void {
        try self.string_bindings.ensureUnusedCapacity(@intCast(@min(func.params.items.len, arg_facts.len)));
        try self.object_role_bindings.ensureUnusedCapacity(@intCast(@min(func.params.items.len, arg_facts.len)));
        try self.property_target_bindings.ensureUnusedCapacity(@intCast(func.params.items.len));
        for (func.params.items, 0..) |param, index| {
            if (index < arg_facts.len) {
                if (arg_facts[index].string_literal) |value| try self.string_bindings.put(param.name, value);
                if (arg_facts[index].object_role) |role_name| try self.object_role_bindings.put(param.name, role_name);
                if (self.propertyTargetForArgFacts(arg_facts, index, param.ty)) |target| {
                    try self.property_target_bindings.put(param.name, target);
                }
                try self.bindSelectionReads(param.name, arg_facts[index].summary.selection_reads.items);
            }
        }
        try self.bindLocalParams(func.params.items);
    }

    fn bindFunctionParamsFromStaticFacts(self: *Analyzer, func: ast.FunctionDecl, arg_facts: []const StaticCallArgFacts) !void {
        try self.string_bindings.ensureUnusedCapacity(@intCast(@min(func.params.items.len, arg_facts.len)));
        try self.object_role_bindings.ensureUnusedCapacity(@intCast(@min(func.params.items.len, arg_facts.len)));
        try self.property_target_bindings.ensureUnusedCapacity(@intCast(func.params.items.len));
        for (func.params.items, 0..) |param, index| {
            if (index < arg_facts.len) {
                if (arg_facts[index].string_literal) |value| try self.string_bindings.put(param.name, value);
                if (arg_facts[index].object_role) |role_name| try self.object_role_bindings.put(param.name, role_name);
                if (self.propertyTargetForStaticFacts(arg_facts, index, param.ty)) |target| {
                    try self.property_target_bindings.put(param.name, target);
                }
            }
        }
        try self.bindLocalParams(func.params.items);
    }

    fn propertyTargetForStaticFacts(self: *Analyzer, arg_facts: []const StaticCallArgFacts, index: usize, param_type: ast.Type) ?PropertyTarget {
        if (index >= arg_facts.len) return self.propertyTargetForType(param_type);
        const fact = arg_facts[index];
        if (fact.object_role) |role_name| {
            if (fact.property_target == null or fact.property_target.?.owner.isUnknown()) {
                return PropertyTarget.object(self.objectClassForRole(role_name));
            }
        }
        return fact.property_target orelse self.propertyTargetForType(param_type);
    }

    fn bindFunctionParamsFromStringRoleFacts(self: *Analyzer, func: ast.FunctionDecl, arg_facts: []const StringRoleArgFacts) !void {
        try self.string_bindings.ensureUnusedCapacity(@intCast(@min(func.params.items.len, arg_facts.len)));
        try self.object_role_bindings.ensureUnusedCapacity(@intCast(@min(func.params.items.len, arg_facts.len)));
        for (func.params.items, 0..) |param, index| {
            if (index < arg_facts.len) {
                if (arg_facts[index].string_literal) |value| try self.string_bindings.put(param.name, value);
                if (arg_facts[index].object_role) |role_name| try self.object_role_bindings.put(param.name, role_name);
            }
        }
        try self.bindLocalParams(func.params.items);
    }

    fn bindFunctionParamsFromStringFacts(self: *Analyzer, func: ast.FunctionDecl, arg_facts: []const StringArgFacts) !void {
        try self.string_bindings.ensureUnusedCapacity(@intCast(@min(func.params.items.len, arg_facts.len)));
        for (func.params.items, 0..) |param, index| {
            if (index < arg_facts.len) {
                if (arg_facts[index].string_literal) |value| try self.string_bindings.put(param.name, value);
            }
        }
        try self.bindLocalParams(func.params.items);
    }

    const FunctionFactsSnapshot = struct {
        analyzer: *Analyzer,
        string_bindings: std.StringHashMap([]const u8),
        local_variables: std.StringHashMap(void),
        object_role_bindings: std.StringHashMap([]const u8),
        property_target_bindings: std.StringHashMap(PropertyTarget),
        selection_read_bindings: std.StringHashMap(std.ArrayList(Resource)),

        fn restore(self: *FunctionFactsSnapshot) void {
            var string_snapshot = self.analyzer.string_bindings;
            self.analyzer.string_bindings = self.string_bindings;
            string_snapshot.deinit();

            var local_snapshot = self.analyzer.local_variables;
            self.analyzer.local_variables = self.local_variables;
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

    fn pushFreshFunctionFacts(self: *Analyzer) FunctionFactsSnapshot {
        const snapshot = FunctionFactsSnapshot{
            .analyzer = self,
            .string_bindings = self.string_bindings,
            .local_variables = self.local_variables,
            .object_role_bindings = self.object_role_bindings,
            .property_target_bindings = self.property_target_bindings,
            .selection_read_bindings = self.selection_read_bindings,
        };
        self.string_bindings = std.StringHashMap([]const u8).init(self.allocator);
        self.local_variables = std.StringHashMap(void).init(self.allocator);
        self.object_role_bindings = std.StringHashMap([]const u8).init(self.allocator);
        self.property_target_bindings = std.StringHashMap(PropertyTarget).init(self.allocator);
        self.selection_read_bindings = std.StringHashMap(std.ArrayList(Resource)).init(self.allocator);
        return snapshot;
    }

    const LocalFactsSnapshot = struct {
        analyzer: *Analyzer,
        local_variables: std.StringHashMap(void),
        object_role_bindings: std.StringHashMap([]const u8),
        property_target_bindings: std.StringHashMap(PropertyTarget),
        selection_read_bindings: std.StringHashMap(std.ArrayList(Resource)),

        fn restore(self: *LocalFactsSnapshot) void {
            var local_snapshot = self.analyzer.local_variables;
            self.analyzer.local_variables = self.local_variables;
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
        var local_clone = try self.cloneLocalVariables();
        errdefer local_clone.deinit();
        var role_clone = try self.cloneObjectRoles();
        errdefer role_clone.deinit();
        var property_target_clone = try self.clonePropertyTargets();
        errdefer property_target_clone.deinit();
        var selection_clone = try self.cloneSelectionReadBindings();
        errdefer self.deinitSelectionReadBindings(&selection_clone);

        const snapshot = LocalFactsSnapshot{
            .analyzer = self,
            .local_variables = self.local_variables,
            .object_role_bindings = self.object_role_bindings,
            .property_target_bindings = self.property_target_bindings,
            .selection_read_bindings = self.selection_read_bindings,
        };
        self.local_variables = local_clone;
        self.object_role_bindings = role_clone;
        self.property_target_bindings = property_target_clone;
        self.selection_read_bindings = selection_clone;
        return snapshot;
    }

    fn cloneLocalVariables(self: *Analyzer) !std.StringHashMap(void) {
        var clone = std.StringHashMap(void).init(self.allocator);
        errdefer clone.deinit();
        try clone.ensureTotalCapacity(@intCast(self.local_variables.count()));
        var iter = self.local_variables.iterator();
        while (iter.next()) |entry| try clone.put(entry.key_ptr.*, {});
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

    const CallbackFactsSnapshot = struct {
        analyzer: *Analyzer,
        string_bindings: std.StringHashMap([]const u8),
        object_role_bindings: std.StringHashMap([]const u8),
        property_target_bindings: std.StringHashMap(PropertyTarget),

        fn restore(self: *CallbackFactsSnapshot) void {
            var string_snapshot = self.analyzer.string_bindings;
            self.analyzer.string_bindings = self.string_bindings;
            string_snapshot.deinit();

            var role_snapshot = self.analyzer.object_role_bindings;
            self.analyzer.object_role_bindings = self.object_role_bindings;
            role_snapshot.deinit();

            var property_target_snapshot = self.analyzer.property_target_bindings;
            self.analyzer.property_target_bindings = self.property_target_bindings;
            property_target_snapshot.deinit();
        }
    };

    fn pushCallbackFacts(self: *Analyzer) !CallbackFactsSnapshot {
        var string_clone = try self.cloneStringBindings();
        errdefer string_clone.deinit();
        var role_clone = try self.cloneObjectRoles();
        errdefer role_clone.deinit();
        var property_target_clone = try self.clonePropertyTargets();
        errdefer property_target_clone.deinit();

        const snapshot = CallbackFactsSnapshot{
            .analyzer = self,
            .string_bindings = self.string_bindings,
            .object_role_bindings = self.object_role_bindings,
            .property_target_bindings = self.property_target_bindings,
        };
        self.string_bindings = string_clone;
        self.object_role_bindings = role_clone;
        self.property_target_bindings = property_target_clone;
        return snapshot;
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

    fn applyCallbackArgBindings(
        self: *Analyzer,
        params: []const ast.ParamDecl,
        bindings: []const CallbackArgBinding,
    ) !void {
        for (params, 0..) |param, index| {
            const binding = if (index < bindings.len) bindings[index] else CallbackArgBinding{};
            if (binding.string_literal) |value| {
                try self.string_bindings.put(param.name, value);
            } else {
                _ = self.string_bindings.remove(param.name);
            }
            if (binding.object_role) |role_name| {
                try self.object_role_bindings.put(param.name, role_name);
            } else {
                _ = self.object_role_bindings.remove(param.name);
            }
            if (binding.property_target) |target| {
                try self.property_target_bindings.put(param.name, target);
            } else {
                _ = self.property_target_bindings.remove(param.name);
            }
        }
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
                try summary.addWrite(Resource.makeObjects(core.GroupRole));
                summary.writes_layout_input = true;
            },
            .new_page => {
                try summary.addWrite(Resource.makePages(null));
                summary.writes_layout_input = true;
            },
            .equal, .constraints => {
                summary.writes_layout_input = true;
            },
            else => {},
        }
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
                try summary.addRead(Resource.makeProperty(owner, null));
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
                try summary.addWrite(Resource.makeProperty(propertyOwnerFromArgFacts(arg_facts, 0), "repr"));
                summary.writes_layout_input = true;
            },
            .group => {
                try summary.addWrite(Resource.makeObjects(core.GroupRole));
                summary.writes_layout_input = true;
            },
            .new_page => {
                try summary.addWrite(Resource.makePages(null));
                summary.writes_layout_input = true;
            },
            .new => {
                try summary.addWrite(Resource.makeObjects(literalStringFromArgFacts(arg_facts, 1)));
                summary.writes_layout_input = true;
            },
            .place_on => {
                try summary.addWrite(Resource.makeObjects(objectRoleFromArgFacts(arg_facts, 1)));
                summary.writes_layout_input = true;
            },
            .set_prop => {
                try summary.addWrite(Resource.makeProperty(
                    propertyOwnerFromArgFacts(arg_facts, 0),
                    literalStringFromArgFacts(arg_facts, 1),
                ));
                summary.writes_layout_input = true;
            },
            .equal, .constraints => {
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
            .place_on,
            .set_prop,
            => true,
            else => false,
        };
    }

    fn functionCallbackCall(
        self: *Analyzer,
        key: core.FunctionKey,
        module_id: core.SourceModuleId,
        func: ast.FunctionDecl,
        bindings: []const CallbackArgBinding,
        initial_summary: AccessSummary,
    ) anyerror!AccessSummary {
        var summary = initial_summary;
        errdefer summary.deinit();
        if (self.visiting.contains(key)) return summary;

        const cache_key = if (self.run_cache != null)
            try buildFunctionCallbackSummaryKey(self.allocator, key, self.variable_scope, bindings)
        else
            null;
        defer if (cache_key) |owned| self.allocator.free(owned);
        if (cache_key) |owned| {
            if (try self.run_cache.?.cachedSummary(owned, self.allocator)) |cached_body| {
                var body = cached_body;
                defer body.deinit();
                try summary.merge(body);
                return summary;
            }
        }

        try self.visiting.put(key, {});
        defer _ = self.visiting.remove(key);

        var facts = self.pushFreshFunctionFacts();
        defer facts.restore();
        try self.applyCallbackArgBindings(func.params.items, bindings);
        try self.bindLocalParams(func.params.items);

        const previous = self.sema;
        self.sema = self.sema.forModule(module_id);
        defer self.sema = previous;

        var body = try self.analyzeStatements(func.statements.items, .local);
        defer body.deinit();
        if (cache_key) |owned| try self.run_cache.?.putSummary(owned, body);
        try summary.merge(body);
        return summary;
    }

    fn lambdaCallbackCall(self: *Analyzer, lambda: ast.LambdaExpr, bindings: []const CallbackArgBinding) !AccessSummary {
        var facts = try self.pushCallbackFacts();
        defer facts.restore();
        try self.applyCallbackArgBindings(lambda.params.items, bindings);
        return try self.withLambdaLocals(lambda);
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
            switch (call.args.items[callback_spec.function_arg_index]) {
                .ident => |callback_ident| {
                    const callback_name = callback_ident.name;
                    if (try self.resolvedConst(ast.CallableName.bare(callback_name))) |callback| {
                        callback_summary = try self.constValue(callback);
                    } else if (try self.resolvedFunction(ast.CallableName.bare(callback_name))) |callback| {
                        var initial_summary = AccessSummary.init(self.allocator);
                        errdefer initial_summary.deinit();
                        callback_summary = try self.functionCallbackCall(
                            callback.key,
                            callback.module_id,
                            callback.decl,
                            callback_arg_bindings.items,
                            initial_summary,
                        );
                    }
                },
                .lambda => |lambda| {
                    callback_summary = try self.lambdaCallbackCall(lambda, callback_arg_bindings.items);
                },
                else => {
                    var callback_expr = try self.analyzeExpr(call.args.items[callback_spec.function_arg_index]);
                    defer callback_expr.deinit();
                    try callback_summary.merge(callback_expr);
                },
            }
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
            .page_objects_by_role,
            .document_objects_by_role,
            => try summary.addSelectionRead(Resource.makeObjects(literalStringFromArgFacts(arg_facts, 2))),
            .children,
            .descendants,
            .self_object,
            => try summary.addSelectionRead(Resource.makeObjects(null)),
            .previous_page,
            .parent_page,
            => try summary.addRead(Resource.makePages(null)),
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
                if (try self.resolvedConst(ast.CallableName.bare(name))) |resolved| {
                    break :blk try self.propertyTargetConst(resolved);
                }
                break :blk null;
            },
            .call => |call| try self.propertyTargetCall(call),
            .optional_check => |check| try self.propertyTargetExpr(check.target.*),
            .coalesce => |coalesce| blk: {
                const target = try self.propertyTargetExpr(coalesce.target.*);
                const fallback = try self.propertyTargetExpr(coalesce.fallback.*);
                break :blk mergePropertyTargets(target, fallback);
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
                .new => PropertyTarget.object(self.objectClassForRole(try literalStringArg(self, call, 1))),
                .group => PropertyTarget.object(self.objectClassForRole(core.GroupRole)),
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
                .selection_union, .selection_intersection, .selection_difference => try self.propertyTargetSelectionAlgebra(call),
                .select => try self.propertyTargetSelect(call),
                else => if (primitive.result_type) |ty| self.propertyTargetForType(ty) else null,
            },
            .function => |resolved| try self.propertyTargetFunctionCall(resolved, call),
        };
    }

    fn propertyTargetSelectionAlgebra(self: *Analyzer, call: ast.CallExpr) !?PropertyTarget {
        if (call.args.items.len == 0) return PropertyTarget.any();
        var target = try self.propertyTargetExpr(call.args.items[0]);
        for (call.args.items[1..]) |arg| {
            target = mergePropertyTargets(target, try self.propertyTargetExpr(arg));
        }
        return target orelse PropertyTarget.any();
    }

    fn propertyTargetSelect(self: *Analyzer, call: ast.CallExpr) !?PropertyTarget {
        const query_name = (try literalStringArg(self, call, 1)) orelse return PropertyTarget.any();
        const query = registry.lookupQueryOp(query_name) orelse return PropertyTarget.any();
        return switch (query.op) {
            .document_pages, .previous_page, .parent_page => PropertyTarget.page(),
            .page_objects_by_role,
            .document_objects_by_role,
            => PropertyTarget.object(self.objectClassForRole(try literalStringArg(self, call, 2))),
            .children, .descendants, .self_object => if (call.args.items.len > 0)
                (try self.propertyTargetExpr(call.args.items[0])) orelse PropertyTarget.any()
            else
                PropertyTarget.any(),
        };
    }

    fn propertyTargetConst(self: *Analyzer, resolved: semantic_env.ResolvedConst) anyerror!?PropertyTarget {
        if (self.visiting.contains(resolved.key)) return null;
        try self.visiting.put(resolved.key, {});
        defer _ = self.visiting.remove(resolved.key);

        var state = self.pushFreshFunctionFacts();
        defer state.restore();

        const previous = self.sema;
        self.sema = self.sema.forModule(resolved.module_id);
        defer self.sema = previous;

        return try self.propertyTargetExpr(resolved.decl.value);
    }

    fn propertyTargetFunctionCall(
        self: *Analyzer,
        resolved: semantic_env.ResolvedFunction,
        call: ast.CallExpr,
    ) anyerror!?PropertyTarget {
        const fallback = self.propertyTargetForType(resolved.decl.result_type);
        if (self.visiting.contains(resolved.key)) return fallback;
        try self.visiting.put(resolved.key, {});
        defer _ = self.visiting.remove(resolved.key);

        var arg_facts = try self.collectStaticCallArgFacts(call);
        defer arg_facts.deinit(self.allocator);
        var facts = self.pushFreshFunctionFacts();
        defer facts.restore();
        try self.bindFunctionParamsFromStaticFacts(resolved.decl, arg_facts.items);

        const previous = self.sema;
        self.sema = self.sema.forModule(resolved.module_id);
        defer self.sema = previous;

        for (resolved.decl.statements.items) |stmt| {
            switch (stmt.kind) {
                .return_expr => |expr| return (try self.propertyTargetExpr(expr)) orelse fallback,
                .return_void => return null,
                else => {
                    var nested = try self.analyzeStatement(stmt, .local);
                    nested.deinit();
                },
            }
        }
        return fallback;
    }

    fn propertyTargetForType(self: *Analyzer, ty: ast.Type) ?PropertyTarget {
        return switch (ty.kind) {
            .document => PropertyTarget.document(),
            .page => PropertyTarget.page(),
            .object => PropertyTarget.object(ty.class_name),
            .selection => switch (ty.param) {
                .page => PropertyTarget.page(),
                .object, .any => PropertyTarget.object(ty.param_class_name),
                else => null,
            },
            .optional => if (ty.optional_child) |child| self.propertyTargetForType(child.*) else null,
            else => null,
        };
    }

    fn objectClassForRole(self: *Analyzer, role_name: ?[]const u8) ?[]const u8 {
        const name = role_name orelse return null;
        return self.sema.roleClass(name) orelse name;
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
                if (try self.resolvedConst(ast.CallableName.bare(name))) |resolved| {
                    break :blk try self.objectRoleConst(resolved);
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
        if (self.visiting.contains(resolved.key)) return null;
        try self.visiting.put(resolved.key, {});
        defer _ = self.visiting.remove(resolved.key);

        var arg_facts = try self.collectStringRoleArgFacts(call);
        defer arg_facts.deinit(self.allocator);
        var facts = self.pushFreshFunctionFacts();
        defer facts.restore();
        try self.bindFunctionParamsFromStringRoleFacts(resolved.decl, arg_facts.items);

        const previous = self.sema;
        self.sema = self.sema.forModule(resolved.module_id);
        defer self.sema = previous;

        for (resolved.decl.statements.items) |stmt| {
            switch (stmt.kind) {
                .return_expr => |expr| return try self.objectRoleExpr(expr),
                .return_void => return null,
                else => {
                    var nested = try self.analyzeStatement(stmt, .local);
                    nested.deinit();
                },
            }
        }
        return null;
    }
};

fn buildConstSummaryKey(
    allocator: std.mem.Allocator,
    key: core.FunctionKey,
    variable_scope: ResourceScope,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendKeyBytes(allocator, &out, "const");
    try appendFunctionKey(allocator, &out, key);
    try appendResourceScopeKey(allocator, &out, variable_scope);
    return try out.toOwnedSlice(allocator);
}

fn buildFunctionCallSummaryKey(
    allocator: std.mem.Allocator,
    key: core.FunctionKey,
    variable_scope: ResourceScope,
    facts: []const Analyzer.CallArgFacts,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendKeyBytes(allocator, &out, "call");
    try appendFunctionKey(allocator, &out, key);
    try appendResourceScopeKey(allocator, &out, variable_scope);
    try appendKeyInt(allocator, &out, facts.len);
    for (facts) |fact| {
        try appendOptionalBytesKey(allocator, &out, fact.string_literal);
        try appendOptionalBytesKey(allocator, &out, fact.object_role);
        try appendOptionalPropertyTargetKey(allocator, &out, fact.property_target);
        try appendResourceListKey(allocator, &out, fact.summary.selection_reads.items);
    }
    return try out.toOwnedSlice(allocator);
}

fn buildFunctionCallbackSummaryKey(
    allocator: std.mem.Allocator,
    key: core.FunctionKey,
    variable_scope: ResourceScope,
    bindings: []const CallbackArgBinding,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendKeyBytes(allocator, &out, "callback");
    try appendFunctionKey(allocator, &out, key);
    try appendResourceScopeKey(allocator, &out, variable_scope);
    try appendKeyInt(allocator, &out, bindings.len);
    for (bindings) |binding| {
        try appendOptionalBytesKey(allocator, &out, binding.string_literal);
        try appendOptionalBytesKey(allocator, &out, binding.object_role);
        try appendOptionalPropertyTargetKey(allocator, &out, binding.property_target);
    }
    return try out.toOwnedSlice(allocator);
}

fn appendFunctionKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: core.FunctionKey) !void {
    try appendKeyInt(allocator, out, key.module_id);
    try appendKeyBytes(allocator, out, key.name);
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
            try appendOptionalBytesKey(allocator, out, role_name);
        },
        .property => |property| {
            try out.append(allocator, 'p');
            try appendPropertyOwnerKey(allocator, out, property.owner);
            try appendPropertyKeyKey(allocator, out, property.key);
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
            try appendOptionalBytesKey(allocator, out, object_owner.class_name);
            if (object_owner.identity) |identity| {
                try out.append(allocator, 'i');
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

fn mergePropertyTargets(left: ?PropertyTarget, right: ?PropertyTarget) ?PropertyTarget {
    if (left == null) return right;
    if (right == null) return left;
    return .{ .owner = left.?.owner.merge(right.?.owner) };
}

fn literalStringArg(self: *Analyzer, call: ast.CallExpr, index: usize) !?[]const u8 {
    if (index >= call.args.items.len) return null;
    return try literalStringExpr(self, call.args.items[index]);
}

fn literalStringExpr(self: *Analyzer, expr: ast.Expr) anyerror!?[]const u8 {
    return switch (expr) {
        .string => |literal| literal.text,
        .color => |value| value,
        .ident => |ident| self.string_bindings.get(ident.name),
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
    return try ownString(self, try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ left, right }));
}

fn literalStringFunctionCall(
    self: *Analyzer,
    resolved: semantic_env.ResolvedFunction,
    call: ast.CallExpr,
) !?[]const u8 {
    if (self.visiting.contains(resolved.key)) return null;
    try self.visiting.put(resolved.key, {});
    defer _ = self.visiting.remove(resolved.key);

    var arg_facts = try self.collectStringArgFacts(call);
    defer arg_facts.deinit(self.allocator);
    var facts = self.pushFreshFunctionFacts();
    defer facts.restore();
    try self.bindFunctionParamsFromStringFacts(resolved.decl, arg_facts.items);

    const previous = self.sema;
    self.sema = self.sema.forModule(resolved.module_id);
    defer self.sema = previous;

    for (resolved.decl.statements.items) |stmt| {
        switch (stmt.kind) {
            .return_expr => |expr| return try literalStringExpr(self, expr),
            .return_void => return null,
            else => {},
        }
    }
    return null;
}

fn ownString(self: *Analyzer, value: []const u8) ![]const u8 {
    errdefer self.allocator.free(value);
    try self.owned_strings.append(self.allocator, value);
    return value;
}

pub fn callableNamePlacesObjects(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "!");
}
