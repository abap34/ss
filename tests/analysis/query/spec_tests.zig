const std = @import("std");
const analysis = @import("analysis");
const allocation_testing = @import("allocation_testing");
const testing = std.testing;

test "analysis query spec: document and page settings share value fields and their definitions" {
    const path = "stdlib/internal/settings-query-test.ss";
    const source =
        \\import std:prelude as *
        \\type PageSettings { layout_h_center_offset: String = "Unrelated" }
        \\fn document_offset(doc: Document) -> Number = doc.layout_h_center_offset
        \\fn page_offset(page: Page) -> Number = page.layout_h_center_offset
        \\page main
        \\  let value: Number = document_offset(docctx()) + page_offset(pagectx())
        \\end
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    for ([_][]const u8{ "doc.layout_h_center_offset", "page.layout_h_center_offset" }) |needle| {
        try expectAppliedField(&snapshot, path, source, needle, "layout_h_center_offset", "Number", 4);
        const request = analysis.query.types.SourceRequest{
            .path = path,
            .source = source,
            .offset = std.mem.indexOf(u8, source, needle).? + needle.len - 1,
        };
        const definitions = try analysis.snapshot.definitionAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 });
        defer testing.allocator.free(definitions);
        try testing.expectEqual(@as(usize, 1), definitions.len);
        try testing.expectEqualStrings("std:document/settings", definitions[0].module_spec orelse return error.ExpectedDefinitionModule);
        var completion = try analysis.snapshot.completeAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 });
        defer completion.deinit(testing.allocator);
        var has_left = false;
        for (completion.items) |candidate| {
            try testing.expect(!std.mem.eql(u8, candidate.label, "content"));
            try testing.expect(!std.mem.eql(u8, candidate.label, "render_kind"));
            if (std.mem.eql(u8, candidate.label, "left")) {
                try testing.expectEqualStrings("Anchor", candidate.detail orelse "");
                has_left = true;
            }
        }
        try testing.expectEqual(std.mem.startsWith(u8, needle, "page."), has_left);
    }
}

fn expectAppliedField(snapshot: *const analysis.snapshot.AnalysisSnapshot, path: []const u8, source: []const u8, needle: []const u8, field_name: []const u8, expected_type: []const u8, declaration_line: usize) !void {
    const offset = std.mem.indexOf(u8, source, needle).? + needle.len - 1;
    const request = analysis.query.types.SourceRequest{ .path = path, .source = source, .offset = offset };
    var completion = try analysis.snapshot.completeAt(testing.allocator, snapshot, request, .{ .budget_ms = 1000 });
    defer completion.deinit(testing.allocator);
    var found = false;
    for (completion.items) |candidate| {
        if (!std.mem.eql(u8, candidate.label, field_name)) continue;
        try testing.expectEqualStrings(expected_type, candidate.detail orelse "");
        found = true;
    }
    try testing.expect(found);
    var hover = (try analysis.snapshot.hoverAt(testing.allocator, snapshot, request, .{ .budget_ms = 1000 })) orelse return error.ExpectedHover;
    defer hover.deinit(testing.allocator);
    const expected = try std.fmt.allocPrint(testing.allocator, "({s}: {s})", .{ field_name, expected_type });
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.indexOf(u8, hover.markdown, expected) != null);
    const definitions = try analysis.snapshot.definitionAt(testing.allocator, snapshot, request, .{ .budget_ms = 1000 });
    defer testing.allocator.free(definitions);
    try testing.expectEqual(@as(usize, 1), definitions.len);
    try testing.expectEqual(declaration_line, definitions[0].line);
}

