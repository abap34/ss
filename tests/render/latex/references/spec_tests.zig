const std = @import("std");
const testing = std.testing;
const allocation_testing = @import("allocation_testing");
const references = @import("latex_references");
const utils = @import("utils");

const first = "1\t20\t30\t4\t25\tbatch.pdf\n{\"version\":1,\"inputs\":[{\"path\":\"/project/input.tex\",\"fingerprint\":{\"present\":true,\"digest\":42}}]}\n";
const second = "2\t40\t50\t6\t45\tother.pdf\n{\"version\":1,\"inputs\":[{\"path\":\"/project/input.tex\",\"fingerprint\":{\"present\":true,\"digest\":43}}]}\n";

fn pathFor(temporary: *const testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ temporary.sub_path, name });
}

var read_count: usize = 0;
var cancel_reads = false;
var replacement: ?struct { from: []const u8, to: []const u8 } = null;

fn countedRead(_: ?*anyopaque, file: std.Io.File, buffers: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
    read_count += 1;
    if (cancel_reads) return error.Canceled;
    const count = try testing.io.vtable.fileReadPositional(testing.io.userdata, file, buffers, offset);
    if (replacement) |value| {
        replacement = null;
        std.Io.Dir.cwd().rename(value.from, std.Io.Dir.cwd(), value.to, testing.io) catch return error.Unexpected;
    }
    return count;
}

test "latex references: unchanged files avoid reads and identical manifests share parsed inputs" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try pathFor(&temporary, "first.ref");
    defer testing.allocator.free(path);
    const other = try pathFor(&temporary, "other.ref");
    defer testing.allocator.free(other);
    try utils.fs.writeFile(testing.io, path, first);
    try utils.fs.writeFile(testing.io, other, first);
    var cache = references.Cache.init(testing.allocator);
    defer cache.deinit();
    var vtable = testing.io.vtable.*;
    vtable.fileReadPositional = countedRead;
    const io = std.Io{ .userdata = testing.io.userdata, .vtable = &vtable };
    read_count = 0;
    var initial = try references.read(testing.allocator, io, path, &cache);
    defer initial.deinit();
    const initial_reads = read_count;
    try testing.expect(initial_reads > 0);
    var repeated = try references.read(testing.allocator, io, path, &cache);
    defer repeated.deinit();
    try testing.expectEqual(initial_reads, read_count);
    var shared = try references.read(testing.allocator, io, other, &cache);
    defer shared.deinit();
    try testing.expectEqual(initial.inputs.ptr, repeated.inputs.ptr);
    try testing.expectEqual(initial.inputs.ptr, shared.inputs.ptr);
    try testing.expectEqual(@as(usize, 1), cache.manifests.count());
}

test "latex references: updates preserve older borrowers and missing or corrupt files can recover" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try pathFor(&temporary, "value.ref");
    defer testing.allocator.free(path);
    try utils.fs.writeFile(testing.io, path, first);
    var cache = references.Cache.init(testing.allocator);
    defer cache.deinit();
    var initial = try references.read(testing.allocator, testing.io, path, &cache);
    defer initial.deinit();
    try utils.fs.writeFile(testing.io, path, second);
    var changed = try references.read(testing.allocator, testing.io, path, &cache);
    defer changed.deinit();
    try testing.expectEqual(@as(u64, 43), changed.inputs[0].fingerprint.digest);
    try testing.expectEqual(@as(usize, 2), changed.value.page_index);
    try testing.expectEqual(@as(u64, 42), initial.inputs[0].fingerprint.digest);
    try testing.expectEqualStrings("batch.pdf", initial.value.pdf_name);
    try utils.fs.writeFile(testing.io, path, "interrupted");
    try testing.expectError(error.InvalidPdfCache, references.read(testing.allocator, testing.io, path, &cache));
    try std.Io.Dir.cwd().deleteFile(testing.io, path);
    try testing.expectError(error.FileNotFound, references.read(testing.allocator, testing.io, path, &cache));
    try utils.fs.writeFile(testing.io, path, first);
    var restored = try references.read(testing.allocator, testing.io, path, &cache);
    defer restored.deinit();
    try testing.expectEqual(@as(u64, 42), restored.inputs[0].fingerprint.digest);
}

test "latex references: replacement during a read retries the new generation" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try pathFor(&temporary, "value.ref");
    defer testing.allocator.free(path);
    const next = try pathFor(&temporary, "next.ref");
    defer testing.allocator.free(next);
    try utils.fs.writeFile(testing.io, path, first);
    try utils.fs.writeFile(testing.io, next, second);
    replacement = .{ .from = next, .to = path };
    defer replacement = null;
    var vtable = testing.io.vtable.*;
    vtable.fileReadPositional = countedRead;
    var cache = references.Cache.init(testing.allocator);
    defer cache.deinit();
    var value = try references.read(testing.allocator, .{ .userdata = testing.io.userdata, .vtable = &vtable }, path, &cache);
    defer value.deinit();
    try testing.expectEqual(@as(u64, 43), value.inputs[0].fingerprint.digest);
    try testing.expectEqualStrings("other.pdf", value.value.pdf_name);
}

