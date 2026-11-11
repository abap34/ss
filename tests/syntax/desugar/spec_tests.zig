const std = @import("std");
const testing = std.testing;
const syntax = @import("syntax");
const ast = @import("ast");
const allocation_testing = @import("allocation_testing");

const source =
    \\type Label<T> { value: T count: Number = 1 + 2 }
    \\fn/! label<T>(value: T, tone: String = "soft") -> Label<T> = Label<T> { value = value }
    \\fn double(value: Number = 2 * 3) -> Number = value + value
    \\document
    \\  show true
    \\    let first = 1 + 2
    \\  end
    \\end
    \\document
    \\  let second = 3
    \\end
    \\page Demo
    \\  show s >= s.second
    \\    let item = label!("Body")
    \\  end
    \\  ~ item.width == 240
    \\  item // label!("Footer")
    \\  let invalid = s()
    \\  stages s { first second }
    \\end
;

test "desugar: the surface tree retains syntax and expansion produces only core nodes" {
    try testing.expect(@hasField(syntax.Surface.Expr, "operation"));
    try testing.expect(@hasField(syntax.Surface.Statement.Kind, "show"));
    try testing.expect(!@hasField(ast.Expr, "operation"));
    try testing.expect(!@hasField(ast.Statement.Kind, "show"));
    var parsed = try syntax.parseSurface(testing.allocator, source);
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), parsed.functions.items.len);
    try testing.expect(parsed.functions.items[0].paired);
    try testing.expect(parsed.functions.items[0].expression_body);
    try testing.expect(parsed.functions.items[1].params.items[0].default_value.?.* == .operation);
    try testing.expect(parsed.pages.items[0].statements.items[0].kind == .show);
    try testing.expectEqual(@as(usize, 1), parsed.pages.items.len);

    var expanded = try syntax.desugar(testing.allocator, &parsed, .{});
    defer expanded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), expanded.functions.items.len);
    try testing.expectEqualStrings("label!", expanded.functions.items[1].name);
    const placing = expanded.functions.items[1].statements.items[0].kind.return_expr.call;
    try testing.expectEqualStrings("place_on!", placing.callee.name);
    try testing.expect(placing.callee.resolution == .intrinsic);
    try testing.expect(placing.args.items[0].call.callee.resolution == .intrinsic);
    try testing.expect(placing.args.items[1].call.callee.resolution == .function);
    try testing.expectEqualStrings("T", placing.args.items[1].call.type_args.items[0].class_name.?);
    const double = expanded.functions.items[2];
    try testing.expectEqualStrings("add", double.statements.items[0].kind.return_expr.call.callee.name);
    try testing.expectEqualStrings("mul", double.params.items[0].default_value.?.call.callee.name);
    try testing.expectEqualStrings("add", expanded.records.items[0].fields.items[1].default_value.?.call.callee.name);
    try testing.expectEqual(@as(usize, 2), expanded.pages.items.len);
    const statements = expanded.pages.items[0].statements.items;
    try testing.expectEqual(@as(usize, 6), statements.len);
    try testing.expectEqualStrings("draw_when!", statements[2].kind.let_binding.expr.call.callee.name);
    const predicate = statements[0].kind.let_binding.expr.lambda.body.call;
    try testing.expectEqualStrings("num_ge", predicate.callee.name);
    try testing.expectEqual(@as(f32, 0), predicate.args.items[0].number);
    try testing.expectEqual(@as(f32, 1), predicate.args.items[1].number);
    try testing.expectEqual(ast.GroupComposition.vertical, statements[4].kind.expr_stmt.call.callee.composition.?);
    // Expansion borrows rather than consuming or rewriting the input tree.
    try testing.expectEqual(@as(usize, 1), parsed.pages.items.len);
    try testing.expect(parsed.pages.items[0].statements.items[0].kind == .show);
}

test "desugar: stage declarations apply to the whole page from any body position" {
    const body = "  let current = s\n  let named = s.second\n";
    const declaration = "  stages s { first second }\n";
    for ([_]usize{ 0, "  let current = s\n".len, body.len }) |position| {
        const text = try std.fmt.allocPrint(testing.allocator, "page Demo\n{s}{s}{s}end\n", .{ body[0..position], declaration, body[position..] });
        defer testing.allocator.free(text);
        var parsed = try syntax.parseSurface(testing.allocator, text);
        defer parsed.deinit(testing.allocator);
        const stages = parsed.pages.items[0].stages.?;
        try testing.expectEqualStrings("stages s { first second }", text[stages.span.start..stages.span.end]);
        try testing.expectEqual(@as(usize, 2), parsed.pages.items[0].statements.items.len);
        var expanded = try syntax.desugar(testing.allocator, &parsed, .{});
        defer expanded.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), expanded.pages.items.len);
        for (expanded.pages.items, 0..) |page, index| {
            try testing.expectEqual(@as(usize, 2), page.statements.items.len);
            const current = page.statements.items[0].kind.let_binding;
            const named = page.statements.items[1].kind.let_binding;
            try testing.expectEqualStrings("current", current.name);
            try testing.expectEqual(@as(f32, @floatFromInt(index)), current.expr.number);
            try testing.expectEqualStrings("named", named.name);
            try testing.expectEqual(@as(f32, 1), named.expr.number);
        }
    }
}

