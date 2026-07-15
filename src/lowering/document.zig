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

pub fn solveDocument(ir: *core.Context, trace_path: ?[]const u8, options: core.layout.graph.SolveOptions) !core.layout.Document {
    var document = try ir.finalizeDocument(trace_path, options);
    errdefer document.deinit(ir.allocator);
    try analysis_index.refreshSolvedFrameHints(ir.allocator, ir);
    return document;
}

pub fn scheduleTraceJsonFromGraph(allocator: std.mem.Allocator, ir: *const core.Context, graph: *const execution.ExecutionGraph) ![]u8 {
    return execution.executionGraphJson(allocator, ir, graph);
}
