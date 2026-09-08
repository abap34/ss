const std = @import("std");
const FileInputs = @import("utils").FileInputs;
const testing = std.testing;

test "file inputs: canonical paths are unique and ordered independently of recording order" {
    var inputs = FileInputs.init(testing.allocator);
    defer inputs.deinit();
    try inputs.record("/project", "nested/../z.data", .file);
    try inputs.record("/project", "a.data", .file);
    try inputs.record("/project", "./z.data", .file);
    const recorded = inputs.items();
    try testing.expectEqual(@as(usize, 2), recorded.len);
    try testing.expectEqualStrings("/project/a.data", recorded[0].path);
    try testing.expectEqualStrings("/project/z.data", recorded[1].path);
    inputs.clear();
    try testing.expectEqual(@as(usize, 0), inputs.items().len);
    try inputs.record("/project", "resources", .directory);
    try testing.expectEqual(@as(usize, 1), inputs.items().len);
    try testing.expectEqual(.directory, inputs.items()[0].kind);
}

test "file inputs: allocation failures preserve ownership" {
    try testing.checkAllAllocationFailures(testing.allocator, recordInputs, .{});
}

fn recordInputs(allocator: std.mem.Allocator) !void {
    var inputs = FileInputs.init(allocator);
    defer inputs.deinit();
    for (0..20) |index| {
        var path_buffer: [40]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "input-{d}.data", .{index});
        try inputs.record("/project", path, .file);
    }
    try testing.expectEqual(@as(usize, 20), inputs.items().len);
}

test "file inputs: each unique path retains its first observation" {
    const Counter = struct {
        value: u64 = 0,

        fn capture(context: *anyopaque, path: []const u8, _: @import("utils").file_inputs.Kind) !u64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            try testing.expect(std.fs.path.isAbsolute(path));
            self.value += 1;
            return self.value;
        }
    };
    var counter = Counter{};
    var inputs = FileInputs.init(testing.allocator);
    defer inputs.deinit();
    inputs.observer = .{ .context = &counter, .capture = Counter.capture };
    try inputs.record("/project", "first.data", .file);
    try inputs.record("/project", "./first.data", .file);
    try inputs.record("/project", "second.data", .file);
    const recorded = inputs.items();
    try testing.expectEqual(@as(usize, 2), recorded.len);
    try testing.expectEqual(@as(u64, 1), recorded[0].observation.?);
    try testing.expectEqual(@as(u64, 2), recorded[1].observation.?);
    inputs.clear();
    try inputs.record("/project", "first.data", .file);
    try testing.expectEqual(@as(u64, 3), inputs.items()[0].observation.?);
}

test "file inputs: failed observations leave no partial path" {
    var context: u8 = 0;
    var inputs = FileInputs.init(testing.allocator);
    defer inputs.deinit();
    inputs.observer = .{ .context = &context, .capture = struct {
        fn capture(_: *anyopaque, _: []const u8, _: @import("utils").file_inputs.Kind) !u64 {
            return error.Canceled;
        }
    }.capture };
    try testing.expectError(error.Canceled, inputs.record("/project", "first.data", .file));
    try testing.expectEqual(@as(usize, 0), inputs.paths.count());
    try testing.expectEqual(@as(usize, 0), inputs.items().len);
}
