const std = @import("std");
const core = @import("core");
const eval_toplevel = @import("../eval/toplevel.zig");
const execution = @import("../analysis/execution.zig");

pub fn evaluateDocument(state: *core.DocumentState, graph: *const execution.ExecutionGraph) !void {
    try eval_toplevel.executeGraph(state.allocator, state, graph);
    try core.constraint_updates.resolve(state);
    try state.validatePageLocalLayout();
}

pub fn solveDocument(state: *core.DocumentState, trace_path: ?[]const u8, options: core.layout.graph.SolveOptions) !core.layout.Document {
    return try state.finalizeDocument(trace_path, options);
}

pub fn scheduleTraceJsonFromGraph(allocator: std.mem.Allocator, state: *const core.DocumentState, graph: *const execution.ExecutionGraph) ![]u8 {
    return execution.executionGraphJson(allocator, state, graph);
}
