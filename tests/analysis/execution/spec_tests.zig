const std = @import("std");
const compiler = @import("compiler");
const core = compiler.core;
const Type = compiler.language.Type;
const testing = std.testing;
const allocation_testing = @import("allocation_testing");

fn document(source: []const u8) !core.DocumentState {
    const allocator = testing.allocator;
    var text = try allocator.dupe(u8, source);
    defer allocator.free(text);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, text, "execution.ss");
    defer syntax.deinit(allocator);
    var modules = try compiler.analysis.loadModuleIndex(allocator, testing.io, ".", syntax, .{});
    defer modules.deinit();
    return compiler.analysis.buildDocumentState(allocator, "execution.ss", ".", &text, &syntax, &modules);
}

const CancelFunctionAnalysis = struct {
    analyzer: *compiler.analysis.dependencies.Analyzer,
    triggered: bool = false,

    fn canceled(context: *const anyopaque) bool {
        const self: *CancelFunctionAnalysis = @ptrCast(@alignCast(@constCast(context)));
        self.triggered = self.triggered or self.analyzer.value_bindings.contains("argument");
        return self.triggered;
    }
};

test "canceled function dependency analysis releases argument summaries once" {
    var state = try document(
        \\fn increment(argument: Number) -> Number
        \\  return argument + 1
        \\end
        \\document
        \\  let seed = 1
        \\  let result = increment(seed)
        \\end
    );
    defer state.deinit();
    const sema = compiler.semantic_env.SemanticEnv.init(&state, state.declaration_index, &state.functions);
    var analyzer = compiler.analysis.dependencies.Analyzer.init(testing.allocator, &sema);
    defer analyzer.deinit();
    var cancellation = CancelFunctionAnalysis{ .analyzer = &analyzer };
    state.runtime.analysis_cancellation = .{ .context = &cancellation, .is_canceled = CancelFunctionAnalysis.canceled };
    defer state.runtime.analysis_cancellation = null;
    try testing.expectError(error.Canceled, analyzer.documentStatements(state.projectSyntax().document_statements.items));
    try testing.expect(cancellation.triggered);
    state.runtime.analysis_cancellation = null;
    var recovered = try analyzer.documentStatements(state.projectSyntax().document_statements.items);
    defer recovered.deinit();
    try testing.expect(recovered.reads.items.len > 0);
}

fn analyzeFunctionDependencies(allocator: std.mem.Allocator, state: *core.DocumentState) !void {
    const sema = compiler.semantic_env.SemanticEnv.init(state, state.declaration_index, &state.functions);
    var analyzer = compiler.analysis.dependencies.Analyzer.init(allocator, &sema);
    defer analyzer.deinit();
    var summary = try analyzer.documentStatements(state.projectSyntax().document_statements.items);
    defer summary.deinit();
}

test "function dependency summaries have one owner on allocation failure" {
    var state = try document(
        \\fn increment(argument: Number) -> Number
        \\  return argument + 1
        \\end
        \\fn twice(argument: Number) -> Number
        \\  return increment(increment(argument))
        \\end
        \\document
        \\  let seed = 1
        \\  let result = twice(seed)
        \\end
    );
    defer state.deinit();
    try allocation_testing.checkAllAllocationFailures(testing.allocator, analyzeFunctionDependencies, .{&state});
}

