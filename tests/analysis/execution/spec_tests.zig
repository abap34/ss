const std = @import("std");
const compiler = @import("compiler");
const core = compiler.core;
const testing = std.testing;

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
            \\  let target = text("hello")
            \\  target.content = target.content ++ "!"
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
        try testing.expectEqual(keys.len, std.mem.count(u8, message, " via "));
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
        \\  let downstream = docctx().footer_text
        \\  docctx().footer_text = docctx().watermark
        \\  docctx().watermark = docctx().footer_text
        \\end
    , &.{
        "docctx().footer_text = docctx().watermark",
        "docctx().watermark = docctx().footer_text",
    }, &.{ "footer_text", "watermark" });
}

test "cycle diagnostics include the resource of a self dependency" {
    try expectCyclePath(
        \\document
        \\  let independent = 2
        \\  let downstream = docctx().footer_text
        \\  docctx().footer_text = docctx().footer_text
        \\end
    , &.{"docctx().footer_text = docctx().footer_text"}, &.{"footer_text"});
}

test "cycle diagnostics retain every edge of a longer closed path" {
    try expectCyclePath(
        \\document
        \\  let downstream = docctx().footer_text
        \\  docctx().footer_text = docctx().watermark
        \\  docctx().watermark = docctx().pageno_fmt
        \\  docctx().pageno_fmt = docctx().footer_text
        \\end
    , &.{
        "docctx().footer_text = docctx().watermark",
        "docctx().watermark = docctx().pageno_fmt",
        "docctx().pageno_fmt = docctx().footer_text",
    }, &.{ "footer_text", "watermark", "pageno_fmt" });
}

test "nested record anchors depend on both immutable root bindings" {
    var state = try document(
        \\record Inner { item: Object }
        \\record Outer { inner: Inner }
        \\page main
        \\  let target = Outer { inner = Inner { item = text!(docctx().footer_text ?? "missing") } }
        \\  let source = Outer { inner = Inner { item = text!(docctx().watermark ?? "missing") } }
        \\  ~ target.inner.item.left == source.inner.item.right + 24
        \\end
        \\document
        \\  docctx().footer_text = "Target"
        \\  docctx().watermark = "Source"
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
            \\fn read_size() -> Number = prop(docctx(), "font_" ++ "size")
            \\document
            \\  let first = read_size()
            \\end
            \\document
            \\  let second = read_size()
            \\end
            \\document
            \\  set_prop(docctx(), "font_" ++ "size", 24)
            \\end
            \\page main
            \\  let items = doc_objs(docctx(), "tag" ++ "ged")
            \\  let item = place!(new("item", "tag" ++ "ged", "text"))
            \\end
        );
        defer state.deinit();
        var declarations = try compiler.declarations.build(testing.allocator, &state);
        defer declarations.deinit();
        var graph = try compiler.analysis.ExecutionGraph.build(allocator, &state, &declarations, .{});
        defer graph.deinit();
        try testing.expectEqual(@as(usize, 5), graph.units.items.len);
        for (graph.units.items[0..2]) |unit| {
            var found = false;
            for (unit.summary.reads.items) |resource| {
                if (resource == .property and resource.property.owner == .document) {
                    if (resource.property.key.displayName()) |name| {
                        if (std.mem.eql(u8, name, "font_size")) found = true;
                    }
                }
            }
            try testing.expect(found);
        }
        var found_role = false;
        for (graph.units.items[3].summary.reads.items) |resource| {
            if (resource == .objects) {
                if (resource.objects.role) |role| {
                    if (std.mem.eql(u8, role, "tagged")) found_role = true;
                }
            }
        }
        try testing.expect(found_role);
        for ([_]compiler.analysis.DependencyEdge{ .{ .from = 2, .to = 0 }, .{ .from = 2, .to = 1 }, .{ .from = 4, .to = 3 } }) |expected| {
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
        try testing.expect(diagnostic.data == .user_report);
        try testing.expectEqualStrings(expected_message, diagnostic.data.user_report.message);
        return;
    }
    return error.ExpectedDiagnostic;
}

test "validation diagnostics own messages independently of analysis storage" {
    try expectOwnedDiagnostic(
        \\fn label(item: Object) -> String = readlines("missing.txt")
        \\page main
        \\  set_repr(text!("A"), label)
        \\end
    , "ImpureDisplayFunction", "display functions must be pure and read-only, including indirect calls");
    try expectOwnedDiagnostic(
        \\type Holder = object {
        \\  roles = ["holder"]
        \\  format: (Object -> String)?
        \\}
        \\page main
        \\  let item = txt_obj("A", "holder")
        \\  set_repr(item, item.format ?? ((value: Object) |-> content(value)))
        \\end
    , "InvalidPropertyType", "property 'format' must not contain functions or unconstrained Any values");
    try expectOwnedDiagnostic(
        \\page main
        \\  let item = text!("A")
        \\  set_repr(item, (self: Object) |-> repr(self))
        \\end
    , "RecursiveFunction", "recursive function value application");
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
    const specific: deps.PropertyOwner = .{ .object = .{ .identity = .{ .scope = .{ .page = 1 }, .name = "item" } } };
    const pairs = [_][2]deps.Resource{
        .{ deps.Resource.makeProperty(specific, "badge"), deps.Resource.makeProperty(.{ .object = .{} }, "badge") },
        .{ deps.Resource.makeProperty(.document, "badge"), deps.Resource.makeProperty(.document, null) },
        .{ deps.Resource.makeObjects("body"), deps.Resource.makeObjects(null) },
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
    const name = try testing.allocator.dupe(u8, "body");
    defer testing.allocator.free(name);
    try testing.expect(deps.Resource.makeObjects(name).eql(deps.Resource.makeObjects("body")));
}

test "execution graph owns deferred display summaries and their computed resource names" {
    var poison = PoisonAllocator{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer poison.arena.deinit();
    for ([_]std.mem.Allocator{ poison.allocator(), testing.allocator }) |allocator| {
        var state = try document(
            \\fn label(item: Object) -> String = prop(docctx(), "footer_" ++ "text") ?? ""
            \\page main
            \\  let item = new("item", "body", "text")
            \\  set_repr(item, label)
            \\  let text = repr(item)
            \\end
            \\document
            \\  set_prop(docctx(), "footer_" ++ "text", "X")
            \\end
        );
        defer state.deinit();
        var declarations = try compiler.declarations.build(testing.allocator, &state);
        defer declarations.deinit();
        var graph = try compiler.analysis.ExecutionGraph.build(allocator, &state, &declarations, .{});
        defer graph.deinit();
        var found = false;
        for (graph.edges.items) |edge| {
            if (edge.from == 3 and edge.to == 2) found = true;
        }
        try testing.expect(found);
        const definitions = graph.units.items[1].summary.display_definitions.items;
        try testing.expectEqual(@as(usize, 1), definitions.len);
        var found_name = false;
        for (definitions[0].reads.reads.items) |resource| {
            if (resource == .property) {
                if (resource.property.key.displayName()) |name| {
                    if (std.mem.eql(u8, name, "footer_text")) found_name = true;
                }
            }
        }
        try testing.expect(found_name);
    }
}
