const std = @import("std");
const dependencies = @import("dependencies.zig");

const Allocator = std.mem.Allocator;
const Resource = dependencies.Resource;
const ResourceScope = dependencies.ResourceScope;
const ObjectIdentity = dependencies.ObjectIdentity;

pub const WriteEntry = struct {
    unit_index: usize,
    resource: Resource,
};

const Entries = std.ArrayList(WriteEntry);

// Keys borrow the execution units' generation-owned names. Each write occurs
// once in a query result, including writes with wildcard keys or owners.
pub const ResourceWriterIndex = struct {
    allocator: Allocator,
    variables: std.StringHashMapUnmanaged(ScopedEntries) = .{},
    pages: ScopedEntries = .{},
    objects: Entries = .empty,
    any_owner: NamedEntries = .{},
    document_owner: NamedEntries = .{},
    page_owner: NamedEntries = .{},
    object_owners: ObjectEntries = .{},

    pub fn init(allocator: Allocator) ResourceWriterIndex {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ResourceWriterIndex) void {
        deinitValues(self.allocator, &self.variables);
        self.pages.deinit(self.allocator);
        self.objects.deinit(self.allocator);
        self.any_owner.deinit(self.allocator);
        self.document_owner.deinit(self.allocator);
        self.page_owner.deinit(self.allocator);
        self.object_owners.deinit(self.allocator);
    }

    pub fn addWrite(self: *ResourceWriterIndex, unit_index: usize, resource: Resource) !void {
        const entry = WriteEntry{ .unit_index = unit_index, .resource = resource };
        switch (resource) {
            .variable => |variable| {
                const scoped = try getBucket(self.allocator, &self.variables, variable.name);
                try scoped.add(self.allocator, variable.scope, entry);
            },
            .pages => |scope| try self.pages.add(self.allocator, scope, entry),
            .objects => try self.objects.append(self.allocator, entry),
            .property => |property| switch (property.owner) {
                .any => try self.any_owner.add(self.allocator, property.key.indexName(), entry),
                .document => try self.document_owner.add(self.allocator, property.key.indexName(), entry),
                .page => try self.page_owner.add(self.allocator, property.key.indexName(), entry),
                .object => try self.object_owners.add(self.allocator, entry),
            },
        }
    }

    pub fn forEachCandidate(self: *const ResourceWriterIndex, read: Resource, visitor: anytype) !void {
        var matching = struct {
            read: Resource,
            visitor: @TypeOf(visitor),

            pub fn visit(filter: *@This(), entry: WriteEntry) !void {
                if (entry.resource.intersects(filter.read)) try filter.visitor.visit(entry);
            }
        }{ .read = read, .visitor = visitor };
        try self.visitBuckets(read, &matching);
    }

    fn visitBuckets(self: *const ResourceWriterIndex, read: Resource, visitor: anytype) !void {
        switch (read) {
            .variable => |variable| {
                if (self.variables.getPtr(variable.name)) |scoped| try scoped.visit(variable.scope, visitor);
            },
            .pages => |scope| try self.pages.visit(scope, visitor),
            .objects => try visitEntries(self.objects.items, visitor),
            .property => |property| {
                const key = property.key.indexName();
                try self.any_owner.visit(key, visitor);
                switch (property.owner) {
                    .any => {
                        try self.document_owner.visit(key, visitor);
                        try self.page_owner.visit(key, visitor);
                        try self.object_owners.all.visit(key, visitor);
                    },
                    .document => try self.document_owner.visit(key, visitor),
                    .page => try self.page_owner.visit(key, visitor),
                    .object => |owner| try self.object_owners.visit(owner, key, visitor),
                }
            },
        }
    }
};

const ScopedEntries = struct {
    any: Entries = .empty,
    concrete: std.AutoHashMapUnmanaged(ResourceScope, Entries) = .{},

    fn deinit(self: *ScopedEntries, allocator: Allocator) void {
        self.any.deinit(allocator);
        deinitValues(allocator, &self.concrete);
    }

    fn add(self: *ScopedEntries, allocator: Allocator, scope: ResourceScope, entry: WriteEntry) !void {
        if (scope == .any) return self.any.append(allocator, entry);
        const entries = try getEntryBucket(allocator, &self.concrete, scope);
        try entries.append(allocator, entry);
    }

    fn visit(self: *const ScopedEntries, scope: ResourceScope, visitor: anytype) !void {
        try visitEntries(self.any.items, visitor);
        if (scope == .any) {
            var values = self.concrete.valueIterator();
            while (values.next()) |entries| try visitEntries(entries.items, visitor);
        } else if (self.concrete.get(scope)) |entries| {
            try visitEntries(entries.items, visitor);
        }
    }
};

