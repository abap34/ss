const std = @import("std");
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

fn addLayoutFixture(state: *core.DocumentState) !void {
    const page_id = try state.addPage("page");
    const object_id = try state.makeObject(
        page_id,
        "object",
        null,
        .text,
        .text,
        "content",
    );
    state.getNode(page_id).?.frame = .{ .width = 640, .height = 360 };
    state.getNode(object_id).?.frame = .{
        .x = 10,
        .y = 20,
        .width = 30,
        .height = 40,
    };
}

fn initAndDeinitOwnedLayoutOutput(allocator: std.mem.Allocator) !void {
    var state = try initDocumentState(allocator);
    defer state.deinit();
    try addLayoutFixture(&state);

    var report = try core.layout.conflicts.Report.init(allocator, &state);
    var report_transferred = false;
    errdefer if (!report_transferred) report.deinit();
    report_transferred = true;
    var output = try analysis.snapshot.LayoutOutput.fromDocumentStateWithOwnedReport(
        allocator,
        &state,
        report,
        null,
        null,
    );
    defer output.deinit(allocator);
}

test "analysis snapshot layout output adopts an owned conflict report" {
    var state = try initDocumentState(testing.allocator);
    defer state.deinit();
    try addLayoutFixture(&state);

    var report = try core.layout.conflicts.Report.init(testing.allocator, &state);
    var report_transferred = false;
    errdefer if (!report_transferred) report.deinit();
    const report_pages_pointer = report.pages.ptr;
    const report_objects_pointer = report.objects.ptr;
    const conflicts_json = try testing.allocator.dupe(u8, "{}\n");

    report_transferred = true;
    var output = try analysis.snapshot.LayoutOutput.fromDocumentStateWithOwnedReport(
        testing.allocator,
        &state,
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
    try testing.checkAllAllocationFailures(
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
    try testing.checkAllAllocationFailures(testing.allocator, retainQueryTypes, .{});
}

fn releasePreparedLayoutInputs(allocator: std.mem.Allocator, retain_state: bool) !void {
    var state = try initDocumentState(allocator);
    var state_owned = true;
    defer if (state_owned) state.deinit();
    const page_id = try state.addPage("retained");
    _ = try state.makeObject(page_id, "object", null, .text, .text, "");
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
        try testing.expect(state.getNode(state.page_order.items[0]) != null);
    }
}

test "prepared layout inputs follow retained state ownership and canceled hook output" {
    for ([_]bool{ false, true }) |retain_state| {
        try releasePreparedLayoutInputs(testing.allocator, retain_state);
        try testing.checkAllAllocationFailures(testing.allocator, releasePreparedLayoutInputs, .{retain_state});
    }
}
