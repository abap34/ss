const std = @import("std");
const ast = @import("ast");
const syntax = @import("syntax");
const testing = std.testing;

const operators = [_][]const u8{ "||", "//", "|=|", "/=/" };
const gaps = [_][]const u8{ "", " ", "\n", "\n\n", "\n;; generated comment\n\t", "\r\n# generated comment\r\n  " };
const Node = union(enum) {
    leaf: u8,
    chain: struct { operator: usize, children: []const Node },
};

const Format = struct {
    parentheses: usize = 0,
    gap: usize = 0,
    literal: usize = 0,
    before: bool = false,
    baseline: bool = false,
};

const Printer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    format: Format,
    site: usize = 0,

    fn append(self: *Printer, text: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, text);
    }

    fn expression(self: *Printer, node: Node, nested: bool) !void {
        const site = self.site;
        self.site += 1;
        const extra = !self.format.baseline and (self.format.parentheses & (@as(usize, 1) << @intCast(site % 3))) != 0;
        const depth: usize = @intFromBool(nested and node == .chain) + @as(usize, if (extra) 2 else 0);
        const trivia = if (self.format.baseline) "" else gaps[self.format.gap];
        for (0..depth) |_| {
            try self.append("(");
            try self.append(trivia);
        }
        switch (node) {
            .leaf => |label| {
                const text = &[_]u8{label};
                const style = if (self.format.baseline) 0 else (self.format.literal + label - 'A') % 4;
                switch (style) {
                    0 => {
                        try self.append("text(");
                        try self.append(trivia);
                        try self.append("\"");
                        try self.append(text);
                        try self.append("\"");
                        try self.append(trivia);
                        try self.append(")");
                    },
                    1 => {
                        try self.append("text \"");
                        try self.append(text);
                        try self.append("\"");
                    },
                    2, 3 => {
                        try self.append(if (style == 2) "text(<<\n" else "text << # generated header\n");
                        // String contents are not formatting trivia.
                        try self.append(text);
                        try self.append("\n\t>>");
                        if (style == 2) {
                            try self.append(trivia);
                            try self.append(")");
                        }
                    },
                    else => unreachable,
                }
            },
            .chain => |chain| {
                for (chain.children, 0..) |child, index| {
                    if (index != 0) {
                        try self.append(if (self.format.baseline) " " else if (self.format.before) trivia else if (self.format.gap % 2 == 0) "" else "\t");
                        try self.append(operators[chain.operator]);
                        try self.append(if (self.format.baseline) " " else trivia);
                    }
                    try self.expression(child, true);
                }
            },
        }
        for (0..depth) |_| {
            try self.append(trivia);
            try self.append(")");
        }
    }

    fn document(self: *Printer, tree: Node) ![]const u8 {
        try self.append("page Generated\nlet result = ");
        try self.expression(tree, false);
        try self.append("\nlet sentinel = 123\nend\n");
        return self.bytes.items;
    }
};

fn equivalent(left: ast.Expr, right: ast.Expr) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .call => |call| blk: {
            const other = right.call;
            if (!std.mem.eql(u8, call.callee.name, other.callee.name) or
                !std.mem.eql(u8, call.callee.qualifier orelse "", other.callee.qualifier orelse "") or
                call.args.items.len != other.args.items.len) break :blk false;
            for (call.args.items, other.args.items) |a, b| if (!equivalent(a, b)) break :blk false;
            break :blk true;
        },
        .string => |text| std.mem.eql(u8, text.text, right.string.text),
        .number => |value| value == right.number,
        .ident => |name| std.mem.eql(u8, name.name, right.ident.name),
        else => false,
    };
}

fn result(module: ast.Module) !ast.Expr {
    try testing.expectEqual(@as(usize, 1), module.pages.items.len);
    const statements = module.pages.items[0].statements.items;
    try testing.expectEqual(@as(usize, 2), statements.len);
    try testing.expectEqualStrings("sentinel", statements[1].kind.let_binding.name);
    try testing.expectEqual(@as(f32, 123), statements[1].kind.let_binding.expr.number);
    return statements[0].kind.let_binding.expr;
}

fn checkVariants(tree: Node, family: usize) !usize {
    var baseline_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer baseline_arena.deinit();
    var baseline_printer = Printer{ .allocator = baseline_arena.allocator(), .format = .{ .baseline = true } };
    const baseline_text = try baseline_printer.document(tree);
    const baseline = try syntax.parse(baseline_arena.allocator(), baseline_text);
    const expected = try result(baseline);
    var count: usize = 0;
    for (0..8) |parentheses| {
        for (gaps, 0..) |_, gap| {
            for (0..8) |variant| {
                const literal = variant % 4;
                const before = variant >= 4;
                var arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena.deinit();
                var printer = Printer{ .allocator = arena.allocator(), .format = .{ .parentheses = parentheses, .gap = gap, .literal = literal, .before = before } };
                const text = try printer.document(tree);
                errdefer std.debug.print("\nGenerated formatting failure: family={d}, parentheses={d}, gap={d}, literal={d}, before={}\nBaseline:\n{s}\nVariant:\n{s}\n", .{ family, parentheses, gap, literal, before, baseline_text, text });
                const parsed = try syntax.parse(arena.allocator(), text);
                try testing.expect(equivalent(expected, try result(parsed)));
                const recovered = try syntax.parseRecovering(arena.allocator(), text);
                try testing.expectEqual(@as(usize, 0), recovered.holes.diagnostics.len);
                try testing.expect(equivalent(expected, try result(recovered.module)));
                count += 1;
            }
        }
    }
    return count;
}