test "type facts preserve generic arguments and outlive individual analyzers" {
    var state = try document(
        \\type Holder<T> { item: T }
        \\fn number(value: Holder<Number>) -> Number = value.item
        \\fn first(value: Holder<Placement>) -> Number = value.item.x
        \\fn second(value: Holder<Placement>) -> Number = value.item.x
        \\document
        \\  let a = number(input)
        \\  let b = first(input)
        \\  let c = second(input)
        \\end
    );
    defer state.deinit();
    const dependencies = compiler.analysis.dependencies;
    const sema = compiler.semantic_env.SemanticEnv.init(&state, state.declaration_index, &state.functions);
    var strings = std.heap.ArenaAllocator.init(testing.allocator);
    defer strings.deinit();
    var cache = dependencies.RunCache.init(testing.allocator, strings.allocator());
    defer cache.deinit();
    const statements = state.projectSyntax().document_statements.items;
    var number_count: usize = 0;
    {
        var analyzer = dependencies.Analyzer.initWithScopeAndCache(testing.allocator, &sema, .{ .document = 0 }, &cache);
        defer analyzer.deinit();
        var numeric = try analyzer.documentStatements(statements[0..1]);
        defer numeric.deinit();
        number_count = cache.type_body_analyses;
        try testing.expect(number_count > 0);
        var placement = try analyzer.documentStatements(statements[1..2]);
        defer placement.deinit();
        try testing.expect(cache.type_body_analyses > number_count);
    }
    const placement_count = cache.type_body_analyses;
    var analyzer = dependencies.Analyzer.initWithScopeAndCache(testing.allocator, &sema, .{ .document = 0 }, &cache);
    defer analyzer.deinit();
    var reused = try analyzer.documentStatements(statements[2..]);
    defer reused.deinit();
    try testing.expectEqual(placement_count, cache.type_body_analyses);
    var uncached = dependencies.Analyzer.init(testing.allocator, &sema);
    defer uncached.deinit();
    var expected = try uncached.documentStatements(statements[2..]);
    defer expected.deinit();
    try testing.expectEqualDeep(expected.reads.items, reused.reads.items);
    try testing.expectEqualDeep(expected.writes.items, reused.writes.items);
}

fn analyzeCachedTypeFacts(allocator: std.mem.Allocator, state: *core.DocumentState) !void {
    const dependencies = compiler.analysis.dependencies;
    const sema = compiler.semantic_env.SemanticEnv.init(state, state.declaration_index, &state.functions);
    var strings = std.heap.ArenaAllocator.init(allocator);
    defer strings.deinit();
    var cache = dependencies.RunCache.init(allocator, strings.allocator());
    defer cache.deinit();
    var analyzer = dependencies.Analyzer.initWithScopeAndCache(allocator, &sema, .{ .document = 0 }, &cache);
    defer analyzer.deinit();
    var summary = try analyzer.documentStatements(state.projectSyntax().document_statements.items);
    defer summary.deinit();
}

test "cached type facts release every partially constructed field tree" {
    var state = try document(
        \\type Inner { item: Placement }
        \\type Outer { inner: Inner }
        \\fn read(value: Outer) -> Number = value.inner.item.x
        \\document
        \\  let result = read(input)
        \\end
    );
    defer state.deinit();
    try allocation_testing.checkAllAllocationFailures(testing.allocator, analyzeCachedTypeFacts, .{&state});
}

test "diagnostic analysis leaves pages untouched while evaluation registers ordered pages and origins" {
    var state = try document(
        \\page first
        \\  text!("First")
        \\end
        \\page second
        \\  text!("Second")
        \\end
    );
    defer state.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node_count = state.graph.nodes.items.len;
    try testing.expect((try compiler.analysis.analyzeDocumentStateWithMode(arena.allocator(), &state, .diagnostics_only)) == null);
    try testing.expectEqual(node_count, state.graph.nodes.items.len);
    try testing.expectEqual(@as(usize, 0), state.graph.page_order.items.len);
    try testing.expectEqual(@as(usize, 0), state.source_map.pages.items.len);
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(arena.allocator(), &state, .evaluation)).?;
    defer graph.deinit();
    try testing.expectEqual(@as(usize, 2), state.graph.page_order.items.len);
    try testing.expectEqual(@as(usize, 2), state.source_map.pages.items.len);
    for ([_][]const u8{ "first", "second" }, 0..) |name, index| {
        const page_id = state.graph.page_order.items[index];
        try testing.expectEqualStrings(name, state.getNode(page_id).?.name);
        const origin = state.source_map.pages.items[index];
        try testing.expectEqual(page_id, origin.page_id);
        try testing.expectEqualStrings("execution.ss", origin.path);
        try testing.expect(origin.span_end > origin.span_start);
        const unit = graph.units.items[index];
        try testing.expectEqual(page_id, unit.kind.page_statement.page_id);
        try testing.expectEqual(index * 2 + 1, unit.source_order);
    }
}

