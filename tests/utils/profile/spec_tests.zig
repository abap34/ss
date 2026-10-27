const std = @import("std");
const utils = @import("utils");
const profile = utils.profile;
const testing = std.testing;

test "disabled profiling preserves the disabled measurement path" {
    try testing.expect(!profile.isRecording());
    try testing.expectEqual(@as(i128, 0), profile.timestamp());
    try testing.expectEqual(@as(i128, 0), profile.start());
    profile.counter("test.disabled", 1);
    try testing.expect(!try profile.checkpoint());
    try testing.expectEqual(@as(u32, 42), profile.call("disabled", identity, .{@as(u32, 42)}));
    try testing.expectError(error.Expected, profile.call("disabled failure", failure, .{}));
}

test "SDK sessions checkpoint without replacing existing recordings" {
    if (!profile.available) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/recording", .{tmp.sub_path});
    defer testing.allocator.free(path);
    try testing.expectError(error.InvalidProfileLimit, profile.Session.init(testing.allocator, testing.io, path, 1, .{}));
    var session = try profile.Session.init(testing.allocator, testing.io, path, 1024, .{ .command = "test" });
    defer session.deinit();
    profile.activate(&session);
    defer profile.deactivate();
    session.identifyInput("input bytes");
    try testing.expectEqual(@as(u32, 42), profile.call("identity", identity, .{@as(u32, 42)}));
    try testing.expectError(error.Expected, profile.call("failure", failure, .{}));
    try testing.expect(try profile.checkpoint());
    try testing.expectEqual(@as(u64, 1), session.checkpoint_count);
    try testing.expectError(error.PathAlreadyExists, profile.Session.init(testing.allocator, testing.io, path, 1024, .{}));
    try session.write(true);
    const manifest_path = try std.fs.path.join(testing.allocator, &.{ path, "manifest.json" });
    defer testing.allocator.free(manifest_path);
    const manifest = try utils.fs.readFileAlloc(testing.io, testing.allocator, manifest_path);
    defer testing.allocator.free(manifest);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, manifest, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 64), parsed.value.object.get("input_sha256").?.string.len);
    try testing.expectEqual(@as(i64, 2), parsed.value.object.get("checkpoints").?.integer);
    try testing.expect(parsed.value.object.get("completed").?.bool);
    const trace_path = try std.fs.path.join(testing.allocator, &.{ path, "trace.pftrace" });
    defer testing.allocator.free(trace_path);
    const trace = try utils.fs.readFileAlloc(testing.io, testing.allocator, trace_path);
    defer testing.allocator.free(trace);
    try testing.expect(trace.len > 0);
}

test "profile thread dispatch preserves execution and joins workers" {
    var count = std.atomic.Value(u32).init(0);
    var threads: [3]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (&threads) |*thread| {
        thread.* = try profile.spawn(.{}, worker, .{&count});
        started += 1;
    }
    for (threads[0..started]) |thread| thread.join();
    started = 0;
    try testing.expectEqual(@as(u32, 300), count.load(.monotonic));
}

fn worker(count: *std.atomic.Value(u32)) void {
    const scope = profile.zone(@src());
    defer scope.end();
    for (0..100) |_| _ = count.fetchAdd(1, .monotonic);
}
fn identity(value: u32) u32 {
    return value;
}
fn failure() error{Expected}!void {
    return error.Expected;
}
