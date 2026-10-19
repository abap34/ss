const std = @import("std");
const allocation_testing = @import("allocation_testing");
const compiler = @import("compiler");
const query_types = compiler.analysis.query.types;
const resolve_query = compiler.analysis.query.resolve;
const snapshot_api = compiler.analysis.snapshot;
const type_resolution = compiler.language.type_resolution;

const testing = std.testing;

const DeadlineClock = struct {
    calls: usize = 0,
    expire_at: usize = std.math.maxInt(usize),

    fn now(context: *const anyopaque) i128 {
        const self: *DeadlineClock = @ptrCast(@alignCast(@constCast(context)));
        self.calls += 1;
        return if (self.calls >= self.expire_at) std.time.ns_per_s else 0;
    }

    fn options(self: *DeadlineClock) query_types.QueryOptions {
        return .{ .budget_ms = 100, .clock = .{ .context = self, .now_ns = now } };
    }
};

const DeadlineAfterTarget = struct {
    clock: *DeadlineClock,
    allocations: *testing.FailingAllocator,
    cancel: bool,
    triggered: bool = false,

    fn canceled(context: *const anyopaque) bool {
        const self: *DeadlineAfterTarget = @ptrCast(@alignCast(@constCast(context)));
        // The context owns one name allocation; the next allocation holds targets.
        if (self.allocations.alloc_index < 2) return false;
        self.triggered = true;
        self.clock.expire_at = self.clock.calls + 1;
        return self.cancel;
    }
};

test "analysis queries: every deadline selects the independent lexical completion" {
    var case = try CompletionCase.init(
        \\import std:text
        \\type Label {
        \\  title: String,
        \\  subtitle: String,
        \\  body: String
        \\}
        \\page main
        \\  let value = Label { title = "Title", subtitle = "Subtitle", body = "Body" }
        \\  let copy = value with { title = "Changed" }
        \\  let t = text!("Body")
        \\  text::text("Title")
        \\  ~ t.left == page.left + 20
        \\end
    );
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    for ([_][]const u8{ "page main\n", "text::", "t.", "with { " }) |needle| {
        const req = query_types.SourceRequest{ .path = case.path, .source = case.source, .offset = offsetAfter(case.source, needle) };
        var clock = DeadlineClock{};
        var full = try snapshot_api.completeAt(testing.allocator, snapshot, req, clock.options());
        defer full.deinit(testing.allocator);
        try testing.expect(!full.is_incomplete);
        try testing.expect(full.items.len > 1);
        const steps = clock.calls;
        clock = .{};
        var fast_options = clock.options();
        fast_options.budget_ms = 0;
        var fast = try snapshot_api.completeAt(testing.allocator, snapshot, req, fast_options);
        defer fast.deinit(testing.allocator);
        try testing.expect(fast.items.len > 0);
        // Expiration before parsing and during traversal both select the same
        // separate analysis, rather than whichever candidates were accumulated.
        for (1..33) |part| {
            clock = .{ .expire_at = 2 + (steps - 2) * part / 32 };
            var partial = try snapshot_api.completeAt(testing.allocator, snapshot, req, clock.options());
            defer partial.deinit(testing.allocator);
            try testing.expect(partial.is_incomplete);
            try expectUnique(partial);
            try testing.expectEqual(fast.items.len, partial.items.len);
            for (partial.items, fast.items) |item, expected| {
                try testing.expectEqualStrings(expected.label, item.label);
                try testing.expectEqual(expected.kind, item.kind);
            }
            try testing.expect(clock.calls <= clock.expire_at + compiler.analysis.query.fallback.Limits.facts + 32);
        }
    }
}

test "analysis queries: zero budget marks completion as incomplete" {
    var case = try CompletionCase.init("page main\nend\n");
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    var result = try snapshot_api.completeAt(testing.allocator, snapshot, .{
        .path = case.path,
        .source = case.source,
        .offset = 0,
    }, .{ .budget_ms = 0 });
    defer result.deinit(testing.allocator);
    try testing.expect(result.is_incomplete);
    try expectHas(result, "page");
}

test "analysis queries: hover switches to shallow types when documentation exceeds the deadline" {
    var case = try CompletionCase.init(
        \\fn local(value: Number) -> Number
        \\  return value
        \\end
        \\page main
        \\  let result = local(1)
        \\end
    );
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    // A large doc comment makes the signature-only stage observable.
    for (snapshot.value_bindings) |*binding| {
        if (!std.mem.eql(u8, binding.name, "local")) continue;
        case.allocator.free(binding.documentation);
        binding.documentation = try case.allocator.dupe(u8, std.mem.asBytes(&@as([1024]["Long documentation.\n".len]u8, @splat("Long documentation.\n".*))));
    }
    const req = query_types.SourceRequest{ .path = case.path, .source = case.source, .offset = offsetAfter(case.source, "local(1") - 3 };
    var clock = DeadlineClock{};
    var full = (try snapshot_api.hoverAt(testing.allocator, snapshot, req, clock.options())) orelse return error.ExpectedHover;
    defer full.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, full.markdown, "Long documentation.") != null);
    clock = .{ .expire_at = clock.calls - 1 };
    var brief = (try snapshot_api.hoverAt(testing.allocator, snapshot, req, clock.options())) orelse return error.ExpectedHover;
    defer brief.deinit(testing.allocator);
    try testing.expectEqualStrings("```ss\n(local: Any)\n```", brief.markdown);
    try testing.expect(std.mem.indexOf(u8, brief.markdown, "Long documentation.") == null);
    try testing.expect(std.mem.endsWith(u8, brief.markdown, "```"));
}

test "analysis queries: definition fallback still honors cancellation" {
    var case = try CompletionCase.init("page main\n  let value = 1\n  let copy = value\nend\n");
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    const req = query_types.SourceRequest{ .path = case.path, .source = case.source, .offset = offsetAfter(case.source, "copy = val") };
    var clock = DeadlineClock{};
    const full = try snapshot_api.definitionAt(testing.allocator, snapshot, req, clock.options());
    defer testing.allocator.free(full);
    try testing.expectEqual(@as(usize, 1), full.len);
    for ([_]bool{ false, true }) |cancel| {
        clock = .{};
        var allocations = testing.FailingAllocator.init(testing.allocator, .{});
        var deadline = DeadlineAfterTarget{ .clock = &clock, .allocations = &allocations, .cancel = cancel };
        var options = clock.options();
        options.cancellation = .{ .context = &deadline, .is_canceled = DeadlineAfterTarget.canceled };
        const result = try snapshot_api.definitionAt(allocations.allocator(), snapshot, req, options);
        defer allocations.allocator().free(result);
        try testing.expect(deadline.triggered);
        if (cancel) {
            try testing.expectEqual(@as(usize, 0), result.len);
        } else {
            try testing.expectEqualDeep(full, result);
        }
    }
}

