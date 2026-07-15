const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const language_names = @import("../language/names.zig");
const SemanticEnv = @import("../language/env.zig").SemanticEnv;

pub const Generator = struct {
    allocator: std.mem.Allocator,
    sema: SemanticEnv,
    reserved: std.StringHashMap(void),
    statements: std.AutoHashMap(usize, []u8),

    pub fn init(
        allocator: std.mem.Allocator,
        ir: *const core.Ir,
        page: *const ast.PageDecl,
    ) !Generator {
        const root_sema = SemanticEnv.init(ir, null, &ir.functions);
        var generator = Generator{
            .allocator = allocator,
            .sema = root_sema.forModule(ir.project_module_id),
            .reserved = std.StringHashMap(void).init(allocator),
            .statements = std.AutoHashMap(usize, []u8).init(allocator),
        };
        errdefer generator.deinit();
        try generator.reserveStatements(page.statements.items);
        return generator;
    }

    pub fn deinit(self: *Generator) void {
        self.reserved.deinit();
        var names = self.statements.valueIterator();
        while (names.next()) |name| self.allocator.free(name.*);
        self.statements.deinit();
        self.* = undefined;
    }

    pub fn forStatement(
        self: *Generator,
        statement_start: usize,
        raw_callee: []const u8,
    ) ![]const u8 {
        if (self.statements.get(statement_start)) |name| return name;

        const stem = try self.bindingStem(raw_callee);
        defer self.allocator.free(stem);
        var suffix: usize = 1;
        while (true) {
            const candidate = if (suffix == 1)
                try self.allocator.dupe(u8, stem)
            else
                try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ stem, suffix });
            if (self.isReserved(candidate)) {
                self.allocator.free(candidate);
                suffix = std.math.add(usize, suffix, 1) catch return error.BindingNameExhausted;
                continue;
            }
            errdefer self.allocator.free(candidate);
            try self.reserved.put(candidate, {});
            try self.statements.put(statement_start, candidate);
            return candidate;
        }
    }

    fn bindingStem(self: *Generator, raw_callee: []const u8) ![]u8 {
        var end = raw_callee.len;
        while (end > 0 and raw_callee[end - 1] == '!') end -= 1;
        if (end == 0) return self.allocator.dupe(u8, "item");
        return std.fmt.allocPrint(self.allocator, "{s}_item", .{raw_callee[0..end]});
    }

    fn isReserved(self: *const Generator, candidate: []const u8) bool {
        return self.reserved.contains(candidate) or
            self.sema.hasFunction(candidate) or
            self.sema.hasConst(candidate) or
            self.sema.primitive(candidate) != null or
            self.sema.query(candidate) != null or
            language_names.isKeyword(candidate);
    }

    fn reserveName(self: *Generator, name: []const u8) !void {
        if (language_names.isDiscardBindingName(name)) return;
        try self.reserved.put(name, {});
    }

    fn reserveStatements(self: *Generator, statements: []const ast.Statement) !void {
        for (statements) |statement| switch (statement.kind) {
            .hole, .return_void => {},
            .let_binding => |binding| {
                try self.reserveName(binding.name);
                try self.reserveExpr(binding.expr);
            },
            .return_expr => |expr| try self.reserveExpr(expr),
            .constrain => |constraint| {
                if (constraint.offset) |offset| try self.reserveExpr(offset);
            },
            .property_set => |property_set| {
                try self.reserveExpr(property_set.target);
                try self.reserveExpr(property_set.value);
            },
            .if_stmt => |conditional| {
                try self.reserveExpr(conditional.condition);
                try self.reserveStatements(conditional.then_statements.items);
                try self.reserveStatements(conditional.else_statements.items);
            },
            .expr_stmt => |expr| try self.reserveExpr(expr),
        };
    }

    fn reserveExpr(self: *Generator, expr: ast.Expr) !void {
        switch (expr) {
            .call => |call| for (call.args.items) |arg| try self.reserveExpr(arg),
            .apply => |apply| {
                try self.reserveExpr(apply.callee.*);
                for (apply.args.items) |arg| try self.reserveExpr(arg);
            },
            .lambda => |lambda| {
                for (lambda.params.items) |param| {
                    try self.reserveName(param.name);
                    if (param.default_value) |default_value| try self.reserveExpr(default_value.*);
                }
                try self.reserveExpr(lambda.body.*);
            },
            .record => |record| for (record.fields.items) |field| try self.reserveExpr(field.value),
            .record_update => |update| {
                try self.reserveExpr(update.target.*);
                for (update.fields.items) |field| try self.reserveExpr(field.value);
            },
            .member => |member| try self.reserveExpr(member.target.*),
            .optional_check => |check| try self.reserveExpr(check.target.*),
            .coalesce => |coalesce| {
                try self.reserveExpr(coalesce.target.*);
                try self.reserveExpr(coalesce.fallback.*);
            },
            else => {},
        }
    }
};