test "desugar: integer stages preserve literal values, order, and inclusive endpoints" {
    const cases = .{
        .{ "1:3", &[_]f32{ 1, 2, 3 } },
        .{ "-2 : 0", &[_]f32{ -2, -1, 0 } },
        .{ "7:7", &[_]f32{7} },
        .{ "1:2:9", &[_]f32{ 1, 3, 5, 7, 9 } },
        .{ "1:2:8", &[_]f32{ 1, 3, 5, 7 } },
        .{ "9:-2:1", &[_]f32{ 9, 7, 5, 3, 1 } },
        .{ "9:-2:2", &[_]f32{ 9, 7, 5, 3 } },
        .{ "-3:2:3", &[_]f32{ -3, -1, 1, 3 } },
        .{ "3:-2:-3", &[_]f32{ 3, 1, -1, -3 } },
        .{ "7:-2:7", &[_]f32{7} },
        .{ "1:3 7 10:12", &[_]f32{ 1, 2, 3, 7, 10, 11, 12 } },
        .{ "0:2:4 1:2:5", &[_]f32{ 0, 2, 4, 1, 3, 5 } },
        .{ "9:-2:5 1:2", &[_]f32{ 9, 7, 5, 1, 2 } },
        .{ "-16777216:16777216:16777216", &[_]f32{ -16777216, 0, 16777216 } },
        .{ "16777216:-16777216:-16777216", &[_]f32{ 16777216, 0, -16777216 } },
        .{ "7 1 -3 0", &[_]f32{ 7, 1, -3, 0 } },
        .{ "-16777216 16777216", &[_]f32{ -16777216, 16777216 } },
        .{ "1 ;; First value\n  3", &[_]f32{ 1, 3 } },
        .{ "1\n :\n 2", &[_]f32{ 1, 2 } },
        .{ "1\n :\n 2\n :\n 5", &[_]f32{ 1, 3, 5 } },
    };
    inline for (cases) |case| {
        const text = "page Before\nend\npage Demo\nlet current = i\nstages i { " ++ case[0] ++ " }\nend\npage After\nend\n";
        var parsed = try syntax.parseSurface(testing.allocator, text);
        defer parsed.deinit(testing.allocator);
        var expanded = try syntax.desugar(testing.allocator, &parsed, .{});
        defer expanded.deinit(testing.allocator);
        try testing.expectEqual(case[1].len + 2, expanded.pages.items.len);
        try testing.expectEqualStrings("Before", expanded.pages.items[0].name);
        try testing.expectEqualStrings("After", expanded.pages.items[expanded.pages.items.len - 1].name);
        for (expanded.pages.items[1 .. 1 + case[1].len], case[1], 0..) |page, value, index| {
            try testing.expectEqual(value, page.statements.items[0].kind.let_binding.expr.number);
            try testing.expectEqual(index, page.stage_index.?);
            try testing.expectEqualStrings("Demo", page.source_name.?);
            const label = try std.fmt.allocPrint(testing.allocator, "Demo / {d}", .{@as(i32, @intFromFloat(value))});
            defer testing.allocator.free(label);
            try testing.expectEqualStrings(label, page.name);
            try testing.expectEqual(index + 1, expanded.top_level_items.items[index + 1].page);
        }
    }
}

