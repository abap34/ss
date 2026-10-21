const document_testing = @import("document_testing");
const LayoutFixture = @import("layout_testing").Fixture;
const std = @import("std");
const allocation_testing = @import("allocation_testing");
const analysis = @import("analysis");
const ast = @import("ast");
const core = @import("core");
const render_text = @import("render_text");

const testing = std.testing;

fn initDocumentState(allocator: std.mem.Allocator) !core.DocumentState {
    const asset_base_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, "analysis-snapshot-test.ss");
    errdefer allocator.free(project_path);
    const project_source = try allocator.dupe(u8, "");
    errdefer allocator.free(project_source);
    return core.DocumentState.init(
        allocator,
        asset_base_dir,
        project_path,
        project_source,
        ast.Module.init(),
    );
}

fn addLayoutFixture(state: *core.DocumentState, geometry: *LayoutFixture) !void {
    const page_id = try state.addPage("page");
    const object_id = try document_testing.native(state, page_id, "object", .text, "content");
    (try geometry.frame(page_id)).* = .{ .width = 640, .height = 360 };
    (try geometry.frame(object_id)).* = .{
        .x = 10,
        .y = 20,
        .width = 30,
        .height = 40,
    };
}

fn initAndDeinitOwnedLayoutOutput(allocator: std.mem.Allocator) !void {
    var state = try initDocumentState(allocator);
    defer state.deinit();
    var geometry = LayoutFixture.init(&state);
    defer geometry.deinit();
    try addLayoutFixture(&state, &geometry);

    var report = try core.layout.conflicts.Report.init(allocator, &state, try geometry.document());
    var report_transferred = false;
    errdefer if (!report_transferred) report.deinit();
    report_transferred = true;
    var output = try analysis.snapshot.LayoutOutput.fromDocumentStateWithOwnedReport(
        allocator,
        &state,
        try geometry.document(),
        report,
        null,
        null,
    );
    defer output.deinit(allocator);
}

test "analysis snapshot layout output adopts an owned conflict report" {
    var state = try initDocumentState(testing.allocator);
    defer state.deinit();
    var geometry = LayoutFixture.init(&state);
    defer geometry.deinit();
    try addLayoutFixture(&state, &geometry);

    var report = try core.layout.conflicts.Report.init(testing.allocator, &state, try geometry.document());
    var report_transferred = false;
    errdefer if (!report_transferred) report.deinit();
    const report_pages_pointer = report.pages.ptr;
    const report_objects_pointer = report.objects.ptr;
    const conflicts_json = try testing.allocator.dupe(u8, "{}\n");

    report_transferred = true;
    var output = try analysis.snapshot.LayoutOutput.fromDocumentStateWithOwnedReport(
        testing.allocator,
        &state,
        try geometry.document(),
        report,
        null,
        conflicts_json,
    );
    defer output.deinit(testing.allocator);

    try testing.expectEqual(@intFromPtr(report_pages_pointer), @intFromPtr(output.report.pages.ptr));
    try testing.expectEqual(@intFromPtr(report_objects_pointer), @intFromPtr(output.report.objects.ptr));
    try testing.expectEqual(@as(usize, 1), output.report.pages.len);
    try testing.expectEqual(@as(usize, 1), output.report.objects.len);
}

test "analysis snapshot owned layout output releases every partial allocation" {
    try allocation_testing.checkAllAllocationFailures(
        testing.allocator,
        initAndDeinitOwnedLayoutOutput,
        .{},
    );
}