test "analysis completion: composition remains independent of lexical function names" {
    var case = try CompletionCase.init(
        \\import std:layout as layout
        \\const hjoin: Number = 9
        \\fn vjoin(a: Text, b: Text) -> Number
        \\  return 1
        \\end
        \\page main
        \\  let a = text("A")
        \\  let b = text("B")
        \\  let hjoin = (left: Text, right: Text) |-> 1
        \\  let combined = a || b
        \\  let label = (a || b).gap
        \\end
    );
    defer case.deinit();

    const snapshot = try case.snapshotFor(case.source);
    try testing.expect(!snapshot.diagnostics.hasErrors());
    const module = snapshot.moduleForPath(case.path) orelse return error.ExpectedModule;
    for ([_][]const u8{ "hjoin", "vjoin" }) |name| {
        try testing.expect(resolve_query.valueBinding(null, snapshot, module.id, name, "std:layout", .function) == null);
    }
    const constant = resolve_query.valueBinding(null, snapshot, module.id, "hjoin", null, .constant) orelse return error.ExpectedConstant;
    try testing.expectEqual(module.id, constant.module_id);
    try testing.expectEqual(.number, constant.value_type.kind);
    const explicit_function = resolve_query.valueBinding(null, snapshot, module.id, "vjoin", null, .function) orelse return error.ExpectedFunction;
    try testing.expectEqual(module.id, explicit_function.module_id);
    try testing.expectEqual(.number, explicit_function.value_type.kind);
    try testing.expect(resolve_query.valueBinding(null, snapshot, module.id, "hjoin", "layout", .function) == null);
    try testing.expect(resolve_query.valueBinding(null, snapshot, module.id, "hjoin", "std:missing", .function) == null);
    const expired_budget = query_types.QueryBudget.start(.{ .budget_ms = 0 });
    try testing.expect(resolve_query.valueBinding(expired_budget, snapshot, module.id, "hjoin", "std:layout", .function) == null);

    var result = try snapshot_api.completeAt(case.allocator, snapshot, .{
        .path = case.path,
        .source = case.source,
        .offset = offsetAfter(case.source, "(a || b)."),
    }, .{ .budget_ms = 100 });
    defer result.deinit(case.allocator);
    try expectHas(result, "gap");
    try expectOnlyKind(result, .property);
}

test "analysis completion: dot module and normal positions keep candidate kinds separate" {
    var case = try CompletionCase.init(
        \\import std:text
        \\import std:text as *
        \\
        \\page title
        \\  let t = text::text("body")
        \\  let restyled = t.style with { text.size = 20 }
        \\end
        \\
    );
    defer case.deinit();

    {
        var result = try case.completeAfter("t.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "style");
        try expectHas(result, "content");
        try expectMissing(result, "text_size");
        try expectMissing(result, "page");
        try expectMissing(result, "add");
        try expectMissing(result, "Align");
        try expectMissing(result, "String");
        try expectOnlyKind(result, .property);
    }

    {
        var result = try case.completeAfter("text::");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "text");
        try expectHas(result, "text!");
        try expectMissing(result, "page");
        try expectMissing(result, "add");
        try expectMissing(result, "text_size");
        try expectMissing(result, "String");
        try expectMissing(result, "Align");
    }

    {
        var result = try case.completeAfter("page title\n");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "page");
        try expectHas(result, "text!");
        try expectHas(result, "String");
        try expectMissing(result, "Object");
        try expectHas(result, "Placed");
        try expectHas(result, "Placement");
        try expectHas(result, "Selection");
        try expectHas(result, "Align");
        try expectHas(result, "Text");
        try expectMissing(result, "text_size");
    }
}

test "analysis completion: normal position follows import visibility" {
    var case = try CompletionCase.init(
        \\import std:markdown as theme
        \\
        \\page title
        \\
        \\end
        \\
    );
    defer case.deinit();

    var result = try case.completeAfter("page title\n");
    defer result.deinit(case.allocator);
    try expectUnique(result);
    try expectHas(result, "page");
    try expectMissing(result, "link");
    try expectMissing(result, "text_size");
}

test "analysis completion: visible function prefers imported module definitions over re-exported names" {
    var case = try CompletionCase.init(
        \\import std:text as *
        \\
        \\page title
        \\  text!("body")
        \\end
        \\
    );
    defer case.deinit();

    const snapshot = try case.snapshotFor(case.source);
    const module = snapshot.moduleForPath(case.path) orelse return error.ExpectedModule;
    const item = resolve_query.valueBinding(null, snapshot, module.id, "text", null, .function) orelse return error.ExpectedFunction;

    try testing.expectEqualStrings("text", item.name);
    try testing.expectEqualStrings("text(content: String, style: TextBlockStyle = default_text_style, config: LatexConfig = LatexConfig {  }) -> Text", item.signature);
}

