const std = @import("std");
const Lease = @import("utils").render_cache.PublishedLease;

const Delivery = struct {
    snapshot_id: []u8,
    sequence: u64,
    resources: ?*Lease,

    fn deinit(self: *Delivery, allocator: std.mem.Allocator) void {
        allocator.free(self.snapshot_id);
        if (self.resources) |lease| lease.deinit();
    }
};

const Client = struct {
    entry_path: []u8,
    sequence: u64 = 0,
    deliveries: std.ArrayList(Delivery) = .empty,

    fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_path);
        for (self.deliveries.items) |*delivery| delivery.deinit(allocator);
        self.deliveries.deinit(allocator);
    }
};

/// A client retains displayed, deferred, and not-yet-observed responses.
/// Analysis generations and cached JSON have separate resource owners.
pub const Clients = struct {
    allocator: std.mem.Allocator,
    items: std.StringHashMap(Client),

    pub fn init(allocator: std.mem.Allocator) Clients {
        return .{ .allocator = allocator, .items = std.StringHashMap(Client).init(allocator) };
    }

    pub fn deinit(self: *Clients) void {
        var iterator = self.items.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.items.deinit();
    }

    pub fn deliver(self: *Clients, path: []const u8, entry_path: []const u8, snapshot_id: []const u8, resources: ?*Lease) !void {
        if (self.items.getPtr(path)) |client| {
            if (!std.mem.eql(u8, client.entry_path, entry_path)) {
                const owned_entry = try self.allocator.dupe(u8, entry_path);
                self.allocator.free(client.entry_path);
                client.entry_path = owned_entry;
            }
            return self.append(client, snapshot_id, resources);
        }
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        var client = Client{ .entry_path = try self.allocator.dupe(u8, entry_path) };
        errdefer client.deinit(self.allocator);
        try self.append(&client, snapshot_id, resources);
        try self.items.putNoClobber(owned_path, client);
    }

    fn append(self: *Clients, client: *Client, snapshot_id: []const u8, resources: ?*Lease) !void {
        const sequence = try std.math.add(u64, client.sequence, 1);
        for (client.deliveries.items) |*delivery| {
            if (!std.mem.eql(u8, delivery.snapshot_id, snapshot_id)) continue;
            const retained = if (resources) |lease| lease.retain() else null;
            if (delivery.resources) |lease| lease.deinit();
            delivery.resources = retained;
            delivery.sequence = sequence;
            client.sequence = sequence;
            return;
        }
        const owned_id = try self.allocator.dupe(u8, snapshot_id);
        errdefer self.allocator.free(owned_id);
        try client.deliveries.ensureUnusedCapacity(self.allocator, 1);
        client.deliveries.appendAssumeCapacity(.{
            .snapshot_id = owned_id,
            .sequence = sequence,
            .resources = if (resources) |lease| lease.retain() else null,
        });
        client.sequence = sequence;
    }

    pub fn observe(self: *Clients, path: []const u8, observed_snapshot_id: []const u8, retained_ids: []const []const u8) void {
        const client = self.items.getPtr(path) orelse return;
        const observed_sequence = for (client.deliveries.items) |delivery| {
            if (std.mem.eql(u8, delivery.snapshot_id, observed_snapshot_id)) break delivery.sequence;
        } else return;
        var index: usize = 0;
        while (index < client.deliveries.items.len) {
            const delivery = &client.deliveries.items[index];
            const retained = for (retained_ids) |id| {
                if (std.mem.eql(u8, id, delivery.snapshot_id)) break true;
            } else false;
            if (delivery.sequence > observed_sequence or retained) {
                index += 1;
            } else {
                var removed = client.deliveries.swapRemove(index);
                removed.deinit(self.allocator);
            }
        }
    }

    pub fn close(self: *Clients, path: []const u8) void {
        if (self.items.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            var client = entry.value;
            client.deinit(self.allocator);
        }
    }

    pub fn hasEntry(self: *const Clients, entry_path: []const u8) bool {
        var values = self.items.valueIterator();
        while (values.next()) |client| if (std.mem.eql(u8, client.entry_path, entry_path)) return true;
        return false;
    }
};
