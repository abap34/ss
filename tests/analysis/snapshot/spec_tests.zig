const std = @import("std");
const analysis = @import("analysis");
const ast = @import("ast");
const core = @import("core");

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