fn retainQueryTypes(allocator: std.mem.Allocator) !void {
    var storage = analysis.snapshot.TypeStorage.init(allocator);
    defer storage.deinit();
    var nested_name = [_]u8{ 'T', 'e', 'x', 't' };
    const child = ast.Type.recordType(&nested_name).inModule(13);
    var record = ast.Type.recordType("Style").inModule(12);
    record.arguments = &.{child};
    const optional = ast.Type{ .kind = .optional, .optional_child = &record };
    var params = [_]ast.Type{optional};
    const function = ast.Type{ .kind = .function, .fn_params = &params, .fn_result = &record };
    const retained = try storage.retain(function);
    try testing.expect(ast.Type.eql(function, retained));
    try testing.expect(retained.fn_result.?.class_name.?.ptr != record.class_name.?.ptr);
    try testing.expect(retained.fn_params[0].optional_child.?.class_name.?.ptr != record.class_name.?.ptr);
    try testing.expectEqual(@as(?u32, 12), retained.fn_params[0].optional_child.?.nominal_module_id);
    nested_name[0] = 'N';
    try testing.expectEqualStrings("Text", retained.fn_result.?.arguments[0].class_name.?);
    try testing.expectEqualStrings("Text", retained.fn_params[0].optional_child.?.arguments[0].class_name.?);
    try testing.expectEqual(@as(?u32, 13), retained.fn_result.?.arguments[0].nominal_module_id);
}

test "analysis snapshot types retain nested names independently of source owners" {
    try retainQueryTypes(testing.allocator);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, retainQueryTypes, .{});
}

fn releasePreparedLayoutInputs(allocator: std.mem.Allocator, retain_state: bool) !void {
    var state = try initDocumentState(allocator);
    var state_owned = true;
    defer if (state_owned) state.deinit();
    const page_id = try state.addPage("retained");
    _ = try document_testing.native(&state, page_id, "object", .text, "content");
    var output = analysis.snapshot.LayoutHookOutput{ .reuse_inputs = .{
        .pages = try core.prepared.prepare(allocator, &state),
        .font_environment = std.mem.zeroes(render_text.FontEnvironment),
    } };
    defer output.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), output.reuse_inputs.?.pages.pages.len);
    try testing.expectEqual(@as(usize, 1), output.reuse_inputs.?.pages.pages[0].objects.len);
    if (retain_state) {
        var retained = analysis.snapshot.RetainedLayoutState{ .state = state, .reuse_inputs = output.reuse_inputs };
        state_owned = false;
        output.reuse_inputs = null;
        retained.deinit();
    } else {
        // Canceled layout work releases its prepared inputs while the caller still owns the state.
        output.deinit(allocator);
        try testing.expect(state.getNode(state.graph.page_order.items[0]) != null);
    }
}

test "prepared layout inputs follow retained state ownership and canceled hook output" {
    for ([_]bool{ false, true }) |retain_state| {
        try releasePreparedLayoutInputs(testing.allocator, retain_state);
        try allocation_testing.checkAllAllocationFailures(testing.allocator, releasePreparedLayoutInputs, .{retain_state});
    }
}

fn buildStageSnapshot(source: []const u8, options: analysis.snapshot.Options) !analysis.snapshot.AnalysisSnapshot {
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    // A core-module path keeps these ownership checks independent of the prelude.
    const path = "stdlib/internal/snapshot-stage-test.ss";
    try sources.put(path, source);
    return analysis.snapshot.build(testing.allocator, &sources, path, ".", options);
}

test "snapshot construction preserves query sources and optional execution inputs" {
    const source = "page sample\nend\n";
    for ([_]bool{ false, true }) |retain_inputs| {
        var snapshot = try buildStageSnapshot(source, .{ .generation = 7, .retain_layout_inputs = retain_inputs });
        defer snapshot.deinit();
        try testing.expect(!snapshot.diagnostics.hasErrors());
        try testing.expectEqual(@as(u64, 7), snapshot.generation);
        try testing.expectEqual(retain_inputs, snapshot.retained_layout_inputs != null);
        try testing.expectEqualStrings(source, analysis.snapshot.sourceForPath(&snapshot, "stdlib/internal/snapshot-stage-test.ss").?);
        if (snapshot.retained_layout_inputs) |*inputs| {
            try testing.expectEqualStrings(source, inputs.state.projectSource());
            try testing.expectEqual(@as(usize, 1), inputs.state.graph.page_order.items.len);
        }
    }
}

