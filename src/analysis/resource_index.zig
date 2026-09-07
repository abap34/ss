const std = @import("std");
const core = @import("core");
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
    objects: NamedEntries = .{},
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
            .objects => |role| try self.objects.add(self.allocator, role, entry),
            .property => |property| switch (property.owner) {
                .any => try self.any_owner.add(self.allocator, property.key.displayName(), entry),
                .document => try self.document_owner.add(self.allocator, property.key.displayName(), entry),
                .page => try self.page_owner.add(self.allocator, property.key.displayName(), entry),
                .object => try self.object_owners.add(self.allocator, entry),
            },
        }
    }

    pub fn forEachCandidate(self: *const ResourceWriterIndex, read: Resource, visitor: anytype) !void {
        switch (read) {
            .variable => |variable| {
                if (self.variables.getPtr(variable.name)) |scoped| try scoped.visit(variable.scope, visitor);
            },
            .pages => |scope| try self.pages.visit(scope, visitor),
            .objects => |role| try self.objects.visit(role, visitor),
            .property => |property| {
                const key = property.key.displayName();
                try self.any_owner.visit(key, visitor);
                switch (property.owner) {
                    .any => {
                        try self.document_owner.visit(key, visitor);
                        try self.page_owner.visit(key, visitor);
                        try self.object_owners.all_by_class.visit(null, key, visitor);
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

// Content and named("content") share a bucket, matching PropertyKey.intersects.
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

const ClassEntries = struct {
    any: NamedEntries = .{},
    concrete: std.HashMapUnmanaged(core.NominalId, NamedEntries, NominalContext, std.hash_map.default_max_load_percentage) = .{},

    fn deinit(self: *ClassEntries, allocator: Allocator) void {
        self.any.deinit(allocator);
        deinitValues(allocator, &self.concrete);
    }

    fn add(self: *ClassEntries, allocator: Allocator, entry: WriteEntry) !void {
        const property = entry.resource.property;
        const keys = if (property.owner.object.class_id) |class_id|
            try getBucket(allocator, &self.concrete, class_id)
        else
            &self.any;
        try keys.add(allocator, property.key.displayName(), entry);
    }

    fn visit(self: *const ClassEntries, class_id: ?core.NominalId, key: ?[]const u8, visitor: anytype) !void {
        try self.any.visit(key, visitor);
        if (class_id) |id| {
            if (self.concrete.getPtr(id)) |keys| try keys.visit(key, visitor);
        } else {
            var values = self.concrete.valueIterator();
            while (values.next()) |keys| try keys.visit(key, visitor);
        }
    }
};

const ObjectEntries = struct {
    all_by_class: ClassEntries = .{},
    unidentified_by_class: ClassEntries = .{},
    by_identity: std.HashMapUnmanaged(ObjectIdentity, NamedEntries, IdentityContext, std.hash_map.default_max_load_percentage) = .{},

    fn deinit(self: *ObjectEntries, allocator: Allocator) void {
        self.all_by_class.deinit(allocator);
        self.unidentified_by_class.deinit(allocator);
        deinitValues(allocator, &self.by_identity);
    }

    fn add(self: *ObjectEntries, allocator: Allocator, entry: WriteEntry) !void {
        try self.all_by_class.add(allocator, entry);
        const property = entry.resource.property;
        if (property.owner.object.identity) |identity| {
            const keys = try getBucket(allocator, &self.by_identity, identity);
            try keys.add(allocator, property.key.displayName(), entry);
        } else {
            try self.unidentified_by_class.add(allocator, entry);
        }
    }

    fn visit(self: *const ObjectEntries, owner: dependencies.ObjectOwner, key: ?[]const u8, visitor: anytype) !void {
        if (owner.identity) |identity| {
            // When both sides have an identity, it takes precedence over class
            // information. Only writers without an identity use class matching.
            if (self.by_identity.getPtr(identity)) |keys| try keys.visit(key, visitor);
            try self.unidentified_by_class.visit(owner.class_id, key, visitor);
        } else {
            try self.all_by_class.visit(owner.class_id, key, visitor);
        }
    }
};

const NominalContext = struct {
    pub fn hash(_: NominalContext, id: core.NominalId) u64 {
        var hasher = std.hash.Wyhash.init(id.module_id);
        hasher.update(id.name);
        return hasher.final();
    }

    pub fn eql(_: NominalContext, a: core.NominalId, b: core.NominalId) bool {
        return a.eql(b);
    }
};

const IdentityContext = struct {
    pub fn hash(_: IdentityContext, identity: ObjectIdentity) u64 {
        var hasher = std.hash.Wyhash.init(0);
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