test "analysis query spec: applied fields retain arguments across members constructors calls and updates" {
    const path = "stdlib/internal/applied-fields-query-test.ss";
    const source =
        \\type Box<T> { value: T }
        \\type Handler<T> { apply: (T) -> T }
        \\type T { unrelated: String }
        \\fn identity<T>(value: T) -> T = value
        \\fn nested(box: Box<Box<Number>>) -> Number = box.value.value
        \\fn optional(box: Box<String>?) -> String = box?.value ?? ""
        \\fn callback(handler: Handler<Number>) -> Number = handler.apply(3)
        \\fn generic<T>(box: Box<T>) -> T = identity<Box<T>>(box).value
        \\page main
        \\  let number = Box<Number> { value = 7 }
        \\  let inferred = Box { value = "Inferred" }
        \\  let deep = Box { value = number }
        \\  let updated = deep with { value.value = 9 }
        \\  let direct: Number = identity(number).value
        \\  let explicit: Number = identity<Box<Number>>(number).value
        \\  let direct_constructor: String = (Box<String> { value = "Direct" }).value
        \\end
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    for ([_][]const u8{ "box.value.value", "Box<Number> { value", "with { value.value", "identity(number).value", "identity<Box<Number>>(number).value" }) |needle| {
        try expectAppliedField(&snapshot, path, source, needle, "value", "Number", 0);
    }
    for ([_][]const u8{ "box?.value", "Box { value", "(Box<String> { value = \"Direct\" }).value" }) |needle| {
        try expectAppliedField(&snapshot, path, source, needle, "value", "String", 0);
    }
    try expectAppliedField(&snapshot, path, source, "handler.apply", "apply", "Number -> Number", 1);
    try expectAppliedField(&snapshot, path, source, "identity<Box<T>>(box).value", "value", "T", 0);
    // Query specialization must leave the shared declaration facts unchanged.
    for (snapshot.record_fields) |field| {
        if (std.mem.eql(u8, field.record_name, "Box")) try testing.expectEqual(.parameter, field.value_type.kind);
    }
}

test "analysis query spec: incomplete applied members and updates retain concrete completion" {
    const path = "stdlib/internal/partial-applied-query-test.ss";
    const cases = [_]struct { source: []const u8, needle: []const u8 }{
        .{ .source = "type Box<T> { value: T }\nfn read(box: Box<Number>) -> Number = box.\n", .needle = "box." },
        .{ .source = "type Box<T> { value: T }\npage main\nlet box = Box { value = Box { value = 1 } }\nlet next = box with { value. }\nend\n", .needle = "with { value." },
        .{ .source = "type Box<T> { value: T }\npage main\nlet box = Box<Number> { val = 1 }\nend\n", .needle = "Box<Number> { val" },
    };
    for (cases) |case| {
        var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
        defer sources.deinit();
        try sources.put(path, case.source);
        var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
        defer snapshot.deinit();
        var completion = try analysis.snapshot.completeAt(testing.allocator, &snapshot, .{
            .path = path,
            .source = case.source,
            .offset = std.mem.indexOf(u8, case.source, case.needle).? + case.needle.len,
        }, .{ .budget_ms = 1000 });
        defer completion.deinit(testing.allocator);
        var found = false;
        for (completion.items) |item| {
            if (!std.mem.eql(u8, item.label, "value")) continue;
            try testing.expectEqualStrings("Number", item.detail orelse "");
            found = true;
        }
        if (!found) std.debug.print("missing concrete field completion after {s}\n", .{case.needle});
        try testing.expect(found);
    }
}

test "analysis query spec: applied imported fields retain their nominal module" {
    const path = "stdlib/internal/applied-import-query-test.ss";
    const imported_path = "stdlib/internal/query-types.ss";
    const imported = "type Box<T> { value: T }\ntype Payload { size: Number }\nfn identity<T>(value: T) -> T = value\n";
    const source =
        \\import ./query-types as lib
        \\type Payload { size: String }
        \\fn read(box: lib::Box<lib::Payload>) -> Number = box.value.size
        \\page main
        \\  let n = lib::identity<lib::Payload>(lib::Payload { size = 3 }).size
        \\end
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    try sources.put(imported_path, imported);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    try expectAppliedField(&snapshot, path, source, "box.value.size", "size", "Number", 1);
    try expectAppliedField(&snapshot, path, source, "lib::identity<lib::Payload>(lib::Payload { size = 3 }).size", "size", "Number", 1);
    const definitions = try analysis.snapshot.definitionAt(testing.allocator, &snapshot, .{
        .path = path,
        .source = source,
        .offset = std.mem.indexOf(u8, source, "box.value.size").? + "box.value.si".len,
    }, .{ .budget_ms = 1000 });
    defer testing.allocator.free(definitions);
    try testing.expectEqual(@as(usize, 1), definitions.len);
    try testing.expect(std.mem.endsWith(u8, definitions[0].path orelse "", "query-types.ss"));
}