test "snapshot construction preserves query sources after semantic errors" {
    const source = "page sample\nlet value: Number = \"invalid\"\nend\n";
    var snapshot = try buildStageSnapshot(source, .{ .retain_layout_inputs = true });
    defer snapshot.deinit();
    try testing.expect(snapshot.diagnostics.hasErrors());
    try testing.expect(snapshot.retained_layout_inputs == null);
    try testing.expectEqualStrings(source, analysis.snapshot.sourceForPath(&snapshot, "stdlib/internal/snapshot-stage-test.ss").?);
}

const CancelAfterLayout = struct {
    canceled: bool = false,

    fn isCanceled(context: *const anyopaque) bool {
        const self: *const CancelAfterLayout = @ptrCast(@alignCast(context));
        return self.canceled;
    }

    fn run(context: *anyopaque, state: *core.DocumentState, _: *const analysis.execution.ExecutionGraph) anyerror!analysis.snapshot.LayoutHookOutput {
        const self: *CancelAfterLayout = @ptrCast(@alignCast(context));
        const pages = try core.prepared.prepare(state.allocator, state);
        self.canceled = true;
        return .{ .reuse_inputs = .{
            .pages = pages,
            .font_environment = std.mem.zeroes(render_text.FontEnvironment),
        } };
    }
};

test "snapshot cancellation releases results returned by the layout hook" {
    var cancellation = CancelAfterLayout{};
    try testing.expectError(error.Canceled, buildStageSnapshot("page sample\nend\n", .{
        .layout_hook = .{ .context = &cancellation, .run = CancelAfterLayout.run },
        .cancellation = .{ .context = &cancellation, .is_canceled = CancelAfterLayout.isCanceled },
        .retain_evaluated_layout_state = true,
    }));
    try testing.expect(cancellation.canceled);
}

test "snapshot cancellation releases each intermediate stage and preserves reusable sources" {
    const entry = "stdlib/cancellation-entry.ss";
    const source =
        \\type Pair<T> { first: T second: T }
        \\fn choose(value: Number, offset: Number = 2) -> Number
        \\  if value > 0
        \\    return value + offset
        \\  else
        \\    return offset
        \\  end
        \\end
        \\fn apply(operation: Number -> Number, value: Number) -> Number
        \\  return operation(value)
        \\end
        \\const initial: Number = 3
        \\document
        \\  let input = initial
        \\  let callback = (value: Number) |-> choose(value)
        \\  let first = apply(callback, input)
        \\  let second = choose(first)
        \\  let pair = Pair<Number> { first = first second = second }
        \\end
        \\page sample
        \\  let value = choose(2)
        \\end
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    for ([_]bool{ false, true }) |broken| {
        const text = if (broken) try std.fmt.allocPrint(testing.allocator, "{s}\npage unfinished\nlet partial =\n", .{source}) else try testing.allocator.dupe(u8, source);
        defer testing.allocator.free(text);
        try sources.put(entry, text);
        var counter = CancelAtCheck{};
        const options = analysis.snapshot.Options{
            .retain_layout_inputs = true,
            .cancellation = .{ .context = &counter, .is_canceled = CancelAtCheck.canceled },
        };
        {
            var baseline = try analysis.snapshot.build(testing.allocator, &sources, entry, ".", options);
            defer baseline.deinit();
            try testing.expectEqual(broken, baseline.diagnostics.hasErrors());
        }
        const total_checks = counter.checks;
        try testing.expect(total_checks > 20);
        for (1..total_checks + 1) |limit| {
            counter = .{ .limit = limit };
            try testing.expectError(error.Canceled, analysis.snapshot.build(testing.allocator, &sources, entry, ".", options));
        }
        counter = .{};
        var recovered = try analysis.snapshot.build(testing.allocator, &sources, entry, ".", options);
        defer recovered.deinit();
        try testing.expectEqual(broken, recovered.diagnostics.hasErrors());
        try testing.expectEqualStrings(text, analysis.snapshot.sourceForPath(&recovered, entry).?);
    }
}

