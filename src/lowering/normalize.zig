const std = @import("std");
const core = @import("core");
const eval_toplevel = @import("../eval/toplevel.zig");
const editor = @import("../analysis/editor.zig");

pub fn evaluateDocument(ir: *core.Ir) !void {
    try eval_toplevel.evalIr(ir.allocator, ir);
    try ir.addUnplacedObjectWarnings();
}

pub fn solveLayout(ir: *core.Ir) !void {
    try ir.finalize();
    try editor.refreshSolvedFrameHints(ir.allocator, ir);
}

pub fn solveLayoutWithTracePath(ir: *core.Ir, trace_path: []const u8) !void {
    try ir.finalizeWithLayoutTracePath(trace_path);
    try editor.refreshSolvedFrameHints(ir.allocator, ir);
}

pub fn lowerToIr(ir: *core.Ir) !void {
    try evaluateDocument(ir);
    try solveLayout(ir);
}

pub fn scheduleTraceJson(allocator: std.mem.Allocator, ir: *core.Ir) ![]u8 {
    return eval_toplevel.scheduleTraceJson(allocator, ir);
}
