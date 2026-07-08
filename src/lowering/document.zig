const std = @import("std");
const core = @import("core");
const eval_toplevel = @import("../eval/toplevel.zig");
const analysis_index = @import("../analysis/index.zig");
const schedule = @import("../analysis/schedule.zig");

pub fn evaluateDocumentWithSchedule(ir: *core.Ir, graph: *const schedule.ScheduleGraph) !void {
    try eval_toplevel.evalIrWithSchedule(ir.allocator, ir, graph);
    try ir.validatePageLocalLayout();
}

pub fn solveLayout(ir: *core.Ir) !void {
    var results = try solveLayoutResults(ir);
    defer results.deinit(ir.allocator);
}

pub fn solveLayoutResults(ir: *core.Ir) !core.LayoutResults {
    var results = try ir.finalizeWithLayoutResultsAndOptions(null, .{});
    errdefer results.deinit(ir.allocator);
    try analysis_index.refreshSolvedFrameHints(ir.allocator, ir);
    return results;
}

pub fn solveLayoutWithOptions(ir: *core.Ir, options: core.layout.graph.SolveOptions) !void {
    var results = try solveLayoutResultsWithOptions(ir, options);
    defer results.deinit(ir.allocator);
}

pub fn solveLayoutResultsWithOptions(ir: *core.Ir, options: core.layout.graph.SolveOptions) !core.LayoutResults {
    var results = try ir.finalizeWithLayoutResultsAndOptions(null, options);
    errdefer results.deinit(ir.allocator);
    try analysis_index.refreshSolvedFrameHints(ir.allocator, ir);
    return results;
}

pub fn solveLayoutWithTracePath(ir: *core.Ir, trace_path: []const u8) !void {
    var results = try solveLayoutResultsWithTracePath(ir, trace_path);
    defer results.deinit(ir.allocator);
}

pub fn solveLayoutResultsWithTracePath(ir: *core.Ir, trace_path: []const u8) !core.LayoutResults {
    var results = try ir.finalizeWithLayoutResultsAndOptions(trace_path, .{});
    errdefer results.deinit(ir.allocator);
    try analysis_index.refreshSolvedFrameHints(ir.allocator, ir);
    return results;
}

pub fn solveLayoutWithTracePathAndOptions(ir: *core.Ir, trace_path: []const u8, options: core.layout.graph.SolveOptions) !void {
    var results = try solveLayoutResultsWithTracePathAndOptions(ir, trace_path, options);
    defer results.deinit(ir.allocator);
}

pub fn solveLayoutResultsWithTracePathAndOptions(ir: *core.Ir, trace_path: []const u8, options: core.layout.graph.SolveOptions) !core.LayoutResults {
    var results = try ir.finalizeWithLayoutResultsAndOptions(trace_path, options);
    errdefer results.deinit(ir.allocator);
    try analysis_index.refreshSolvedFrameHints(ir.allocator, ir);
    return results;
}

pub fn scheduleTraceJsonFromGraph(allocator: std.mem.Allocator, ir: *const core.Ir, graph: *const schedule.ScheduleGraph) ![]u8 {
    return schedule.scheduleGraphJson(allocator, ir, graph);
}
