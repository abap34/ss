const std = @import("std");
const core = @import("core");
const Type = @import("ast").Type;

pub const ResourceKind = enum {
    variable,
    pages,
    objects,
    property,
};

pub const ObjectIdentity = struct {
    origin: enum { binding, constant, local } = .binding,
    scope: ResourceScope,
    name: []const u8,
    local_id: usize = 0,

    pub fn eql(self: ObjectIdentity, other: ObjectIdentity) bool {
        return self.origin == other.origin and self.local_id == other.local_id and resourceScopeEql(self.scope, other.scope) and std.mem.eql(u8, self.name, other.name);
    }
};

pub const ObjectOwner = struct {
    class_id: ?core.NominalId = null,
    identity: ?ObjectIdentity = null,

    pub fn eql(self: ObjectOwner, other: ObjectOwner) bool {
        if (!core.NominalId.optionalEql(self.class_id, other.class_id)) return false;
        if (self.identity) |identity| return if (other.identity) |other_identity| identity.eql(other_identity) else false;
        return other.identity == null;
    }

    pub fn intersects(self: ObjectOwner, other: ObjectOwner) bool {
        if (self.identity != null and other.identity != null) {
            return self.identity.?.eql(other.identity.?);
        }
        return (self.class_id == null or other.class_id == null or self.class_id.?.eql(other.class_id.?));
    }

    pub fn merge(self: ObjectOwner, other: ObjectOwner) ObjectOwner {
        return .{
            .class_id = if (core.NominalId.optionalEql(self.class_id, other.class_id)) self.class_id else null,
            .identity = if (self.identity != null and other.identity != null and self.identity.?.eql(other.identity.?))
                self.identity
            else
                null,
        };
    }

    pub fn isUnknown(self: ObjectOwner) bool {
        return self.class_id == null and self.identity == null;
    }
};

pub const PropertyOwner = union(enum) {
    any,
    document,
    page,
    object: ObjectOwner,

    pub fn eql(self: PropertyOwner, other: PropertyOwner) bool {
        return switch (self) {
            .any => other == .any,
            .document => other == .document,
            .page => other == .page,
            .object => |owner| other == .object and owner.eql(other.object),
        };
    }

    pub fn intersects(self: PropertyOwner, other: PropertyOwner) bool {
        return switch (self) {
            .any => true,
            .document => switch (other) {
                .any, .document => true,
                .page, .object => false,
            },
            .page => switch (other) {
                .any, .page => true,
                .document, .object => false,
            },
            .object => |left| switch (other) {
                .any => true,
                .object => |right| left.intersects(right),
                .document, .page => false,
            },
        };
    }

    pub fn merge(self: PropertyOwner, other: PropertyOwner) PropertyOwner {
        return switch (self) {
            .any => .any,
            .document => switch (other) {
                .any => .any,
                .document => .document,
                .page, .object => .any,
            },
            .page => switch (other) {
                .any => .any,
                .page => .page,
                .document, .object => .any,
            },
            .object => |left| switch (other) {
                .any => .any,
                .object => |right| .{ .object = left.merge(right) },
                .document, .page => .any,
            },
        };
    }

    pub fn isUnknown(self: PropertyOwner) bool {
        return switch (self) {
            .any => true,
            .object => |owner| owner.isUnknown(),
            .document, .page => false,
        };
    }
};

pub const PropertyKey = union(enum) {
    any,
    content,
    named: []const u8,

    const content_name = "content";

    pub fn fromName(maybe_name: ?[]const u8) PropertyKey {
        const value = maybe_name orelse return .any;
        if (std.mem.eql(u8, value, content_name)) return .content;
        return .{ .named = value };
    }

    pub fn intersects(self: PropertyKey, other: PropertyKey) bool {
        return switch (self) {
            .any => true,
            .content => switch (other) {
                .any, .content => true,
                .named => |named_value| std.mem.eql(u8, named_value, content_name),
            },
            .named => |left| switch (other) {
                .any => true,
                .content => std.mem.eql(u8, left, content_name),
                .named => |right| core.PropertyPath.intersects(left, right),
            },
        };
    }

    // Index by the first segment; exact overlap is checked by intersects.
    pub fn indexName(self: PropertyKey) ?[]const u8 {
        const name = self.displayName() orelse return null;
        return core.PropertyPath.root(name);
    }

    pub fn displayName(self: PropertyKey) ?[]const u8 {
        return switch (self) {
            .any => null,
            .content => content_name,
            .named => |value| value,
        };
    }
};

