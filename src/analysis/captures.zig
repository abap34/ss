const std = @import("std");
const ast = @import("ast");

// Keys and names borrow one syntax generation. Nested lambdas contribute their
// free references to the enclosing lambda, excluding that lambda's parameters.
pub const Index = struct {
    allocator: std.mem.Allocator,
    lambdas: std.AutoHashMap(*const ast.Expr, []const []const u8),

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{ .allocator = allocator, .lambdas = .init(allocator) };
    }

    pub fn deinit(self: *Index) void {
        var values = self.lambdas.valueIterator();
        while (values.next()) |captured| self.allocator.free(captured.*);
        self.lambdas.deinit();
    }

    pub fn names(self: *const Index, lambda: ast.LambdaExpr) ?[]const []const u8 {
        return self.lambdas.get(lambda.body);
    }

    pub fn collectModule(self: *Index, module: ast.Module) !void {
        for (module.constants.items) |constant| try self.expr(constant.value, null);
        for (module.functions.items) |function| {
            for (function.params.items) |param| {
                if (param.default_value) |value| try self.expr(value.*, null);
            }
            try self.statements(function.statements.items);
        }
        for (module.records.items) |record| try self.fields(record.fields.items);
        for (module.objects.items) |object| try self.fields(object.fields.items);
        for (module.object_extensions.items) |extension| try self.fields(extension.fields.items);
        try self.statements(module.document_statements.items);
        for (module.pages.items) |page| try self.statements(page.statements.items);
    }

    fn fields(self: *Index, items: []const ast.ObjectFieldDecl) !void {
        for (items) |field| {
            if (field.default_value) |value| try self.expr(value.*, null);
        }
    }

    fn statements(self: *Index, items: []const ast.Statement) anyerror!void {
        for (items) |statement| {
            switch (statement.kind) {
                .hole, .return_void => {},
                .let_binding => |binding| try self.expr(binding.expr, null),
                .return_expr, .expr_stmt => |value| try self.expr(value, null),
                .constrain => |constraint| if (constraint.offset) |offset| try self.expr(offset, null),
                .property_set => |property| {
                    try self.expr(property.target, null);
                    try self.expr(property.value, null);
                },
                .if_stmt => |branch| {
                    try self.expr(branch.condition, null);
                    try self.statements(branch.then_statements.items);
                    try self.statements(branch.else_statements.items);
                },
            }
        }
    }

    fn lambdaNames(self: *Index, lambda: ast.LambdaExpr) anyerror![]const []const u8 {
        if (self.names(lambda)) |existing| return existing;
        var references = References{
            .allocator = self.allocator,
            .parameters = .init(self.allocator),
            .free = .{},
        };
        defer references.parameters.deinit();
        defer references.free.deinit(self.allocator);
        for (lambda.params.items) |param| try references.parameters.put(param.name, {});
        try self.expr(lambda.body.*, &references);
        const result = try self.allocator.dupe([]const u8, references.free.keys());
        errdefer self.allocator.free(result);
        try self.lambdas.put(lambda.body, result);
        return result;
    }

    fn expr(self: *Index, value: ast.Expr, references: ?*References) anyerror!void {
        switch (value) {
            .ident => |ident| if (references) |refs| try refs.add(ident.name),
            .lambda => |lambda| {
                const nested = try self.lambdaNames(lambda);
                if (references) |refs| for (nested) |name| {
                    try refs.add(name);
                };
            },
            .call => |call| {
                if (!call.callee.isQualified()) {
                    if (references) |refs| try refs.add(call.callee.name);
                }
                for (call.args.items) |arg| try self.expr(arg, references);
            },
            .apply => |apply| {
                try self.expr(apply.callee.*, references);
                for (apply.args.items) |arg| try self.expr(arg, references);
            },
            .record => |record| for (record.fields.items) |field| {
                try self.expr(field.value, references);
            },
            .record_update => |update| {
                try self.expr(update.target.*, references);
                for (update.fields.items) |field| try self.expr(field.value, references);
            },
            .member => |member| try self.expr(member.target.*, references),
            .optional_check => |check| try self.expr(check.target.*, references),
            .coalesce => |coalesce| {
                try self.expr(coalesce.target.*, references);
                try self.expr(coalesce.fallback.*, references);
            },
            .hole, .string, .color, .number, .boolean, .none, .enum_case => {},
        }
    }
};

const References = struct {
    allocator: std.mem.Allocator,
    parameters: std.StringHashMap(void),
    free: std.array_hash_map.String(void),

    fn add(self: *References, name: []const u8) !void {
        if (!self.parameters.contains(name)) try self.free.put(self.allocator, name, {});
    }
};