test "dependency cycle diagnostics retain source locations in both graph construction modes" {
    for ([_]compiler.analysis.AnalysisMode{ .diagnostics_only, .evaluation }) |mode| {
        var state = try document(
            \\page bad
            \\  let target = pagectx()
            \\  target.layout_h_center_offset = target.layout_h_center_offset + 1
            \\end
        );
        defer state.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try testing.expectError(error.ExecutionDependencyCycle, compiler.analysis.analyzeDocumentStateWithMode(arena.allocator(), &state, mode));
        try testing.expectEqual(@as(usize, if (mode == .evaluation) 1 else 0), state.graph.page_order.items.len);
        const diagnostic = state.diagnostics.entries.items[state.diagnostics.entries.items.len - 1];
        try testing.expectEqualStrings("ExecutionDependencyCycle", diagnostic.code());
        const origin = diagnostic.origin.?.location().?;
        try testing.expectEqualStrings("execution.ss", origin.path.?);
        try testing.expect(origin.span.end > origin.span.start);
    }
}

test "display expansion cycles retain structural edge reasons after graph teardown" {
    const source =
        \\type Count<T> { amount: Number = selection_count(select<Text>(docctx())) }
        \\page first
        \\  let count = Count<Number> {}
        \\  heading!(str(count.amount))
        \\end
        \\page second
        \\  text!("Body")
        \\end
    ;
    for ([_]compiler.analysis.AnalysisMode{ .diagnostics_only, .evaluation }) |mode| {
        var state = try document(source);
        defer state.deinit();
        {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            try testing.expectError(error.ExecutionDependencyCycle, compiler.analysis.analyzeDocumentStateWithMode(arena.allocator(), &state, mode));
        }
        const diagnostic = state.diagnostics.entries.items[state.diagnostics.entries.items.len - 1];
        try testing.expectEqualStrings("ExecutionDependencyCycle", diagnostic.code());
        const location = diagnostic.origin.?.location().?;
        try testing.expectEqualStrings("execution.ss", location.path.?);
        const message = diagnostic.data.user_report.message;
        try testing.expect(std.mem.indexOf(u8, message, "via display expansion input") != null);
        try testing.expect(std.mem.indexOf(u8, message, "Objects(") != null);
        try testing.expect(std.mem.indexOf(u8, message, "Variable(") != null);
    }
}

fn expectCyclePath(source: []const u8, statements: []const []const u8, keys: []const []const u8) !void {
    for ([_]compiler.analysis.AnalysisMode{ .diagnostics_only, .evaluation }) |mode| {
        var state = try document(source);
        defer state.deinit();
        {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            try testing.expectError(error.ExecutionDependencyCycle, compiler.analysis.analyzeDocumentStateWithMode(arena.allocator(), &state, mode));
        }
        // The diagnostic and its complete witness must survive graph storage.
        const diagnostic = state.diagnostics.entries.items[state.diagnostics.entries.items.len - 1];
        try testing.expectEqualStrings("ExecutionDependencyCycle", diagnostic.code());
        const location = diagnostic.origin.?.location().?;
        try testing.expectEqualStrings(statements[0], source[location.span.start..location.span.end]);
        const message = diagnostic.data.user_report.message;
        try testing.expectEqual(statements.len, std.mem.count(u8, message, " via "));
        for (statements) |statement| {
            const start = std.mem.indexOf(u8, source, statement).?;
            const span = try std.fmt.allocPrint(testing.allocator, "execution.ss:bytes:{d}-{d}", .{ start, start + statement.len });
            defer testing.allocator.free(span);
            // Every member occurs once as a writer and once as a reader.
            try testing.expectEqual(@as(usize, 2), std.mem.count(u8, message, span));
        }
        for (keys) |key| {
            const reason = try std.fmt.allocPrint(testing.allocator, "Property(owner=document, key={s})", .{key});
            defer testing.allocator.free(reason);
            try testing.expectEqual(@as(usize, 1), std.mem.count(u8, message, reason));
        }
    }
}

