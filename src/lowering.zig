pub const normalize = @import("lowering/normalize.zig");

pub const evaluateDocument = normalize.evaluateDocument;
pub const solveLayout = normalize.solveLayout;
pub const lowerToIr = normalize.lowerToIr;
