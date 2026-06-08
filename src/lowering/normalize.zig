const core = @import("core");
const eval_toplevel = @import("../eval/toplevel.zig");
const editor = @import("../analysis/editor.zig");

pub fn lowerToIr(ir: *core.Ir) !void {
    try eval_toplevel.evalIr(ir.allocator, ir);
    try ir.addUnplacedObjectWarnings();
    try ir.finalize();
    try editor.refreshSolvedFrameHints(ir.allocator, ir);
}
