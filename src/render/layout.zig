const std = @import("std");
const core = @import("core");
const lowering = @import("../lowering.zig");
const pdf = @import("pdf.zig");
const schedule = @import("../analysis/schedule.zig");

pub fn evaluateAndSolveWithPdfMeasurements(io: std.Io, ir: *core.Ir, graph: *const schedule.ScheduleGraph) !void {
    try lowering.evaluateDocumentWithSchedule(ir, graph);
    var pages = try core.page_unit.prepare(ir.allocator, ir);
    defer pages.deinit(ir.allocator);
    var results = try solveWithPdfMeasurementsAndPreparedPages(io, ir, &pages);
    defer results.deinit(ir.allocator);
}

pub fn solveWithPdfMeasurements(io: std.Io, ir: *core.Ir) !core.LayoutResults {
    var measurement_scope = try pdf.LayoutMeasurementScope.init(ir.allocator, io, ir);
    defer measurement_scope.deinit();
    return try lowering.solveLayoutResultsWithOptions(ir, .{ .measurement_provider = measurement_scope.provider() });
}

pub fn solveWithPdfMeasurementsAndPreparedPages(io: std.Io, ir: *core.Ir, pages: *const core.page_unit.PreparedPages) !core.LayoutResults {
    return try solveWithPdfMeasurementsAndPreparedPagesProgress(io, ir, pages, null, null);
}

pub fn preloadPreparedPageArtifacts(
    io: std.Io,
    ir: *core.Ir,
    pages: *const core.page_unit.PreparedPages,
    progress: ?pdf.RenderProgress,
    jobs: ?usize,
) !void {
    try pdf.preloadPreparedPageArtifactsWithOptions(ir.allocator, io, ir, pages, .{
        .jobs = jobs,
    }, progress);
}

pub fn solveWithPdfMeasurementsAndPreparedPagesProgress(
    io: std.Io,
    ir: *core.Ir,
    pages: *const core.page_unit.PreparedPages,
    progress: ?core.layout.graph.LayoutProgress,
    jobs: ?usize,
) !core.LayoutResults {
    var measurement_scope = try pdf.LayoutMeasurementScope.initWithPreparedPages(ir.allocator, io, ir, pages);
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

pub fn solveWithPdfMeasurementsAndTracePath(io: std.Io, ir: *core.Ir, trace_path: []const u8) !core.LayoutResults {
    var measurement_scope = try pdf.LayoutMeasurementScope.init(ir.allocator, io, ir);
    defer measurement_scope.deinit();
    return try lowering.solveLayoutResultsWithTracePathAndOptions(ir, trace_path, .{ .measurement_provider = measurement_scope.provider() });
}

pub fn solveWithPdfMeasurementsPreparedAndTracePath(io: std.Io, ir: *core.Ir, pages: *const core.page_unit.PreparedPages, trace_path: []const u8) !core.LayoutResults {
    return try solveWithPdfMeasurementsPreparedAndTracePathProgress(io, ir, pages, trace_path, null, null);
}

pub fn solveWithPdfMeasurementsPreparedAndTracePathProgress(
    io: std.Io,
    ir: *core.Ir,
    pages: *const core.page_unit.PreparedPages,
    trace_path: []const u8,
    progress: ?core.layout.graph.LayoutProgress,
    jobs: ?usize,
) !core.LayoutResults {
    var measurement_scope = try pdf.LayoutMeasurementScope.initWithPreparedPages(ir.allocator, io, ir, pages);
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