test "analysis completion: visible variables and definitions use shared scope resolution" {
    var case = try CompletionCase.init(
        \\document
        \\  let x = "document"
        \\  let doc_probe = x
        \\end
        \\
        \\page title
        \\  let x = 1
        \\  let page_probe = x
        \\end
        \\
        \\fn make() -> Bool
        \\  let x = true
        \\  let fn_probe = x
        \\  return x
        \\end
        \\
    );
    defer case.deinit();

    {
        const snapshot = try case.snapshotFor(case.source);
        const module = snapshot.moduleForPath(case.path) orelse return error.ExpectedModule;
        const offset = offsetAfter(case.source, "doc_probe = x");
        const variable = resolve_query.visibleVariableBinding(null, snapshot, module.id, offset, "x") orelse return error.ExpectedVariable;
        try testing.expectEqualStrings("x", variable.name);
        try testing.expectEqualStrings("String", variable.type_label);
        const definition = resolve_query.visibleVariable(null, snapshot, module.id, offset, "x") orelse return error.ExpectedDefinition;
        try testing.expectEqual(compiler.core.DefinitionKind.variable, definition.kind);
        try testing.expectEqual(module.id, definition.module_id);
    }

    {
        const snapshot = try case.snapshotFor(case.source);
        const module = snapshot.moduleForPath(case.path) orelse return error.ExpectedModule;
        const offset = offsetAfter(case.source, "page_probe = x");
        const variable = resolve_query.visibleVariableBinding(null, snapshot, module.id, offset, "x") orelse return error.ExpectedVariable;
        try testing.expectEqualStrings("Number", variable.type_label);
        const definition = resolve_query.visibleVariable(null, snapshot, module.id, offset, "x") orelse return error.ExpectedDefinition;
        try testing.expectEqual(compiler.core.DefinitionKind.variable, definition.kind);
        try testing.expectEqual(module.id, definition.module_id);
    }

    {
        const snapshot = try case.snapshotFor(case.source);
        const module = snapshot.moduleForPath(case.path) orelse return error.ExpectedModule;
        const offset = offsetAfter(case.source, "fn_probe = x");
        const variable = resolve_query.visibleVariableBinding(null, snapshot, module.id, offset, "x") orelse return error.ExpectedVariable;
        try testing.expectEqualStrings("Bool", variable.type_label);
        const definition = resolve_query.visibleVariable(null, snapshot, module.id, offset, "x") orelse return error.ExpectedDefinition;
        try testing.expectEqual(compiler.core.DefinitionKind.variable, definition.kind);
        try testing.expectEqual(module.id, definition.module_id);
    }
}

test "analysis completion: normal positions include builtin and source type names" {
    var case = try CompletionCase.init(
        \\import std:text as *
        \\
        \\page title
        \\end
        \\
    );
    defer case.deinit();

    const request_source =
        \\import std:text as *
        \\
        \\enum SourceOnly { alpha beta }
        \\type SourceCard {
        \\}
        \\
        \\fn keep(value: ) -> SourceOnly
        \\  return value
        \\end
        \\
    ;

    var result = try case.completeSourceAfter(request_source, "value: ");
    defer result.deinit(case.allocator);
    try expectUnique(result);
    for (type_resolution.builtinTypes()) |builtin| try expectHas(result, builtin.name);
    try testing.expect(type_resolution.isBuiltinTypeName("Selection"));
    try expectHas(result, "SourceOnly");
    try expectHas(result, "SourceCard");
    try expectMissing(result, "text_size");
}

test "analysis completion: enum type dot completes cases" {
    var case = try CompletionCase.init(
        \\import std:text as *
        \\import std:layout as classes
        \\
        \\page title
        \\  let style = TextStyle {} with { math.align = Align.center }
        \\  let qualified = TextStyle {} with { math.align = classes::Align.left }
        \\end
        \\
    );
    defer case.deinit();

    const request_source =
        \\import std:text as *
        \\import std:layout as classes
        \\
        \\page title
        \\  Align.
        \\  classes::Align.
        \\end
        \\
    ;

    inline for (.{ "Align.", "classes::Align." }) |needle| {
        var result = try case.completeSourceAfter(request_source, needle);
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "left");
        try expectHas(result, "center");
        try expectHas(result, "right");
        try expectKind(result, "left", .enum_case);
        try expectKind(result, "center", .enum_case);
        try expectKind(result, "right", .enum_case);
        try expectMissing(result, "page");
        try expectMissing(result, "String");
        try expectMissing(result, "text_size");
    }
}

test "analysis completion: source recovery sees preceding same-scope bindings" {
    var case = try CompletionCase.init(
        \\import std:text as *
        \\
        \\page title
        \\  let t = text! "before"
        \\  let alias = t
        \\  let later = text! "after"
        \\  ~ alias.left == page.left + 20
        \\  ~ later.left == page.left + 20
        \\end
        \\
    );
    defer case.deinit();

    const request_source =
        \\import std:text as *
        \\
        \\page title
        \\  let t = text! "before"
        \\  let alias = t
        \\  alias.
        \\  let later = text! "after"
        \\  later.
        \\end
        \\
    ;

    {
        var result = try case.completeSourceAfter(request_source, "alias.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "value");
        try expectHas(result, "left");
        try expectMissing(result, "text_size");
        try expectHas(result, "page");
    }

    {
        var result = try case.completeSourceAfter(request_source, "later.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "value");
        try expectHas(result, "left");
        try expectMissing(result, "text_size");
        try expectHas(result, "page");
    }
}

test "analysis completion: function and const annotations preserve inputs and placements" {
    var case = try CompletionCase.init(
        \\fn make_plain() -> Text = text("plain")
        \\fn/! make_paired(content: String) -> Text = text(content)
        \\const make_const: Text = text("const")
        \\page main
        \\  let a = make_plain()
        \\  let b = make_paired!("paired")
        \\  let c = make_const
        \\end
    );
    defer case.deinit();
    const request_source =
        \\fn make_plain() -> Text = text("plain")
        \\fn/! make_paired(content: String) -> Text = text(content)
        \\const make_const: Text = text("const")
        \\page main
        \\  let a = make_plain()
        \\  a.
        \\  let b = make_paired!("paired")
        \\  b.
        \\  let c = make_const
        \\  c.
        \\end
    ;
    inline for (.{ "a.", "c." }) |needle| {
        var result = try case.completeSourceAfter(request_source, needle);
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "content");
        try expectHas(result, "style");
        try expectMissing(result, "layout");
        try expectMissing(result, "page");
    }
    var placed = try case.completeSourceAfter(request_source, "b.");
    defer placed.deinit(case.allocator);
    try expectUnique(placed);
    try expectHas(placed, "value");
    try expectHas(placed, "left");
    try expectHas(placed, "page");
    try expectMissing(placed, "style");
}

test "analysis completion: placed groups expose their layout record" {
    var case = try CompletionCase.init(
        \\page main
        \\  let row = text!("Left") |=| text!("Right")
        \\  row.layout.gap = 24
        \\end
    );
    defer case.deinit();
    const request_source =
        \\page main
        \\  let row = text!("Left") |=| text!("Right")
        \\  row.
        \\  row.layout.
        \\end
    ;
    var placed = try case.completeSourceAfter(request_source, "row.");
    defer placed.deinit(case.allocator);
    try expectUnique(placed);
    try expectHas(placed, "layout");
    try expectHas(placed, "value");
    try expectHas(placed, "left");
    var layout = try case.completeSourceAfter(request_source, "row.layout.");
    defer layout.deinit(case.allocator);
    try expectUnique(layout);
    try expectHas(layout, "gap");
    try expectMissing(layout, "value");
}

test "analysis completion: record update paths complete record fields" {
    var case = try CompletionCase.init(
        \\import std:text as *
        \\
        \\page title
        \\  let local = default_theme() with {
        \\    body.text.size = 20
        \\  }
        \\  text!("body", local.body)
        \\end
        \\
    );
    defer case.deinit();

    const request_source =
        \\import std:text as *
        \\
        \\page title
        \\  let local = default_theme() with {
        \\
        \\    bod
        \\    body.
        \\    body.text.
        \\    body.text.size =
        \\  }
        \\  text!("body", local.body)
        \\end
        \\
    ;

    {
        var result = try case.completeSourceAfter(request_source, "with {\n");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "body");
        try expectHas(result, "h1");
        try expectHas(result, "page_number");
        try expectMissing(result, "callout");
        try expectMissing(result, "figure");
        try expectMissing(result, "head");
        try expectMissing(result, "size");
        try expectMissing(result, "page");
        try expectMissing(result, "String");
    }

    {
        var result = try case.completeSourceAfter(request_source, "body.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "text");
        try expectHas(result, "layout");
        try expectMissing(result, "size");
        try expectMissing(result, "page");
    }

    {
        var result = try case.completeSourceAfter(request_source, "body.text.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "size");
        try expectHas(result, "color");
        try expectMissing(result, "text");
        try expectMissing(result, "page");
    }

    {
        var result = try case.completeSourceAfter(request_source, "bod");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "body");
        try expectHas(result, "h1");
        try expectHas(result, "page_number");
        try expectMissing(result, "callout");
        try expectMissing(result, "figure");
        try expectMissing(result, "head");
        try expectMissing(result, "size");
        try expectMissing(result, "page");
        try expectMissing(result, "String");
    }

    {
        const unindented_source =
            \\import std:text as *
            \\
            \\page title
            \\  let local = default_theme() with  {
            \\bod
            \\  }
            \\  text!("body", local.body)
            \\end
            \\
        ;
        var result = try case.completeSourceAfter(unindented_source, "bod");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "body");
        try expectHas(result, "h1");
        try expectHas(result, "page_number");
        try expectMissing(result, "callout");
        try expectMissing(result, "figure");
        try expectMissing(result, "head");
        try expectMissing(result, "size");
        try expectMissing(result, "page");
        try expectMissing(result, "String");
    }

    {
        var result = try case.completeSourceAfter(request_source, "body.text.size =");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectMissing(result, "page_number");
        try expectHas(result, "page");
    }
}