fn exerciseAppliedQueryAllocations(allocator: std.mem.Allocator, snapshot: *const analysis.snapshot.AnalysisSnapshot, request: analysis.query.types.SourceRequest) !void {
    var completion = try analysis.snapshot.completeAt(allocator, snapshot, request, .{ .budget_ms = 10000 });
    defer completion.deinit(allocator);
    var hover = (try analysis.snapshot.hoverAt(allocator, snapshot, request, .{ .budget_ms = 10000 })) orelse return error.ExpectedHover;
    defer hover.deinit(allocator);
    const definitions = try analysis.snapshot.definitionAt(allocator, snapshot, request, .{ .budget_ms = 10000 });
    defer allocator.free(definitions);
}

test "analysis query spec: applied query allocations have request ownership" {
    const path = "stdlib/internal/applied-ownership-query-test.ss";
    const source = "type Box<T> { value: T }\nfn read(box: Box<Box<Number>>) -> Number = box.value.value\n";
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    const request = analysis.query.types.SourceRequest{
        .path = path,
        .source = source,
        .offset = std.mem.indexOf(u8, source, "box.value.value").? + "box.value.val".len,
    };
    try allocation_testing.checkAllAllocationFailures(testing.allocator, exerciseAppliedQueryAllocations, .{ &snapshot, request });
}

comptime {
    _ = @import("fallback_spec_tests.zig");
}

test "analysis query spec: optional members support completion hover and definition" {
    const path = "stdlib/internal/optional-query-test.ss";
    const source = "type Style { size: Number = 4 }\nfn read(style: Style?) -> Number = style?.size ?? 0\npage main\nend\n";
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

    const incomplete = "type Style { size: Number = 4 }\nfn read(style: Style?) -> Number = style?.\npage main\nend\n";
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
    const path = "stdlib/internal/literal-query-test.ss";
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

test "lambda parameters shadow outer names only within their lexical extent" {
    const path = "stdlib/internal/lambda-query-test.ss";
    const source =
        \\const identity: Number -> Number = (value: Number) |-> value
        \\fn factory() -> Number -> Number = (arg: Number) |-> arg
        \\page main
        \\  let x = "Outer"
        \\  let f = (x: Number) |-> x
        \\  let nested = (x: Number) |-> ((x: String) |-> x)("Inner")
        \\  let sibling = (n: Number) |-> n
        \\  let outside = x
        \\end
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    if (snapshot.diagnostics.hasErrors()) for (snapshot.diagnostics.items.items) |diagnostic| {
        std.debug.print("{s}: {s}\n", .{ diagnostic.code, diagnostic.message });
    };
    try testing.expect(!snapshot.diagnostics.hasErrors());
    const cases = [_]struct { needle: []const u8, name: []const u8, ty: []const u8, declaration: []const u8 }{
        .{ .needle = "|-> value", .name = "value", .ty = "Number", .declaration = "value: Number" },
        .{ .needle = "|-> arg", .name = "arg", .ty = "Number", .declaration = "arg: Number" },
        .{ .needle = "|-> x\n", .name = "x", .ty = "Number", .declaration = "x: Number" },
        .{ .needle = "|-> x)(", .name = "x", .ty = "String", .declaration = "x: String" },
        .{ .needle = "|-> n", .name = "n", .ty = "Number", .declaration = "n: Number" },
        .{ .needle = "outside = x", .name = "x", .ty = "String", .declaration = "x = \"Outer\"" },
        .{ .needle = "x: String", .name = "x", .ty = "String", .declaration = "x: String" },
    };
    var index = try @import("utils").source.LineIndex.init(testing.allocator, source);
    defer index.deinit(testing.allocator);
    for (cases) |case| {
        const begin = std.mem.indexOf(u8, source, case.needle).?;
        const offset = begin + std.mem.lastIndexOf(u8, case.needle, case.name).?;
        const request = analysis.query.types.SourceRequest{ .path = path, .source = source, .offset = offset };
        var hover = (try analysis.snapshot.hoverAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 })) orelse return error.ExpectedHover;
        defer hover.deinit(testing.allocator);
        const expected = try std.fmt.allocPrint(testing.allocator, "({s}: {s})", .{ case.name, case.ty });
        defer testing.allocator.free(expected);
        try testing.expect(std.mem.indexOf(u8, hover.markdown, expected) != null);
        const definitions = try analysis.snapshot.definitionAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 });
        defer testing.allocator.free(definitions);
        try testing.expectEqual(@as(usize, 1), definitions.len);
        const declaration = std.mem.indexOf(u8, source, case.declaration).?;
        try testing.expectEqual(index.lineAt(declaration).number - 1, definitions[0].line);
        var completion = try analysis.snapshot.completeAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 });
        defer completion.deinit(testing.allocator);
        var found = false;
        for (completion.items) |item| {
            if (std.mem.eql(u8, item.label, case.name)) {
                try testing.expectEqualStrings(case.ty, item.detail.?);
                found = true;
            }
        }
        try testing.expect(found);
    }
}