test "desugar: integer stages preserve lexical shadowing and callable errors" {
    var parsed = try syntax.parseSurface(testing.allocator,
        \\page Demo
        \\  stages i { 3 7 }
        \\  let identity = (i: Number) |-> i
        \\  let captured = (n: Number) |-> i
        \\  let invalid = i()
        \\  let i = i + 10
        \\  let local = i
        \\end
    );
    defer parsed.deinit(testing.allocator);
    var expanded = try syntax.desugar(testing.allocator, &parsed, .{});
    defer expanded.deinit(testing.allocator);
    for (expanded.pages.items, [_]f32{ 3, 7 }) |page, value| {
        const statements = page.statements.items;
        try testing.expectEqualStrings("i", statements[0].kind.let_binding.expr.lambda.body.ident.name);
        try testing.expectEqual(value, statements[1].kind.let_binding.expr.lambda.body.number);
        try testing.expectEqual(value, statements[2].kind.let_binding.expr.apply.callee.number);
        try testing.expectEqual(value, statements[3].kind.let_binding.expr.call.args.items[0].number);
        try testing.expectEqualStrings("i", statements[4].kind.let_binding.expr.ident.name);
    }
}

fn integerStagesAllocation(allocator: std.mem.Allocator) !void {
    var parsed = try syntax.parseSurface(allocator, "page Range\nstages i { -1:1 }\nlet value = i\nend\npage List\nstages i { 7:-2:3 0 }\nlet value = i\nend\n");
    defer parsed.deinit(allocator);
    var retained = try syntax.desugar(allocator, &parsed, .{ .expand_stages = false });
    defer retained.deinit(allocator);
    var copy = try retained.clone(allocator);
    defer copy.deinit(allocator);
    var expanded = try syntax.desugar(allocator, &parsed, .{});
    defer expanded.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), copy.pages.items.len);
    try testing.expectEqual(@as(usize, 3), copy.pages.items[0].stages.?.count());
    try testing.expectEqual(@as(usize, 7), expanded.pages.items.len);
}

test "desugar: integer stage lists and compact ranges release partial allocations" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, integerStagesAllocation, .{});
}

test "desugar: document block offsets follow flattened show statements" {
    var parsed = try syntax.parseSurface(testing.allocator, source);
    defer parsed.deinit(testing.allocator);
    var expanded = try syntax.desugar(testing.allocator, &parsed, .{});
    defer expanded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), expanded.document_statements.items.len);
    try testing.expectEqual(@as(usize, 3), expanded.document_blocks.items[0].statement_count);
    try testing.expectEqual(@as(usize, 3), expanded.document_blocks.items[1].statement_start);
    try testing.expectEqualStrings("second", expanded.document_statements.items[3].kind.let_binding.name);
}

test "desugar: source queries lower sugar without duplicating stage pages" {
    var parsed = try syntax.parseSurface(testing.allocator, source);
    defer parsed.deinit(testing.allocator);
    var expanded = try syntax.desugar(testing.allocator, &parsed, .{ .expand_stages = false });
    defer expanded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), expanded.pages.items.len);
    const predicate = expanded.pages.items[0].statements.items[0].kind.let_binding.expr.lambda.body.call;
    try testing.expectEqualStrings("s", predicate.args.items[0].ident.name);
    try testing.expectEqualStrings("second", predicate.args.items[1].member.name);
    const offset = std.mem.indexOf(u8, source, ">=").?;
    try testing.expectEqual(offset, predicate.callee.span.?.start);
    try testing.expectEqual(offset + 2, predicate.callee.span.?.end);
}

test "desugar: constraint registration retains the marker span after whitespace" {
    const text = "page Demo\n  let item = 1\n  item   ~ 2\n  ~ 3\nend\n";
    var parsed = try syntax.parseSurface(testing.allocator, text);
    defer parsed.deinit(testing.allocator);
    var expanded = try syntax.desugar(testing.allocator, &parsed, .{});
    defer expanded.deinit(testing.allocator);
    for (expanded.pages.items[0].statements.items[1..]) |statement| {
        const call = statement.kind.expr_stmt.call;
        try testing.expectEqualStrings("constrain_on!", call.callee.name);
        const span = call.callee.span.?;
        try testing.expectEqualStrings("~", text[span.start..span.end]);
    }
    const current_page = expanded.pages.items[0].statements.items[2].kind.expr_stmt.call.args.items[0].call;
    try testing.expectEqualStrings("pagectx", current_page.callee.name);
    try testing.expect(current_page.callee.resolution == .intrinsic);
}

fn parseExpandClone(allocator: std.mem.Allocator) !void {
    var parsed = try syntax.parseSurface(allocator, source);
    var parsed_alive = true;
    defer if (parsed_alive) parsed.deinit(allocator);
    var surface_copy = try parsed.clone(allocator);
    defer surface_copy.deinit(allocator);
    var expanded = try syntax.desugar(allocator, &parsed, .{});
    var expanded_alive = true;
    defer if (expanded_alive) expanded.deinit(allocator);
    parsed.deinit(allocator);
    parsed_alive = false;
    var cloned = try expanded.clone(allocator);
    defer cloned.deinit(allocator);
    expanded.deinit(allocator);
    expanded_alive = false;
    const generic = cloned.functions.items[1].statements.items[0].kind.return_expr.call.args.items[1].call.type_args.items[0];
    try testing.expectEqualStrings("T", generic.class_name.?);
}