pub const ResourceScope = union(enum) {
    any,
    document: core.SourceModuleId,
    page: core.NodeId,

    pub fn intersects(self: ResourceScope, other: ResourceScope) bool {
        return switch (self) {
            .any => true,
            .document => |left| switch (other) {
                .any => true,
                .document => |right| left == right,
                .page => false,
            },
            .page => |left| switch (other) {
                .any => true,
                .document => false,
                .page => |right| left == right,
            },
        };
    }
};

pub const Resource = union(ResourceKind) {
    variable: struct {
        scope: ResourceScope,
        name: []const u8,
    },
    pages: ResourceScope,
    objects: struct {
        role: ?[]const u8 = null,
        input_type: ?Type = null,
        owner: ObjectOwner = .{},
        page_scope: ResourceScope = .any,
    },
    property: struct {
        owner: PropertyOwner,
        key: PropertyKey,
    },

    pub fn eql(self: Resource, other: Resource) bool {
        return switch (self) {
            .variable => |variable| other == .variable and resourceScopeEql(variable.scope, other.variable.scope) and std.mem.eql(u8, variable.name, other.variable.name),
            .pages => |scope| other == .pages and resourceScopeEql(scope, other.pages),
            .objects => |left| other == .objects and optionalTypeEql(left.input_type, other.objects.input_type) and optionalNameEql(left.role, other.objects.role) and left.owner.eql(other.objects.owner) and resourceScopeEql(left.page_scope, other.objects.page_scope),
            .property => |property| other == .property and property.owner.eql(other.property.owner) and optionalNameEql(property.key.displayName(), other.property.key.displayName()),
        };
    }

    pub fn intersects(self: Resource, other: Resource) bool {
        return switch (self) {
            .variable => |left| switch (other) {
                .variable => |right| left.scope.intersects(right.scope) and std.mem.eql(u8, left.name, right.name),
                else => false,
            },
            .pages => |left| switch (other) {
                .pages => |right| left.intersects(right),
                else => false,
            },
            .objects => |left| switch (other) {
                .objects => |right| blk: {
                    if ((left.input_type != null and right.role != null) or (right.input_type != null and left.role != null)) break :blk false;
                    if (left.input_type != null and right.input_type != null and !Type.eql(left.input_type.?, right.input_type.?)) break :blk false;
                    break :blk optionalNameIntersects(left.role, right.role) and left.owner.intersects(right.owner) and left.page_scope.intersects(right.page_scope);
                },
                else => false,
            },
            .property => |left| switch (other) {
                .property => |right| left.owner.intersects(right.owner) and left.key.intersects(right.key),
                else => false,
            },
        };
    }

    pub fn makeVariable(scope: ResourceScope, name: []const u8) Resource {
        return .{ .variable = .{ .scope = scope, .name = name } };
    }

    pub fn makeObjects(role_name: ?[]const u8) Resource {
        return .{ .objects = .{ .role = role_name } };
    }

    pub fn makeProperty(owner: PropertyOwner, key: ?[]const u8) Resource {
        return .{ .property = .{ .owner = owner, .key = PropertyKey.fromName(key) } };
    }

    pub fn makeContentProperty(owner: PropertyOwner) Resource {
        return .{ .property = .{ .owner = owner, .key = .content } };
    }

    pub fn makePages(page_id: ?core.NodeId) Resource {
        return .{ .pages = if (page_id) |id| .{ .page = id } else .any };
    }
};

fn optionalNameEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |value| return if (right) |other| std.mem.eql(u8, value, other) else false;
    return right == null;
}

fn resourceScopeEql(left: ResourceScope, right: ResourceScope) bool {
    return switch (left) {
        .any => right == .any,
        .document => |left_id| switch (right) {
            .document => |right_id| left_id == right_id,
            else => false,
        },
        .page => |left_id| switch (right) {
            .page => |right_id| left_id == right_id,
            else => false,
        },
    };
}

fn optionalNameIntersects(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return true;
    return std.mem.eql(u8, left.?, right.?);
}

fn optionalTypeEql(left: ?Type, right: ?Type) bool {
    if (left) |ty| return if (right) |other| Type.eql(ty, other) else false;
    return right == null;
}
