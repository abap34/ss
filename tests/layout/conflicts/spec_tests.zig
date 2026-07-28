const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const testing = std.testing;

const Fixture = struct {
    first_page: core.NodeId,
    second_page: core.NodeId,
    first_object: core.NodeId,
    second_object: core.NodeId,
};

fn initDocumentState(allocator: std.mem.Allocator) !core.DocumentState {
    const asset_base_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, "layout-conflicts-test.ss");
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

fn addFixture(state: *core.DocumentState) !Fixture {
    const first_page = try state.addPage("first");
    const second_page = try state.addPage("second");
    const first_object = try state.makeObject(
        first_page,
        "first-object",
        null,
        .text,
        .text,
        "first",
    );
    const second_object = try state.makeObject(
        second_page,
        "second-object",
        null,
        .text,
        .text,
        "second",
    );
    try state.addAnchorConstraint(
        first_object,
        .left,
        .{ .page = .left },
        12,
        "bytes:0-0",
    );

    state.getNode(first_page).?.frame = .{ .width = 640, .height = 360 };
    state.getNode(second_page).?.frame = .{ .width = 1280, .height = 720 };
    state.getNode(first_object).?.frame = .{
        .x = 10,
        .y = 20,
        .width = 30,
        .height = 40,
    };
    state.getNode(second_object).?.frame = .{
        .x = 50,
        .y = 60,
        .width = 70,
        .height = 80,
    };

    return .{
        .first_page = first_page,
        .second_page = second_page,
        .first_object = first_object,
        .second_object = second_object,
    };
}

fn initAndDeinitReport(allocator: std.mem.Allocator, state: *core.DocumentState) !void {
    var report = try core.layout.conflicts.Report.init(allocator, state);
    defer report.deinit();

    try testing.expectEqual(state.page_order.items.len, report.page_index_by_id.count());
    try testing.expectEqual(@as(usize, 2), report.object_index_by_id.count());
    try testing.expectEqual(@as(usize, 1), report.relations.len);
}

test "layout conflict report indexes pages and objects by node id" {
    var state = try initDocumentState(testing.allocator);
    defer state.deinit();
    const fixture = try addFixture(&state);

    var report = try core.layout.conflicts.Report.init(testing.allocator, &state);
    defer report.deinit();

    try testing.expectEqual(@as(?usize, 0), report.page_index_by_id.get(fixture.first_page));
    try testing.expectEqual(@as(?usize, 1), report.page_index_by_id.get(fixture.second_page));
    try testing.expectEqual(@as(?usize, 0), report.object_index_by_id.get(fixture.first_object));
    try testing.expectEqual(@as(?usize, 1), report.object_index_by_id.get(fixture.second_object));

    const page = report.pageById(fixture.second_page) orelse return error.MissingPage;
    try testing.expectEqual(fixture.second_page, page.id);
    try testing.expectEqual(@as(f32, 1280), page.width);
    try testing.expectEqual(@as(f32, 720), page.height);

    const object = report.objectById(fixture.second_object) orelse return error.MissingObject;
    try testing.expectEqual(fixture.second_object, object.id);
    try testing.expectEqual(fixture.second_page, object.page_id);
    try testing.expectEqual(@as(f32, 50), object.x);
    try testing.expectEqual(@as(f32, 60), object.y);
    try testing.expectEqual(@as(f32, 70), object.width);
    try testing.expectEqual(@as(f32, 80), object.height);

    try testing.expect(report.pageById(std.math.maxInt(core.NodeId)) == null);
    try testing.expect(report.objectById(std.math.maxInt(core.NodeId)) == null);
}

test "layout conflict report releases every partial allocation" {
    var state = try initDocumentState(testing.allocator);
    defer state.deinit();
    _ = try addFixture(&state);

    try testing.checkAllAllocationFailures(
        testing.allocator,
        initAndDeinitReport,
        .{&state},
    );
}
