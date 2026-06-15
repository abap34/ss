const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const registry = @import("../language/registry.zig");
const semantic_env = @import("../language/env.zig");
const names = @import("../language/names.zig");

const SemanticEnv = semantic_env.SemanticEnv;
const FunctionVisitSet = std.HashMap(core.FunctionKey, void, core.FunctionKeyContext, std.hash_map.default_max_load_percentage);

pub const ResourceKind = enum {
    variable,
    objects,
    property,
    page_index,
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

pub const Resource = struct {
    kind: ResourceKind,
    scope: ResourceScope = .any,
    owner: ?[]const u8 = null,
    key: ?[]const u8 = null,

    pub fn intersects(self: Resource, other: Resource) bool {
        if (self.kind != other.kind) return false;
        if (!self.scope.intersects(other.scope)) return false;
        if (self.owner != null and other.owner != null and !std.mem.eql(u8, self.owner.?, other.owner.?)) return false;
        if (self.key != null and other.key != null and !std.mem.eql(u8, self.key.?, other.key.?)) return false;
        return true;
    }

    pub fn variable(scope: ResourceScope, name: []const u8) Resource {
        return .{ .kind = .variable, .scope = scope, .key = name };
    }

    pub fn objects(role_name: ?[]const u8) Resource {
        return .{ .kind = .objects, .key = role_name };
    }

    pub fn property(owner: ?[]const u8, key: ?[]const u8) Resource {
        return .{ .kind = .property, .owner = owner, .key = key };
    }

    pub fn pageIndex(page_id: ?core.NodeId) Resource {
        return .{
            .kind = .page_index,
            .scope = if (page_id) |id| .{ .page = id } else .any,
        };
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
        for (other.reads.items) |resource| try self.addRead(resource);
        for (other.writes.items) |resource| try self.addWrite(resource);
        for (other.selection_reads.items) |resource| try self.addSelectionRead(resource);
        self.reads_layout = self.reads_layout or other.reads_layout;
        self.writes_layout_input = self.writes_layout_input or other.writes_layout_input;
        self.places_objects = self.places_objects or other.places_objects;
        if (self.invalid_selection_mutation == null) self.invalid_selection_mutation = other.invalid_selection_mutation;
    }
};

pub fn formatAccessSummary(allocator: std.mem.Allocator, summary: AccessSummary) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "DependencyQuery:");
    var wrote_item = false;
    for (summary.reads.items) |resource| {
        try appendAccessLine(allocator, &out, "read", resource);
        wrote_item = true;
    }
    for (summary.writes.items) |resource| {
        try appendAccessLine(allocator, &out, "write", resource);
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

fn appendAccessLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), access: []const u8, resource: Resource) !void {
    try out.appendSlice(allocator, "\n  ");
    try out.appendSlice(allocator, access);
    try out.appendSlice(allocator, " ");
    try appendResource(allocator, out, resource);
}

fn appendFlagLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), flag: []const u8) !void {
    try out.appendSlice(allocator, "\n  flag ");
    try out.appendSlice(allocator, flag);
}

fn appendResource(allocator: std.mem.Allocator, out: *std.ArrayList(u8), resource: Resource) !void {
    switch (resource.kind) {
        .variable => {
            try out.appendSlice(allocator, "Variable(");
            try appendScope(allocator, out, resource.scope);
            try out.appendSlice(allocator, ", ");
            try appendOptionalName(allocator, out, resource.key);
            try out.append(allocator, ')');
        },
        .objects => {
            try out.appendSlice(allocator, "Objects(");
            try appendOptionalName(allocator, out, resource.key);
            try out.append(allocator, ')');
        },
        .property => {
            try out.appendSlice(allocator, "Property(");
            try appendOptionalName(allocator, out, resource.owner);
            try out.appendSlice(allocator, ", ");
            try appendOptionalName(allocator, out, resource.key);
            try out.append(allocator, ')');
        },
        .page_index => {
            try out.appendSlice(allocator, "PageIndex(");
            try appendScope(allocator, out, resource.scope);
            try out.append(allocator, ')');
        },
    }
}