test "desugar: partial trees release allocations and generic references survive cloning" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseExpandClone, .{});
}

test "desugar: cancellation releases a partial expansion and leaves the surface reusable" {
    const Budget = struct {
        remaining: usize,
        fn canceled(context: *const anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(@constCast(context)));
            if (self.remaining == 0) return true;
            self.remaining -= 1;
            return false;
        }
    };
    var parsed = try syntax.parseSurface(testing.allocator, source);
    defer parsed.deinit(testing.allocator);
    for ([_]usize{ 0, 1, 10, 50, 100 }) |limit| {
        var budget = Budget{ .remaining = limit };
        try testing.expectError(error.Canceled, syntax.desugar(testing.allocator, &parsed, .{
            .cancellation = .{ .context = &budget, .is_canceled = Budget.canceled },
        }));
    }
    var expanded = try syntax.desugar(testing.allocator, &parsed, .{});
    defer expanded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), expanded.pages.items.len);
}

fn expandSource(text: []const u8) !ast.Module {
    var parsed = try syntax.parseSurface(testing.allocator, text);
    defer parsed.deinit(testing.allocator);
    return syntax.desugar(testing.allocator, &parsed, .{});
}

fn expectCall(expr: ast.Expr, name: []const u8, arity: usize) !ast.CallExpr {
    switch (expr) {
        .call => |call| {
            try testing.expectEqualStrings(name, call.callee.name);
            try testing.expectEqual(arity, call.args.items.len);
            return call;
        },
        else => return error.ExpectedCallExpr,
    }
}

fn expectNumber(expr: ast.Expr, expected: f32) !void {
    switch (expr) {
        .number => |actual| try testing.expectApproxEqAbs(expected, actual, 0.0001),
        else => return error.ExpectedNumberExpr,
    }
}

fn expectString(expr: ast.Expr, expected: []const u8) !void {
    switch (expr) {
        .string => |actual| try testing.expectEqualStrings(expected, actual.text),
        else => return error.ExpectedStringExpr,
    }
}

fn expectBoolean(expr: ast.Expr, expected: bool) !void {
    switch (expr) {
        .boolean => |actual| try testing.expectEqual(expected, actual),
        else => return error.ExpectedBooleanExpr,
    }
}

test "desugar: expression bodies return values and execute Void expressions" {
    var parsed = try expandSource(
        \\fn square(x: Number) -> Number = x * x
        \\
        \\fn remember(action: (Document, String, Number) -> Void) -> Void =
        \\  action(
        \\    docctx(),
        \\    "layout_h_center_offset",
        \\    42,
        \\  )
        \\
        \\fn/! badge(text_value: String) -> Text = text(text_value)
        \\
    );
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), parsed.functions.items.len);

    const square = parsed.functions.items[0];
    try testing.expectEqualStrings("square", square.name);
    try testing.expectEqual(@as(usize, 1), square.statements.items.len);
    _ = try expectCall(square.statements.items[0].kind.return_expr, "mul", 2);

    const remember = parsed.functions.items[1];
    try testing.expectEqualStrings("remember", remember.name);
    try testing.expectEqual(@as(usize, 1), remember.statements.items.len);
    _ = try expectCall(remember.statements.items[0].kind.expr_stmt, "action", 3);

    const badge = parsed.functions.items[2];
    try testing.expectEqualStrings("badge", badge.name);
    try testing.expectEqual(@as(usize, 1), badge.statements.items.len);
    _ = try expectCall(badge.statements.items[0].kind.return_expr, "text", 1);

    const placing = parsed.functions.items[3];
    try testing.expectEqualStrings("badge!", placing.name);
    const place_on = try expectCall(placing.statements.items[0].kind.return_expr, "place_on!", 2);
    _ = try expectCall(place_on.args.items[0], "pagectx", 0);
    _ = try expectCall(place_on.args.items[1], "badge", 1);
}

