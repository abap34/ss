const std = @import("std");
const core = @import("core");
const render = @import("render");
const utils = @import("utils");

pub const Options = struct {
    cache_dir: []const u8 = ".ss-cache/render",
    highlight_languages: []const utils.highlight.Language = &.{},
};

pub const Backend = struct {
    context: *anyopaque,
    prepareFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        compiler_context: *core.Context,
        pages: *const core.prepared.PreparedPages,
    ) anyerror!void,
    compilePageFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        compiler_context: *core.Context,
        page: *const core.prepared.PreparedPage,
    ) anyerror!render.Page,

    fn prepare(
        self: Backend,
        allocator: std.mem.Allocator,
        compiler_context: *core.Context,
        pages: *const core.prepared.PreparedPages,
    ) !void {
        try self.prepareFn(self.context, allocator, compiler_context, pages);
    }

    fn compilePage(
        self: Backend,
        allocator: std.mem.Allocator,
        compiler_context: *core.Context,
        page: *const core.prepared.PreparedPage,
    ) !render.Page {
        return try self.compilePageFn(self.context, allocator, compiler_context, page);
    }
};

pub fn document(
    allocator: std.mem.Allocator,
    compiler_context: *core.Context,
    prepared_pages: *const core.prepared.PreparedPages,
    backend: Backend,
) !render.Ir {
    try backend.prepare(allocator, compiler_context, prepared_pages);

    var pages = std.ArrayList(render.Page).empty;
    errdefer {
        for (pages.items) |*page| page.deinit(allocator);
        pages.deinit(allocator);
    }
    for (prepared_pages.pages) |*prepared_page| {
        try pages.append(allocator, try backend.compilePage(
            allocator,
            compiler_context,
            prepared_page,
        ));
    }
    return .{ .pages = try pages.toOwnedSlice(allocator) };
}
