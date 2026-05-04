pub const doc = @import("stage0/doc.zig");
pub const eval = @import("stage0/eval.zig");
pub const builtin = @import("stage0/builtin.zig");

pub const Document = doc.Document;
pub const Term = doc.Term;
pub const elaborateProgram = eval.elaborateProgram;
