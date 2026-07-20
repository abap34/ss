const std = @import("std");
const compiler = @import("compiler");

const testing = std.testing;

const CancellationCounter = struct {
    checks: usize = 0,
    cancel_after: usize,
};

fn cancelAfterCheck(context: *const anyopaque) bool {
    const counter: *CancellationCounter = @ptrCast(@alignCast(@constCast(context)));
    counter.checks += 1;
    return counter.checks >= counter.cancel_after;
}

test "document evaluation cooperatively cancels without adding a diagnostic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = "evaluation-cancellation.ss";
    var source = try allocator.dupe(u8,
        \\page cancellation
        \\let first = 1
        \\let second = first
        \\end
        \\
    );
    var syntax = try compiler.syntax.parseWithSourceName(allocator, source, path);
    var index = try compiler.analysis.loadModuleIndex(allocator, testing.io, ".", syntax, .{});
    defer index.deinit();

    var state = try compiler.analysis.buildDocumentStateWithOptions(
        allocator,
        path,
        ".",
        &source,
        &syntax,
        &index,
        .{ .allow_diagnostics = true },
    );
    defer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(allocator, &state, .evaluation)).?;
    defer graph.deinit();

    const diagnostic_count = state.diagnostics.items.len;
    var counter = CancellationCounter{ .cancel_after = 5 };
    try testing.expectError(error.Canceled, compiler.lowering.evaluateDocument(&state, &graph, .{
        .cancellation = .{
            .context = &counter,
            .is_canceled = cancelAfterCheck,
        },
    }));
    try testing.expect(counter.checks >= counter.cancel_after);
    try testing.expectEqual(diagnostic_count, state.diagnostics.items.len);
}