test "missing imports preserve local symbols folding and lexical definitions" {
    const path = "stdlib/internal/import-recovery-query.ss";
    const source =
        \\import ./missing-query-module as missing
        \\fn identity(value: Number) -> Number = value
        \\page a
        \\  let x = 1
        \\  let f = (n: Number) |-> n
        \\  let later = x
        \\end
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(snapshot.diagnostics.hasErrors());
    var unknown_import = false;
    for (snapshot.diagnostics.items.items) |diagnostic| if (std.mem.eql(u8, diagnostic.code, "UnknownImport")) {
        unknown_import = true;
    };
    if (!unknown_import) for (snapshot.diagnostics.items.items) |diagnostic| {
        std.debug.print("{s}: {s}\n", .{ diagnostic.code, diagnostic.message });
    };
    try testing.expect(unknown_import);
    const symbols = analysis.snapshot.documentSymbols(&snapshot, path);
    try testing.expectEqual(@as(usize, 2), symbols.len);
    try testing.expectEqualStrings("a", symbols[1].name);
    try testing.expectEqual(@as(usize, 1), analysis.snapshot.foldingRanges(&snapshot, path).len);
    const request = analysis.query.types.SourceRequest{ .path = path, .source = source, .offset = std.mem.indexOf(u8, source, "later = x").? + "later = ".len };
    var completion = try analysis.snapshot.completeAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 });
    defer completion.deinit(testing.allocator);
    var found = false;
    for (completion.items) |item| if (std.mem.eql(u8, item.label, "x")) {
        found = true;
        try testing.expectEqualStrings("unknown", item.detail.?);
    };
    try testing.expect(found);
    const definitions = try analysis.snapshot.definitionAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 });
    defer testing.allocator.free(definitions);
    try testing.expectEqual(@as(usize, 1), definitions.len);
    try testing.expectEqual(@as(usize, 3), definitions[0].line);
}

test "analysis query budget includes time spent obtaining the snapshot" {
    var now: i128 = 10 * std.time.ns_per_s;
    const started = now;
    now += 3 * std.time.ns_per_ms;
    const budget = analysis.query.types.QueryBudget.start(.{
        .budget_ms = 2,
        .start_ns = started,
        .clock = .{ .context = &now, .now_ns = testNow },
    });
    try testing.expect(budget.expired());
    try testing.expect(!budget.canceled());
}

