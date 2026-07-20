const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const eval_toplevel = @import("../eval/toplevel.zig");
const execution = @import("../analysis/execution.zig");

pub const EvaluateOptions = struct {
    cancellation: ?utils.Cancellation = null,

    fn checkCanceled(self: EvaluateOptions) !void {
        if (self.cancellation) |cancellation| try cancellation.check();
    }
};

pub fn evaluateDocument(
    state: *core.DocumentState,
    graph: *const execution.ExecutionGraph,
    options: EvaluateOptions,
) !void {
    try options.checkCanceled();
    try eval_toplevel.executeGraph(state.allocator, state, graph, .{
        .cancellation = options.cancellation,
    });
    try options.checkCanceled();
    try core.constraint_updates.resolve(state);
    try options.checkCanceled();
    try state.validatePageLocalLayout();
    try options.checkCanceled();
}

pub fn solveDocument(state: *core.DocumentState, trace_path: ?[]const u8, options: core.layout.graph.SolveOptions) !core.layout.Document {
    return try state.finalizeDocument(trace_path, options);
}

pub fn scheduleTraceJsonFromGraph(allocator: std.mem.Allocator, state: *const core.DocumentState, graph: *const execution.ExecutionGraph) ![]u8 {
    return execution.executionGraphJson(allocator, state, graph);
}