test "analysis completion: chevron blocks and comments do not create fake bindings or scopes" {
    var case = try CompletionCase.init(
        \\import std:text as *
        \\
        \\page title
        \\  ;; let fake_comment = text! "comment"
        \\  let t = text! <<
        \\let fake_block = text! "block"
        \\end
        \\>>
        \\  ~ t.left == page.left + 20
        \\end
        \\
    );
    defer case.deinit();

    const request_source =
        \\import std:text as *
        \\
        \\page title
        \\  ;; let fake_comment = text! "comment"
        \\  let t = text! <<
        \\let fake_block = text! "block"
        \\end
        \\>>
        \\  t.
        \\end
        \\
    ;

    {
        var result = try case.completeSourceAfter(request_source, "t.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "value");
        try expectHas(result, "left");
        try expectMissing(result, "text_size");
        try expectHas(result, "page");
    }

    {
        var result = try case.completeSourceAfter(request_source, "page title\n");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectMissing(result, "fake_comment");
        try expectMissing(result, "fake_block");
        try expectMissing(result, "text_size");
    }
}

test "analysis queries: module identity survives nested fields and label changes" {
    try checkNominalQueries("import \"a\" as a\nimport \"b\" as b\n");
    try checkNominalQueries("import \"b\" as b\nimport \"a\" as a\n");
}

fn checkNominalQueries(imports: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = ".ss-cache/query-nominal-fixture";
    const path = root ++ "/main.ss";
    const source = try std.mem.concat(allocator, u8, &.{
        imports,
        \\page main
        \\  let first = a::make()
        \\  let second = b::make()
        \\  let ar = a::record_value()
        \\  let br = b::record_value()
        \\  let ax = first.base.base_a
        \\  let bx = second.base.base_b
        \\  let av = ar.value.only_a
        \\  let bv = br.value.only_b
        \\  let am = a::Mode.alpha
        \\  let bm = b::Mode.beta
        \\end
    });
    var sources = snapshot_api.SourceSet.init(allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    try sources.put(root ++ "/a.ss",
        \\type Style { only_a: Number = 1 }
        \\type Box { value: Style = Style {} }
        \\type Base { base_a: Number = 1 }
        \\type Card { base: Base = Base {} }
        \\enum Mode { alpha }
        \\fn make() -> Card
        \\  return Card {}
        \\end
        \\fn record_value() -> Box
        \\  return Box {}
        \\end
    );
    try sources.put(root ++ "/b.ss",
        \\type Style { only_b: String = "b" }
        \\type Box { value: Style = Style {} }
        \\type Base { base_b: String = "b" }
        \\type Card { base: Base = Base {} }
        \\enum Mode { beta }
        \\fn make() -> Card
        \\  return Card {}
        \\end
        \\fn record_value() -> Box
        \\  return Box {}
        \\end
    );
    var snapshot = try snapshot_api.build(allocator, &sources, path, root, .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    for (snapshot.value_bindings) |*binding| @memset(binding.type_label, '!');
    for (snapshot.variable_bindings) |*binding| @memset(binding.type_label, '!');
    for (snapshot.record_fields) |*field| @memset(field.type_label, '!');
    const queries = .{
        .{ "first.base.", "base_a", "base_b" },
        .{ "second.base.", "base_b", "base_a" },
        .{ "ar.value.", "only_a", "only_b" },
        .{ "br.value.", "only_b", "only_a" },
        .{ "a::Mode.", "alpha", "beta" },
        .{ "b::Mode.", "beta", "alpha" },
    };
    inline for (queries) |query| {
        var result = try snapshot_api.completeAt(allocator, &snapshot, .{ .path = path, .source = source, .offset = offsetAfter(source, query[0]) }, .{ .budget_ms = 100 });
        defer result.deinit(allocator);
        try expectHas(result, query[1]);
        try expectMissing(result, query[2]);
    }
    inline for (.{ .{ "ar.value.only_a", "a.ss" }, .{ "br.value.only_b", "b.ss" }, .{ "first.base.base_a", "a.ss" }, .{ "second.base.base_b", "b.ss" } }) |query| {
        const targets = try snapshot_api.definitionAt(allocator, &snapshot, .{ .path = path, .source = source, .offset = offsetAfter(source, query[0]) - 1 }, .{ .budget_ms = 100 });
        defer allocator.free(targets);
        try testing.expectEqual(@as(usize, 1), targets.len);
        try testing.expect(std.mem.endsWith(u8, targets[0].path orelse "", query[1]));
    }
}

const CompletionCase = struct {
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    snapshot: ?snapshot_api.AnalysisSnapshot = null,

    fn init(source: []const u8) !CompletionCase {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        const arena = try testing.allocator.create(std.heap.ArenaAllocator);
        errdefer testing.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
        try std.Io.Dir.cwd().createDirPath(testing.io, root);
        const path = try std.fs.path.join(allocator, &.{ root, "case.ss" });
        const owned_source = try allocator.dupe(u8, source);
        return .{
            .arena = arena,
            .allocator = allocator,
            .path = path,
            .source = owned_source,
        };
    }

    fn deinit(self: *CompletionCase) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.arena.deinit();
        testing.allocator.destroy(self.arena);
    }

    fn completeAfter(self: *CompletionCase, needle: []const u8) !query_types.CompletionResult {
        return self.completeSourceAfter(self.source, needle);
    }

    fn completeSourceAfter(self: *CompletionCase, source: []const u8, needle: []const u8) !query_types.CompletionResult {
        const offset = offsetAfter(source, needle);
        const snapshot = try self.snapshotFor(source);
        // Visibility tests exercise full completion; deadline behavior is tested
        // separately with an explicitly advancing clock.
        var clock = DeadlineClock{};
        var result = try snapshot_api.completeAt(self.allocator, snapshot, .{
            .path = self.path,
            .source = source,
            .offset = offset,
            .source_version = snapshot.generation,
        }, clock.options());
        errdefer result.deinit(self.allocator);
        try testing.expect(!result.is_incomplete);
        return result;
    }

    fn snapshotFor(self: *CompletionCase, source: []const u8) !*snapshot_api.AnalysisSnapshot {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.snapshot = try buildAnalysis(self.allocator, self.path, source);
        return if (self.snapshot) |*snapshot| snapshot else unreachable;
    }
};

fn buildAnalysis(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !snapshot_api.AnalysisSnapshot {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    var sources = snapshot_api.SourceSet.init(allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    return snapshot_api.build(allocator, &sources, path, asset_base_dir, .{});
}

fn offsetAfter(source: []const u8, needle: []const u8) usize {
    const start = std.mem.indexOf(u8, source, needle) orelse @panic("needle not found");
    return start + needle.len;
}

fn expectHas(result: query_types.CompletionResult, label: []const u8) !void {
    for (result.items) |item| {
        if (std.mem.eql(u8, item.label, label)) return;
    }
    return error.ExpectedCompletionMissing;
}

fn expectKind(result: query_types.CompletionResult, label: []const u8, kind: query_types.CompletionKind) !void {
    for (result.items) |item| {
        if (!std.mem.eql(u8, item.label, label)) continue;
        try testing.expectEqual(kind, item.kind);
        return;
    }
    return error.ExpectedCompletionMissing;
}

fn expectMissing(result: query_types.CompletionResult, label: []const u8) !void {
    for (result.items) |item| {
        if (std.mem.eql(u8, item.label, label)) return error.UnexpectedCompletionPresent;
    }
}

fn expectUnique(result: query_types.CompletionResult) !void {
    var seen = std.StringHashMap(void).init(testing.allocator);
    defer seen.deinit();
    for (result.items) |item| {
        if (seen.contains(item.label)) return error.DuplicateCompletionLabel;
        try seen.put(item.label, {});
    }
}

fn expectOnlyKind(result: query_types.CompletionResult, kind: query_types.CompletionKind) !void {
    for (result.items) |item| try testing.expectEqual(kind, item.kind);
}

test "analysis queries: recovery syntax is borrowed for repeated requests" {
    var case = try CompletionCase.init(
        \\page title
        \\  let t = text("body")
        \\  t.
        \\end
        \\
    );
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    const tree = snapshot.syntaxForSource(case.path, case.source) orelse return error.TestUnexpectedResult;
    const req = query_types.SourceRequest{ .path = case.path, .source = case.source, .offset = offsetAfter(case.source, "  t") };
    for (0..32) |_| {
        var limited = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
        var context = try compiler.analysis.query.context.Context.initFromSnapshot(limited.allocator(), snapshot, req, null);
        defer context.deinit(limited.allocator());
        try testing.expectEqual(tree, context.module().?);
        try testing.expect(context.parsed.owned == null);
        try testing.expectEqualStrings("t", context.target);
    }
    var completion = try snapshot_api.completeAt(testing.allocator, snapshot, .{
        .path = case.path,
        .source = case.source,
        .offset = offsetAfter(case.source, "t."),
    }, .{ .budget_ms = 1000 });
    defer completion.deinit(testing.allocator);
    try expectHas(completion, "style");
    try expectHas(completion, "config");
    try expectHas(completion, "content");
}

test "analysis queries: failed imports keep the entry recovery tree" {
    var case = try CompletionCase.init(
        \\import ./absent as missing
        \\page title
        \\  missing::unfinished()
        \\end
        \\
    );
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    try testing.expect(snapshot.diagnostics.hasErrors());
    const tree = snapshot.syntaxForSource(case.path, case.source) orelse return error.TestUnexpectedResult;
    var context = try compiler.analysis.query.context.Context.initFromSnapshot(testing.allocator, snapshot, .{
        .path = case.path,
        .source = case.source,
        .offset = offsetAfter(case.source, "missing::un"),
    }, null);
    defer context.deinit(testing.allocator);
    try testing.expectEqual(tree, context.module().?);
    try testing.expectEqualStrings("missing", context.qualifiedCallableAlias().?);
}

const retained_source =
    \\fn accept(value: first::Card?, callback: (second::Card) -> first::Card) -> first::Card = callback(value?)
    \\page title
    \\  let broken: third::Card =
    \\end
    \\
;

fn ownQuerySyntax(allocator: std.mem.Allocator) !void {
    var storage = snapshot_api.SyntaxStorage.init(allocator);
    defer storage.deinit();
    {
        const source = try testing.allocator.dupe(u8, retained_source);
        defer testing.allocator.free(source);
        var parsed = try compiler.syntax.parseRecoveringWithSourceName(testing.allocator, source, "owned.ss");
        defer parsed.deinit(testing.allocator);
        try storage.capture("owned.ss", source, parsed.module);
    }
    const tree = storage.forSource("owned.ss", retained_source) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), tree.functions.items.len);
    const function = tree.functions.items[0];
    try testing.expectEqualStrings("first::Card", function.result_type.class_name.?);
    try testing.expectEqualStrings("first::Card", function.params.items[0].ty.optional_child.?.class_name.?);
    try testing.expectEqualStrings("second::Card", function.params.items[1].ty.fn_params[0].class_name.?);
    try testing.expectEqualStrings("first::Card", function.params.items[1].ty.fn_result.?.class_name.?);
    try testing.expect(storage.forSource("owned.ss", "page changed\nend\n") == null);
    try storage.replace("owned.ss", "page changed\nend\n", null);
    try testing.expect(storage.forSource("owned.ss", retained_source) == null);
    try testing.expect(storage.forSource("owned.ss", "page changed\nend\n") != null);
}

test "analysis queries: retained syntax owns all type spellings and partial allocations" {
    try ownQuerySyntax(testing.allocator);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, ownQuerySyntax, .{});
}

const ParseCancellation = struct {
    checks: usize = 0,
    limit: usize,

    fn canceled(context: *const anyopaque) bool {
        const self: *ParseCancellation = @ptrCast(@alignCast(@constCast(context)));
        self.checks += 1;
        return self.checks >= self.limit;
    }
};

test "analysis queries: fallback parsing checks cancellation inside a document" {
    const source = "page title\n" ++ (std.mem.asBytes(&@as([100]["  let value = add(1, 2)\n".len]u8, @splat("  let value = add(1, 2)\n".*)))) ++ "end\n";
    var cancellation = ParseCancellation{ .limit = 20 };
    const budget = query_types.QueryBudget.start(.{
        .budget_ms = 1000,
        .cancellation = .{ .context = &cancellation, .is_canceled = ParseCancellation.canceled },
    });
    try testing.expectError(error.NoQueryTarget, compiler.analysis.query.context.Context.initWithBudget(testing.allocator, .{
        .path = "cancel.ss",
        .source = source,
        .offset = offsetAfter(source, "val"),
    }, budget));
    try testing.expect(cancellation.checks >= cancellation.limit);
    try testing.expect(cancellation.checks <= cancellation.limit + 8);
}

test "analysis queries: replacing source invalidates syntax and keeps failed replacements atomic" {
    var case = try CompletionCase.init("page title\n  let value = 1\nend\n");
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    const old_tree = snapshot.syntaxForSource(case.path, case.source).?;
    const changed = "page title\n  let value = 2\nend\n";
    var context = try compiler.analysis.query.context.Context.initFromSnapshot(testing.allocator, snapshot, .{
        .path = case.path,
        .source = changed,
        .offset = offsetAfter(changed, "val"),
    }, null);
    defer context.deinit(testing.allocator);
    try testing.expect(context.parsed.owned != null);
    try testing.expectEqual(old_tree, snapshot.syntaxForSource(case.path, case.source).?);
    var cancellation = ParseCancellation{ .limit = 1 };
    try testing.expectError(error.Canceled, snapshot.updateSyntax(case.path, changed, .{
        .context = &cancellation,
        .is_canceled = ParseCancellation.canceled,
    }));
    try testing.expectEqual(old_tree, snapshot.syntaxForSource(case.path, case.source).?);
    try snapshot.updateSyntax(case.path, changed, null);
    try testing.expect(snapshot.syntaxForSource(case.path, case.source) == null);
    const new_tree = snapshot.syntaxForSource(case.path, changed) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f64, 2), new_tree.pages.items[0].statements.items[0].kind.let_binding.expr.number);
}