test "analysis queries resolve nominal names inside nested type arguments" {
    const path = "stdlib/internal/nested-type-query-test.ss";
    const source =
        \\type Payload {
        \\  count: Number
        \\}
        \\fn inspect(items: Selection<Selection<Payload>>) -> Void
        \\end
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    const offset = std.mem.lastIndexOf(u8, source, "Payload").?;
    const request = analysis.query.types.SourceRequest{ .path = path, .source = source, .offset = offset };
    var hover = (try analysis.snapshot.hoverAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 })) orelse return error.ExpectedHover;
    defer hover.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "Payload") != null);
    const definitions = try analysis.snapshot.definitionAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 });
    defer testing.allocator.free(definitions);
    try testing.expectEqual(@as(usize, 1), definitions.len);
    try testing.expectEqual(@as(usize, 0), definitions[0].line);
}

test "analysis query spec: generic type parameters retain their lexical scope and definition" {
    const path = "stdlib/internal/generic-query-test.ss";
    const source =
        \\type T { count: Number }
        \\type Box<T> { value: T }
        \\fn first<T>(value: T) -> T = value
        \\fn second<T>(value: T) -> T = value
        \\page main
        \\end
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());

    for ([_]struct { occurrence: []const u8, relative: usize, declaration_line: usize, declaration_column: usize }{
        .{ .occurrence = "Box<T>", .relative = 4, .declaration_line = 1, .declaration_column = 9 },
        .{ .occurrence = "value: T }", .relative = 7, .declaration_line = 1, .declaration_column = 9 },
        .{ .occurrence = "first<T>", .relative = 6, .declaration_line = 2, .declaration_column = 9 },
        .{ .occurrence = "first<T>(value: T)", .relative = 16, .declaration_line = 2, .declaration_column = 9 },
        .{ .occurrence = "second<T>(value: T)", .relative = 17, .declaration_line = 3, .declaration_column = 10 },
    }) |item| {
        const offset = std.mem.indexOf(u8, source, item.occurrence).? + item.relative;
        const request = analysis.query.types.SourceRequest{ .path = path, .source = source, .offset = offset };
        var hover = (try analysis.snapshot.hoverAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 })).?;
        defer hover.deinit(testing.allocator);
        try testing.expectEqualStrings("Type parameter `T`", hover.markdown);
        var completion = try analysis.snapshot.completeAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 });
        defer completion.deinit(testing.allocator);
        var found_parameter = false;
        for (completion.items) |candidate| {
            if (std.mem.eql(u8, candidate.label, "T") and std.mem.eql(u8, candidate.detail orelse "", "type parameter")) found_parameter = true;
        }
        try testing.expect(found_parameter);
        const definitions = try analysis.snapshot.definitionAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 });
        defer testing.allocator.free(definitions);
        try testing.expectEqual(@as(usize, 1), definitions.len);
        try testing.expectEqual(item.declaration_line, definitions[0].line);
        try testing.expectEqual(item.declaration_column, definitions[0].character);
    }

    var count: usize = 0;
    var first_id: ?@TypeOf(snapshot.value_bindings[0].value_type.parameter_id.?) = null;
    for (snapshot.value_bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "first") and !std.mem.eql(u8, binding.name, "second")) continue;
        try testing.expect(std.mem.indexOf(u8, binding.signature, "<T>(value: T) -> T") != null);
        try testing.expectEqual(.parameter, binding.value_type.kind);
        const id = binding.value_type.parameter_id.?;
        if (first_id) |previous| try testing.expect(!std.meta.eql(previous, id));
        first_id = id;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "analysis query spec: placement members expose concrete input and hide erased fields" {
    const path = "stdlib/internal/placement-query-test.ss";
    const source =
        \\type Box<T> { value: T }
        \\fn read(item: Placed<Box<Number>>) -> Number = item.value.value
        \\fn owner(item: Placement) -> Page = item.page
        \\fn document_of(item: Placement) -> Document = item.document
        \\fn left(item: Placement) -> Anchor = item.left
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    try expectAppliedField(&snapshot, path, source, "item.value.value", "value", "Number", 0);
    for ([_]struct { needle: []const u8, label: []const u8, ty: []const u8, has_value: bool }{
        .{ .needle = "item.value", .label = "value", .ty = "Box<Number>", .has_value = true },
        .{ .needle = "item.page", .label = "page", .ty = "Page", .has_value = false },
        .{ .needle = "item.document", .label = "document", .ty = "Document", .has_value = false },
        .{ .needle = "item.left", .label = "left", .ty = "Anchor", .has_value = false },
    }) |case| {
        const request = analysis.query.types.SourceRequest{ .path = path, .source = source, .offset = std.mem.indexOf(u8, source, case.needle).? + case.needle.len - 1 };
        var completion = try analysis.snapshot.completeAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 });
        defer completion.deinit(testing.allocator);
        var found = false;
        for (completion.items) |item| {
            try testing.expect(!std.mem.eql(u8, item.label, "content"));
            if (!case.has_value) try testing.expect(!std.mem.eql(u8, item.label, "value"));
            if (!std.mem.eql(u8, item.label, case.label)) continue;
            try testing.expectEqualStrings(case.ty, item.detail orelse "");
            found = true;
        }
        try testing.expect(found);
        var hover = (try analysis.snapshot.hoverAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 })) orelse return error.ExpectedHover;
        defer hover.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, hover.markdown, case.ty) != null);
        const definitions = try analysis.snapshot.definitionAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 });
        defer testing.allocator.free(definitions);
        try testing.expectEqual(@as(usize, 0), definitions.len);
    }
}

