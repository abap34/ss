const std = @import("std");
const ast = @import("ast");
const utils = @import("utils");

pub const Failure = struct {
    span: ?ast.Span = null,
    detail: ?[]const u8 = null,
};

pub fn expand(allocator: std.mem.Allocator, module: *ast.Module, failure: *Failure, cancellation: ?utils.Cancellation) !void {
    var needed = false;
    for (module.pages.items) |page| if (page.stages != null and page.stage_index == null) {
        needed = true;
        const stages = page.stages.?;
        if (stages.entries.items.len == 0) {
            failure.* = .{ .span = stages.span };
            return error.EmptyStages;
        }
        for (stages.entries.items, 0..) |entry, index| {
            for (stages.entries.items[0..index]) |previous| if (std.mem.eql(u8, previous.name, entry.name)) {
                failure.* = .{ .span = entry.name_span };
                return error.DuplicateStageName;
            };
        }
    };
    if (!needed) return;
    var pages = std.ArrayList(ast.PageDecl).empty;
    errdefer {
        for (pages.items) |*page| page.deinit(allocator);
        pages.deinit(allocator);
    }
    var starts = std.ArrayList(usize).empty;
    defer starts.deinit(allocator);
    var counts = std.ArrayList(usize).empty;
    defer counts.deinit(allocator);
    for (module.pages.items) |original| {
        if (cancellation) |token| try token.check();
        try starts.append(allocator, pages.items.len);
        const count = if (original.stages) |stages| if (original.stage_index == null) stages.entries.items.len else 1 else 1;
        try counts.append(allocator, count);
        for (0..count) |index| {
            var page = try original.clone(allocator);
            var moved = false;
            errdefer if (!moved) page.deinit(allocator);
            if (original.stages) |stages| {
                if (original.stage_index == null) {
                    page.stage_index = index;
                    const name = try std.fmt.allocPrint(allocator, "{s} / {s}", .{ original.name, stages.entries.items[index].name });
                    page.source_name = page.name;
                    page.name = name;
                    var rewriter = Rewriter{ .allocator = allocator, .stages = stages, .index = index, .failure = failure, .cancellation = cancellation };
                    try rewriter.statements(page.statements.items, false);
                }
            }
            try pages.append(allocator, page);
            moved = true;
        }
    }
    var items = std.ArrayList(ast.TopLevelItem).empty;
    errdefer items.deinit(allocator);
    for (module.top_level_items.items) |item| switch (item) {
        .page => |index| for (0..counts.items[index]) |offset| {
            try items.append(allocator, .{ .page = starts.items[index] + offset });
        },
        else => try items.append(allocator, item),
    };
    for (module.pages.items) |*page| page.deinit(allocator);
    module.pages.deinit(allocator);
    module.pages = pages;
    module.top_level_items.deinit(allocator);
    module.top_level_items = items;
}

const Rewriter = struct {
    allocator: std.mem.Allocator,
    stages: ast.StagesDecl,
    index: usize,
    failure: *Failure,
    cancellation: ?utils.Cancellation,

    fn statements(self: *Rewriter, items: []ast.Statement, initially_shadowed: bool) anyerror!void {
        var shadowed = initially_shadowed;
        for (items) |*stmt| switch (stmt.kind) {
            .hole, .return_void => {},
            .let_binding => |*binding| {
                try self.expr(&binding.expr, shadowed);
                if (std.mem.eql(u8, binding.name, self.stages.name)) shadowed = true;
            },
            .return_expr, .expr_stmt => |*value| try self.expr(value, shadowed),
            .property_set => |*property| {
                try self.expr(&property.target, shadowed);
                try self.expr(&property.value, shadowed);
            },
            .constrain => |*constraint| if (constraint.offset) |*value| try self.expr(value, shadowed),
            .if_stmt, .drawing => |*block| {
                try self.expr(&block.condition, shadowed);
                try self.statements(block.then_statements.items, shadowed);
                try self.statements(block.else_statements.items, shadowed);
            },
        };
    }

    fn expr(self: *Rewriter, value: *ast.Expr, shadowed: bool) anyerror!void {
        if (self.cancellation) |token| try token.check();
        switch (value.*) {
            .ident => |ident| if (!shadowed and std.mem.eql(u8, ident.name, self.stages.name)) {
                value.deinit(self.allocator);
                value.* = .{ .number = @floatFromInt(self.index) };
            },
            .member => |*member| {
                if (!shadowed and member.target.* == .ident and std.mem.eql(u8, member.target.ident.name, self.stages.name)) {
                    for (self.stages.entries.items, 0..) |entry, index| {
                        if (std.mem.eql(u8, entry.name, member.name)) {
                            value.deinit(self.allocator);
                            value.* = .{ .number = @floatFromInt(index) };
                            return;
                        }
                    }
                    self.failure.* = .{ .span = member.name_span, .detail = "Choose a stage name declared in this page's stages list." };
                    return error.UnknownStage;
                }
                try self.expr(member.target, shadowed);
            },
            .call => |*call| {
                for (call.args.items) |*arg| try self.expr(arg, shadowed);
                if (!shadowed and !call.callee.isQualified() and !call.callee.is_operator and std.mem.eql(u8, call.callee.name, self.stages.name)) {
                    const callee = try self.allocator.create(ast.Expr);
                    callee.* = .{ .number = @floatFromInt(self.index) };
                    const args = call.args;
                    const arg_spans = call.arg_spans;
                    for (call.type_args.items) |*argument| argument.deinit(self.allocator);
                    call.type_args.deinit(self.allocator);
                    call.callee.deinit(self.allocator);
                    value.* = .{ .apply = .{ .callee = callee, .args = args, .arg_spans = arg_spans } };
                }
            },
            .apply => |*apply| {
                try self.expr(apply.callee, shadowed);
                for (apply.args.items) |*arg| try self.expr(arg, shadowed);
            },
            .lambda => |*lambda| {
                var local_shadowed = shadowed;
                for (lambda.params.items) |*param| {
                    if (param.default_value) |default| try self.expr(default, local_shadowed);
                    if (std.mem.eql(u8, param.name, self.stages.name)) local_shadowed = true;
                }
                try self.expr(lambda.body, local_shadowed);
            },
            .record => |*record| for (record.fields.items) |*field| try self.expr(&field.value, shadowed),
            .record_update => |*update| {
                try self.expr(update.target, shadowed);
                for (update.fields.items) |*field| try self.expr(&field.value, shadowed);
            },
            .optional_check => |*check| try self.expr(check.target, shadowed),
            .coalesce => |*coalesce| {
                try self.expr(coalesce.target, shadowed);
                try self.expr(coalesce.fallback, shadowed);
            },
            else => {},
        }
    }
};
