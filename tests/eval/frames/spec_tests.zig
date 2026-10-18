const std = @import("std");
const allocation_testing = @import("allocation_testing");
const compiler = @import("compiler");
const frames = compiler.evaluation_frames;
const testing = std.testing;

fn exerciseFrames(allocator: std.mem.Allocator) !void {
    var stack = frames.Stack.init(allocator, 2);
    defer stack.deinit();
    const first = try stack.push(1, 0, .{}, null);
    try first.environment.putOwned("captured", .{ .number = 42 });
    const second = try stack.push(2, 1, .{}, &first.environment);
    try testing.expectEqual(@as(f32, 42), second.environment.get("captured").?.number);
    try testing.expectError(error.EvaluationResourceLimit, stack.push(3, 2, .{}, null));
    try testing.expectEqual(@as(u32, 2), stack.depth);
    try testing.expect(stack.current == second);
    stack.pop(second);
    try testing.expect(stack.current == first);
    const replacement = try stack.push(3, 1, .{}, null);
    try testing.expect(replacement.environment.get("captured") == null);
    stack.pop(replacement);
    stack.pop(first);
    try testing.expectEqual(@as(u32, 0), stack.depth);
    try testing.expect(stack.current == null);
}

test "evaluation frames retain captures and unwind after resource or allocation failure" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, exerciseFrames, .{});
}

const CancellationCounter = struct {
    checks: usize = 0,
    cancel_after: usize,

    fn isCanceled(context: *const anyopaque) bool {
        const self: *CancellationCounter = @ptrCast(@alignCast(@constCast(context)));
        self.checks += 1;
        return self.checks >= self.cancel_after;
    }
};

fn evaluate(source_text: []const u8, maximum: u32, expected: ?anyerror) !void {
    return evaluateWithCancellation(source_text, maximum, expected, null);
}

fn evaluateWithCancellation(source_text: []const u8, maximum: u32, expected: ?anyerror, cancel_after: ?usize) !void {
    const allocator = testing.allocator;
    var source = try allocator.dupe(u8, source_text);
    defer allocator.free(source);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, source, "evaluation-frames.ss");
    defer syntax.deinit(allocator);
    var modules = try compiler.analysis.loadModuleIndex(allocator, testing.io, ".", syntax, .{});
    defer modules.deinit();
    var state = try compiler.analysis.buildDocumentState(allocator, "evaluation-frames.ss", ".", &source, &syntax, &modules);
    defer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(allocator, &state, .evaluation)).?;
    defer graph.deinit();
    var counter = CancellationCounter{ .cancel_after = cancel_after orelse 0 };
    const result = compiler.lowering.evaluateDocument(&state, &graph, .{
        .io = testing.io,
        .max_call_frames = maximum,
        .cancellation = if (cancel_after != null) .{ .context = &counter, .is_canceled = CancellationCounter.isCanceled } else null,
    });
    if (expected) |err| {
        try testing.expectError(err, result);
        if (err == error.Canceled) {
            try testing.expectEqual(@as(usize, 0), state.diagnostics.entries.items.len);
            return;
        }
        try testing.expectEqual(@as(usize, 1), state.diagnostics.entries.items.len);
        const diagnostic = state.diagnostics.entries.items[0];
        try testing.expectEqualStrings("EvaluationResourceLimit", diagnostic.code());
        try testing.expect(diagnostic.origin.?.location() != null);
    } else try result;
}

const leaf =
    \\fn leaf() -> String
    \\  return "done"
    \\end
    \\
;

test "evaluation frames count named calls and release each completed call" {
    const source = leaf ++
        \\fn outer() -> String
        \\  return leaf()
        \\end
        \\page main
        \\  let first = outer()
        \\  let second = outer()
        \\end
    ;
    try evaluate(source, 1, error.EvaluationResourceLimit);
    try evaluate(source, 2, null);
}

test "evaluation frames include calls made by default arguments" {
    const source = leaf ++
        \\fn outer(value: String = leaf()) -> String
        \\  return value
        \\end
        \\page main
        \\  let result = outer()
        \\end
    ;
    try evaluate(source, 1, error.EvaluationResourceLimit);
    try evaluate(source, 2, null);
}

test "evaluation frames include lambdas and primitive callbacks" {
    const source = leaf ++
        \\page main
        \\  let item = place_on!(pagectx(), Text { content = "A" })
        \\  foreach(select<Text>(pagectx()), (o: Placed<Text>) |-> leaf())
        \\end
    ;
    try evaluate(source, 1, error.EvaluationResourceLimit);
    try evaluate(source, 2, null);
}

test "evaluation frames include typed displays and their captured callbacks" {
    const source = leaf ++
        \\type Label { format: () -> String }
        \\fn display(self: Placed<Label>) -> Text = Text { content = self.value.format() }
        \\page main
        \\  place!(Label { format = () |-> leaf() })
        \\end
    ;
    try evaluate(source, 2, error.EvaluationResourceLimit);
    try evaluate(source, 3, null);
}

test "evaluation frames release active environments when canceled inside a call" {
    const source = leaf ++
        \\fn outer() -> String
        \\  let local = "owned binding"
        \\  return leaf()
        \\end
        \\page main
        \\  let result = outer()
        \\end
    ;
    for (8..11) |cancel_after| try evaluateWithCancellation(source, 2, error.Canceled, cancel_after);
}