test "analysis query spec: paired typed constructors expose placing signatures and input fields" {
    const path = "stdlib/internal/paired-placement-query-test.ss";
    const source =
        \\import std:text/content as native
        \\type Wrapper<T> { content: T }
        \\fn display<T>(self: Placed<Wrapper<T>>) -> T = self.value.content
        \\fn/! wrap<T>(content: T) -> Wrapper<T> = Wrapper<T> { content = content }
        \\page main
        \\  let content = native::Text { content = "Wrapped" }
        \\  let placed = wrap!(content)
        \\  let text: String = placed.value.content.content
        \\end
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    try expectAppliedField(&snapshot, path, source, "placed.value.content", "content", "Text", 1);
    const request = analysis.query.types.SourceRequest{
        .path = path,
        .source = source,
        .offset = std.mem.indexOf(u8, source, "wrap!(content)").? + 2,
    };
    var hover = (try analysis.snapshot.hoverAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 })) orelse return error.ExpectedHover;
    defer hover.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "Placed<Wrapper<T>>") != null);
    const definitions = try analysis.snapshot.definitionAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 });
    defer testing.allocator.free(definitions);
    try testing.expectEqual(@as(usize, 1), definitions.len);
    try testing.expectEqual(@as(usize, 3), definitions[0].line);
}

test "analysis query spec: typed selections retain input fields through first and advertise generic syntax" {
    const path = "stdlib/internal/typed-selection-query-test.ss";
    const source =
        \\type Heading { title: String }
        \\fn title(scope: Document) -> String = first(select<Heading>(scope)).value.title
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    try expectAppliedField(&snapshot, path, source, "first(select<Heading>(scope)).value.title", "title", "String", 0);
    const request = analysis.query.types.SourceRequest{
        .path = path,
        .source = source,
        .offset = std.mem.indexOf(u8, source, "select<Heading>").? + 2,
    };
    var hover = (try analysis.snapshot.hoverAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 })) orelse return error.ExpectedHover;
    defer hover.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "select<T>(scope) -> Selection<Placed<T>>") != null);
}

test "analysis query spec: selection operators retain concrete fields through direct expressions" {
    for ([_][]const u8{ "|", "&", "-" }) |operator| {
        const path = "stdlib/internal/selection-operator-query-test.ss";
        const source = try std.fmt.allocPrint(testing.allocator, "type Heading {{ title: String }}\nfn title(a: Selection<Placed<Heading>>, b: Selection<Placed<Heading>>) -> String = first(a {s} b).value.title\n", .{operator});
        defer testing.allocator.free(source);
        var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
        defer sources.deinit();
        try sources.put(path, source);
        var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
        defer snapshot.deinit();
        try testing.expect(!snapshot.diagnostics.hasErrors());
        const expression = source[std.mem.indexOf(u8, source, "first(a").?..];
        try expectAppliedField(&snapshot, path, source, std.mem.trim(u8, expression, "\n"), "title", "String", 0);
    }
}

