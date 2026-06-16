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

pub fn lowerToIr(ir: *core.Ir) !void {
    try evaluateDocument(ir);
    try solveLayout(ir);
}
