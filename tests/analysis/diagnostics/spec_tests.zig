const std = @import("std");
const analysis = @import("analysis");

const testing = std.testing;

fn addAndDeinitDiagnostic(allocator: std.mem.Allocator) !void {
    var bag = analysis.diagnostics.DiagnosticBag.init(allocator);
    defer bag.deinit();
    try bag.add(
        "slide.ss",
        "page demo\nend\n",
        .@"error",
        "ExampleDiagnostic",
        "example diagnostic",
        .{ .start = 0, .end = 4 },
        null,
    );
}

test "analysis diagnostic ownership survives every allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        addAndDeinitDiagnostic,
        .{},
    );
}
