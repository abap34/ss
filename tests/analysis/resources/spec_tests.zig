const std = @import("std");
const compiler = @import("compiler");
const dependencies = compiler.analysis.dependencies;
const resource_index = compiler.analysis.resource_index;
const Resource = dependencies.Resource;
const Scope = dependencies.ResourceScope;
const Owner = dependencies.PropertyOwner;
const Key = dependencies.PropertyKey;
const testing = std.testing;

const MatchingVisitor = struct {
    read: Resource,
    seen: []bool,
    count: usize = 0,

    pub fn visit(self: *MatchingVisitor, entry: resource_index.WriteEntry) !void {
        try testing.expect(!self.seen[entry.unit_index]);
        self.seen[entry.unit_index] = true;
        self.count += 1;
        try testing.expect(entry.resource.intersects(self.read));
    }
};

fn verifyResourceMatrix(allocator: std.mem.Allocator, resources: []const Resource) !void {
    var index = resource_index.ResourceWriterIndex.init(allocator);
    defer index.deinit();
    for (resources, 0..) |resource, position| try index.addWrite(position, resource);
    const seen = try allocator.alloc(bool, resources.len);
    defer allocator.free(seen);
    for (resources) |read| {
        @memset(seen, false);
        var visitor = MatchingVisitor{ .read = read, .seen = seen };
        try index.forEachCandidate(read, &visitor);
        for (resources, seen) |write, found| try testing.expectEqual(write.intersects(read), found);
    }
}

test "resource index: candidates equal pairwise intersections across scopes owners and wildcards" {
    const scopes = [_]Scope{ .any, .{ .document = 1 }, .{ .document = 2 }, .{ .page = 1 }, .{ .page = 2 } };
    const classes = [_]?compiler.core.NominalId{
        null,
        .{ .module_id = 1, .name = "Text" },
        .{ .module_id = 2, .name = "Text" },
        .{ .module_id = 1, .name = "Body" },
    };
    const identities = [_]?dependencies.ObjectIdentity{
        null,
        .{ .scope = .any, .name = "title" },
        .{ .scope = .{ .document = 1 }, .name = "title" },
        .{ .scope = .{ .page = 1 }, .name = "title" },
        .{ .scope = .{ .page = 2 }, .name = "title" },
        .{ .scope = .{ .page = 1 }, .name = "body" },
    };
    const keys = [_]Key{ .any, .content, .{ .named = "content" }, .{ .named = "x" }, .{ .named = "y" } };
    var resources = std.ArrayList(Resource).empty;
    defer resources.deinit(testing.allocator);
    for (scopes) |scope| {
        try resources.append(testing.allocator, .{ .pages = scope });
        for ([_][]const u8{ "title", "body" }) |name| {
            try resources.append(testing.allocator, Resource.makeVariable(scope, name));
        }
    }
    for ([_]?[]const u8{ null, "title", "body" }) |role| {
        try resources.append(testing.allocator, Resource.makeObjects(role));
    }
    for ([_]Owner{ .any, .document, .page }) |owner| {
        for (keys) |key| try resources.append(testing.allocator, .{ .property = .{ .owner = owner, .key = key } });
    }
    for (classes) |class_id| {
        for (identities) |identity| {
            for (keys) |key| {
                try resources.append(testing.allocator, .{ .property = .{
                    .owner = .{ .object = .{ .class_id = class_id, .identity = identity } },
                    .key = key,
                } });
            }
        }
    }
    try verifyResourceMatrix(testing.allocator, resources.items);
}

test "resource index: unrelated pages and owners do not increase candidate counts" {
    for ([_]usize{ 1, 32, 128, 512 }) |count| {
        var index = resource_index.ResourceWriterIndex.init(testing.allocator);
        defer index.deinit();
        const seen = try testing.allocator.alloc(bool, count * 4);
        defer testing.allocator.free(seen);
        for (0..count) |position| {
            const page_id: u32 = @intCast(position);
            try index.addWrite(position, Resource.makeVariable(.{ .page = page_id }, "title"));
            try index.addWrite(count + position, Resource.makeProperty(.{ .object = .{
                .class_id = .{ .module_id = 1, .name = "Text" },
                .identity = .{ .scope = .{ .page = page_id }, .name = "title" },
            } }, "x"));
            try index.addWrite(count * 2 + position, Resource.makePages(page_id));
            try index.addWrite(count * 3 + position, Resource.makeProperty(.{ .object = .{
                .class_id = .{ .module_id = page_id, .name = "Shared" },
            } }, "x"));
        }
        var total: usize = 0;
        for (0..count) |position| {
            const page_id: u32 = @intCast(position);
            const reads = [_]Resource{
                Resource.makeVariable(.{ .page = page_id }, "title"),
                Resource.makeProperty(.{ .object = .{
                    .class_id = .{ .module_id = 1, .name = "Text" },
                    .identity = .{ .scope = .{ .page = page_id }, .name = "title" },
                } }, "x"),
                Resource.makePages(page_id),
                Resource.makeProperty(.{ .object = .{
                    .class_id = .{ .module_id = page_id, .name = "Shared" },
                } }, "x"),
            };
            for (reads) |read| {
                @memset(seen, false);
                var visitor = MatchingVisitor{ .read = read, .seen = seen };
                try index.forEachCandidate(read, &visitor);
                try testing.expectEqual(@as(usize, 1), visitor.count);
                total += visitor.count;
            }
        }
        try testing.expectEqual(count * 4, total);
    }
}

test "resource index: allocation failures release every partially built bucket" {
    const resources = [_]Resource{
        Resource.makeVariable(.any, "title"),
        Resource.makeVariable(.{ .page = 1 }, "title"),
        Resource.makePages(null),
        Resource.makePages(1),
        Resource.makeObjects(null),
        Resource.makeObjects("title"),
        Resource.makeProperty(.any, null),
        Resource.makeProperty(.document, "x"),
        Resource.makeContentProperty(.page),
        Resource.makeProperty(.{ .object = .{} }, "x"),
        Resource.makeProperty(.{ .object = .{ .class_id = .{ .module_id = 1, .name = "Text" } } }, "x"),
        Resource.makeProperty(.{ .object = .{ .identity = .{ .scope = .{ .page = 1 }, .name = "title" } } }, null),
        Resource.makeProperty(.{ .object = .{
            .class_id = .{ .module_id = 1, .name = "Text" },
            .identity = .{ .scope = .{ .page = 2 }, .name = "title" },
        } }, "x"),
    };
    try testing.checkAllAllocationFailures(testing.allocator, verifyResourceMatrix, .{&resources});
}