test "cycle diagnostics identify the cycle instead of an earlier downstream statement" {
    try expectCyclePath(
        \\document
        \\  let downstream = docctx().layout_h_center_offset
        \\  docctx().layout_h_center_offset = docctx().layout_v_center_offset
        \\  docctx().layout_v_center_offset = docctx().layout_h_center_offset
        \\end
    , &.{
        "docctx().layout_h_center_offset = docctx().layout_v_center_offset",
        "docctx().layout_v_center_offset = docctx().layout_h_center_offset",
    }, &.{ "layout_h_center_offset", "layout_v_center_offset" });
}

test "cycle diagnostics include the resource of a self dependency" {
    try expectCyclePath(
        \\document
        \\  let independent = 2
        \\  let downstream = docctx().layout_h_center_offset
        \\  docctx().layout_h_center_offset = docctx().layout_h_center_offset
        \\end
    , &.{"docctx().layout_h_center_offset = docctx().layout_h_center_offset"}, &.{"layout_h_center_offset"});
}

test "cycle diagnostics retain every edge of a longer closed path" {
    try expectCyclePath(
        \\document
        \\  let downstream = docctx().layout_h
        \\  let third = docctx().layout_h
        \\  docctx().layout_h = docctx().layout_v
        \\  docctx().layout_v = third
        \\end
    , &.{
        "let third = docctx().layout_h",
        "docctx().layout_h = docctx().layout_v",
        "docctx().layout_v = third",
    }, &.{ "layout_h", "layout_v" });
}

test "nested record anchors depend on both immutable root bindings" {
    var state = try document(
        \\type Inner { item: Placed<Text> }
        \\type Outer { inner: Inner }
        \\page main
        \\  let target = Outer { inner = Inner { item = text!(str(docctx().layout_h_center_offset)) } }
        \\  let source = Outer { inner = Inner { item = text!(str(docctx().layout_v_center_offset)) } }
        \\  ~ target.inner.item.left == source.inner.item.right + 24
        \\end
        \\document
        \\  docctx().layout_h_center_offset = 42
        \\  docctx().layout_v_center_offset = 84
        \\end
    );
    defer state.deinit();
    var declarations = try compiler.declarations.build(testing.allocator, &state);
    defer declarations.deinit();
    var graph = try compiler.analysis.ExecutionGraph.build(testing.allocator, &state, &declarations, .{});
    defer graph.deinit();
    try testing.expectEqual(@as(usize, 5), graph.units.items.len);
    for ([_][]const u8{ "target", "source" }) |name| {
        var found = false;
        for (graph.units.items[2].summary.reads.items) |read| {
            if (read == .variable and std.mem.eql(u8, read.variable.name, name)) found = true;
        }
        try testing.expect(found);
    }
    for ([_]compiler.analysis.DependencyEdge{
        .{ .from = 3, .to = 0 },
        .{ .from = 4, .to = 1 },
        .{ .from = 0, .to = 2 },
        .{ .from = 1, .to = 2 },
    }) |expected| {
        var found = false;
        for (graph.edges.items) |edge| {
            if (edge.from == expected.from and edge.to == expected.to) found = true;
        }
        try testing.expect(found);
    }
}

// Keep freed allocations mapped but overwrite them, so stale string references
// fail deterministically rather than depending on allocator reuse.
const PoisonAllocator = struct {
    arena: std.heap.ArenaAllocator,

    fn allocator(self: *PoisonAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.arena.allocator().rawAlloc(len, alignment, ret_addr);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        @memset(memory, 0xa5);
    }
};

