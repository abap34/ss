const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const render_compile = @import("render_compile");
const allocation_testing = @import("allocation_testing");
const testing = std.testing;

fn preloadAssets(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *core.DocumentState,
    first: []core.prepared.AssetDependency,
    second: []core.prepared.AssetDependency,
) !void {
    var objects: [2]core.prepared.PreparedObject = @splat(.{
        .node_id = 1,
        .content = "",
        .content_provenance = &.{},
        .link_id = null,
        .render = std.mem.zeroes(core.render_policy.ResolvedRender),
        .parse_mode = .block,
        .asset_deps = first,
        .latex_preamble = "\\usepackage{amsmath}",
        .latex_engine = .pdflatex,
        .origin = null,
        .payload_kind = null,
        .attached = true,
    });
    objects[1].node_id = 2;
    objects[1].asset_deps = second;
    var prepared = [_]core.prepared.PreparedPage{.{ .page_id = 1, .index = 0, .background = null, .objects = &objects }};
    const pages = core.prepared.PreparedPages{ .pages = &prepared };
    try render_compile.preload(allocator, io, state, &pages, .{
        .cache_dir = ".ss-cache/preload-ownership",
        .jobs = 1,
    }, null);
}

fn documentState() !core.DocumentState {
    const base = try testing.allocator.dupe(u8, ".");
    errdefer testing.allocator.free(base);
    const path = try testing.allocator.dupe(u8, "preload-ownership.ss");
    errdefer testing.allocator.free(path);
    const source = try testing.allocator.dupe(u8, "");
    errdefer testing.allocator.free(source);
    return core.DocumentState.init(testing.allocator, base, path, source, ast.Module.init());
}

fn preloadIcons(allocator: std.mem.Allocator, state: *core.DocumentState) !void {
    var first = [_]core.prepared.AssetDependency{.{ .kind = .icon, .source = "fa-solid:star" }};
    var second = [_]core.prepared.AssetDependency{
        .{ .kind = .icon, .source = "fa-solid:heart" },
        .{ .kind = .icon, .source = "fa-solid:circle" },
        .{ .kind = .icon, .source = "fa-solid:square" },
        .{ .kind = .icon, .source = "fa-solid:plus" },
        .{ .kind = .icon, .source = "fa-solid:minus" },
        .{ .kind = .icon, .source = "fa-solid:user" },
        .{ .kind = .icon, .source = "fa-solid:check" },
        .{ .kind = .icon, .source = "fa-solid:xmark" },
        // A duplicate can still grow this object's dependency list.
        .{ .kind = .icon, .source = "fa-solid:star" },
        .{ .kind = .icon, .source = "fa-solid:star" },
    };
    try preloadAssets(allocator, testing.io, state, &first, &second);
}

test "preload registration has one owner at every allocation failure" {
    var state = try documentState();
    defer state.deinit();
    // Warm assets before enumerating failures so every attempt uses the same path.
    try preloadIcons(testing.allocator, &state);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, preloadIcons, .{&state});
}

const CanceledSpawn = struct {
    var calls: usize = 0;

    fn spawn(_: ?*anyopaque, _: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        calls += 1;
        return error.Canceled;
    }
};

fn preloadCanceledLatex(allocator: std.mem.Allocator, state: *core.DocumentState, kind: core.prepared.AssetDependency.Kind) !void {
    var vtable = testing.io.vtable.*;
    // Exercise collection and cleanup without executing a TeX subprocess.
    vtable.processSpawn = CanceledSpawn.spawn;
    const io = std.Io{ .userdata = testing.io.userdata, .vtable = &vtable };
    var dependencies: [2]core.prepared.AssetDependency = @splat(.{ .kind = kind, .source = "x + y" });
    CanceledSpawn.calls = 0;
    preloadAssets(allocator, io, state, &dependencies, &dependencies) catch |err| switch (err) {
        error.Canceled => {
            try testing.expectEqual(@as(usize, 1), CanceledSpawn.calls);
            return;
        },
        else => return err,
    };
    return error.ExpectedCanceledSpawn;
}

test "LaTeX preloads release cloned text on cancellation and every allocation failure" {
    var state = try documentState();
    defer state.deinit();
    for ([_]core.prepared.AssetDependency.Kind{ .inline_math, .display_math, .latex_body }) |kind| {
        try allocation_testing.checkAllAllocationFailures(testing.allocator, preloadCanceledLatex, .{ &state, kind });
    }
}
