const std = @import("std");
const core = @import("core");
const lowering = @import("../lowering.zig");
const pdf = @import("pdf.zig");
const execution = @import("../analysis/execution.zig");

pub fn evaluateAndSolvePreparedPages(io: std.Io, ir: *core.Context, graph: *const execution.ExecutionGraph) !core.prepared.PreparedPages {
    try lowering.evaluateDocument(ir, graph);
    var pages = try core.prepared.prepare(ir.allocator, ir);
    errdefer pages.deinit(ir.allocator);
    var results = try solvePreparedPages(io, ir, &pages, null, null);
    defer results.deinit(ir.allocator);
    return pages;
}

pub fn preloadPreparedPageArtifacts(
    io: std.Io,
    ir: *core.Context,
    pages: *const core.prepared.PreparedPages,
    progress: ?pdf.RenderProgress,
    jobs: ?usize,
) !void {
    try pdf.preloadPreparedPageArtifacts(ir.allocator, io, ir, pages, .{
        .jobs = jobs,
    }, progress);
}

pub fn solvePreparedPages(
    io: std.Io,
    ir: *core.Context,
    pages: *const core.prepared.PreparedPages,
    progress: ?core.layout.graph.LayoutProgress,
    jobs: ?usize,
) !core.layout.Document {
    var measurement_scope = try pdf.LayoutMeasurementScope.init(ir.allocator, io, ir, pages);
    defer measurement_scope.deinit();
    var results = try lowering.solveDocument(ir, null, .{
        .measurement_provider = measurement_scope.provider(),
        .progress = progress,
        .jobs = jobs,
    });
    errdefer results.deinit(ir.allocator);
    try core.prepared.attachAssetKeys(ir.allocator, &results, pages);
    return results;
}

pub fn solvePreparedPagesWithTrace(
    io: std.Io,
    ir: *core.Context,
    pages: *const core.prepared.PreparedPages,
    trace_path: []const u8,
    progress: ?core.layout.graph.LayoutProgress,
    jobs: ?usize,
) !core.layout.Document {
    var measurement_scope = try pdf.LayoutMeasurementScope.init(ir.allocator, io, ir, pages);
    defer measurement_scope.deinit();
    var results = try lowering.solveDocument(ir, trace_path, .{
        .measurement_provider = measurement_scope.provider(),
        .progress = progress,
        .jobs = jobs,
    });
    errdefer results.deinit(ir.allocator);
    try core.prepared.attachAssetKeys(ir.allocator, &results, pages);
    return results;
}
