pub const value = @import("eval/value.zig");
pub const functions = @import("eval/functions.zig");
pub const toplevel = @import("eval/toplevel.zig");
pub const builtin = @import("eval/builtin.zig");
pub const value_contracts = @import("eval/value_contracts.zig");

pub const evalIr = toplevel.evalIr;
