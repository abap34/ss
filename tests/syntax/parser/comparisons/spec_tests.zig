const std = @import("std");
const syntax = @import("syntax");
const ast = @import("ast");
const testing = std.testing;

const operators = [_][]const u8{ "==", "!=", "<", "<=", ">", ">=" };
const callees = [_][]const u8{ "num_eq", "num_ne", "num_lt", "num_le", "num_gt", "num_ge" };

fn call(expr: ast.Expr, name: []const u8, arity: usize) !ast.CallExpr {
    try testing.expect(expr == .call);
    try testing.expectEqualStrings(name, expr.call.callee.name);
    try testing.expectEqual(arity, expr.call.args.items.len);
    return expr.call;
}

fn ident(expr: ast.Expr, name: []const u8) !void {
    try testing.expect(expr == .ident);
    try testing.expectEqualStrings(name, expr.ident.name);
}

fn parse(source: []const u8) !syntax.Module {
    return syntax.parseWithSourceName(testing.allocator, source, "comparisons.ss");
}

fn parseAndDeinit(allocator: std.mem.Allocator, source: []const u8) !void {
    var module = try syntax.parseWithSourceName(allocator, source, "comparisons.ss");
    defer module.deinit(allocator);
}

fn recoverAndDeinit(allocator: std.mem.Allocator, source: []const u8) !void {
    var result = try syntax.parseRecoveringWithSourceName(allocator, source, "comparisons.ss");
    defer result.deinit(allocator);
}

test "comparisons: all operators preserve operands with independent whitespace" {
    for (operators, callees) |operator, callee| {
        for ([_][]const u8{ "", " ", "\t" }) |before| {
            for ([_][]const u8{ "", " ", "\t" }) |after| {
                const source = try std.fmt.allocPrint(
                    testing.allocator,
                    "page Sample\nlet result = left{s}{s}{s}right\nend\n",
                    .{ before, operator, after },
                );
                defer testing.allocator.free(source);
                var module = try parse(source);
                defer module.deinit(testing.allocator);
                const comparison = try call(module.pages.items[0].statements.items[0].kind.let_binding.expr, callee, 2);
                try ident(comparison.args.items[0], "left");
                try ident(comparison.args.items[1], "right");
                var recovered = try syntax.parseRecoveringWithSourceName(testing.allocator, source, "comparisons.ss");
                defer recovered.deinit(testing.allocator);
                try testing.expectEqual(@as(usize, 0), recovered.holes.diagnostics.len);
                const recovered_comparison = try call(recovered.module.pages.items[0].statements.items[0].kind.let_binding.expr, callee, 2);
                try ident(recovered_comparison.args.items[0], "left");
                try ident(recovered_comparison.args.items[1], "right");
            }
        }
    }
}

test "comparisons: arithmetic unary calls and members bind on both sides" {
    for (operators, callees) |operator, callee| {
        const source = try std.fmt.allocPrint(
            testing.allocator,
            "page Sample\nlet result = -left + 2 * value(){s}item.size / 3 - -4\nend\n",
            .{operator},
        );
        defer testing.allocator.free(source);
        var module = try parse(source);
        defer module.deinit(testing.allocator);
        const comparison = try call(module.pages.items[0].statements.items[0].kind.let_binding.expr, callee, 2);
        const sum = try call(comparison.args.items[0], "add", 2);
        const negation = try call(sum.args.items[0], "neg", 1);
        try ident(negation.args.items[0], "left");
        const product = try call(sum.args.items[1], "mul", 2);
        try testing.expectEqual(@as(f32, 2), product.args.items[0].number);
        _ = try call(product.args.items[1], "value", 0);
        const difference = try call(comparison.args.items[1], "sub", 2);
        const quotient = try call(difference.args.items[0], "div", 2);
        try testing.expect(quotient.args.items[0] == .member);
        try testing.expectEqual(@as(f32, 3), quotient.args.items[1].number);
        const negative = try call(difference.args.items[1], "neg", 1);
        try testing.expectEqual(@as(f32, 4), negative.args.items[0].number);
    }
}

