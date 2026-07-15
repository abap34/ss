const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const render = @import("render");
const render_compile = @import("render_compile");

const testing = std.testing;

const FakeCompiler = struct {
    prepare_count: usize = 0,
    page_count: usize = 0,
    fail_at_index: ?usize = null,

    pub fn prepare(
        self: *FakeCompiler,
        _: std.mem.Allocator,
        _: *core.DocumentState,
        _: *const core.prepared.PreparedPages,
    ) !void {
        self.prepare_count += 1;
    }

    pub fn compilePage(
        self: *FakeCompiler,
        allocator: std.mem.Allocator,
        _: *core.DocumentState,
        prepared_page: *const core.prepared.PreparedPage,
    ) !render.Page {
        if (self.fail_at_index == prepared_page.index) return error.IntentionalCompileFailure;
        self.page_count += 1;
        var page = render.Page{
            .page_id = prepared_page.page_id,
            .index = prepared_page.index,
            .width = 1280,
            .height = 720,
        };
        errdefer page.deinit(allocator);
        try page.appendText(
            allocator,
            prepared_page.page_id,
            20,
            40,
            200,
            "owned",
            .{ .family = "sans-serif", .weight = 400, .style = .normal, .stretch = .normal },
            16,
            .{ .r = 0, .g = 0, .b = 0 },
            false,
            false,
        );
        return page;
    }
};

fn initEmptyDocumentState() !core.DocumentState {
    const allocator = testing.allocator;
    const asset_base_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, "render-compile-test.ss");
    errdefer allocator.free(project_path);
    const project_source = try allocator.dupe(u8, "");
    errdefer allocator.free(project_source);
    return try core.DocumentState.init(allocator, asset_base_dir, project_path, project_source, ast.Module.init());
}

fn preparedPage(page_id: core.NodeId, index: usize) core.prepared.PreparedPage {
    return .{
        .page_id = page_id,
        .index = index,
        .background = null,
        .object_ids = &.{},
        .constraints = &.{},
        .objects = &.{},
    };
}

test "render compiler prepares once and preserves page order" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var source_pages = [_]core.prepared.PreparedPage{
        preparedPage(10, 0),
        preparedPage(20, 1),
    };
    const prepared_pages = core.prepared.PreparedPages{ .pages = &source_pages };
    var compiler = FakeCompiler{};

    var result = try render_compile.document(testing.allocator, &state, &prepared_pages, &compiler);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), compiler.prepare_count);
    try testing.expectEqual(@as(usize, 2), compiler.page_count);
    try testing.expectEqual(@as(usize, 2), result.pages.len);
    try testing.expectEqual(@as(core.NodeId, 10), result.pages[0].page_id);
    try testing.expectEqual(@as(core.NodeId, 20), result.pages[1].page_id);
}

test "render compiler releases completed pages after a later failure" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var source_pages = [_]core.prepared.PreparedPage{
        preparedPage(10, 0),
        preparedPage(20, 1),
    };
    const prepared_pages = core.prepared.PreparedPages{ .pages = &source_pages };
    var compiler = FakeCompiler{ .fail_at_index = 1 };

    try testing.expectError(
        error.IntentionalCompileFailure,
        render_compile.document(testing.allocator, &state, &prepared_pages, &compiler),
    );
    try testing.expectEqual(@as(usize, 1), compiler.page_count);
}
