const std = @import("std");
const analysis = @import("analysis");
const testing = std.testing;

comptime {
    _ = @import("fallback_spec_tests.zig");
}

test "analysis query spec: optional members support completion hover and definition" {
    const path = "stdlib/core/optional-query-test.ss";
    const source = "record Style { size: Number = 4 }\nfn read(style: Style?) -> Number = style?.size ?? 0\npage main\nend\n";
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    const offset = std.mem.indexOf(u8, source, "style?.size").? + "style?.si".len;
    const request = analysis.query.types.SourceRequest{ .path = path, .source = source, .offset = offset };
    var completion = try analysis.snapshot.completeAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 });
    defer completion.deinit(testing.allocator);
    var found = false;
    for (completion.items) |item| if (std.mem.eql(u8, item.label, "size")) {
        found = true;
    };
    try testing.expect(found);
    var hover = (try analysis.snapshot.hoverAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 })).?;
    defer hover.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "Number") != null);
    const definitions = try analysis.snapshot.definitionAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 });
    defer testing.allocator.free(definitions);
    try testing.expectEqual(@as(usize, 1), definitions.len);
    try testing.expectEqual(@as(usize, 0), definitions[0].line);

    const incomplete = "record Style { size: Number = 4 }\nfn read(style: Style?) -> Number = style?.\npage main\nend\n";
    try sources.put(path, incomplete);
    var partial = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer partial.deinit();
    var suggestions = try analysis.snapshot.completeAt(testing.allocator, &partial, .{
        .path = path,
        .source = incomplete,
        .offset = std.mem.indexOf(u8, incomplete, "style?.").? + "style?.".len,
    }, .{ .budget_ms = 1000 });
    defer suggestions.deinit(testing.allocator);
    found = false;
    for (suggestions.items) |item| if (std.mem.eql(u8, item.label, "size")) {
        found = true;
    };
    try testing.expect(found);
}

test "analysis query spec: zero millisecond budget is already expired" {
    const budget = analysis.query.types.QueryBudget.start(.{ .budget_ms = 0 });
    try testing.expect(budget.expired());
    try testing.expect(!budget.canceled());
}

test "analysis query spec: positive budget is available at query start" {
    const budget = analysis.query.types.QueryBudget.start(.{ .budget_ms = 1000 });
    try testing.expect(!budget.expired());
}

test "analysis query spec: cancellation expires an active budget" {
    var canceled = true;
    const budget = analysis.query.types.QueryBudget.start(.{
        .budget_ms = 1000,
        .cancellation = .{
            .context = &canceled,
            .is_canceled = cancellationState,
        },
    });
    try testing.expect(budget.expired());
    try testing.expect(budget.canceled());
}

test "analysis query spec: all query stages share the same deadline" {
    var now: i128 = 10 * std.time.ns_per_s;
    const budget = analysis.query.types.QueryBudget.start(.{
        .budget_ms = 2,
        .clock = .{ .context = &now, .now_ns = testNow },
    });
    const nested = budget;
    now += std.time.ns_per_ms;
    try testing.expect(!nested.expired());
    now += std.time.ns_per_ms;
    try testing.expect(nested.expired());
    try testing.expect(budget.expired());
    try testing.expect(!budget.canceled());
}

fn testNow(context: *const anyopaque) i128 {
    const now: *const i128 = @ptrCast(@alignCast(context));
    return now.*;
}

test "analysis query spec: expired context leaves lexical lookup to the bounded fallback" {
    try testing.expectError(error.NoQueryTarget, analysis.query.context.Context.initWithBudget(testing.allocator, .{
        .path = "unit.ss",
        .source = "page title\n  text!(\"Title\")\nend\n",
        .offset = 15,
    }, .{ .start_ns = 0, .budget_ns = 0 }));
}

fn cancellationState(context: *const anyopaque) bool {
    const canceled: *const bool = @ptrCast(@alignCast(context));
    return canceled.*;
}

