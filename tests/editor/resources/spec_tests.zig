const std = @import("std");
const Clients = @import("editor_resources").Clients;
const Lease = @import("utils").render_cache.PublishedLease;
const testing = std.testing;

test "editor resources retain displayed, deferred, and in-flight snapshots until acknowledged" {
    const current = (try Lease.create(testing.allocator, testing.io, &.{"editor/current.svg"})).?;
    defer current.deinit();
    const deferred = (try Lease.create(testing.allocator, testing.io, &.{"editor/deferred.svg"})).?;
    defer deferred.deinit();
    const queued = (try Lease.create(testing.allocator, testing.io, &.{"editor/queued.svg"})).?;
    defer queued.deinit();
    var clients = Clients.init(testing.allocator);
    defer clients.deinit();
    try clients.deliver("slide.ss", "entry.ss", "current", current);
    try clients.deliver("slide.ss", "entry.ss", "deferred", deferred);
    try clients.deliver("slide.ss", "entry.ss", "queued", queued);
    clients.observe("slide.ss", "deferred", &.{ "current", "deferred" });
    try testing.expectEqual(@as(usize, 2), current.references.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), deferred.references.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), queued.references.load(.monotonic));
    clients.observe("slide.ss", "queued", &.{"queued"});
    try testing.expectEqual(@as(usize, 1), current.references.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), deferred.references.load(.monotonic));
    clients.observe("slide.ss", "current", &.{});
    try clients.deliver("slide.ss", "entry.ss", "queued", queued);
    try testing.expectEqual(@as(usize, 2), queued.references.load(.monotonic));
    try clients.deliver("other.ss", "entry.ss", "queued", queued);
    clients.close("slide.ss");
    try testing.expect(clients.hasEntry("entry.ss"));
    try testing.expectEqual(@as(usize, 2), queued.references.load(.monotonic));
    clients.close("other.ss");
    try testing.expect(!clients.hasEntry("entry.ss"));
    try testing.expectEqual(@as(usize, 1), queued.references.load(.monotonic));
}

test "editor resources release partial deliveries after every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, resourceOwnership, .{});
}

fn resourceOwnership(allocator: std.mem.Allocator) !void {
    const resource = (try Lease.create(allocator, testing.io, &.{"editor/ownership.svg"})).?;
    defer resource.deinit();
    var clients = Clients.init(allocator);
    defer clients.deinit();
    try clients.deliver("slide.ss", "entry.ss", "first", resource);
    try clients.deliver("slide.ss", "entry.ss", "second", resource);
    try clients.deliver("slide.ss", "changed.ss", "third", resource);
    try clients.deliver("other.ss", "entry.ss", "first", resource);
    clients.observe("slide.ss", "third", &.{"third"});
    clients.close("slide.ss");
    try testing.expect(clients.hasEntry("entry.ss"));
    clients.close("other.ss");
    try testing.expectEqual(@as(usize, 1), resource.references.load(.monotonic));
}
