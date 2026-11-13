// Definitions of single-assignment settings guaranteed on a control-flow path.
// A definition of none still satisfies a read, but cannot suppress a fallback.
const std = @import("std");
const core = @import("core");
const resources = @import("resources.zig");

pub const Key = struct {
    // null identifies the document. An unknown page never establishes a fact.
    page: ?core.NodeId,
    name: []const u8,

    fn from(owner: resources.PropertyOwner, name: []const u8) ?Key {
        return .{ .page = switch (owner) {
            .document => null,
            .page => |id| id orelse return null,
            else => return null,
        }, .name = name };
    }

    pub fn fromResource(resource: resources.Resource) ?Key {
        if (resource != .property) return null;
        return from(resource.property.owner, resource.property.key.displayName() orelse return null);
    }

    pub fn eql(a: Key, b: Key) bool {
        return a.page == b.page and std.mem.eql(u8, a.name, b.name);
    }

    pub const Context = struct {
        pub fn hash(_: @This(), key: Key) u64 {
            return std.hash.Wyhash.hash(key.page orelse 0, key.name);
        }
        pub fn eql(_: @This(), a: Key, b: Key) bool {
            return a.eql(b);
        }
    };
};

pub const Facts = struct {
    const Entry = struct { key: Key, present: bool };
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Facts, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn clear(self: *Facts) void {
        self.entries.clearRetainingCapacity();
    }

    fn get(self: Facts, key: Key) ?Entry {
        for (self.entries.items) |fact| if (fact.key.eql(key)) return fact;
        return null;
    }

    fn add(self: *Facts, allocator: std.mem.Allocator, fact: Entry) !void {
        for (self.entries.items) |*old| if (old.key.eql(fact.key)) {
            old.present = old.present or fact.present;
            return;
        };
        try self.entries.append(allocator, fact);
    }

    pub fn define(self: *Facts, allocator: std.mem.Allocator, owner: resources.PropertyOwner, name: []const u8, present: bool) !void {
        const key = Key.from(owner, name) orelse return;
        try self.add(allocator, .{ .key = key, .present = present });
    }

    pub fn include(self: *Facts, allocator: std.mem.Allocator, other: Facts) !void {
        for (other.entries.items) |fact| try self.add(allocator, fact);
    }

    pub fn intersect(self: *Facts, other: Facts) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const fact = &self.entries.items[i];
            if (other.get(fact.key)) |rhs| {
                fact.present = fact.present and rhs.present;
                i += 1;
            } else {
                _ = self.entries.swapRemove(i);
            }
        }
    }

    pub fn satisfies(self: Facts, read: resources.Resource) bool {
        if (self.entries.items.len == 0 or read != .property) return false;
        const name = read.property.key.displayName() orelse return false;
        if (read.property.unless_defined_on) |page| {
            if (self.get(.{ .page = page, .name = name })) |fact| if (fact.present) return true;
        }
        const key = Key.from(read.property.owner, name) orelse return false;
        for (self.entries.items) |fact| {
            if (key.page == fact.key.page and core.PropertyPath.contains(fact.key.name, key.name)) return true;
        }
        return false;
    }
};

// Intersection over reachable predecessors. An unreachable predecessor is
// different from a reachable one that defines no settings.
pub const Join = struct {
    facts: Facts = .{},
    reachable: bool = false,

    pub fn deinit(self: *Join, allocator: std.mem.Allocator) void {
        self.facts.deinit(allocator);
    }

    pub fn add(self: *Join, allocator: std.mem.Allocator, path: Facts) !void {
        if (self.reachable) {
            self.facts.intersect(path);
        } else {
            try self.facts.include(allocator, path);
            self.reachable = true;
        }
    }
};