fn appendScope(allocator: std.mem.Allocator, out: *std.ArrayList(u8), scope: ResourceScope) !void {
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

fn appendOptionalName(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: ?[]const u8) !void {
    try out.appendSlice(allocator, value orelse "*");
}

fn appendUnique(allocator: std.mem.Allocator, list: *std.ArrayList(Resource), resource: Resource) !void {
    for (list.items) |existing| {
        if (existing.intersects(resource) and resource.intersects(existing)) return;
    }
    try list.append(allocator, resource);
}

const LetPolicy = enum {
    scheduled,
    local,
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    sema: SemanticEnv,
    variable_scope: ResourceScope,
    visiting: FunctionVisitSet,
    string_bindings: std.StringHashMap([]const u8),
    owned_strings: std.ArrayList([]const u8),
    local_variables: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, sema: *const SemanticEnv) Analyzer {
        return initWithScope(allocator, sema, .{ .document = sema.module_id });
    }

    pub fn initWithScope(allocator: std.mem.Allocator, sema: *const SemanticEnv, variable_scope: ResourceScope) Analyzer {
        return .{
            .allocator = allocator,
            .sema = sema.*,
            .variable_scope = variable_scope,
            .visiting = FunctionVisitSet.init(allocator),
            .string_bindings = std.StringHashMap([]const u8).init(allocator),
            .owned_strings = .empty,
            .local_variables = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.local_variables.deinit();
        for (self.owned_strings.items) |value| self.allocator.free(value);
        self.owned_strings.deinit(self.allocator);
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
            .let_binding => |binding| {
                var expr = try self.analyzeExpr(binding.expr);
                defer expr.deinit();
                try summary.merge(expr);
                if (!names.isDiscardBindingName(binding.name)) {
                    switch (let_policy) {
                        .scheduled => try summary.addWrite(Resource.variable(self.variable_scope, binding.name)),
                        .local => try self.local_variables.put(binding.name, {}),
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
                try summary.addWrite(Resource.property(null, property_set.property_name));
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
        var snapshot = try self.cloneLocalVariables();
        const current = self.local_variables;
        self.local_variables = snapshot;
        defer {
            snapshot = self.local_variables;
            self.local_variables = current;
            snapshot.deinit();
        }
        return try self.analyzeStatements(statements, .local);
    }

    fn analyzeExpr(self: *Analyzer, value: ast.Expr) anyerror!AccessSummary {
        return switch (value) {
            .ident => |name| blk: {
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
                try summary.addRead(Resource.property(null, member.name));
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
        if (self.local_variables.contains(name)) return;
        if (self.sema.resolvedConst(ast.CallableName.bare(name))) |resolved| {
            var nested = try self.constValue(resolved);
            defer nested.deinit();
            try summary.merge(nested);
            return;
        }
        if (self.sema.resolvedFunction(ast.CallableName.bare(name)) != null) return;
        try summary.addRead(Resource.variable(self.variable_scope, name));
    }

    fn analyzeCall(self: *Analyzer, call: ast.CallExpr) anyerror!AccessSummary {
        if (self.sema.resolvedConst(call.callee)) |resolved| {
            var summary = try self.callArgs(call);
            errdefer summary.deinit();
            var const_summary = try self.constValue(resolved);
            defer const_summary.deinit();
            try summary.merge(const_summary);
            return summary;
        }
        const descriptor = self.sema.callCallee(call.callee) orelse return try self.callArgs(call);
        return switch (descriptor) {
            .function => |resolved| blk: {
                var summary = try self.callArgs(call);
                errdefer summary.deinit();
                if (callableNamePlacesObjects(call.callee.name)) summary.places_objects = true;
                const previous = self.sema;
                self.sema = self.sema.forModule(resolved.module_id);
                defer self.sema = previous;
                break :blk try self.functionCall(resolved.key, resolved.decl, call, summary);
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

    fn functionCall(self: *Analyzer, key: core.FunctionKey, func: ast.FunctionDecl, call: ast.CallExpr, initial_summary: AccessSummary) anyerror!AccessSummary {
        var summary = initial_summary;
        errdefer summary.deinit();
        if (self.visiting.contains(key)) return summary;
        try self.visiting.put(key, {});
        defer _ = self.visiting.remove(key);

        var bindings = std.ArrayList(StringBindingRestore).empty;
        defer {
            var index = bindings.items.len;
            while (index > 0) {
                index -= 1;
                const binding = bindings.items[index];
                if (binding.had_old) {
                    self.string_bindings.put(binding.name, binding.old.?) catch {};
                } else {
                    _ = self.string_bindings.remove(binding.name);
                }
            }
            bindings.deinit(self.allocator);
        }
        try self.bindLiteralStringArgs(func, call, &bindings);

        const body = try self.withFunctionLocals(func, summary);
        summary = AccessSummary.init(self.allocator);
        return body;
    }

    fn constValue(self: *Analyzer, resolved: semantic_env.ResolvedConst) anyerror!AccessSummary {
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        if (self.visiting.contains(resolved.key)) return summary;
        try self.visiting.put(resolved.key, {});
        defer _ = self.visiting.remove(resolved.key);

        const previous = self.sema;
        self.sema = self.sema.forModule(resolved.module_id);
        defer self.sema = previous;

        var nested = try self.analyzeExpr(resolved.decl.value);
        defer nested.deinit();
        try summary.merge(nested);
        return summary;
    }

    fn withFunctionLocals(self: *Analyzer, func: ast.FunctionDecl, initial_summary: AccessSummary) !AccessSummary {
        var summary = initial_summary;
        errdefer summary.deinit();
        var snapshot = try self.cloneLocalVariables();
        const current = self.local_variables;
        self.local_variables = snapshot;
        defer {
            snapshot = self.local_variables;
            self.local_variables = current;
            snapshot.deinit();
        }
        for (func.params.items) |param| try self.local_variables.put(param.name, {});
        var body = try self.analyzeStatements(func.statements.items, .local);
        defer body.deinit();
        try summary.merge(body);
        return summary;
    }

    fn withLambdaLocals(self: *Analyzer, lambda: ast.LambdaExpr) !AccessSummary {
        var snapshot = try self.cloneLocalVariables();
        const current = self.local_variables;
        self.local_variables = snapshot;
        defer {
            snapshot = self.local_variables;
            self.local_variables = current;
            snapshot.deinit();
        }
        for (lambda.params.items) |param| try self.local_variables.put(param.name, {});
        return try self.analyzeExpr(lambda.body.*);
    }

    fn cloneLocalVariables(self: *Analyzer) !std.StringHashMap(void) {
        var clone = std.StringHashMap(void).init(self.allocator);
        errdefer clone.deinit();
        var iter = self.local_variables.iterator();
        while (iter.next()) |entry| try clone.put(entry.key_ptr.*, {});
        return clone;
    }

    const StringBindingRestore = struct {
        name: []const u8,
        had_old: bool,
        old: ?[]const u8,
    };

    fn bindLiteralStringArgs(
        self: *Analyzer,
        func: ast.FunctionDecl,
        call: ast.CallExpr,
        restores: *std.ArrayList(StringBindingRestore),
    ) !void {
        for (func.params.items, 0..) |param, index| {
            const previous = self.string_bindings.get(param.name);
            try restores.append(self.allocator, .{
                .name = param.name,
                .had_old = previous != null,
                .old = previous,
            });
            if (index < call.args.items.len) {
                if (try literalStringExpr(self, call.args.items[index])) |value| {
                    try self.string_bindings.put(param.name, value);
                } else {
                    _ = self.string_bindings.remove(param.name);
                }
            } else {
                _ = self.string_bindings.remove(param.name);
            }
        }
    }

    fn primitiveCall(self: *Analyzer, call: ast.CallExpr, descriptor: registry.PrimitiveDescriptor) anyerror!AccessSummary {
        if (descriptor.callback != null) return try self.primitiveCallbackCall(call, descriptor);

        var summary = try self.callArgs(call);
        errdefer summary.deinit();
        if (descriptor.places_objects) summary.places_objects = true;
        switch (descriptor.op) {
            .select => try self.applySelectSummary(&summary, call),
            .page_index, .page_count => try summary.addRead(Resource.pageIndex(null)),
            .frame_x, .frame_y, .frame_width, .frame_height => {
                summary.reads_layout = true;
            },
            .content => try summary.addRead(Resource.property(null, "content")),
            .prop, .has_prop, .prop_eq => try summary.addRead(Resource.property(null, try literalStringArg(self, call, 1))),
            .set_content => {
                try summary.addWrite(Resource.property(null, "content"));
                summary.writes_layout_input = true;
            },
            .group => {
                try summary.addWrite(Resource.objects("group"));
                summary.writes_layout_input = true;
            },
            .new_page => {
                try summary.addWrite(Resource.pageIndex(null));
                summary.writes_layout_input = true;
            },
            .new => {
                try summary.addWrite(Resource.objects(try literalStringArg(self, call, 1)));
                try summary.addWrite(Resource.property(null, "content"));
                summary.writes_layout_input = true;
            },
            .place_on => {
                try summary.addWrite(Resource.objects(null));
                summary.writes_layout_input = true;
            },
            .set_prop => {
                try summary.addWrite(Resource.property(null, try literalStringArg(self, call, 1)));
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

    fn primitiveCallbackCall(self: *Analyzer, call: ast.CallExpr, descriptor: registry.PrimitiveDescriptor) anyerror!AccessSummary {
        const callback_spec = descriptor.callback orelse unreachable;
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();

        for (call.args.items, 0..) |arg, index| {
            if (index == callback_spec.function_arg_index) continue;
            var arg_summary = try self.analyzeExpr(arg);
            defer arg_summary.deinit();
            try summary.merge(arg_summary);
        }

        var callback_summary = AccessSummary.init(self.allocator);
        defer callback_summary.deinit();
        if (call.args.items.len > callback_spec.function_arg_index) {
            switch (call.args.items[callback_spec.function_arg_index]) {
                .ident => |callback_name| {
                    if (self.sema.resolvedConst(ast.CallableName.bare(callback_name))) |callback| {
                        callback_summary = try self.constValue(callback);
                    } else if (self.sema.resolvedFunction(ast.CallableName.bare(callback_name))) |callback| {
                        var initial_summary = AccessSummary.init(self.allocator);
                        errdefer initial_summary.deinit();
                        const previous = self.sema;
                        self.sema = self.sema.forModule(callback.module_id);
                        defer self.sema = previous;
                        callback_summary = try self.functionCall(callback.key, callback.decl, .{
                            .callee = ast.CallableName.bare(callback_name),
                            .args = .empty,
                        }, initial_summary);
                    }
                },
                .lambda => |lambda| {
                    callback_summary = try self.withLambdaLocals(lambda);
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

    fn applySelectSummary(self: *Analyzer, summary: *AccessSummary, call: ast.CallExpr) !void {
        const query_name = (try literalStringArg(self, call, 1)) orelse {
            try summary.addRead(Resource.objects(null));
            try summary.addSelectionRead(Resource.objects(null));
            return;
        };
        const query = registry.lookupQueryOp(query_name) orelse {
            try summary.addRead(Resource.objects(null));
            return;
        };
        switch (query.op) {
            .document_pages => try summary.addSelectionRead(Resource.pageIndex(null)),
            .page_objects_by_role,
            .document_objects_by_role,
            => try summary.addSelectionRead(Resource.objects(try literalStringArg(self, call, 2))),
            .children,
            .descendants,
            .self_object,
            => try summary.addSelectionRead(Resource.objects(null)),
            .previous_page,
            .parent_page,
            => try summary.addRead(Resource.pageIndex(null)),
        }
    }
};

fn literalStringArg(self: *Analyzer, call: ast.CallExpr, index: usize) !?[]const u8 {
    if (index >= call.args.items.len) return null;
    return try literalStringExpr(self, call.args.items[index]);
}

fn literalStringExpr(self: *Analyzer, expr: ast.Expr) anyerror!?[]const u8 {
    return switch (expr) {
        .string => |value| value,
        .color => |value| value,
        .ident => |name| self.string_bindings.get(name),
        .call => |call| try literalStringCall(self, call),
        else => null,
    };
}

fn literalStringCall(self: *Analyzer, call: ast.CallExpr) anyerror!?[]const u8 {
    const descriptor = self.sema.callCallee(call.callee) orelse return null;
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

    var bindings = std.ArrayList(Analyzer.StringBindingRestore).empty;
    defer {
        var index = bindings.items.len;
        while (index > 0) {
            index -= 1;
            const binding = bindings.items[index];
            if (binding.had_old) {
                self.string_bindings.put(binding.name, binding.old.?) catch {};
            } else {
                _ = self.string_bindings.remove(binding.name);
            }
        }
        bindings.deinit(self.allocator);
    }
    try self.bindLiteralStringArgs(resolved.decl, call, &bindings);

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
