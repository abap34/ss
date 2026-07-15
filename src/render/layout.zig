const std = @import("std");
const core = @import("core");
const lowering = @import("../lowering.zig");
const pdf = @import("pdf.zig");
const execution = @import("../analysis/execution.zig");

pub fn evaluateAndSolvePreparedPages(io: std.Io, state: *core.DocumentState, graph: *const execution.ExecutionGraph) !core.prepared.PreparedPages {
    try lowering.evaluateDocument(state, graph);
    var pages = try core.prepared.prepare(state.allocator, state);
    errdefer pages.deinit(state.allocator);
    var results = try solvePreparedPages(io, state, &pages, null, null);
    defer results.deinit(state.allocator);
    return pages;
}

pub fn preloadPreparedPageArtifacts(
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    progress: ?pdf.Progress,
    jobs: ?usize,
) !void {
    try pdf.preloadPreparedPageArtifacts(state.allocator, io, state, pages, .{
        .jobs = jobs,
    }, progress);
}

pub fn solvePreparedPages(
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    progress: ?core.layout.graph.LayoutProgress,
    jobs: ?usize,
) !core.layout.Document {
    var measurement_scope = try pdf.LayoutMeasurementScope.init(state.allocator, io, state, pages);
    defer measurement_scope.deinit();
    var results = try lowering.solveDocument(state, null, .{
        .measurement_provider = measurement_scope.provider(),
        .progress = progress,
        .jobs = jobs,
    });
    errdefer results.deinit(state.allocator);
    try core.prepared.attachAssetKeys(state.allocator, &results, pages);
    return results;
}

pub fn solvePreparedPagesWithTrace(
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    trace_path: []const u8,
    progress: ?core.layout.graph.LayoutProgress,
    jobs: ?usize,
) !core.layout.Document {
    var measurement_scope = try pdf.LayoutMeasurementScope.init(state.allocator, io, state, pages);
    defer measurement_scope.deinit();
    var results = try lowering.solveDocument(state, trace_path, .{
        .measurement_provider = measurement_scope.provider(),
        .progress = progress,
        .jobs = jobs,
    });
    errdefer results.deinit(state.allocator);
    try core.prepared.attachAssetKeys(state.allocator, &results, pages);
    return results;
}