test "snapshot retains recovered import diagnostics and clears them after repair" {
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    const entry = "stdlib/internal/snapshot-import-test.ss";
    const imported = "stdlib/internal/snapshot-import-library.ss";
    const entry_source = "import ./snapshot-import-library as library\npage sample\nend\n";
    const broken_source = "const missing: Number =\nconst kept: Number = 2\n";
    try sources.put(entry, entry_source);
    try sources.put(imported, broken_source);
    {
        var snapshot = try analysis.snapshot.build(testing.allocator, &sources, entry, ".", .{});
        defer snapshot.deinit();
        try testing.expect(snapshot.diagnostics.hasErrors());
        var found_import = false;
        var found_summary = false;
        for (snapshot.diagnostics.items.items) |diagnostic| {
            if (std.mem.endsWith(u8, diagnostic.path, "snapshot-import-library.ss")) {
                found_import = true;
                try testing.expectEqualStrings(broken_source, diagnostic.source);
                try testing.expect(diagnostic.span != null);
                try testing.expectEqual(core.DiagnosticSeverity.@"error", diagnostic.severity);
            }
            if (std.mem.eql(u8, diagnostic.code, "ImportFailed")) {
                found_summary = true;
                try testing.expectEqualStrings(entry, diagnostic.path);
                try testing.expect(diagnostic.span != null);
            }
        }
        if (!found_import) {
            for (snapshot.diagnostics.items.items) |diagnostic| {
                std.debug.print("{s}: {s}: {s}\n", .{ diagnostic.path, diagnostic.code, diagnostic.message });
            }
        }
        try testing.expect(found_import);
        try testing.expect(found_summary);
        try testing.expectEqualStrings(entry_source, analysis.snapshot.sourceForPath(&snapshot, entry).?);
    }
    try sources.put(imported, "const missing: Number = 1\nconst kept: Number = 2\n");
    var repaired = try analysis.snapshot.build(testing.allocator, &sources, entry, ".", .{ .generation = 2 });
    defer repaired.deinit();
    try testing.expect(!repaired.diagnostics.hasErrors());
}

fn projectFactsWithFailure(allocator: std.mem.Allocator, state: *const core.DocumentState, cancel: bool) !void {
    var languages = [_]std.meta.Child(@TypeOf((analysis.snapshot.ProjectFacts{}).highlight.languages)){.{
        .name = @constCast("custom"),
        .parser = @constCast("parser.so"),
        .query = @constCast("(identifier) @variable"),
    }};
    const result = analysis.snapshot.ProjectFacts.fromDocumentState(allocator, state, "entry.ss", ".", .{
        .project = .{ .highlight = .{ .languages = &languages } },
        .cancellation = .{ .context = &cancel, .is_canceled = projectFactsCanceled },
    });
    if (cancel) {
        // Allocation failure remains visible to the failure enumerator.
        if (result) |value| {
            var facts = value;
            facts.deinit(allocator);
            return error.ExpectedCancellation;
        } else |err| {
            if (err == error.OutOfMemory) return err;
            try testing.expectEqual(error.Canceled, err);
        }
    } else {
        var facts = try result;
        defer facts.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), facts.module_paths.len);
        try testing.expectEqualStrings("custom", facts.highlight.languages[0].name);
    }
}

fn projectFactsCanceled(context: *const anyopaque) bool {
    const canceled: *const bool = @ptrCast(@alignCast(context));
    return canceled.*;
}

test "project facts release collected module paths on cancellation and allocation failure" {
    var state = try initDocumentState(testing.allocator);
    defer state.deinit();
    for ([_]bool{ false, true }) |cancel| {
        try allocation_testing.checkAllAllocationFailures(testing.allocator, projectFactsWithFailure, .{ &state, cancel });
    }
}

