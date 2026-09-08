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

const PreparedEvaluation = struct {
    state: compiler.core.DocumentState,
    graph: compiler.analysis.ExecutionGraph,

    fn deinit(self: *PreparedEvaluation) void {
        self.graph.deinit();
        self.state.deinit();
    }
};

fn prepare(allocator: std.mem.Allocator, text: []const u8) !PreparedEvaluation {
    const path = "evaluation-cancellation.ss";
    var source = try allocator.dupe(u8, text);
    defer allocator.free(source);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, source, path);
    defer syntax.deinit(allocator);
    var index = try compiler.analysis.loadModuleIndex(allocator, testing.io, ".", syntax, .{});
    defer index.deinit();
    var state = try compiler.analysis.buildDocumentStateWithOptions(allocator, path, ".", &source, &syntax, &index, .{});
    errdefer state.deinit();
    const graph = (try compiler.analysis.analyzeDocumentStateWithMode(allocator, &state, .evaluation)).?;
    return .{ .state = state, .graph = graph };
}

test "document evaluation cooperatively cancels without adding a diagnostic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var evaluation = try prepare(arena.allocator(),
        \\page cancellation
        \\let first = 1
        \\let second = first
        \\end
    );
    defer evaluation.deinit();
    const diagnostic_count = evaluation.state.diagnostics.items.len;
    var counter = CancellationCounter{ .cancel_after = 5 };
    try testing.expectError(error.Canceled, compiler.lowering.evaluateDocument(&evaluation.state, &evaluation.graph, .{
        .io = testing.io,
        .cancellation = .{
            .context = &counter,
            .is_canceled = cancelAfterCheck,
        },
    }));
    try testing.expect(counter.checks >= counter.cancel_after);
    try testing.expectEqual(diagnostic_count, evaluation.state.diagnostics.items.len);
}

fn canceledRead(_: ?*anyopaque, _: std.Io.File, _: []const []u8, _: u64) std.Io.File.ReadPositionalError!usize {
    return error.Canceled;
}

test "document evaluation propagates read cancellation without a readlines diagnostic" {
    const root = ".ss-cache/test-evaluation-file-cancellation";
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, root);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = root ++ "/input.txt", .data = "input" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var evaluation = try prepare(arena.allocator(),
        \\page cancellation
        \\let contents = readlines(".ss-cache/test-evaluation-file-cancellation/input.txt")
        \\end
    );
    defer evaluation.deinit();
    const diagnostic_count = evaluation.state.diagnostics.items.len;
    var vtable = testing.io.vtable.*;
    vtable.fileReadPositional = canceledRead;
    const io = std.Io{ .userdata = testing.io.userdata, .vtable = &vtable };
    try testing.expectError(error.Canceled, compiler.lowering.evaluateDocument(&evaluation.state, &evaluation.graph, .{ .io = io }));
    try testing.expect(evaluation.state.has_external_evaluation_inputs);
    try testing.expectEqual(diagnostic_count, evaluation.state.diagnostics.items.len);
}

test "readlines accepts exactly one MiB and diagnoses larger input" {
    const root = ".ss-cache/test-evaluation-file-limit";
    const maximum = 1024 * 1024;
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, root);
    const bytes = try testing.allocator.alloc(u8, maximum + 1);
    defer testing.allocator.free(bytes);
    @memset(bytes, 'x');
    for ([_]usize{ maximum, maximum + 1 }) |length| {
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = root ++ "/input.txt", .data = bytes[0..length] });
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var evaluation = try prepare(arena.allocator(),
            \\page limits
            \\let contents = readlines(".ss-cache/test-evaluation-file-limit/input.txt")
            \\end
        );
        defer evaluation.deinit();
        const diagnostic_count = evaluation.state.diagnostics.items.len;
        try compiler.lowering.evaluateDocument(&evaluation.state, &evaluation.graph, .{ .io = testing.io });
        if (length == maximum) {
            try testing.expectEqual(diagnostic_count, evaluation.state.diagnostics.items.len);
        } else {
            try testing.expect(evaluation.state.diagnostics.items.len > diagnostic_count);
        }
    }
}