test "analysis queries: parser cancellation releases partial expressions and declarations" {
    const source =
        \\fn scale(value: Number, transform: (Number) -> Number) -> Number
        \\  if true
        \\    return transform(add(value, 1))
        \\  else
        \\    return 0
        \\  end
        \\end
        \\page title
        \\  let label = text("value")
        \\  label.text.size = 20
        \\end
        \\
    ;
    for (1..120) |limit| {
        var cancellation = ParseCancellation{ .limit = limit };
        var parsed = compiler.syntax.parseRecoveringWithOptions(testing.allocator, source, "cancel.ss", .{
            .cancellation = .{ .context = &cancellation, .is_canceled = ParseCancellation.canceled },
        }) catch |err| {
            try testing.expectEqual(error.Canceled, err);
            continue;
        };
        parsed.deinit(testing.allocator);
    }
}

test "analysis queries: retained syntax traversal stops before reaching a distant target" {
    const source = (std.mem.asBytes(&@as([100]["fn repeated(value: Number) -> Number\n  return add(value, 1)\nend\n".len]u8, @splat("fn repeated(value: Number) -> Number\n  return add(value, 1)\nend\n".*)))) ++
        "page title\n  let target = 1\nend\n";
    var parsed = try compiler.syntax.parseRecoveringWithSourceName(testing.allocator, source, "traversal.ss");
    defer parsed.deinit(testing.allocator);
    const SyntaxView = struct {
        tree: *const compiler.syntax.Module,

        pub fn syntaxForSource(self: @This(), _: []const u8, _: []const u8) ?*const compiler.syntax.Module {
            return self.tree;
        }
    };
    var cancellation = ParseCancellation{ .limit = 40 };
    const budget = query_types.QueryBudget.start(.{
        .budget_ms = 1000,
        .cancellation = .{ .context = &cancellation, .is_canceled = ParseCancellation.canceled },
    });
    try testing.expectError(error.NoQueryTarget, compiler.analysis.query.context.Context.initFromSnapshot(testing.allocator, SyntaxView{ .tree = &parsed.module }, .{
        .path = "traversal.ss",
        .source = source,
        .offset = offsetAfter(source, "tar"),
    }, budget));
    // Cancellation does not release the syntax borrowed from the snapshot.
    try testing.expectEqual(@as(usize, 100), parsed.module.functions.items.len);
    try testing.expect(cancellation.checks >= cancellation.limit);
    try testing.expect(cancellation.checks <= cancellation.limit + 8);
}

