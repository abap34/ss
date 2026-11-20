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

pub const Definitions = struct {
    const Entry = struct { key: Key, present: bool };
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Definitions, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn clear(self: *Definitions) void {
        self.entries.clearRetainingCapacity();
    }

    fn get(self: Definitions, key: Key) ?Entry {
        for (self.entries.items) |definition| if (definition.key.eql(key)) return definition;
        return null;
    }

    fn add(self: *Definitions, allocator: std.mem.Allocator, definition: Entry) !void {
        for (self.entries.items) |*old| if (old.key.eql(definition.key)) {
            old.present = old.present or definition.present;
            return;
        };
        try self.entries.append(allocator, definition);
    }

    pub fn define(self: *Definitions, allocator: std.mem.Allocator, owner: resources.PropertyOwner, name: []const u8, present: bool) !void {
        const key = Key.from(owner, name) orelse return;
        try self.add(allocator, .{ .key = key, .present = present });
    }

    pub fn include(self: *Definitions, allocator: std.mem.Allocator, other: Definitions) !void {
        for (other.entries.items) |definition| try self.add(allocator, definition);
    }

    pub fn intersect(self: *Definitions, other: Definitions) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const definition = &self.entries.items[i];
            if (other.get(definition.key)) |rhs| {
                definition.present = definition.present and rhs.present;
                i += 1;
            } else {
                _ = self.entries.swapRemove(i);
            }
        }
    }

    pub fn satisfies(self: Definitions, read: resources.Resource) bool {
        if (self.entries.items.len == 0 or read != .property) return false;
        const name = read.property.key.displayName() orelse return false;
        if (read.property.unless_defined_on) |page| {
            if (self.get(.{ .page = page, .name = name })) |definition| if (definition.present) return true;
        }
        const key = Key.from(read.property.owner, name) orelse return false;
        for (self.entries.items) |definition| {
            if (key.page == definition.key.page and core.PropertyPath.contains(definition.key.name, key.name)) return true;
        }
        return false;
    }
};

// Intersection over reachable predecessors. An unreachable predecessor is
// different from a reachable one that defines no settings.
pub const Join = struct {
    definitions: Definitions = .{},
    reachable: bool = false,

    pub fn deinit(self: *Join, allocator: std.mem.Allocator) void {
        self.definitions.deinit(allocator);
    }

    pub fn add(self: *Join, allocator: std.mem.Allocator, path: Definitions) !void {
        if (self.reachable) {
            self.definitions.intersect(path);
        } else {
            try self.definitions.include(allocator, path);
            self.reachable = true;
        }
    }
};
