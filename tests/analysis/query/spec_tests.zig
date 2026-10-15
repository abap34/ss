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

test "analysis query spec: expired structural parse budget keeps callable target" {
    const source =
        \\page title
        \\  let t1 = ultra_big! "Title"
        \\end
        \\
    ;
    const offset = (std.mem.indexOf(u8, source, "ultra_big!") orelse return error.TestUnexpectedResult) + 1;

    var context = try analysis.query.context.Context.initWithBudget(testing.allocator, .{
        .path = "unit.ss",
        .source = source,
        .offset = offset,
    }, .{
        .start_ns = 0,
        .budget_ns = 0,
    });
    defer context.deinit(testing.allocator);

    try testing.expect(context.module() == null);
    try testing.expectEqualStrings("ultra_big!", context.target);
}

test "analysis query spec: expired structural parse budget keeps local target" {
    const source =
        \\page title
        \\  let t1 = ultra_big! "Title"
        \\  ~ t1.left == page.left
        \\end
        \\
    ;
    const offset = (std.mem.indexOf(u8, source, "t1.left") orelse return error.TestUnexpectedResult) + 1;

    var context = try analysis.query.context.Context.initWithBudget(testing.allocator, .{
        .path = "unit.ss",
        .source = source,
        .offset = offset,
    }, .{
        .start_ns = 0,
        .budget_ns = 0,
    });
    defer context.deinit(testing.allocator);

    try testing.expect(context.module() == null);
    try testing.expectEqualStrings("t1", context.target);
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
