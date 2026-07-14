const std = @import("std");
const core = @import("core");
const lowering = @import("../lowering.zig");
const pdf = @import("pdf.zig");
const schedule = @import("../analysis/schedule.zig");

pub fn evaluateAndSolveWithPdfMeasurements(io: std.Io, ir: *core.Ir, graph: *const schedule.ScheduleGraph) !void {
    try lowering.evaluateDocumentWithSchedule(ir, graph);
    var pages = try core.page_unit.prepare(ir.allocator, ir);
    defer pages.deinit(ir.allocator);
    var results = try solvePreparedPages(io, ir, &pages, null, null);
    defer results.deinit(ir.allocator);
}

pub fn preloadPreparedPageArtifacts(
    io: std.Io,
    ir: *core.Ir,
    pages: *const core.page_unit.PreparedPages,
    progress: ?pdf.RenderProgress,
    jobs: ?usize,
) !void {
    try pdf.preloadPreparedPageArtifacts(ir.allocator, io, ir, pages, .{
        .jobs = jobs,
    }, progress);
}

pub fn solvePreparedPages(
    io: std.Io,
    ir: *core.Ir,
    pages: *const core.page_unit.PreparedPages,
    progress: ?core.layout.graph.LayoutProgress,
    jobs: ?usize,
) !core.LayoutResults {
    var measurement_scope = try pdf.LayoutMeasurementScope.init(ir.allocator, io, ir, pages);
    defer measurement_scope.deinit();
    var results = try lowering.solveLayoutResultsWithOptions(ir, .{
        .measurement_provider = measurement_scope.provider(),
        .progress = progress,
        .jobs = jobs,
    });
    errdefer results.deinit(ir.allocator);
    try core.page_unit.attachAssetKeysToLayoutResults(ir.allocator, &results, pages);
    return results;
}

pub fn solvePreparedPagesWithTrace(
    io: std.Io,
    ir: *core.Ir,
    pages: *const core.page_unit.PreparedPages,
    trace_path: []const u8,
    progress: ?core.layout.graph.LayoutProgress,
    jobs: ?usize,
) !core.LayoutResults {
    var measurement_scope = try pdf.LayoutMeasurementScope.init(ir.allocator, io, ir, pages);
    defer measurement_scope.deinit();
    var results = try lowering.solveLayoutResultsWithTracePathAndOptions(ir, trace_path, .{
        .measurement_provider = measurement_scope.provider(),
        .progress = progress,
        .jobs = jobs,
    });
    errdefer results.deinit(ir.allocator);
    try core.page_unit.attachAssetKeysToLayoutResults(ir.allocator, &results, pages);
    return results;
}