test "recovered holes retain module identity and owned nominal type names" {
    const entry = "stdlib/internal/hole-entry.ss";
    const imported = "stdlib/internal/hole-library.ss";
    var snapshot = blk: {
        var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
        defer sources.deinit();
        try sources.put(entry,
            \\import ./hole-library as library
            \\type Local { value: Number = 1 }
            \\const missing: Number =
            \\const nominal: Local =
        );
        try sources.put(imported,
            \\type Remote { value: String = "value" }
            \\const missing: String =
            \\const nominal: Remote =
        );
        break :blk try analysis.snapshot.build(testing.allocator, &sources, entry, ".", .{});
    };
    defer snapshot.deinit();
    try testing.expect(snapshot.diagnostics.hasErrors());
    var found_entry = false;
    var found_import = false;
    var found_local = false;
    var found_remote = false;
    for (snapshot.holes) |hole| {
        const ty = hole.expected_type orelse continue;
        if (hole.id == 0 and hole.module_id == 0) {
            try testing.expectEqual(ast.Type.Kind.number, ty.kind);
            found_entry = true;
        } else if (hole.id == 0 and hole.module_id != 0) {
            try testing.expectEqual(ast.Type.Kind.string, ty.kind);
            found_import = true;
        }
        if (ty.class_name) |name| {
            if (hole.module_id == 0) {
                try testing.expectEqualStrings("Local", name);
                found_local = true;
            } else {
                try testing.expectEqualStrings("Remote", name);
                found_remote = true;
            }
        }
    }
    try testing.expect(found_entry and found_import and found_local and found_remote);
}

fn expectRecoveredType(expr: ast.Expr, annotation: ast.Type, expected: ?ast.Type) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = try initDocumentState(allocator);
    defer state.deinit();
    try state.projectModuleMutable().syntax.constants.append(allocator, .{
        .name = try allocator.dupe(u8, "value"),
        .span = .{ .start = 0, .end = 1 },
        .value_type = try annotation.clone(allocator),
        .value = try expr.clone(allocator),
    });
    var holes = [_]analysis.syntax_hole.Hole{.{ .id = 0, .kind = .expr, .span = .{ .start = 0, .end = 1 }, .expected = .expression }};
    defer holes[0].deinit(testing.allocator);
    var tables = [_]analysis.syntax_hole.ModuleResult{.{ .module_id = state.modules.project_id, .result = .{ .holes = &holes, .diagnostics = &.{} } }};
    try analysis.hole_facts.populateExpectedTypes(testing.allocator, &state, state.declaration_index, &tables);
    if (expected) |ty| {
        try testing.expect(holes[0].expected_type != null);
        try testing.expect(ast.Type.eql(ty, holes[0].expected_type.?));
    } else try testing.expect(holes[0].expected_type == null);
}

test "hole expectations follow the type of each syntactic position" {
    var hole = ast.Expr{ .hole = 0 };
    var number = ast.Type.number;
    var fallback = ast.Expr{ .number = 1 };
    const function = ast.Type{ .kind = .function, .fn_result = &number };
    try expectRecoveredType(.{ .lambda = .{ .params = .empty, .body = &hole, .span = .{ .start = 0, .end = 1 } } }, function, ast.Type.number);
    try expectRecoveredType(.{ .member = .{ .target = &hole, .name = "field" } }, ast.Type.number, null);
    try expectRecoveredType(.{ .optional_check = .{ .target = &hole } }, ast.Type.boolean, null);
    try expectRecoveredType(.{ .coalesce = .{ .target = &hole, .fallback = &fallback } }, ast.Type.number, .{ .kind = .optional, .optional_child = &number });
    try expectRecoveredType(.{ .coalesce = .{ .target = &fallback, .fallback = &hole } }, ast.Type.number, ast.Type.number);
    try expectRecoveredType(.{ .apply = .{ .callee = &hole, .args = .empty } }, ast.Type.number, null);
    try expectRecoveredType(.{ .record_update = .{ .target = &hole, .fields = .empty, .body_span = .{ .start = 0, .end = 1 } } }, ast.Type.number, ast.Type.number);
}

