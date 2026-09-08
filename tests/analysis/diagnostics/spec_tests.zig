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

fn shareDiagnosticSources(allocator: std.mem.Allocator) !void {
    var copied = analysis.diagnostics.DiagnosticBag.init(allocator);
    defer copied.deinit();
    {
        var original = analysis.diagnostics.DiagnosticBag.init(allocator);
        defer original.deinit();
        var text = [_]u8{'x'} ** 32768;
        const id = try original.registerSource("large.ss", &text);
        for (0..100) |index| {
            try original.addAt(id, .@"error", "Example", "message", .{ .start = index, .end = index + 1 }, null);
        }
        text[0] = 'y';
        try testing.expectEqual(@as(usize, 1), original.sources.items.len);
        const shared_source = original.items.items[0].source;
        for (original.items.items) |item| {
            try testing.expectEqual(id, item.source_id);
            try testing.expectEqual(@intFromPtr(shared_source.ptr), @intFromPtr(item.source.ptr));
            try testing.expectEqual(@as(u8, 'x'), item.source[0]);
        }
        try copied.appendFrom(&original);
    }
    try testing.expectEqual(@as(usize, 100), copied.items.items.len);
    try testing.expectEqual(@as(usize, 1), copied.sources.items.len);
    for (copied.items.items) |item| try testing.expectEqual(@as(u8, 'x'), item.source[0]);
}

test "diagnostics share source storage and copy it once across ownership boundaries" {
    try testing.checkAllAllocationFailures(testing.allocator, shareDiagnosticSources, .{});
}

fn retainSourceVersions(allocator: std.mem.Allocator) !void {
    var bag = analysis.diagnostics.DiagnosticBag.init(allocator);
    defer bag.deinit();
    const first = try bag.registerSource("slide.ss", "first");
    const second = try bag.registerSource("slide.ss", "second");
    try testing.expect(first != second);
    try testing.expectEqual(first, try bag.registerSource("slide.ss", "first"));
    try bag.addAt(second, .warning, "Second", "later source", .{ .start = 2, .end = 3 }, null);
    try bag.addAt(first, .@"error", "First", "earlier source", .{ .start = 0, .end = 1 }, null);
    bag.sortByPath();
    const items = bag.itemsForPath("slide.ss");
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("first", items[0].source);
    try testing.expectEqualStrings("second", items[1].source);
    try testing.expect(!bag.sourcesMatch("slide.ss", "first"));
    try testing.expect(bag.hasErrors());
}

test "diagnostics preserve distinct source versions for the same path" {
    try testing.checkAllAllocationFailures(testing.allocator, retainSourceVersions, .{});
}

test "position edits rebase shared source storage once" {
    var bag = analysis.diagnostics.DiagnosticBag.init(testing.allocator);
    defer bag.deinit();
    const id = try bag.registerSource("slide.ss", "abc");
    try bag.addAt(id, .warning, "Example", "first", null, null);
    try bag.addAt(id, .warning, "Example", "second", null, null);
    const pointer = bag.items.items[0].source.ptr;
    try testing.expect(bag.sourcesMatch("slide.ss", "abc"));
    bag.rebaseSource("slide.ss", "def");
    try testing.expect(bag.sourcesMatch("slide.ss", "def"));
    for (bag.items.items) |item| {
        try testing.expectEqual(@intFromPtr(pointer), @intFromPtr(item.source.ptr));
        try testing.expectEqualStrings("def", item.source);
    }
}

test "syntax hole deduplication includes the source identity" {
    var bag = analysis.diagnostics.DiagnosticBag.init(testing.allocator);
    defer bag.deinit();
    const first = try bag.registerSource("first.ss", "?");
    const second = try bag.registerSource("second.ss", "?");
    try bag.addAt(first, .@"error", "MissingExpression", "first", null, 1);
    try bag.addAt(first, .@"error", "UnknownValue", "caused by the same hole", null, 1);
    try bag.addAt(second, .@"error", "MissingExpression", "second", null, 1);
    try testing.expectEqual(@as(usize, 2), bag.items.items.len);
}