test "execution graph owns computed resource names after analyzers and cached summaries are destroyed" {
    var poison = PoisonAllocator{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer poison.arena.deinit();
    // The testing allocator also checks that the graph's string storage is freed.
    for ([_]std.mem.Allocator{ poison.allocator(), testing.allocator }) |allocator| {
        var state = try document(
            \\fn read_offset() -> Number = docctx().layout.center_offset
            \\document
            \\  let first = read_offset()
            \\end
            \\document
            \\  let second = read_offset()
            \\end
            \\document
            \\  docctx().layout.center_offset = 24
            \\end
        );
        defer state.deinit();
        // Synthetic nested paths allocate resource names in dependency analysis.
        // This tests graph ownership before surface field validation.
        var declarations = try compiler.declarations.build(testing.allocator, &state);
        defer declarations.deinit();
        var graph = try compiler.analysis.ExecutionGraph.build(allocator, &state, &declarations, .{});
        defer graph.deinit();
        try testing.expectEqual(@as(usize, 3), graph.units.items.len);
        for (graph.units.items[0..2]) |unit| {
            var found = false;
            for (unit.summary.reads.items) |resource| {
                if (resource == .property and resource.property.owner == .document) {
                    if (resource.property.key.displayName()) |name| {
                        if (std.mem.eql(u8, name, "layout.center_offset")) found = true;
                    }
                }
            }
            try testing.expect(found);
        }
        for ([_]compiler.analysis.DependencyEdge{ .{ .from = 2, .to = 0 }, .{ .from = 2, .to = 1 } }) |expected| {
            var found = false;
            for (graph.edges.items) |edge| {
                if (edge.from == expected.from and edge.to == expected.to) found = true;
            }
            try testing.expect(found);
        }
    }
}

test "execution graph bounds effect analysis even when called without termination checking" {
    var state = try document(
        \\fn recurse() -> Number = recurse()
        \\page main
        \\  let value = recurse()
        \\end
    );
    defer state.deinit();
    var declarations = try compiler.declarations.build(testing.allocator, &state);
    defer declarations.deinit();
    try testing.expectError(error.FunctionAnalysisLimitExceeded, compiler.analysis.ExecutionGraph.build(testing.allocator, &state, &declarations, .{}));
    const diagnostic = state.diagnostics.entries.items[state.diagnostics.entries.items.len - 1];
    try testing.expectEqualStrings("FunctionAnalysisLimitExceeded", diagnostic.code());
    const location = diagnostic.origin.?.location().?;
    try testing.expectEqualStrings("execution.ss", location.path.?);
    try testing.expect(location.span.end > location.span.start);
}

fn expectOwnedDiagnostic(source: []const u8, expected_code: []const u8, expected_message: []const u8) !void {
    var analysis_storage = std.heap.ArenaAllocator.init(testing.allocator);
    defer analysis_storage.deinit();
    // Document diagnostics use a freeing allocator, independently of the
    // temporary analysis storage.
    var state = try document(source);
    defer state.deinit();
    if (compiler.analysis.analyzeDocumentStateWithMode(analysis_storage.allocator(), &state, .diagnostics_only)) |graph| {
        if (graph) |value| {
            var owned = value;
            owned.deinit();
        }
        return error.ExpectedDiagnostic;
    } else |_| {}
    for (state.diagnostics.entries.items) |diagnostic| {
        if (!std.mem.eql(u8, diagnostic.code(), expected_code)) continue;
        switch (diagnostic.data) {
            .user_report => |data| try testing.expectEqualStrings(expected_message, data.message),
            .recursive_function => |data| try testing.expectEqualStrings(expected_message, data.function_name),
            else => return error.UnexpectedDiagnosticPayload,
        }
        return;
    }
    return error.ExpectedDiagnostic;
}

test "validation diagnostics own messages independently of analysis storage" {
    try expectOwnedDiagnostic(
        \\type Label {}
        \\fn display(self: Placed<Label>) -> Text = Text { content = readlines("missing.txt") }
        \\page main
        \\  place!(Label {})
        \\end
    , "ImpureDisplayFunction", "display functions must be pure and read-only, including indirect calls");
    try expectOwnedDiagnostic(
        \\type Holder { title: String }
        \\page main
        \\  let item = Holder { title = "A" } with { missing = "B" }
        \\end
    , "UnknownField", "type 'Holder' has no field 'missing'");
    try expectOwnedDiagnostic(
        \\type Label {}
        \\fn label() -> String = label()
        \\fn display(self: Placed<Label>) -> Text = Text { content = label() }
        \\page main
        \\  place!(Label {})
        \\end
    , "RecursiveFunction", "label");
}

test "call analysis limit diagnostics survive temporary analysis storage" {
    var source = std.ArrayList(u8).empty;
    defer source.deinit(testing.allocator);
    for (0..130) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "fn f{d}() -> Number = f{d}()\n", .{ i, i + 1 });
        defer testing.allocator.free(line);
        try source.appendSlice(testing.allocator, line);
    }
    try source.appendSlice(testing.allocator, "fn f130() -> Number = 0\npage main\nlet value = f0()\nend\n");
    try expectOwnedDiagnostic(source.items, "FunctionAnalysisLimitExceeded", "cannot establish termination within the function analysis depth limit");
}

