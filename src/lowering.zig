pub const normalize = @import("lowering/normalize.zig");

pub const evaluateDocument = normalize.evaluateDocument;
pub const evaluateDocumentWithSchedule = normalize.evaluateDocumentWithSchedule;
pub const solveLayout = normalize.solveLayout;
pub const solveLayoutWithTracePath = normalize.solveLayoutWithTracePath;
pub const lowerToIr = normalize.lowerToIr;
pub const scheduleTraceJson = normalize.scheduleTraceJson;
pub const scheduleTraceJsonFromGraph = normalize.scheduleTraceJsonFromGraph;
