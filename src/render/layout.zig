const std = @import("std");
const core = @import("core");
const lowering = @import("../lowering.zig");
const pdf = @import("pdf.zig");
const schedule = @import("../analysis/schedule.zig");

pub fn evaluateAndSolveWithPdfMeasurements(io: std.Io, ir: *core.Ir, graph: *const schedule.ScheduleGraph) !void {
    try lowering.evaluateDocumentWithSchedule(ir, graph);
    try solveWithPdfMeasurements(io, ir);
}

pub fn solveWithPdfMeasurements(io: std.Io, ir: *core.Ir) !void {
    var measurement_scope = try pdf.LayoutMeasurementScope.init(ir.allocator, io, ir);
    defer measurement_scope.deinit();
    try lowering.solveLayoutWithOptions(ir, .{ .measurement_provider = measurement_scope.provider() });
}

pub fn solveWithPdfMeasurementsAndTracePath(io: std.Io, ir: *core.Ir, trace_path: []const u8) !void {
    var measurement_scope = try pdf.LayoutMeasurementScope.init(ir.allocator, io, ir);
    defer measurement_scope.deinit();
    try lowering.solveLayoutWithTracePathAndOptions(ir, trace_path, .{ .measurement_provider = measurement_scope.provider() });
}