test "analysis query spec: unfinished placement access keeps the concrete input type" {
    const path = "stdlib/internal/unfinished-placement-query-test.ss";
    for ([_]struct { source: []const u8, needle: []const u8, expected: []const u8 }{
        .{ .source = "type Box<T> { value: T }\nfn read(item: Placed<Box<Number>>) -> Number = item.\n", .needle = "item.", .expected = "Box<Number>" },
        .{ .source = "type Box<T> { value: T }\nfn read(item: Placed<Box<Number>>) -> Number = item.value.\n", .needle = "item.value.", .expected = "Number" },
    }) |case| {
        var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
        defer sources.deinit();
        try sources.put(path, case.source);
        var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
        defer snapshot.deinit();
        var completion = try analysis.snapshot.completeAt(testing.allocator, &snapshot, .{
            .path = path,
            .source = case.source,
            .offset = std.mem.indexOf(u8, case.source, case.needle).? + case.needle.len,
        }, .{ .budget_ms = 1000 });
        defer completion.deinit(testing.allocator);
        var found = false;
        for (completion.items) |item| {
            if (!std.mem.eql(u8, item.label, "value")) continue;
            try testing.expectEqualStrings(case.expected, item.detail orelse "");
            found = true;
        }
        try testing.expect(found);
    }
}

test "analysis query spec: display receiver fields retain independent lexical scopes" {
    const path = "stdlib/internal/display-scope-query-test.ss";
    const source =
        \\type Label { title: String }
        \\type Counter { count: Number }
        \\type Output { text: String }
        \\fn display(first: Placed<Label>) -> Output
        \\  let title = first.value.title
        \\  return Output { text = title }
        \\end
        \\fn display(second: Placed<Counter>) -> Output
        \\  let count = second.value.count
        \\  return Output { text = "Counter" }
        \\end
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    try expectAppliedField(&snapshot, path, source, "first.value.title", "title", "String", 0);
    try expectAppliedField(&snapshot, path, source, "second.value.count", "count", "Number", 1);
    for (snapshot.value_bindings) |binding| try testing.expect(!std.mem.eql(u8, binding.name, "display"));
}

test "analysis query spec: singleton selection preserves its input through first" {
    const path = "stdlib/internal/singleton-selection-query-test.ss";
    const source =
        \\type Heading { title: String }
        \\fn selection<T>(item: T) -> Selection<T> = select(item, "self_placement")
        \\fn title(item: Placed<Heading>) -> String = first(selection(item)).value.title
        \\fn direct(item: Placed<Heading>) -> String = first(select(item, "self_placement")).value.title
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    try expectAppliedField(&snapshot, path, source, "first(selection(item)).value.title", "title", "String", 0);
    try expectAppliedField(&snapshot, path, source, "first(select(item, \"self_placement\")).value.title", "title", "String", 0);
}

test "analysis query spec: filtering preserves generic placement input fields" {
    const path = "stdlib/internal/filtered-selection-query-test.ss";
    const source =
        \\type Heading { title: String }
        \\fn filter<T>(items: Selection<T>, predicate: T -> Bool) -> Selection<T> = selection_filter(items, predicate)
        \\fn title(items: Selection<Placed<Heading>>) -> String = first(filter(items, (h: Placed<Heading>) |-> true)).value.title
        \\fn direct(items: Selection<Placed<Heading>>) -> String = first(selection_filter(items, (h: Placed<Heading>) |-> true)).value.title
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    try expectAppliedField(&snapshot, path, source, "first(filter(items, (h: Placed<Heading>) |-> true)).value.title", "title", "String", 0);
    try expectAppliedField(&snapshot, path, source, "first(selection_filter(items, (h: Placed<Heading>) |-> true)).value.title", "title", "String", 0);
}

