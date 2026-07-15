const std = @import("std");
const core = @import("core");
const render = @import("render");
const utils = @import("utils");

pub const Options = struct {
    cache_dir: []const u8 = ".ss-cache/render",
    highlight_languages: []const utils.highlight.Language = &.{},
};

pub fn document(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    prepared_pages: *const core.prepared.PreparedPages,
    compiler: anytype,
) !render.Ir {
    try compiler.prepare(allocator, state, prepared_pages);

    var pages = std.ArrayList(render.Page).empty;
    errdefer {
        for (pages.items) |*page| page.deinit(allocator);
        pages.deinit(allocator);
    }
    for (prepared_pages.pages) |*prepared_page| {
        try pages.append(allocator, try compiler.compilePage(
            allocator,
            state,
            prepared_page,
        ));
    }
    return .{ .pages = try pages.toOwnedSlice(allocator) };
}
