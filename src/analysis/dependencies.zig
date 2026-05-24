const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const registry = @import("../language/registry.zig");
const semantic_env = @import("../language/env.zig");

const SemanticEnv = semantic_env.SemanticEnv;

pub const ResourceKind = enum {
    graph_pages,
    graph_objects,
    property,
    content,
    metadata,
    constraints,
    render_env,
    diagnostics,
    layout,
    asset,
};

pub const Resource = struct {
    kind: ResourceKind,
    key: ?[]const u8 = null,

    pub fn intersects(self: Resource, other: Resource) bool {
        if (self.kind != other.kind) return false;
        if (self.key == null or other.key == null) return true;
        return std.mem.eql(u8, self.key.?, other.key.?);
    }

    pub fn graphPages() Resource {
        return .{ .kind = .graph_pages };
    }

    pub fn graphObjects(role_name: ?[]const u8) Resource {
        return .{ .kind = .graph_objects, .key = role_name };
    }

    pub fn property(key: ?[]const u8) Resource {
        return .{ .kind = .property, .key = key };
    }

    pub fn content(role_name: ?[]const u8) Resource {
        return .{ .kind = .content, .key = role_name };
    }
};

pub const AccessSummary = struct {
    allocator: std.mem.Allocator,
    reads: std.ArrayList(Resource),
    writes: std.ArrayList(Resource),
    selection_reads: std.ArrayList(Resource),
    reads_layout: bool = false,
    writes_layout_input: bool = false,
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
        if (self.invalid_selection_mutation == null) self.invalid_selection_mutation = other.invalid_selection_mutation;
    }
};