// Keys are the first path segment of a property.
const NamedEntries = struct {
    any: Entries = .empty,
    named: std.StringHashMapUnmanaged(Entries) = .{},

    fn deinit(self: *NamedEntries, allocator: Allocator) void {
        self.any.deinit(allocator);
        deinitValues(allocator, &self.named);
    }

    fn add(self: *NamedEntries, allocator: Allocator, name: ?[]const u8, entry: WriteEntry) !void {
        const key = name orelse return self.any.append(allocator, entry);
        const entries = try getEntryBucket(allocator, &self.named, key);
        try entries.append(allocator, entry);
    }

    fn visit(self: *const NamedEntries, name: ?[]const u8, visitor: anytype) !void {
        try visitEntries(self.any.items, visitor);
        if (name) |key| {
            if (self.named.get(key)) |entries| try visitEntries(entries.items, visitor);
        } else {
            var values = self.named.valueIterator();
            while (values.next()) |entries| try visitEntries(entries.items, visitor);
        }
    }
};

const ObjectEntries = struct {
    all: NamedEntries = .{},
    unidentified: NamedEntries = .{},
    by_identity: std.HashMapUnmanaged(ObjectIdentity, NamedEntries, IdentityContext, std.hash_map.default_max_load_percentage) = .{},

    fn deinit(self: *ObjectEntries, allocator: Allocator) void {
        self.all.deinit(allocator);
        self.unidentified.deinit(allocator);
        deinitValues(allocator, &self.by_identity);
    }

    fn add(self: *ObjectEntries, allocator: Allocator, entry: WriteEntry) !void {
        const property = entry.resource.property;
        try self.all.add(allocator, property.key.indexName(), entry);
        if (property.owner.object.identity) |identity| {
            const keys = try getBucket(allocator, &self.by_identity, identity);
            try keys.add(allocator, property.key.indexName(), entry);
        } else {
            try self.unidentified.add(allocator, property.key.indexName(), entry);
        }
    }

    fn visit(self: *const ObjectEntries, owner: dependencies.ObjectOwner, key: ?[]const u8, visitor: anytype) !void {
        if (owner.identity) |identity| {
            // A known identity also depends on writers with unknown identities.
            if (self.by_identity.getPtr(identity)) |keys| try keys.visit(key, visitor);
            try self.unidentified.visit(key, visitor);
        } else {
            try self.all.visit(key, visitor);
        }
    }
};

const IdentityContext = struct {
    pub fn hash(_: IdentityContext, identity: ObjectIdentity) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, identity.origin);
        std.hash.autoHash(&hasher, identity.local_id);
        std.hash.autoHash(&hasher, identity.scope);
        hasher.update(identity.name);
        return hasher.final();
    }

    pub fn eql(_: IdentityContext, a: ObjectIdentity, b: ObjectIdentity) bool {
        return a.eql(b);
    }
};

fn getBucket(allocator: Allocator, map: anytype, key: anytype) !@TypeOf(map.getPtr(key).?) {
    const result = try map.getOrPut(allocator, key);
    if (!result.found_existing) result.value_ptr.* = .{};
    return result.value_ptr;
}

fn getEntryBucket(allocator: Allocator, map: anytype, key: anytype) !*Entries {
    const result = try map.getOrPut(allocator, key);
    if (!result.found_existing) result.value_ptr.* = .empty;
    return result.value_ptr;
}

fn deinitValues(allocator: Allocator, map: anytype) void {
    var values = map.valueIterator();
    while (values.next()) |value| value.deinit(allocator);
    map.deinit(allocator);
}

fn visitEntries(entries: []const WriteEntry, visitor: anytype) !void {
    for (entries) |entry| try visitor.visit(entry);
}
