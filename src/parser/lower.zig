const std = @import("std");
const core = @import("core");
const exec = @import("exec.zig");
const typecheck = @import("typecheck.zig");

pub fn lowerToIr(ir: *core.Ir) !void {
    try exec.executeProgramIntoIr(ir);
    try ir.finalize();
    try typecheck.refreshSolvedFrameHints(ir.allocator, ir);
}
