const std = @import("std");
const allocation_testing = @import("allocation_testing");
const csv = @import("csv");

fn allocationCase(allocator: std.mem.Allocator, text: []const u8, invalid: bool) !void {
    var failure = csv.Failure{};
    var table = csv.parse(allocator, text, &failure, null) catch |err| {
        if (err == error.InvalidCsv and invalid) return;
        return err;
    };
    defer table.deinit();
    try std.testing.expect(!invalid);
    try std.testing.expectEqual(@as(usize, 6), table.cells.items.len);
    try std.testing.expectEqualStrings("two\nlines", table.cells.items[3].text);
    try std.testing.expectEqualStrings("quoted \"value\"", table.cells.items[4].text);
    try std.testing.expectEqualStrings("", table.cells.items[5].text);
    try std.testing.expectEqual(@as(usize, 2), table.cells.items[5].row);
    try std.testing.expectEqual(@as(usize, 3), table.cells.items[5].column);
    try std.testing.expect(table.cells.items[5].end_row);
}

test "CSV parser frees allocations on success and malformed input" {
    try allocation_testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{ "A,B,C\r\n\"two\r\nlines\",\"quoted \"\"value\"\"\",", false });
    try allocation_testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{ "A,B\n\"unterminated", true });
    try allocation_testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{ "A,B\n1", true });
}

fn cancel(_: *const anyopaque) bool {
    return true;
}

test "CSV parser propagates cancellation" {
    var failure = csv.Failure{};
    const context: u8 = 0;
    try std.testing.expectError(error.Canceled, csv.parse(std.testing.allocator, "A,B\n1,2", &failure, .{ .context = &context, .is_canceled = cancel }));
}

const CancellationCounter = struct {
    checks: usize = 0,

    fn canceled(context: *const anyopaque) bool {
        const self: *CancellationCounter = @ptrCast(@alignCast(@constCast(context)));
        self.checks += 1;
        return self.checks >= 2;
    }
};

test "CSV parser checks cancellation while consuming paired bytes in a quoted field" {
    for ([_][]const u8{ "\"\"", "\r\n" }) |pair| {
        var input = std.ArrayList(u8).empty;
        defer input.deinit(std.testing.allocator);
        try input.append(std.testing.allocator, '\"');
        for (0..8192) |_| try input.appendSlice(std.testing.allocator, pair);
        try input.append(std.testing.allocator, '\"');
        var counter = CancellationCounter{};
        var failure = csv.Failure{};
        try std.testing.expectError(error.Canceled, csv.parse(std.testing.allocator, input.items, &failure, .{
            .context = &counter,
            .is_canceled = CancellationCounter.canceled,
        }));
        try std.testing.expectEqual(@as(usize, 2), counter.checks);
    }
}
