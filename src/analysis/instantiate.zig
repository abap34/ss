const std = @import("std");
const ast = @import("ast");

/// Transforms an owned declaration while preserving source locations. Expression IDs
/// identify the resulting AST occurrences independently of their source spans.
pub const Transform = struct {
    allocator: std.mem.Allocator,
    next_expression_id: *u64,
    substitutions: []const ast.Type.Substitution = &.{},

    pub fn module(self: *Transform, value: *ast.Module) !void {
        for (value.functions.items) |*decl| try self.function(decl);
        for (value.constants.items) |*decl| {
            try self.ty(&decl.value_type);
            try self.expr(&decl.value);
        }
        inline for (.{ value.records.items, value.objects.items, value.object_extensions.items }) |decls| {
            for (decls) |*decl| for (decl.fields.items) |*field| {
                try self.ty(&field.value_type);
                if (field.default_value) |default| try self.expr(default);
            };
        }
        try self.statements(value.document_statements.items);
        for (value.pages.items) |*page| try self.statements(page.statements.items);
    }

    pub fn record(self: *Transform, value: *ast.RecordDecl) !void {
        for (value.fields.items) |*field| {
            try self.ty(&field.value_type);
            if (field.default_value) |default| try self.expr(default);
        }
    }

    pub fn function(self: *Transform, value: *ast.FunctionDecl) !void {
        for (value.params.items) |*parameter| try self.param(parameter);
        try self.ty(&value.result_type);
        try self.statements(value.statements.items);
    }

    fn param(self: *Transform, value: *ast.ParamDecl) !void {
        try self.ty(&value.ty);
        if (value.default_value) |default| try self.expr(default);
    }

    fn ty(self: *Transform, value: *ast.Type) !void {
        if (self.substitutions.len == 0) return;
        const substituted = try value.substitute(self.allocator, self.substitutions);
        value.deinit(self.allocator);
        value.* = substituted;
    }

    fn statements(self: *Transform, values: []ast.Statement) anyerror!void {
        for (values) |*statement| switch (statement.kind) {
            .let_binding => |*binding| {
                if (binding.type_annotation) |*annotation| try self.ty(annotation);
                try self.expr(&binding.expr);
            },
            .return_expr, .expr_stmt => |*value| try self.expr(value),
            .if_stmt => |*branch| {
                try self.expr(&branch.condition);
                try self.statements(branch.then_statements.items);
                try self.statements(branch.else_statements.items);
            },
            .property_set => |*property| {
                try self.expr(&property.target);
                try self.expr(&property.value);
            },
            .constrain => |*constraint| if (constraint.offset) |*offset| try self.expr(offset),
            .hole, .return_void => {},
        };
    }

    fn expr(self: *Transform, value: *ast.Expr) anyerror!void {
        switch (value.*) {
            .call => |*call| {
                call.callee.call_id = self.next_expression_id.*;
                self.next_expression_id.* += 1;
                for (call.type_args.items) |*argument| try self.ty(argument);
                for (call.args.items) |*argument| try self.expr(argument);
            },
            .apply => |*call| {
                try self.expr(call.callee);
                for (call.args.items) |*argument| try self.expr(argument);
            },
            .lambda => |*lambda| {
                lambda.analysis_id = self.next_expression_id.*;
                self.next_expression_id.* += 1;
                for (lambda.params.items) |*parameter| try self.param(parameter);
                try self.expr(lambda.body);
            },
            .record => |*record_value| {
                record_value.analysis_id = self.next_expression_id.*;
                self.next_expression_id.* += 1;
                for (record_value.type_args.items) |*argument| try self.ty(argument);
                for (record_value.fields.items) |*field| try self.expr(&field.value);
            },
            .record_update => |*update| {
                try self.expr(update.target);
                for (update.fields.items) |*field| try self.expr(&field.value);
            },
            .member => |*member| try self.expr(member.target),
            .optional_check => |*check| try self.expr(check.target),
            .coalesce => |*coalesce| {
                try self.expr(coalesce.target);
                try self.expr(coalesce.fallback);
            },
            .ident, .hole, .string, .color, .number, .boolean, .none, .enum_case => {},
        }
    }
};