test "generated formatting preserves composition ASTs in strict and recovering parsers" {
    const leaves = [_]Node{ .{ .leaf = 'A' }, .{ .leaf = 'B' }, .{ .leaf = 'C' } };
    var count: usize = 0;
    var family: usize = 0;
    for (operators, 0..) |_, outer| {
        for (2..4) |arity| {
            count += try checkVariants(.{ .chain = .{ .operator = outer, .children = leaves[0..arity] } }, family);
            family += 1;
        }
        for (operators, 0..) |_, inner| {
            const left = [_]Node{ .{ .chain = .{ .operator = inner, .children = leaves[0..2] } }, leaves[2] };
            const right = [_]Node{ leaves[0], .{ .chain = .{ .operator = inner, .children = leaves[1..3] } } };
            for ([_][]const Node{ &left, &right }) |children| {
                count += try checkVariants(.{ .chain = .{ .operator = outer, .children = children } }, family);
                family += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 15360), count);
}

test "generated AST comparison detects semantic mutations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const baseline = try syntax.parse(allocator, "page Test\nlet x = text(\"A\") |=| text(\"B\") |=| text(\"C\")\nend\n");
    const expected = baseline.pages.items[0].statements.items[0].kind.let_binding.expr;
    for ([_][]const u8{
        "(text(\"A\") |=| text(\"B\")) |=| text(\"C\")",
        "text(\"A\") /=/ text(\"B\") /=/ text(\"C\")",
        "text(\"B\") |=| text(\"A\") |=| text(\"C\")",
        "text(\"Changed\") |=| text(\"B\") |=| text(\"C\")",
    }) |expression| {
        const text = try std.fmt.allocPrint(allocator, "page Test\nlet x = {s}\nend\n", .{expression});
        const mutant = try syntax.parse(allocator, text);
        try testing.expect(!equivalent(expected, mutant.pages.items[0].statements.items[0].kind.let_binding.expr));
    }
}

test "generated statement continuations preserve sugar and the following statement" {
    for (operators) |operator| {
        for ([_][]const u8{ "a", "(a)", "text(\"A\")", "text \"A\"", "text <<\nA\n>>", "text! <<\nA\n>>" }) |left| {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const baseline_text = try std.fmt.allocPrint(allocator, "page Test\n{s} {s} b\nlet sentinel = 123\nend\n", .{ left, operator });
            const baseline = try syntax.parse(allocator, baseline_text);
            const expected = baseline.pages.items[0].statements.items[0].kind.expr_stmt;
            for (gaps) |gap| {
                const text = try std.fmt.allocPrint(allocator, "page Test\n{s}{s}{s}{s}b\nlet sentinel = 123\nend\n", .{ left, gap, operator, gap });
                errdefer std.debug.print("\nGenerated statement continuation failure:\n{s}\n", .{text});
                const parsed = try syntax.parse(allocator, text);
                const recovered = try syntax.parseRecovering(allocator, text);
                try testing.expectEqual(@as(usize, 0), recovered.holes.diagnostics.len);
                for ([_]ast.Module{ parsed, recovered.module }) |module| {
                    const statements = module.pages.items[0].statements.items;
                    try testing.expectEqual(@as(usize, 2), statements.len);
                    try testing.expect(equivalent(expected, statements[0].kind.expr_stmt));
                    try testing.expectEqualStrings("sentinel", statements[1].kind.let_binding.name);
                }
            }
            const terminated = try std.fmt.allocPrint(allocator, "page Test\nlet g = {s};\n{s} b\nend\n", .{ left, operator });
            // An explicit semicolon still prevents expression continuation.
            try testing.expectError(error.ExpectedExpression, syntax.parse(allocator, terminated));
        }
    }
}

test "generated formatting preserves mixed composition errors and operator spans" {
    for (operators) |first| {
        for (operators) |second| {
            if (std.mem.eql(u8, first, second)) continue;
            for (gaps) |gap| {
                for ([_]bool{ false, true }) |wrapped| {
                    var arena = std.heap.ArenaAllocator.init(testing.allocator);
                    defer arena.deinit();
                    const allocator = arena.allocator();
                    const text = try std.fmt.allocPrint(allocator, "page Test\nlet g = {s}{s}{s}{s}{s}{s}{s}{s}c\nlet sentinel = 123\nend\n", .{
                        if (wrapped) "((a))" else "a", gap, first,  gap,
                        if (wrapped) "((b))" else "b", gap, second, gap,
                    });
                    errdefer std.debug.print("\nGenerated mixed composition failure:\n{s}\n", .{text});
                    var failure: syntax.ParseFailure = .{};
                    try testing.expectError(error.MixedCompositionDirections, syntax.parseWithSourceNameAndFailure(allocator, text, "generated.ss", &failure));
                    const diagnostic = failure.diagnostic.?;
                    try testing.expectEqualStrings(second, text[diagnostic.span.start..diagnostic.span.end]);
                    const recovered = try syntax.parseRecovering(allocator, text);
                    try testing.expectEqual(@as(usize, 1), recovered.holes.diagnostics.len);
                    const recovery = recovered.holes.diagnostics[0];
                    try testing.expectEqual(error.MixedCompositionDirections, recovery.err);
                    try testing.expectEqual(diagnostic.span, recovery.span);
                    try testing.expectEqualStrings(diagnostic.detail.?, recovery.detail.?);
                    const statements = recovered.module.pages.items[0].statements.items;
                    try testing.expectEqualStrings("sentinel", statements[statements.len - 1].kind.let_binding.name);
                }
            }
        }
    }
}