test "analysis queries: canceled candidate collection releases partial results" {
    var case = try CompletionCase.init("page title\nend\n");
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    const req = query_types.SourceRequest{ .path = case.path, .source = case.source, .offset = 0 };
    for ([_]usize{ 128, 512 }) |limit| {
        var cancellation = ParseCancellation{ .limit = limit };
        var allocations = testing.FailingAllocator.init(testing.allocator, .{});
        var result = try snapshot_api.completeAt(allocations.allocator(), snapshot, req, .{
            .budget_ms = 1000,
            .cancellation = .{ .context = &cancellation, .is_canceled = ParseCancellation.canceled },
        });
        defer result.deinit(allocations.allocator());
        try testing.expectEqual(@as(usize, 0), result.items.len);
        try testing.expect(allocations.alloc_index > 0);
        try testing.expect(cancellation.checks >= limit);
        try testing.expect(cancellation.checks <= limit + 8);
    }
}

test "analysis queries: fact lookup and import traversal honor cancellation" {
    var case = try CompletionCase.init("page title\nend\n");
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    const module = snapshot.moduleForPath(case.path).?;
    var cancellation = ParseCancellation{ .limit = 40 };
    var budget = query_types.QueryBudget.start(.{
        .budget_ms = 1000,
        .cancellation = .{ .context = &cancellation, .is_canceled = ParseCancellation.canceled },
    });
    try testing.expect(resolve_query.valueBinding(budget, snapshot, module.id, "absent", null, .function) == null);
    try testing.expect(cancellation.checks >= cancellation.limit);
    try testing.expect(cancellation.checks <= cancellation.limit + 8);

    const ImportView = struct {
        value_bindings: []const snapshot_api.ValueBinding = &.{},

        imports: []const snapshot_api.ImportFact,
        visits: *usize,

        pub fn valueBindingInModule(_: @This(), _: compiler.core.SourceModuleId, _: []const u8) ?snapshot_api.ValueBinding {
            return null;
        }

        const Module = struct {
            imports: []const snapshot_api.ImportFact,
            implicit_import_ids: []const compiler.core.SourceModuleId = &.{},
        };

        pub fn moduleById(self: @This(), _: compiler.core.SourceModuleId) ?Module {
            self.visits.* += 1;
            return .{ .imports = self.imports };
        }
    };
    const imports: [512]snapshot_api.ImportFact = @splat(.{ .spec = &.{}, .spec_span = .{ .start = 0, .end = 0 }, .unqualified = true });
    var visits: usize = 0;
    cancellation.checks = 0;
    budget = query_types.QueryBudget.start(.{
        .budget_ms = 1000,
        .cancellation = .{ .context = &cancellation, .is_canceled = ParseCancellation.canceled },
    });
    try testing.expect(resolve_query.valueBinding(budget, ImportView{ .imports = &imports, .visits = &visits }, 0, "absent", null, .function) == null);
    try testing.expect(cancellation.checks >= cancellation.limit);
    try testing.expect(cancellation.checks <= cancellation.limit + 8);
    try testing.expect(visits < cancellation.limit);
}

