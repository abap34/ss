const std = @import("std");
const ast = @import("ast");

/// Print the expanded tree without resugaring calls or renaming generated names.
/// Internal identifiers and primitives make this inspection output, not input
/// accepted by the surface parser. Source spans are not part of the text.
pub fn moduleAlloc(allocator: std.mem.Allocator, module: ast.Module) ![]u8 {
    var printer = Printer{ .allocator = allocator };
    errdefer printer.output.deinit(allocator);
    try printer.module(module);
    return printer.output.toOwnedSlice(allocator);
}

const Printer = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8) = .empty,
    depth: usize = 0,

    fn text(self: *Printer, value: []const u8) !void {
        try self.output.appendSlice(self.allocator, value);
    }

    fn pad(self: *Printer) !void {
        for (0..self.depth) |_| try self.text("  ");
    }

    fn quoted(self: *Printer, value: []const u8) !void {
        try self.text("\"");
        try self.text(value);
        try self.text("\"");
    }

    fn stringLiteral(self: *Printer, value: []const u8) !void {
        if (std.mem.indexOfScalar(u8, value, '"') == null) return self.quoted(value);
        // Block delimiters remove one framing newline at each end.
        try self.text("<<\n\n");
        try self.text(value);
        try self.text("\n>>\n");
    }

    fn ty(self: *Printer, value: ast.Type) !void {
        const label = try value.formatAlloc(self.allocator);
        defer self.allocator.free(label);
        try self.text(label);
    }

    fn typeParams(self: *Printer, values: []const ast.TypeParameter) !void {
        if (values.len == 0) return;
        try self.text("<");
        for (values, 0..) |param, index| {
            if (index != 0) try self.text(", ");
            try self.text(param.name);
        }
        try self.text(">");
    }

    fn typeArgs(self: *Printer, args: []const ast.Type) !void {
        if (args.len == 0) return;
        try self.text("<");
        for (args, 0..) |arg, index| {
            if (index != 0) try self.text(", ");
            try self.ty(arg);
        }
        try self.text(">");
    }

    fn params(self: *Printer, values: []const ast.ParamDecl) !void {
        try self.text("(");
        for (values, 0..) |param, index| {
            if (index != 0) try self.text(", ");
            try self.text(param.name);
            try self.text(": ");
            try self.ty(param.ty);
            if (param.default_value) |value| {
                try self.text(" = ");
                try self.expr(value.*);
            }
        }
        try self.text(")");
    }

    fn module(self: *Printer, value: ast.Module) !void {
        const Item = struct {
            start: usize,
            kind: union(enum) { import: usize, type_decl: usize, record: usize, constant: usize, function: usize, document: usize, page: usize },
            fn less(_: void, a: @This(), b: @This()) bool {
                return a.start < b.start;
            }
        };
        var items = std.ArrayList(Item).empty;
        defer items.deinit(self.allocator);
        for (value.imports.items, 0..) |decl, i| try items.append(self.allocator, .{ .start = decl.span.start, .kind = .{ .import = i } });
        for (value.types.items, 0..) |decl, i| try items.append(self.allocator, .{ .start = decl.span.start, .kind = .{ .type_decl = i } });
        for (value.records.items, 0..) |decl, i| try items.append(self.allocator, .{ .start = decl.span.start, .kind = .{ .record = i } });
        for (value.constants.items, 0..) |decl, i| try items.append(self.allocator, .{ .start = decl.span.start, .kind = .{ .constant = i } });
        for (value.functions.items, 0..) |decl, i| try items.append(self.allocator, .{ .start = decl.span.start, .kind = .{ .function = i } });
        for (value.document_blocks.items, 0..) |decl, i| try items.append(self.allocator, .{ .start = decl.span.start, .kind = .{ .document = i } });
        for (value.pages.items, 0..) |decl, i| try items.append(self.allocator, .{ .start = decl.span.start, .kind = .{ .page = i } });
        // Stable ordering retains paired functions and stage copies sharing a span.
        std.sort.block(Item, items.items, {}, Item.less);
        for (items.items, 0..) |item, index| {
            if (index != 0) try self.text("\n");
            switch (item.kind) {
                .import => |i| {
                    const decl = value.imports.items[i];
                    try self.text("import ");
                    try self.quoted(decl.spec);
                    if (decl.mode.selected.len != 0) {
                        try self.text(" as { ");
                        for (decl.mode.selected, 0..) |name, n| {
                            if (n != 0) try self.text(", ");
                            try self.text(name.name);
                        }
                        try self.text(" }");
                    } else if (!decl.mode.unqualified) {
                        if (decl.mode.alias) |alias| {
                            try self.text(" as ");
                            try self.text(alias);
                        }
                    } else if (decl.mode.alias == null) try self.text(" as *");
                    try self.text("\n");
                },
                .type_decl => |i| {
                    const decl = value.types.items[i];
                    try self.text("enum ");
                    try self.text(decl.name);
                    try self.text(" {");
                    for (decl.cases.items) |case| {
                        try self.text(" ");
                        try self.text(case.name);
                    }
                    try self.text(" }\n");
                },
                .record => |i| {
                    const decl = value.records.items[i];
                    try self.text("type ");
                    try self.text(decl.name);
                    try self.typeParams(decl.type_params.items);
                    try self.text(" {\n");
                    self.depth += 1;
                    for (decl.fields.items) |field| {
                        try self.pad();
                        try self.text(field.name);
                        try self.text(": ");
                        try self.ty(field.value_type);
                        if (field.default_value) |default| {
                            try self.text(" = ");
                            try self.expr(default.*);
                        } else if (field.default_property_value) |property| {
                            try self.text(" = ");
                            try self.text(property);
                        }
                        try self.text("\n");
                    }
                    self.depth -= 1;
                    try self.text("}\n");
                },
                .constant => |i| {
                    const decl = value.constants.items[i];
                    try self.text("const ");
                    try self.text(decl.name);
                    try self.text(": ");
                    try self.ty(decl.value_type);
                    try self.text(" = ");
                    try self.expr(decl.value);
                    try self.text("\n");
                },
                .function => |i| {
                    const decl = value.functions.items[i];
                    try self.text("fn ");
                    try self.text(decl.name);
                    try self.typeParams(decl.type_params.items);
                    try self.params(decl.params.items);
                    try self.text(" -> ");
                    try self.ty(decl.result_type);
                    try self.text("\n");
                    try self.statements(decl.statements.items);
                    try self.text("end\n");
                },
                .document => |i| {
                    const decl = value.document_blocks.items[i];
                    try self.text("document\n");
                    try self.statements(value.document_statements.items[decl.statement_start..][0..decl.statement_count]);
                    try self.text("end\n");
                },
                .page => |i| {
                    const decl = value.pages.items[i];
                    try self.text("page ");
                    try self.quoted(decl.name);
                    try self.text("\n");
                    try self.statements(decl.statements.items);
                    try self.text("end\n");
                },
            }
        }
    }

    fn statements(self: *Printer, values: []const ast.Statement) anyerror!void {
        self.depth += 1;
        defer self.depth -= 1;
        for (values) |statement| {
            try self.pad();
            switch (statement.kind) {
                .hole => try self.text("<hole>"),
                .let_binding => |binding| {
                    try self.text("let ");
                    try self.text(binding.name);
                    if (binding.type_annotation) |annotation| {
                        try self.text(": ");
                        try self.ty(annotation);
                    }
                    try self.text(" = ");
                    try self.expr(binding.expr);
                },
                .return_expr => |result| {
                    try self.text("return ");
                    try self.expr(result);
                },
                .return_void => try self.text("return"),
                .expr_stmt => |expression| try self.expr(expression),
                .property_set => |property| {
                    try self.expr(property.target);
                    for (property.path.items) |segment| {
                        try self.text(".");
                        try self.text(segment.name);
                    }
                    try self.text(" = ");
                    try self.expr(property.value);
                },
                .if_stmt => |branch| {
                    try self.text("if ");
                    try self.expr(branch.condition);
                    try self.text("\n");
                    try self.statements(branch.then_statements.items);
                    if (branch.else_statements.items.len != 0) {
                        try self.pad();
                        try self.text("else\n");
                        try self.statements(branch.else_statements.items);
                    }
                    try self.pad();
                    try self.text("end");
                },
                .constrain => |constraint| {
                    try self.text(if (constraint.action == .update) "~!~ " else "~ ");
                    try self.anchor(constraint.target);
                    if (constraint.source) |source| {
                        try self.text(" == ");
                        try self.anchor(source);
                        if (constraint.offset) |offset| {
                            try self.text(" + ");
                            try self.expr(offset);
                        }
                    }
                },
            }
            try self.text("\n");
        }
    }

    fn anchor(self: *Printer, value: ast.AnchorRef) !void {
        try self.text(if (value.kind == .page) "page" else value.node_path orelse value.node_name.?);
        try self.text(".");
        try self.text(@tagName(value.anchor));
    }

    fn exprs(self: *Printer, values: []const ast.Expr) anyerror!void {
        for (values, 0..) |value, index| {
            if (index != 0) try self.text(", ");
            try self.expr(value);
        }
    }

    fn expr(self: *Printer, value: ast.Expr) anyerror!void {
        switch (value) {
            .ident => |ident| try self.text(ident.name),
            .hole => try self.text("<hole>"),
            .string => |literal| try self.stringLiteral(literal.text),
            .color => |color| {
                try self.text("c");
                try self.quoted(color);
            },
            .number => |number| try self.output.print(self.allocator, "{d}", .{number}),
            .boolean => |boolean| try self.text(if (boolean) "true" else "false"),
            .none => try self.text("none"),
            .call => |call| {
                if (call.callee.qualifier) |qualifier| {
                    try self.text(qualifier);
                    try self.text("::");
                }
                try self.text(call.callee.name);
                try self.typeArgs(call.type_args.items);
                try self.text("(");
                if (call.callee.composition) |composition| {
                    try self.text("\n");
                    self.depth += 1;
                    try self.pad();
                    try self.text(";; composition: ");
                    try self.text(@tagName(composition));
                    try self.text("\n");
                    try self.pad();
                    try self.exprs(call.args.items);
                    try self.text("\n");
                    self.depth -= 1;
                    try self.pad();
                } else try self.exprs(call.args.items);
                try self.text(")");
            },
            .apply => |apply| {
                try self.text("(");
                try self.expr(apply.callee.*);
                try self.text(")(");
                try self.exprs(apply.args.items);
                try self.text(")");
            },
            .lambda => |lambda| {
                try self.text("(");
                try self.params(lambda.params.items);
                try self.text(" |-> ");
                try self.expr(lambda.body.*);
                try self.text(")");
            },
            .member => |member| {
                try self.text("(");
                try self.expr(member.target.*);
                try self.text(if (member.optional) ")?." else ").");
                try self.text(member.name);
            },
            .record => |record| {
                try self.text(record.type_name);
                try self.typeArgs(record.type_args.items);
                try self.text(" {");
                for (record.fields.items, 0..) |field, index| {
                    try self.text(if (index == 0) " " else ", ");
                    try self.text(field.name);
                    try self.text(" = ");
                    try self.expr(field.value);
                }
                try self.text(" }");
            },
            .record_update => |update| {
                try self.text("(");
                try self.expr(update.target.*);
                try self.text(") with {");
                for (update.fields.items, 0..) |field, index| {
                    try self.text(if (index == 0) " " else ", ");
                    for (field.path.items, 0..) |segment, n| {
                        if (n != 0) try self.text(".");
                        try self.text(segment.name);
                    }
                    try self.text(" = ");
                    try self.expr(field.value);
                }
                try self.text(" }");
            },
            .enum_case => |case| {
                try self.text(case.enum_name);
                try self.text(".");
                try self.text(case.case_name);
            },
            .optional_check => |check| {
                try self.text("(");
                try self.expr(check.target.*);
                try self.text(")?");
            },
            .coalesce => |coalesce| {
                try self.text("(");
                try self.expr(coalesce.target.*);
                try self.text(" ?? ");
                try self.expr(coalesce.fallback.*);
                try self.text(")");
            },
        }
    }
};