fn appendUnique(allocator: std.mem.Allocator, list: *std.ArrayList(Resource), resource: Resource) !void {
    for (list.items) |existing| {
        if (existing.intersects(resource) and resource.intersects(existing)) return;
    }
    try list.append(allocator, resource);
}

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    visiting: std.StringHashMap(void),
    string_bindings: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, functions: *const std.StringHashMap(ast.FunctionDecl)) Analyzer {
        return .{
            .allocator = allocator,
            .functions = functions,
            .visiting = std.StringHashMap(void).init(allocator),
            .string_bindings = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.string_bindings.deinit();
        self.visiting.deinit();
    }

    pub fn documentStatements(self: *Analyzer, items: []const ast.Statement) anyerror!AccessSummary {
        return try self.analyzeStatements(items);
    }

    pub fn page(self: *Analyzer, page_decl: ast.PageDecl) anyerror!AccessSummary {
        var summary = try self.analyzeStatements(page_decl.statements.items);
        errdefer summary.deinit();
        summary.writes_layout_input = true;
        return summary;
    }

    pub fn statement(self: *Analyzer, stmt: ast.Statement) anyerror!AccessSummary {
        return try self.analyzeStatement(stmt);
    }

    fn analyzeStatements(self: *Analyzer, items: []const ast.Statement) anyerror!AccessSummary {
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        for (items) |stmt| {
            var nested = try self.analyzeStatement(stmt);
            defer nested.deinit();
            try summary.merge(nested);
        }
        return summary;
    }

    fn analyzeStatement(self: *Analyzer, stmt: ast.Statement) anyerror!AccessSummary {
        var summary = AccessSummary.init(self.allocator);
        errdefer summary.deinit();
        switch (stmt.kind) {
            .let_binding => |binding| {
                var expr = try self.analyzeExpr(binding.expr);
                defer expr.deinit();
                try summary.merge(expr);
            },
            .return_expr => |expr| {
                var nested = try self.analyzeExpr(expr);
                defer nested.deinit();
                try summary.merge(nested);
            },
            .return_void => {},
            .property_set => |property_set| {
                var expr = try self.analyzeExpr(property_set.value);
                defer expr.deinit();
                try summary.merge(expr);
                try summary.addWrite(Resource.property(property_set.property_name));
                summary.writes_layout_input = true;
            },
            .if_stmt => |if_stmt| {
                var condition = try self.analyzeExpr(if_stmt.condition);
                defer condition.deinit();
                try summary.merge(condition);
                var then_summary = try self.analyzeStatements(if_stmt.then_statements.items);
                defer then_summary.deinit();
                try summary.merge(then_summary);
                var else_summary = try self.analyzeStatements(if_stmt.else_statements.items);
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
                try summary.addWrite(.{ .kind = .constraints });
                summary.writes_layout_input = true;
            },
        }
        return summary;
    }

    fn analyzeExpr(self: *Analyzer, value: ast.Expr) anyerror!AccessSummary {
        return switch (value) {
            .ident, .string, .number, .boolean => AccessSummary.init(self.allocator),
            .lambda => |lambda| try self.analyzeExpr(lambda.body.*),
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
            .call => |call| try self.analyzeCall(call),
        };
    }

    fn analyzeCall(self: *Analyzer, call: ast.CallExpr) anyerror!AccessSummary {
        const sema = SemanticEnv.init(null, null, self.functions);
        const descriptor = sema.call(call.name) orelse return try self.callArgs(call);
        return switch (descriptor) {
            .function => |func| try self.functionCall(func, call),
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

    fn functionCall(self: *Analyzer, func: ast.FunctionDecl, call: ast.CallExpr) anyerror!AccessSummary {
        var summary = try self.callArgs(call);
        errdefer summary.deinit();
        if (self.visiting.contains(func.name)) return summary;
        try self.visiting.put(func.name, {});
        defer _ = self.visiting.remove(func.name);

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

        var body = try self.analyzeStatements(func.statements.items);
        defer body.deinit();
        try summary.merge(body);
        return summary;
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
                if (literalStringExpr(self, call.args.items[index])) |value| {
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
        switch (descriptor.op) {
            .select => try self.applySelectSummary(&summary, call),
            .page_index, .page_count => try summary.addRead(Resource.graphPages()),
            .frame_x, .frame_y, .frame_width, .frame_height => {
                try summary.addRead(.{ .kind = .layout });
                summary.reads_layout = true;
            },
            .content => try summary.addRead(Resource.content(null)),
            .emit_metadata => try summary.addWrite(.{ .kind = .metadata }),
            .metadata_in_document, .metadata_on_page, .metadata_content, .metadata_kind, .metadata_page => try summary.addRead(.{ .kind = .metadata }),
            .prop, .has_prop, .prop_eq => try summary.addRead(Resource.property(literalStringArg(self, call, 1))),
            .set_content => {
                try summary.addWrite(Resource.content(null));
                summary.writes_layout_input = true;
            },
            .group => {
                try summary.addWrite(Resource.graphObjects("group"));
                summary.writes_layout_input = true;
            },
            .new_page => {
                try summary.addWrite(Resource.graphPages());
                summary.writes_layout_input = true;
            },
            .new => {
                try summary.addWrite(Resource.graphObjects(literalStringArg(self, call, 2)));
                try summary.addWrite(Resource.content(literalStringArg(self, call, 2)));
                summary.writes_layout_input = true;
            },
            .new_group => {
                try summary.addWrite(Resource.graphObjects("group"));
                summary.writes_layout_input = true;
            },
            .set_prop => {
                try summary.addWrite(Resource.property(literalStringArg(self, call, 1)));
                summary.writes_layout_input = true;
            },
            .extend_render_env => try summary.addWrite(.{ .kind = .render_env }),
            .equal, .constraints => {
                try summary.addWrite(.{ .kind = .constraints });
                summary.writes_layout_input = true;
            },
            .report_error, .report_warning => try summary.addWrite(.{ .kind = .diagnostics }),
            .require_asset_exists => {
                try summary.addRead(.{ .kind = .asset });
                try summary.addWrite(.{ .kind = .diagnostics });
            },
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
                    if (self.functions.get(callback_name)) |callback| {
                        callback_summary = try self.functionCall(callback, .{
                            .name = callback_name,
                            .args = .empty,
                        });
                    }
                },
                .lambda => |lambda| {
                    callback_summary = try self.analyzeExpr(lambda.body.*);
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
        const query_name = literalStringArg(self, call, 1) orelse {
            try summary.addRead(Resource.graphObjects(null));
            try summary.addSelectionRead(Resource.graphObjects(null));
            return;
        };
        if (std.mem.eql(u8, query_name, "document_pages")) {
            try summary.addSelectionRead(Resource.graphPages());
        } else if (std.mem.eql(u8, query_name, "page_objects_by_role") or
            std.mem.eql(u8, query_name, "document_objects_by_role"))
        {
            try summary.addSelectionRead(Resource.graphObjects(literalStringArg(self, call, 2)));
        } else if (std.mem.eql(u8, query_name, "children") or
            std.mem.eql(u8, query_name, "descendants") or
            std.mem.eql(u8, query_name, "self_object"))
        {
            try summary.addSelectionRead(Resource.graphObjects(null));
        } else if (std.mem.eql(u8, query_name, "previous_page") or
            std.mem.eql(u8, query_name, "parent_page"))
        {
            try summary.addRead(Resource.graphPages());
        } else {
            try summary.addRead(Resource.graphObjects(null));
        }
    }
};

fn literalStringArg(self: *Analyzer, call: ast.CallExpr, index: usize) ?[]const u8 {
    if (index >= call.args.items.len) return null;
    return literalStringExpr(self, call.args.items[index]);
}

fn literalStringExpr(self: *Analyzer, expr: ast.Expr) ?[]const u8 {
    return switch (expr) {
        .string => |value| value,
        .ident => |name| self.string_bindings.get(name),
        else => null,
    };
}