test "desugar: paired functions retain default arguments and source spans" {
    var parsed = try expandSource(
        \\fn/! note(text_value: String, tone: String = "soft") -> Text
        \\  return text(text_value)
        \\end
        \\
    );
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), parsed.functions.items.len);
    const note = parsed.functions.items[0];
    try testing.expectEqualStrings("note", note.name);
    try testing.expectEqual(@as(usize, 2), note.params.items.len);
    try testing.expectEqualStrings("tone", note.params.items[1].name);
    try expectString(note.params.items[1].default_value.?.*, "soft");

    const placing = parsed.functions.items[1];
    try testing.expectEqualStrings("note!", placing.name);
    try testing.expectEqual(@as(usize, 2), placing.params.items.len);
    try testing.expectEqualStrings("tone", placing.params.items[1].name);
    try expectString(placing.params.items[1].default_value.?.*, "soft");
    try testing.expectEqual(note.span.start, placing.span.start);
    try testing.expectEqual(note.span.end, placing.span.end);

    const return_expr = placing.statements.items[0].kind.return_expr;
    const place_call = try expectCall(return_expr, "place_on!", 2);
    _ = try expectCall(place_call.args.items[0], "pagectx", 0);
    const inner_call = try expectCall(place_call.args.items[1], "note", 2);
    switch (inner_call.args.items[0]) {
        .ident => |ident| try testing.expectEqualStrings("text_value", ident.name),
        else => return error.ExpectedIdentifier,
    }
    switch (inner_call.args.items[1]) {
        .ident => |ident| try testing.expectEqualStrings("tone", ident.name),
        else => return error.ExpectedIdentifier,
    }
}

test "desugar: arithmetic string and boolean operators produce primitive calls" {
    var parsed = try expandSource(
        \\page Expr
        \\  let value = 1 + 2 * -3
        \\  let text = "a" ++ "b" ++ "c"
        \\  let flag = !false
        \\end
        \\
    );
    defer parsed.deinit(testing.allocator);
    const program = &parsed;

    const numeric = program.pages.items[0].statements.items[0].kind.let_binding.expr;
    const add = try expectCall(numeric, "add", 2);
    try expectNumber(add.args.items[0], 1);
    const mul = try expectCall(add.args.items[1], "mul", 2);
    try expectNumber(mul.args.items[0], 2);
    const neg = try expectCall(mul.args.items[1], "neg", 1);
    try expectNumber(neg.args.items[0], 3);

    const text = program.pages.items[0].statements.items[1].kind.let_binding.expr;
    const outer_concat = try expectCall(text, "concat", 2);
    const inner_concat = try expectCall(outer_concat.args.items[0], "concat", 2);
    try expectString(inner_concat.args.items[0], "a");
    try expectString(inner_concat.args.items[1], "b");
    try expectString(outer_concat.args.items[1], "c");

    const flag = program.pages.items[0].statements.items[2].kind.let_binding.expr;
    const logical_not = try expectCall(flag, "not", 1);
    try expectBoolean(logical_not.args.items[0], false);
}

test "desugar: stage variables shadow callable names until rebound" {
    var expanded = try expandSource(
        \\fn s() -> Number = 99
        \\page Demo
        \\  stages s { first second }
        \\  let invalid = s()
        \\  let s = (value: Number) |-> value
        \\  let valid = s(42)
        \\end
    );
    defer expanded.deinit(testing.allocator);
    for (expanded.pages.items, 0..) |page, index| {
        const invalid = page.statements.items[0].kind.let_binding.expr;
        try testing.expect(invalid == .apply);
        try testing.expectEqual(@as(f32, @floatFromInt(index)), invalid.apply.callee.number);
        const valid = page.statements.items[2].kind.let_binding.expr;
        try testing.expectEqualStrings("s", valid.call.callee.name);
    }
}

test "desugar: show expands to ordinary bindings and primitive calls" {
    var expanded = try expandSource(
        \\page Demo
        \\  show true
        \\    let item = text! "Body"
        \\  end
        \\  item.value.content = "Updated"
        \\end
    );
    defer expanded.deinit(testing.allocator);
    const statements = expanded.pages.items[0].statements.items;
    try testing.expectEqual(@as(usize, 4), statements.len);
    const predicate = statements[0].kind.let_binding;
    try testing.expect(predicate.name_span == null);
    try testing.expect(predicate.expr == .lambda);
    try testing.expect(predicate.expr.lambda.body.boolean);
    const binding = statements[2].kind.let_binding;
    try testing.expectEqualStrings("item", binding.name);
    try testing.expectEqualStrings("draw_when!", binding.expr.call.callee.name);
    try testing.expect(binding.expr.call.callee.resolution == .intrinsic);
    try testing.expectEqualStrings(predicate.name, binding.expr.call.args.items[1].ident.name);
    try testing.expectEqualStrings("text!", binding.expr.call.args.items[0].call.callee.name);
    try testing.expect(statements[3].kind == .property_set);
}
