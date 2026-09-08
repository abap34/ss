const std = @import("std");
const compiler = @import("compiler");
const core = compiler.core;
const Environment = compiler.evaluation_environment.Environment;
const testing = std.testing;

fn aggregate(allocator: std.mem.Allocator, size: usize) !core.Value {
    var selection = core.Selection.init(.object, "test");
    errdefer selection.deinit(allocator);
    try selection.ids.ensureTotalCapacity(allocator, size);
    for (0..size) |index| selection.ids.appendAssumeCapacity(@intCast(index));
    return .{ .selection = selection };
}

test "environment: child frames borrow parents without allocating or releasing their values" {
    var parent = Environment.init(testing.allocator);
    defer parent.deinit();
    try parent.putOwned("large", try aggregate(testing.allocator, 8192));
    var forbidden = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var branch = Environment.child(forbidden.allocator(), &parent);
    const borrowed = branch.get("large").?.selection.ids.items;
    try testing.expectEqual(parent.get("large").?.selection.ids.items.ptr, borrowed.ptr);
    branch.deinit();
    try testing.expectEqual(@as(usize, 8192), parent.get("large").?.selection.ids.items.len);
    try testing.expectEqual(@as(usize, 0), forbidden.alloc_index);
}

test "environment: capture and invocation allocation ignore unused aggregate size" {
    var expected_bytes: ?usize = null;
    for ([_]usize{ 1, 1024, 16384 }) |size| {
        var source = Environment.init(testing.allocator);
        defer source.deinit();
        try source.putOwned("large", try aggregate(testing.allocator, size));
        try source.putOwned("used", .{ .number = 7 });
        var accounting = testing.FailingAllocator.init(testing.allocator, .{});
        var captured = try Environment.capture(accounting.allocator(), &source, &.{ "used", "global_function" });
        defer captured.deinit();
        try testing.expect(captured.get("large") == null);
        try testing.expect(captured.get("global_function") == null);
        var invocation = Environment.child(accounting.allocator(), &captured);
        defer invocation.deinit();
        try invocation.putBorrowed("argument", source.get("large").?);
        try testing.expectEqual(@as(f32, 7), invocation.get("used").?.number);
        try testing.expectEqual(source.get("large").?.selection.ids.items.ptr, invocation.get("argument").?.selection.ids.items.ptr);
        if (expected_bytes) |bytes| {
            try testing.expectEqual(bytes, accounting.allocated_bytes);
        } else expected_bytes = accounting.allocated_bytes;
    }
}

test "environment: captures own free values after their source frame is released" {
    var source = Environment.init(testing.allocator);
    try source.putOwned("value", try aggregate(testing.allocator, 16));
    var captured = Environment.capture(testing.allocator, &source, &.{"value"}) catch |err| {
        source.deinit();
        return err;
    };
    defer captured.deinit();
    try testing.expect(source.get("value").?.selection.ids.items.ptr != captured.get("value").?.selection.ids.items.ptr);
    source.deinit();
    try testing.expectEqual(@as(usize, 16), captured.get("value").?.selection.ids.items.len);
}

fn captureWithAllocationFailures(allocator: std.mem.Allocator, source: *const Environment) !void {
    var captured = try Environment.capture(allocator, source, &.{ "first", "second" });
    defer captured.deinit();
}

test "environment: partially copied captures and failed insertions release ownership" {
    var source = Environment.init(testing.allocator);
    defer source.deinit();
    try source.putOwned("first", try aggregate(testing.allocator, 128));
    try source.putOwned("second", try aggregate(testing.allocator, 256));
    try testing.checkAllAllocationFailures(testing.allocator, captureWithAllocationFailures, .{&source});
}

test "environment: child bindings shadow locally and preserve the parent" {
    var parent = Environment.init(testing.allocator);
    defer parent.deinit();
    try parent.putOwned("value", .{ .number = 1 });
    var child = Environment.child(testing.allocator, &parent);
    defer child.deinit();
    try child.putOwned("value", .{ .number = 2 });
    try testing.expectEqual(@as(f32, 1), parent.get("value").?.number);
    try testing.expectEqual(@as(f32, 2), child.get("value").?.number);
}