test "dependency summary deduplication preserves overlapping resources in either order" {
    const deps = compiler.analysis.dependencies;
    const text_type = Type.recordType("Text").inModule(1);
    const typed: deps.Resource = .{ .objects = .{ .input_type = text_type } };
    const placed: deps.Resource = .{ .objects = .{ .input_type = text_type, .placement = .exact(1, &.{}) } };
    const pairs = [_][2]deps.Resource{
        .{ deps.Resource.makeProperty(.page, "layout_h_center_offset"), deps.Resource.makeProperty(.any, "layout_h_center_offset") },
        .{ deps.Resource.makeProperty(.document, "layout_h_center_offset"), deps.Resource.makeProperty(.document, null) },
        .{ typed, .{ .objects = .{} } },
        .{ placed, typed },
        .{ deps.Resource.makePages(1), deps.Resource.makePages(null) },
        .{ deps.Resource.makeVariable(.{ .page = 1 }, "item"), deps.Resource.makeVariable(.any, "item") },
    };
    for (pairs) |pair| for ([_]bool{ false, true }) |reverse| {
        const first = pair[@intFromBool(reverse)];
        const second = pair[1 - @as(usize, @intFromBool(reverse))];
        try testing.expect(first.intersects(second));
        try testing.expect(!first.eql(second));
        var summary = deps.AccessSummary.init(testing.allocator);
        defer summary.deinit();
        try summary.addSelectionRead(first);
        try summary.addSelectionRead(second);
        try summary.addSelectionRead(first);
        try summary.addWrite(first);
        try summary.addWrite(second);
        try summary.addWrite(second);
        try testing.expectEqual(@as(usize, 2), summary.reads.items.len);
        try testing.expectEqual(@as(usize, 2), summary.writes.items.len);
        try testing.expectEqual(@as(usize, 2), summary.selection_reads.items.len);
    };
    const name = try testing.allocator.dupe(u8, "Text");
    defer testing.allocator.free(name);
    const allocated: deps.Resource = .{ .objects = .{ .input_type = Type.recordType(name).inModule(1) } };
    try testing.expect(allocated.eql(typed));
    const other_module: deps.Resource = .{ .objects = .{ .input_type = Type.recordType("Text").inModule(2) } };
    try testing.expect(!allocated.intersects(other_module));
}

test "execution graph owns typed display summaries after temporary analysis storage is destroyed" {
    var poison = PoisonAllocator{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer poison.arena.deinit();
    for ([_]std.mem.Allocator{ poison.allocator(), testing.allocator }) |allocator| {
        var state = try document(
            \\type Label {}
            \\fn display(self: Placed<Label>) -> Text
            \\  return Text { content = str(self.document.layout_h_center_offset) }
            \\end
            \\page main
            \\  place!(Label {})
            \\end
            \\document
            \\  docctx().layout_h_center_offset = 42
            \\end
        );
        defer state.deinit();
        // Build display plans first, then inspect a graph whose temporary
        // summary allocations have already been freed and overwritten.
        try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
        var graph = try compiler.analysis.ExecutionGraph.build(allocator, &state, state.declaration_index, .{});
        defer graph.deinit();
        var found = false;
        for (graph.units.items, 0..) |unit, index| {
            if (unit.kind != .display) continue;
            for (unit.summary.reads.items) |resource| {
                if (resource != .property) continue;
                const name = resource.property.key.displayName() orelse continue;
                if (!std.mem.eql(u8, name, "layout_h_center_offset")) continue;
                found = true;
                var found_edge = false;
                for (graph.edges.items) |edge| {
                    if (edge.to == index and graph.units.items[edge.from].kind == .document_statement) found_edge = true;
                }
                try testing.expect(found_edge);
            }
        }
        try testing.expect(found);
    }
}
