const std = @import("std");
const core = @import("core");
const eval_toplevel = @import("../eval/toplevel.zig");
const analysis_index = @import("../analysis/index.zig");
const execution = @import("../analysis/execution.zig");

pub fn evaluateDocument(ir: *core.Context, graph: *const execution.ExecutionGraph) !void {
    try eval_toplevel.executeGraph(ir.allocator, ir, graph);
    try core.constraint_updates.resolve(ir);
    try ir.validatePageLocalLayout();
}

pub fn solveLayout(ir: *core.Context) !void {
    var results = try solveLayoutResults(ir);
    defer results.deinit(ir.allocator);
}

pub fn solveLayoutResults(ir: *core.Context) !core.LayoutResults {
    var results = try ir.finalizeWithLayoutResultsAndOptions(null, .{});
    errdefer results.deinit(ir.allocator);
    try analysis_index.refreshSolvedFrameHints(ir.allocator, ir);
    return results;
}

pub fn solveLayoutWithOptions(ir: *core.Context, options: core.layout.graph.SolveOptions) !void {
    var results = try solveLayoutResultsWithOptions(ir, options);
    defer results.deinit(ir.allocator);
}

pub fn solveLayoutResultsWithOptions(ir: *core.Context, options: core.layout.graph.SolveOptions) !core.LayoutResults {
    var results = try ir.finalizeWithLayoutResultsAndOptions(null, options);
    errdefer results.deinit(ir.allocator);
    try analysis_index.refreshSolvedFrameHints(ir.allocator, ir);
    return results;
}

pub fn solveLayoutWithTracePath(ir: *core.Context, trace_path: []const u8) !void {
    var results = try solveLayoutResultsWithTracePath(ir, trace_path);
    defer results.deinit(ir.allocator);
}

pub fn solveLayoutResultsWithTracePath(ir: *core.Context, trace_path: []const u8) !core.LayoutResults {
    var results = try ir.finalizeWithLayoutResultsAndOptions(trace_path, .{});
    errdefer results.deinit(ir.allocator);
    try analysis_index.refreshSolvedFrameHints(ir.allocator, ir);
    return results;
}

pub fn solveLayoutWithTracePathAndOptions(ir: *core.Context, trace_path: []const u8, options: core.layout.graph.SolveOptions) !void {
    var results = try solveLayoutResultsWithTracePathAndOptions(ir, trace_path, options);
    defer results.deinit(ir.allocator);
}

pub fn solveLayoutResultsWithTracePathAndOptions(ir: *core.Context, trace_path: []const u8, options: core.layout.graph.SolveOptions) !core.LayoutResults {
    var results = try ir.finalizeWithLayoutResultsAndOptions(trace_path, options);
    errdefer results.deinit(ir.allocator);
    try analysis_index.refreshSolvedFrameHints(ir.allocator, ir);
    return results;
}

pub fn scheduleTraceJsonFromGraph(allocator: std.mem.Allocator, ir: *const core.Context, graph: *const execution.ExecutionGraph) ![]u8 {
    return execution.executionGraphJson(allocator, ir, graph);
}