test "selected imports: queries retain canonical declarations and export visibility" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = ".ss-cache/query-export-fixture";
    const path = root ++ "/main.ss";
    const source =
        \\import "facade" as facade
        \\import "facade" as { make, Item }
        \\page main
        \\  let value = facade::make()
        \\  let field = value.value
        \\end
    ;
    const facade_source = "import impl as { make, Item }\n";
    const impl_source =
        \\type Item { value: Number = 12 }
        \\type Hidden { private: Number = 0 }
        \\const secret: Number = 99
        \\fn make(item: Item = Item {}) -> Item
        \\  return item
        \\end
        \\fn hidden() -> Number
        \\  return secret
        \\end
    ;
    var sources = snapshot_api.SourceSet.init(allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    try sources.put(root ++ "/facade.ss", facade_source);
    try sources.put(root ++ "/impl.ss", impl_source);
    var snapshot = try snapshot_api.build(allocator, &sources, path, root, .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    const module = snapshot.moduleForPath(path) orelse return error.MissingModule;
    const impl = snapshot.moduleForPath(root ++ "/impl.ss") orelse return error.MissingModule;
    const binding = resolve_query.valueBinding(null, &snapshot, module.id, "make", "facade", .function) orelse return error.MissingFunction;
    try testing.expectEqual(impl.id, binding.module_id);
    const direct_binding = resolve_query.exportedValueBinding(null, &snapshot, impl.id, "make", .function) orelse return error.MissingFunction;
    try testing.expectEqualStrings(direct_binding.signature, binding.signature);
    try testing.expect(resolve_query.valueBinding(null, &snapshot, module.id, "hidden", "facade", .function) == null);
    try testing.expect(resolve_query.valueBinding(null, &snapshot, module.id, "secret", null, .constant) == null);
    const type_definition = resolve_query.typeDefinition(null, &snapshot, module.id, "Item", "facade") orelse return error.MissingType;
    try testing.expectEqual(impl.id, type_definition.module_id);
    {
        var result = try snapshot_api.completeAt(allocator, &snapshot, .{ .path = path, .source = source, .offset = offsetAfter(source, "facade::") }, .{ .budget_ms = 100 });
        defer result.deinit(allocator);
        try expectHas(result, "make");
        try expectHas(result, "Item");
        try expectMissing(result, "Hidden");
        try expectMissing(result, "hidden");
        try expectMissing(result, "secret");
    }
    {
        var result = try snapshot_api.completeAt(allocator, &snapshot, .{ .path = path, .source = source, .offset = offsetAfter(source, "page main\n") }, .{ .budget_ms = 100 });
        defer result.deinit(allocator);
        try expectHas(result, "make");
        try expectHas(result, "Item");
        try expectMissing(result, "Hidden");
        try expectMissing(result, "hidden");
        try expectMissing(result, "secret");
    }
    inline for (.{ "as { make", "make, Item", "facade::make", "value.value" }) |needle| {
        const targets = try snapshot_api.definitionAt(allocator, &snapshot, .{ .path = path, .source = source, .offset = offsetAfter(source, needle) - 1 }, .{ .budget_ms = 100 });
        defer allocator.free(targets);
        try testing.expectEqual(@as(usize, 1), targets.len);
        try testing.expect(std.mem.endsWith(u8, targets[0].path orelse "", "impl.ss"));
    }
    {
        var hover = (try snapshot_api.hoverAt(allocator, &snapshot, .{ .path = path, .source = source, .offset = offsetAfter(source, "as { make") - 1 }, .{ .budget_ms = 100 })) orelse return error.MissingHover;
        defer hover.deinit(allocator);
        try testing.expect(std.mem.indexOf(u8, hover.markdown, binding.signature) != null);
    }
}

test "analysis queries: qualified calls bypass local names in hover and definition" {
    var case = try CompletionCase.init(
        \\import std:text as theme
        \\page main
        \\  let text = theme::text("First")
        \\  theme::text("Second")
        \\end
    );
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    const offset = offsetAfter(case.source, "  theme::text") - 1;
    const req = query_types.SourceRequest{ .path = case.path, .source = case.source, .offset = offset };
    var clock = DeadlineClock{};
    var hover = (try snapshot_api.hoverAt(case.allocator, snapshot, req, clock.options())) orelse return error.ExpectedHover;
    defer hover.deinit(case.allocator);
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "text(") != null);
    const targets = try snapshot_api.definitionAt(case.allocator, snapshot, req, clock.options());
    defer case.allocator.free(targets);
    try testing.expectEqual(@as(usize, 1), targets.len);
    try testing.expect(targets[0].module_spec != null or !std.mem.eql(u8, targets[0].path orelse "", case.path));
}

