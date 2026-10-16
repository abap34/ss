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
    const object_id = try state.makeObject(
        page_id,
        "object",
        null,
        .text,
        .text,
        "content",
    );
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
    var record = ast.Type.recordType("Style").inModule(12);
    const optional = ast.Type{ .kind = .optional, .optional_child = &record };
    var params = [_]ast.Type{optional};
    const function = ast.Type{ .kind = .function, .fn_params = &params, .fn_result = &record };
    const retained = try storage.retain(function);
    try testing.expect(ast.Type.eql(function, retained));
    try testing.expect(retained.fn_result.?.class_name.?.ptr != record.class_name.?.ptr);
    try testing.expect(retained.fn_params[0].optional_child.?.class_name.?.ptr != record.class_name.?.ptr);
    try testing.expectEqual(@as(?u32, 12), retained.fn_params[0].optional_child.?.nominal_module_id);
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
    _ = try state.makeObject(page_id, "object", null, .text, .text, "content");
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
    const path = "stdlib/core/snapshot-stage-test.ss";
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
        try testing.expectEqualStrings(source, analysis.snapshot.sourceForPath(&snapshot, "stdlib/core/snapshot-stage-test.ss").?);
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
    try testing.expectEqualStrings(source, analysis.snapshot.sourceForPath(&snapshot, "stdlib/core/snapshot-stage-test.ss").?);
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

test "snapshot retains recovered import diagnostics and clears them after repair" {
    var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    const entry = "stdlib/core/snapshot-import-test.ss";
    const imported = "stdlib/core/snapshot-import-library.ss";
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
