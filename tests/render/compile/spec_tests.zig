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

    fn backend(self: *FakeCompiler) render_compile.Backend {
        return .{
            .context = self,
            .prepareFn = prepare,
            .compilePageFn = compilePage,
        };
    }

    fn prepare(
        context: *anyopaque,
        _: std.mem.Allocator,
        _: *core.Context,
        _: *const core.prepared.PreparedPages,
    ) !void {
        const self: *FakeCompiler = @ptrCast(@alignCast(context));
        self.prepare_count += 1;
    }

    fn compilePage(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        _: *core.Context,
        prepared_page: *const core.prepared.PreparedPage,
    ) !render.Page {
        const self: *FakeCompiler = @ptrCast(@alignCast(context));
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

fn initEmptyContext() !core.Context {
    const allocator = testing.allocator;
    const asset_base_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, "render-compile-test.ss");
    errdefer allocator.free(project_path);
    const project_source = try allocator.dupe(u8, "");
    errdefer allocator.free(project_source);
    return try core.Context.init(allocator, asset_base_dir, project_path, project_source, ast.Module.init());
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
    var context = try initEmptyContext();
    defer context.deinit();
    var source_pages = [_]core.prepared.PreparedPage{
        preparedPage(10, 0),
        preparedPage(20, 1),
    };
    const prepared_pages = core.prepared.PreparedPages{ .pages = &source_pages };
    var compiler = FakeCompiler{};

    var result = try render_compile.document(testing.allocator, &context, &prepared_pages, compiler.backend());
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), compiler.prepare_count);
    try testing.expectEqual(@as(usize, 2), compiler.page_count);
    try testing.expectEqual(@as(usize, 2), result.pages.len);
    try testing.expectEqual(@as(core.NodeId, 10), result.pages[0].page_id);
    try testing.expectEqual(@as(core.NodeId, 20), result.pages[1].page_id);
}

test "render compiler releases completed pages after a later failure" {
    var context = try initEmptyContext();
    defer context.deinit();
    var source_pages = [_]core.prepared.PreparedPage{
        preparedPage(10, 0),
        preparedPage(20, 1),
    };
    const prepared_pages = core.prepared.PreparedPages{ .pages = &source_pages };
    var compiler = FakeCompiler{ .fail_at_index = 1 };

    try testing.expectError(
        error.IntentionalCompileFailure,
        render_compile.document(testing.allocator, &context, &prepared_pages, compiler.backend()),
    );
    try testing.expectEqual(@as(usize, 1), compiler.page_count);
}