test "comparisons: parentheses override left association" {
    for (operators, callees) |first_operator, first_callee| {
        for (operators, callees) |second_operator, second_callee| {
            const source = try std.fmt.allocPrint(
                testing.allocator,
                "page Sample\nlet chain = a {s} b {s} c\nlet grouped = a {s} (b {s} c)\nend\n",
                .{ first_operator, second_operator, first_operator, second_operator },
            );
            defer testing.allocator.free(source);
            var module = try parse(source);
            defer module.deinit(testing.allocator);
            const statements = module.pages.items[0].statements.items;
            const chain = try call(statements[0].kind.let_binding.expr, second_callee, 2);
            const left = try call(chain.args.items[0], first_callee, 2);
            try ident(left.args.items[0], "a");
            try ident(left.args.items[1], "b");
            try ident(chain.args.items[1], "c");
            const grouped = try call(statements[1].kind.let_binding.expr, first_callee, 2);
            try ident(grouped.args.items[0], "a");
            const right = try call(grouped.args.items[1], second_callee, 2);
            try ident(right.args.items[0], "b");
            try ident(right.args.items[1], "c");
        }
    }
}

test "comparisons: concatenation coalescing and composition keep operand boundaries" {
    var module = try parse(
        \\page Sample
        \\let concatenated = a ++ b == c ++ d
        \\let defaulted = a ?? b <= c ?? d
        \\let composed = a < b || c >= d
        \\let arguments = consume(a != b, c > d)
        \\end
    );
    defer module.deinit(testing.allocator);
    const statements = module.pages.items[0].statements.items;
    const concatenated = try call(statements[0].kind.let_binding.expr, "num_eq", 2);
    _ = try call(concatenated.args.items[0], "concat", 2);
    _ = try call(concatenated.args.items[1], "concat", 2);
    const defaulted = try call(statements[1].kind.let_binding.expr, "num_le", 2);
    try ident(defaulted.args.items[0].coalesce.target.*, "a");
    try ident(defaulted.args.items[0].coalesce.fallback.*, "b");
    try ident(defaulted.args.items[1].coalesce.target.*, "c");
    try ident(defaulted.args.items[1].coalesce.fallback.*, "d");
    const composed = try call(statements[2].kind.let_binding.expr, "hjoin", 2);
    _ = try call(composed.args.items[0], "num_lt", 2);
    _ = try call(composed.args.items[1], "num_ge", 2);
    const arguments = try call(statements[3].kind.let_binding.expr, "consume", 2);
    _ = try call(arguments.args.items[0], "num_ne", 2);
    _ = try call(arguments.args.items[1], "num_gt", 2);
}

test "comparisons: conditional headers consume comparisons before their newline" {
    for (operators, callees) |operator, callee| {
        const source = try std.fmt.allocPrint(
            testing.allocator,
            "page Sample\nif a{s}b # condition\nlet yes = 1\nelse\nlet no = 2\nend\nlet after = 3\nend\n",
            .{operator},
        );
        defer testing.allocator.free(source);
        var module = try parse(source);
        defer module.deinit(testing.allocator);
        const statements = module.pages.items[0].statements.items;
        try testing.expectEqual(@as(usize, 2), statements.len);
        const branch = statements[0].kind.if_stmt;
        _ = try call(branch.condition, callee, 2);
        try testing.expectEqual(@as(usize, 1), branch.then_statements.items.len);
        try testing.expectEqual(@as(usize, 1), branch.else_statements.items.len);
        try testing.expectEqualStrings("after", statements[1].kind.let_binding.name);
    }
}