test "latex references: symlink target changes invalidate cached references" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(testing.io, .{ .sub_path = "first.ref", .data = first });
    try temporary.dir.writeFile(testing.io, .{ .sub_path = "second.ref", .data = second });
    temporary.dir.symLink(testing.io, "first.ref", "alias.ref", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    const path = try pathFor(&temporary, "alias.ref");
    defer testing.allocator.free(path);
    var cache = references.Cache.init(testing.allocator);
    defer cache.deinit();
    var initial = try references.read(testing.allocator, testing.io, path, &cache);
    defer initial.deinit();
    try temporary.dir.deleteFile(testing.io, "alias.ref");
    try temporary.dir.symLink(testing.io, "second.ref", "alias.ref", .{});
    var changed = try references.read(testing.allocator, testing.io, path, &cache);
    defer changed.deinit();
    try testing.expectEqual(@as(u64, 43), changed.inputs[0].fingerprint.digest);
}

test "latex references: capacity limits fall back to independently owned results" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try pathFor(&temporary, "value.ref");
    defer testing.allocator.free(path);
    try utils.fs.writeFile(testing.io, path, first);
    for ([_]references.Cache.Limits{ .{ .entries = 0 }, .{ .bytes = 0 } }) |limits| {
        var cache = references.Cache.init(testing.allocator);
        defer cache.deinit();
        cache.limits = limits;
        var value = try references.read(testing.allocator, testing.io, path, &cache);
        defer value.deinit();
        try testing.expect(value.owned != null);
        try testing.expectEqual(@as(u64, 42), value.inputs[0].fingerprint.digest);
        try testing.expectEqual(@as(usize, 0), cache.current.count());
    }
}

test "latex references: canceled reads leave the cache usable" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try pathFor(&temporary, "value.ref");
    defer testing.allocator.free(path);
    try utils.fs.writeFile(testing.io, path, first);
    var cache = references.Cache.init(testing.allocator);
    defer cache.deinit();
    var vtable = testing.io.vtable.*;
    vtable.fileReadPositional = countedRead;
    cancel_reads = true;
    defer cancel_reads = false;
    try testing.expectError(error.Canceled, references.read(testing.allocator, .{ .userdata = testing.io.userdata, .vtable = &vtable }, path, &cache));
    cancel_reads = false;
    var value = try references.read(testing.allocator, testing.io, path, &cache);
    defer value.deinit();
    try testing.expectEqual(@as(u64, 42), value.inputs[0].fingerprint.digest);
}

test "latex references: allocation failures release cached and uncached generations" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try pathFor(&temporary, "value.ref");
    defer testing.allocator.free(path);
    try utils.fs.writeFile(testing.io, path, first);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, readWithFailures, .{path});
}

fn readWithFailures(allocator: std.mem.Allocator, path: []const u8) !void {
    var cache = references.Cache.init(allocator);
    defer cache.deinit();
    var value = try references.read(allocator, testing.io, path, &cache);
    defer value.deinit();
    var repeated = try references.read(allocator, testing.io, path, &cache);
    defer repeated.deinit();
    var uncached = try references.read(allocator, testing.io, path, null);
    defer uncached.deinit();
    cache.limits.entries = 0;
    try utils.fs.writeFile(testing.io, path, second);
    defer utils.fs.writeFile(testing.io, path, first) catch {};
    var fallback = try references.read(allocator, testing.io, path, &cache);
    defer fallback.deinit();
}

const Concurrent = struct {
    cache: *references.Cache,
    path: []const u8,
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *Concurrent) void {
        for (0..20) |_| {
            var value = references.read(testing.allocator, testing.io, self.path, self.cache) catch {
                self.failed.store(true, .monotonic);
                return;
            };
            defer value.deinit();
            if (value.inputs[0].fingerprint.digest != 42) self.failed.store(true, .monotonic);
        }
    }
};

test "latex references: concurrent readers share immutable manifests" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try pathFor(&temporary, "value.ref");
    defer testing.allocator.free(path);
    try utils.fs.writeFile(testing.io, path, first);
    var cache = references.Cache.init(testing.allocator);
    defer cache.deinit();
    var work = Concurrent{ .cache = &cache, .path = path };
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    while (started < threads.len) : (started += 1) threads[started] = try std.Thread.spawn(.{}, Concurrent.run, .{&work});
    for (threads[0..started]) |thread| thread.join();
    started = 0;
    try testing.expect(!work.failed.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), cache.manifests.count());
}
