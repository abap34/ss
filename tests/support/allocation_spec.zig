const std = @import("std");
const allocation_testing = @import("allocation_testing");
const testing = std.testing;

const Attempts = struct { started: usize = 0, completed: usize = 0 };

fn replaceBuffer(allocator: std.mem.Allocator, attempts: *Attempts) !void {
    attempts.started += 1;
    var buffer = try allocator.alloc(u8, 8);
    defer allocator.free(buffer);
    @memset(buffer, 0xa5);
    buffer = try allocator.realloc(buffer, 128);
    try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0xa5)), buffer[0..8]);
    buffer = try allocator.realloc(buffer, 16);
    try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0xa5)), buffer[0..8]);
    attempts.completed += 1;
}

test "allocation failures cover initial allocation, growth, and shrink replacement" {
    var attempts = Attempts{};
    var backing = testing.FailingAllocator.init(testing.allocator, .{});
    try allocation_testing.checkAllAllocationFailures(backing.allocator(), replaceBuffer, .{&attempts});
    try testing.expectEqual(@as(usize, 4), attempts.started);
    try testing.expectEqual(@as(usize, 1), attempts.completed);
    try testing.expectEqual(@as(usize, 6), backing.allocations);
    try testing.expectEqual(@as(usize, 0), backing.resize_index);
    try testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}
