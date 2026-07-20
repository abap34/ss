const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const lowering = @import("../lowering.zig");
const compiler = @import("compile.zig");
const render_resources = @import("render_resources");
const execution = @import("../analysis/execution.zig");

pub const Options = struct {
    trace_path: ?[]const u8 = null,
    progress: ?core.layout.graph.LayoutProgress = null,
    jobs: ?usize = null,
    cancellation: ?utils.Cancellation = null,
    resource_cache: ?*render_resources.SourceCache = null,

    fn checkCanceled(self: Options) !void {
        if (self.cancellation) |cancellation| try cancellation.check();
    }
};

pub fn evaluateAndSolvePreparedPages(
    io: std.Io,
    state: *core.DocumentState,
    graph: *const execution.ExecutionGraph,
    options: Options,
) !core.prepared.PreparedPages {
    try options.checkCanceled();
    try lowering.evaluateDocument(state, graph, .{ .cancellation = options.cancellation });
    try options.checkCanceled();
    var pages = try core.prepared.prepare(state.allocator, state);
    errdefer pages.deinit(state.allocator);
    try options.checkCanceled();
    var results = try solvePreparedPages(io, state, &pages, options);
    defer results.deinit(state.allocator);
    try options.checkCanceled();
    return pages;
}

pub fn preloadPreparedPageArtifacts(
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    progress: ?compiler.Progress,
    jobs: ?usize,
) !void {
    try compiler.preload(state.allocator, io, state, pages, .{
        .jobs = jobs,
    }, progress);
}

pub fn solvePreparedPages(
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    options: Options,
) !core.layout.Document {
    try options.checkCanceled();
    var measurement_scope = try compiler.LayoutMeasurementScope.init(
        state.allocator,
        io,
        state,
        pages,
        options.resource_cache,
    );
    defer measurement_scope.deinit();
    var results = try lowering.solveDocument(state, options.trace_path, .{
        .measurement_provider = measurement_scope.provider(),
        .progress = options.progress,
        .jobs = options.jobs,
        .cancellation = options.cancellation,
    });
    errdefer results.deinit(state.allocator);
    try options.checkCanceled();
    try core.prepared.attachAssetKeys(state.allocator, &results, pages);
    try options.checkCanceled();
    return results;
}