test "analysis query spec: public placement retains concrete input fields through imports" {
    const path = "public-placement-query.ss";
    const source =
        \\import std:layout as layout
        \\import std:text as text_api
        \\type Heading { title: String }
        \\fn display(self: Placed<Heading>) -> text_api::Text = text_api::Text { content = self.value.title }
        \\page main
        \\  let inferred = place!(Heading { title = "Inferred" })
        \\  let explicit = layout::place!<Heading>(Heading { title = "Explicit" })
        \\  let first = inferred.value.title
        \\  let second = explicit.value.title
        \\end
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    try expectAppliedField(&snapshot, path, source, "inferred.value.title", "title", "String", 2);
    try expectAppliedField(&snapshot, path, source, "explicit.value.title", "title", "String", 2);
}

test "analysis query spec: groups retain concrete types through unfinished placement access" {
    const path = "stdlib/internal/group-query-test.ss";
    const source =
        \\import std:text as text_api
        \\import std:layout
        \\page main
        \\  let text = text_api::Text { content = "Child" }
        \\  let content = group(text, group(text))
        \\  let item = place!(content)
        \\  let input = item.
        \\end
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    var completion = try analysis.snapshot.completeAt(testing.allocator, &snapshot, .{
        .path = path,
        .source = source,
        .offset = std.mem.indexOf(u8, source, "item.").? + "item.".len,
    }, .{ .budget_ms = 1000 });
    defer completion.deinit(testing.allocator);
    var found = false;
    for (completion.items) |item| {
        if (!std.mem.eql(u8, item.label, "value")) continue;
        try testing.expectEqualStrings("Group<Text, Group<Text>>", item.detail.?);
        found = true;
    }
    try testing.expect(found);
    var hover = (try analysis.snapshot.hoverAt(testing.allocator, &snapshot, .{
        .path = path,
        .source = source,
        .offset = std.mem.indexOf(u8, source, "group(text").? + 2,
    }, .{ .budget_ms = 1000 })) orelse return error.ExpectedHover;
    defer hover.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "Group<T1, ...>") != null);
}

test "analysis query spec: composition spacing completes in member and with expressions" {
    const path = "stdlib/internal/composition-query-test.ss";
    for ([_][]const u8{ "row.ga", "row with { ga }" }) |expression| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\import std:text as text_api
            \\page main
            \\  let a = text_api::Text {{ content = "A" }}
            \\  let row = a || a
            \\  let updated = {s}
            \\end
        , .{expression});
        defer testing.allocator.free(source);
        var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
        defer sources.deinit();
        try sources.put(path, source);
        var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
        defer snapshot.deinit();
        var completion = try analysis.snapshot.completeAt(testing.allocator, &snapshot, .{
            .path = path,
            .source = source,
            .offset = std.mem.lastIndexOf(u8, source, "ga").? + 2,
        }, .{ .budget_ms = 1000 });
        defer completion.deinit(testing.allocator);
        var found = false;
        for (completion.items) |item| {
            if (!std.mem.eql(u8, item.label, "gap")) continue;
            try testing.expectEqualStrings("Number", item.detail.?);
            found = true;
        }
        try testing.expect(found);
    }
}

test "analysis query spec: qualified constants support navigation and field completion" {
    const path = "stdlib/internal/qualified-values-query-test.ss";
    const imported_path = "stdlib/internal/query-values.ss";
    const imported = "type Style { size: Number = 18 }\nconst defaults: Style = Style {}\n";
    const source =
        \\import ./query-values as lib
        \\page main
        \\  let defaults = "local"
        \\  let original = lib::defaults
        \\  let size = lib::defaults.size
        \\end
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    try sources.put(imported_path, imported);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    const request = analysis.query.types.SourceRequest{
        .path = path,
        .source = source,
        .offset = std.mem.indexOf(u8, source, "lib::defaults").? + "lib::def".len,
    };
    const definitions = try analysis.snapshot.definitionAt(testing.allocator, &snapshot, request, .{ .budget_ms = 1000 });
    defer testing.allocator.free(definitions);
    try testing.expectEqual(@as(usize, 1), definitions.len);
    try testing.expect(std.mem.endsWith(u8, definitions[0].path orelse "", "query-values.ss"));
    try expectAppliedField(&snapshot, path, source, "lib::defaults.size", "size", "Number", 0);
}