test "analysis queries: enum declarations support hover and lexical completion" {
    var case = try CompletionCase.init(
        \\enum Mode { light dark }
        \\page main
        \\  let mode = Mode.light
        \\end
    );
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    var clock = DeadlineClock{};
    const req = query_types.SourceRequest{ .path = case.path, .source = case.source, .offset = offsetAfter(case.source, "= Mode") - 1 };
    var hover = (try snapshot_api.hoverAt(case.allocator, snapshot, req, clock.options())) orelse return error.ExpectedHover;
    defer hover.deinit(case.allocator);
    try testing.expectEqualStrings("```ss\nenum Mode\n```", hover.markdown);
    var completion = try snapshot_api.completeAt(case.allocator, snapshot, req, .{ .budget_ms = 0 });
    defer completion.deinit(case.allocator);
    try expectHas(completion, "Mode");
}

test "analysis queries: fields never fall back to unrelated value names" {
    var case = try CompletionCase.init(
        \\type Label {
        \\  text: String = "Body"
        \\}
        \\page main
        \\  let item = Label {}
        \\  let value = item.text
        \\  let str = "local"
        \\  let invalid = item.str
        \\end
    );
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    var clock = DeadlineClock{};
    const req = query_types.SourceRequest{ .path = case.path, .source = case.source, .offset = offsetAfter(case.source, "item.text") - 1 };
    var hover = (try snapshot_api.hoverAt(case.allocator, snapshot, req, clock.options())) orelse return error.ExpectedHover;
    defer hover.deinit(case.allocator);
    try testing.expectEqualStrings("```ss\n(text: String)\n```", hover.markdown);
    const targets = try snapshot_api.definitionAt(case.allocator, snapshot, req, clock.options());
    defer case.allocator.free(targets);
    try testing.expectEqual(@as(usize, 1), targets.len);
    try testing.expectEqual(@as(usize, 1), targets[0].line);
    const missing = query_types.SourceRequest{ .path = case.path, .source = case.source, .offset = offsetAfter(case.source, "item.str") - 1 };
    try testing.expect((try snapshot_api.hoverAt(case.allocator, snapshot, missing, clock.options())) == null);
    const absent = try snapshot_api.definitionAt(case.allocator, snapshot, missing, clock.options());
    defer case.allocator.free(absent);
    try testing.expectEqual(@as(usize, 0), absent.len);
}

test "analysis queries: let initializer resolves outside its own binding" {
    var case = try CompletionCase.init(
        \\page main
        \\  let text = text("Body")
        \\end
    );
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    var clock = DeadlineClock{};
    const req = query_types.SourceRequest{ .path = case.path, .source = case.source, .offset = offsetAfter(case.source, "= text") - 1 };
    var hover = (try snapshot_api.hoverAt(case.allocator, snapshot, req, clock.options())) orelse return error.ExpectedHover;
    defer hover.deinit(case.allocator);
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "text(") != null);
    const declaration = query_types.SourceRequest{ .path = case.path, .source = case.source, .offset = offsetAfter(case.source, "let text") - 1 };
    var local = (try snapshot_api.hoverAt(case.allocator, snapshot, declaration, clock.options())) orelse return error.ExpectedHover;
    defer local.deinit(case.allocator);
    try testing.expect(std.mem.indexOf(u8, local.markdown, "text: Text") != null);
}

test "analysis queries: constant record receivers precede enum names" {
    var case = try CompletionCase.init(
        \\enum Mode { alpha beta }
        \\type Settings {
        \\  size: Number = 17
        \\}
        \\const Mode: Settings = Settings {}
        \\page main
        \\  let value = Mode.size
        \\end
    );
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    var clock = DeadlineClock{};
    const req = query_types.SourceRequest{ .path = case.path, .source = case.source, .offset = offsetAfter(case.source, "Mode.size") - 1 };
    var hover = (try snapshot_api.hoverAt(case.allocator, snapshot, req, clock.options())) orelse return error.ExpectedHover;
    defer hover.deinit(case.allocator);
    try testing.expectEqualStrings("```ss\n(size: Number)\n```", hover.markdown);
    const targets = try snapshot_api.definitionAt(case.allocator, snapshot, req, clock.options());
    defer case.allocator.free(targets);
    try testing.expectEqual(@as(usize, 1), targets.len);
    try testing.expectEqual(@as(usize, 2), targets[0].line);
}