test "analysis query spec: import alias completion respects path and keyword boundaries" {
    var snapshot = analysis.snapshot.AnalysisSnapshot{
        .allocator = testing.allocator,
        .diagnostics = analysis.diagnostics.DiagnosticBag.init(testing.allocator),
    };
    defer snapshot.deinit();
    const cases = [_]struct { source: []const u8, alias: ?[]const u8 }{
        .{ .source = "import as", .alias = null },
        .{ .source = "import assets/the", .alias = null },
        .{ .source = "import \"x\" as ", .alias = "x" },
        .{ .source = "import x as ", .alias = "x" },
        .{ .source = "  import\tx\tas\t", .alias = "x" },
        .{ .source = "import assets/theme as th", .alias = "theme" },
        .{ .source = "import \"assets as/theme\" as ", .alias = "theme" },
        .{ .source = "import \"assets as/theme", .alias = null },
        .{ .source = "import x aside", .alias = null },
        .{ .source = "import x ;; as ", .alias = null },
        .{ .source = "import x as ;; alias", .alias = null },
        .{ .source = "import x as *", .alias = null },
    };
    for (cases) |case| {
        var result = try analysis.snapshot.completeAt(testing.allocator, &snapshot, .{
            .path = "import.ss",
            .source = case.source,
            .offset = case.source.len,
        }, .{ .budget_ms = 1000 });
        defer result.deinit(testing.allocator);
        try testing.expect(!result.is_incomplete);
        var star = false;
        var alias = false;
        for (result.items) |item| {
            if (std.mem.eql(u8, item.label, "*")) star = true;
            if (case.alias) |expected| {
                if (std.mem.eql(u8, item.label, expected)) alias = true;
            }
        }
        try testing.expectEqual(case.alias != null, star);
        if (case.alias != null) try testing.expect(alias);
    }
}

test "folding ranges end on the closing line for every newline convention" {
    for ([_][]const u8{ "\n", "\r\n" }) |newline| {
        for ([_]bool{ false, true }) |final_newline| {
            const source = try std.mem.join(testing.allocator, newline, &.{ "page a", "  let x = 1", "end", "page b", "end" });
            defer testing.allocator.free(source);
            const text = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ source, if (final_newline) newline else "" });
            defer testing.allocator.free(text);
            var context = try analysis.query.context.Context.init(testing.allocator, .{ .path = "fold.ss", .source = text, .offset = 5 });
            defer context.deinit(testing.allocator);
            var index = try @import("utils").source.LineIndex.init(testing.allocator, text);
            defer index.deinit(testing.allocator);
            const ranges = try analysis.query.folding.collect(testing.allocator, index, context.module().?.*);
            defer testing.allocator.free(ranges);
            try testing.expectEqual(@as(usize, 2), ranges.len);
            for (ranges, [_][2]usize{ .{ 1, 3 }, .{ 4, 5 } }) |range, expected| {
                try testing.expectEqual(expected[0], index.lineAt(range.span.start).number);
                try testing.expectEqual(expected[1], index.lineAt(range.span.end).number);
                try testing.expectEqualStrings("end", text[range.span.end - 3 .. range.span.end]);
            }
        }
    }
}

test "hover and definition ignore literal and comment contents with either query budget" {
    const path = "stdlib/core/literal-query-test.ss";
    const source =
        \\fn target() -> String = "Value"
        \\page main
        \\  let a = "target"
        \\  let b = """
        \\    target
        \\  """
        \\  let c = <<
        \\    target
        \\  >>
        \\  ;; target
        \\  target()
        \\end
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    for ([_]u32{ 0, 1000 }) |budget| {
        var position: usize = std.mem.indexOf(u8, source, "page main").?;
        const call_position = std.mem.lastIndexOf(u8, source, "target").?;
        while (std.mem.indexOfPos(u8, source, position, "target")) |offset| {
            const request = analysis.query.types.SourceRequest{ .path = path, .source = source, .offset = offset + 2 };
            var hover = try analysis.snapshot.hoverAt(testing.allocator, &snapshot, request, .{ .budget_ms = budget });
            defer if (hover) |*value| value.deinit(testing.allocator);
            const definitions = try analysis.snapshot.definitionAt(testing.allocator, &snapshot, request, .{ .budget_ms = budget });
            defer testing.allocator.free(definitions);
            try testing.expectEqual(offset == call_position, hover != null);
            try testing.expectEqual(@as(usize, if (offset == call_position) 1 else 0), definitions.len);
            position = offset + "target".len;
        }
    }
}