test "invalid function bodies do not create undefined caller bindings" {
    const path = "stdlib/internal/caller-diagnostics.ss";
    const source =
        \\fn label() -> String
        \\  let missing: String = undefined_name
        \\  let subsequent = missing
        \\  return subsequent
        \\end
        \\page main
        \\  let s: String = label()
        \\  let next = s
        \\  let last = label()
        \\  let other = independent_error
        \\end
    ;
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expectEqual(@as(usize, 2), snapshot.diagnostics.items.items.len);
    for (snapshot.diagnostics.items.items) |diagnostic| {
        try testing.expectEqualStrings("UnknownIdentifier", diagnostic.code);
        try testing.expect(std.mem.indexOf(u8, diagnostic.message, "undefined_name") != null or std.mem.indexOf(u8, diagnostic.message, "independent_error") != null);
    }
    try testing.expect(snapshot.retained_layout_inputs == null);
    try testing.expect(snapshot.layout_output == null);
}

test "errors in imported defaults and constants retain their defining source" {
    const path = "stdlib/internal/default-diagnostics.ss";
    const imported = "stdlib/internal/default-library.ss";
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(path,
        \\import ./default-library as *
        \\const early: String = label()
        \\page main
        \\  let s = label()
        \\  let next = s
        \\  let obtained = value
        \\  let use = obtained
        \\end
    );
    try sources.put(imported,
        \\fn label(value: String = missing_default) -> String = value
        \\const value: String = missing_constant
    );
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expectEqual(@as(usize, 2), snapshot.diagnostics.items.items.len);
    for (snapshot.diagnostics.items.items) |diagnostic| {
        try testing.expectEqualStrings("UnknownIdentifier", diagnostic.code);
        try testing.expect(std.mem.endsWith(u8, diagnostic.path, "default-library.ss"));
    }
}

test "argument type errors remain attached to the call site" {
    const path = "stdlib/internal/argument-diagnostics.ss";
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put("stdlib/internal/argument-library.ss", "fn echo(value: String) -> String = value\n");
    try sources.put(path,
        \\import ./argument-library as library
        \\page main
        \\  let bad = library::echo(1)
        \\  let next = bad
        \\end
    );
    var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{});
    defer snapshot.deinit();
    try testing.expectEqual(@as(usize, 1), snapshot.diagnostics.items.items.len);
    const diagnostic = snapshot.diagnostics.items.items[0];
    try testing.expectEqualStrings(path, diagnostic.path);
    try testing.expect(std.mem.indexOf(u8, diagnostic.message, "String") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostic.message, "Number") != null);
}

const CancelAtCheck = struct {
    checks: usize = 0,
    limit: usize = std.math.maxInt(usize),

    fn canceled(context: *const anyopaque) bool {
        const self: *CancelAtCheck = @ptrCast(@alignCast(@constCast(context)));
        self.checks += 1;
        return self.checks >= self.limit;
    }
};

test "snapshot construction propagates cancellation and clears borrowed analysis tokens" {
    const text = "fn increment(value: Number) -> Number = value + 1\npage sample\nlet result = increment(increment(1))\nend\n";
    var counter = CancelAtCheck{};
    var snapshot = try buildStageSnapshot(text, .{
        .retain_layout_inputs = true,
        .cancellation = .{ .context = &counter, .is_canceled = CancelAtCheck.canceled },
    });
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    try testing.expect(snapshot.retained_layout_inputs.?.state.runtime.analysis_cancellation == null);
    const total = counter.checks;
    for ([_]usize{ 1, total / 2, total - 1 }) |limit| {
        counter = .{ .limit = limit };
        try testing.expectError(error.Canceled, buildStageSnapshot(text, .{
            .retain_layout_inputs = true,
            .cancellation = .{ .context = &counter, .is_canceled = CancelAtCheck.canceled },
        }));
    }
}