test "comparisons: constraint equality and bang calls remain distinct" {
    var module = try parse(
        \\page Sample
        \\~ item.left == other.right + 2
        \\~!~ item.top == other.bottom
        \\let result = item.size!=value!()
        \\end
    );
    defer module.deinit(testing.allocator);
    const statements = module.pages.items[0].statements.items;
    try testing.expectEqual(ast.ConstraintDecl.Action.add, statements[0].kind.constrain.action);
    try testing.expectEqual(ast.ConstraintDecl.Action.update, statements[1].kind.constrain.action);
    try testing.expectEqual(@as(f32, 2), statements[0].kind.constrain.offset.?.number);
    const comparison = try call(statements[2].kind.let_binding.expr, "num_ne", 2);
    try testing.expect(comparison.args.items[0] == .member);
    _ = try call(comparison.args.items[1], "value!", 0);
}

test "comparisons: malformed operands reject and recovery preserves following declarations" {
    for (operators) |operator| {
        for ([_][]const u8{ "{s} right", "left {s} )", "left {s} = right" }) |pattern| {
            const expression = try std.mem.replaceOwned(u8, testing.allocator, pattern, "{s}", operator);
            defer testing.allocator.free(expression);
            const source = try std.fmt.allocPrint(
                testing.allocator,
                "page Sample\nlet invalid = {s}\nlet after = 7\nend\n",
                .{expression},
            );
            defer testing.allocator.free(source);
            try testing.expectError(error.ExpectedIdentifier, parseAndDeinit(testing.allocator, source));
            var recovered = try syntax.parseRecoveringWithSourceName(testing.allocator, source, "comparisons.ss");
            defer recovered.deinit(testing.allocator);
            try testing.expect(recovered.holes.diagnostics.len > 0);
            const statements = recovered.module.pages.items[0].statements.items;
            const last = statements[statements.len - 1];
            try testing.expectEqualStrings("after", last.kind.let_binding.name);
            try testing.expectEqual(@as(f32, 7), last.kind.let_binding.expr.number);
        }
    }
}

test "comparisons: allocation failures release nested expression ownership" {
    const source = "page Sample\nlet value = left!=2+3 <= (other>=4)\nend\n";
    try testing.checkAllAllocationFailures(testing.allocator, parseAndDeinit, .{source});
    try testing.checkAllAllocationFailures(testing.allocator, recoverAndDeinit, .{source});
    const incomplete = "page Sample\nlet value = left != # missing\naccept()\nend\n";
    try testing.checkAllAllocationFailures(testing.allocator, recoverAndDeinit, .{incomplete});
}

test "comparisons: missing right operand cannot consume the next statement" {
    for (operators) |operator| {
        for ([_][]const u8{ "\n", " # missing\n", " ;; missing\n" }) |ending| {
            const source = try std.fmt.allocPrint(
                testing.allocator,
                "page Sample\nlet invalid = left {s}{s}accept()\nlet after = 7\nend\n",
                .{ operator, ending },
            );
            defer testing.allocator.free(source);
            errdefer std.debug.print("Comparison source: {s}\n", .{source});
            var failure: syntax.ParseFailure = .{};
            try testing.expectError(error.ExpectedExpression, syntax.parseWithSourceNameAndFailure(testing.allocator, source, "comparisons.ss", &failure));
            var expected_pos = std.mem.indexOf(u8, source, "left ").? + "left ".len + operator.len;
            while (source[expected_pos] == ' ') expected_pos += 1;
            try testing.expectEqual(expected_pos, failure.diagnostic.?.span.start);
            var recovered = try syntax.parseRecoveringWithSourceName(testing.allocator, source, "comparisons.ss");
            defer recovered.deinit(testing.allocator);
            try testing.expectEqual(@as(usize, 1), recovered.holes.diagnostics.len);
            const statements = recovered.module.pages.items[0].statements.items;
            try testing.expectEqual(@as(usize, 3), statements.len);
            _ = try call(statements[1].kind.expr_stmt, "accept", 0);
            try testing.expectEqualStrings("after", statements[2].kind.let_binding.name);
        }
        const incomplete = try std.fmt.allocPrint(testing.allocator, "page Sample\nlet invalid = left {s}", .{operator});
        defer testing.allocator.free(incomplete);
        try testing.expectError(error.ExpectedExpression, parseAndDeinit(testing.allocator, incomplete));
    }
}
