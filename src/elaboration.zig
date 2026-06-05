pub const document = @import("elaboration/document.zig");
pub const eval = @import("elaboration/eval.zig");
pub const builtin = @import("elaboration/builtin.zig");
pub const value_contracts = @import("elaboration/value_contracts.zig");

pub const Document = document.Document;
pub const Term = document.Term;
pub const elaborateProgram = eval.elaborateProgram;
pub const elaborateIr = eval.elaborateIr;
