const std = @import("std");

/// Enumerate allocation failures independently of the backing allocator's free space.
pub fn checkAllAllocationFailures(backing_allocator: std.mem.Allocator, comptime test_fn: anytype, extra_args: anytype) !void {
    // Both growing and shrinking remaps can change the number of allocations.
    // Keep replacement allocations explicit while retaining the backing leak checks.
    var no_resize = std.testing.FailingAllocator.init(backing_allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), test_fn, extra_args);
}
