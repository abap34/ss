const std = @import("std");
const allocation_testing = @import("allocation_testing");
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
    const Type = compiler.language.Type;
    const input_types = [_]?Type{
        null,
        Type.recordType("Text").inModule(1),
        Type.recordType("Text").inModule(2),
        Type.recordType("Body").inModule(1),
    };
    const identities = [_]?dependencies.ObjectIdentity{
        null,
        .{ .scope = .any, .name = "title" },
        .{ .scope = .{ .document = 1 }, .name = "title" },
        .{ .scope = .{ .page = 1 }, .name = "title" },
        .{ .scope = .{ .page = 2 }, .name = "title" },
        .{ .scope = .{ .page = 1 }, .name = "body" },
        .{ .origin = .constant, .scope = .{ .document = 1 }, .name = "title" },
        .{ .origin = .local, .scope = .{ .page = 1 }, .name = "title", .local_id = 1 },
        .{ .origin = .local, .scope = .{ .page = 1 }, .name = "title", .local_id = 2 },
    };
    const keys = [_]Key{ .any, .{ .named = "background_fill" }, .{ .named = "x" }, .{ .named = "y" }, .{ .named = "layout" }, .{ .named = "layout.x" }, .{ .named = "layout.y" }, .{ .named = "layout_extra.x" }, .{ .named = "text.font" }, .{ .named = "text.font.family" } };
    var resources = std.ArrayList(Resource).empty;
    defer resources.deinit(testing.allocator);
    for (scopes) |scope| {
        try resources.append(testing.allocator, .{ .pages = scope });
        for ([_][]const u8{ "title", "body" }) |name| {
            try resources.append(testing.allocator, Resource.makeVariable(scope, name));
        }
    }
    try resources.append(testing.allocator, Resource.makeObjects());
    for ([_]Owner{ .any, .document, .page }) |owner| {
        for (keys) |key| try resources.append(testing.allocator, .{ .property = .{ .owner = owner, .key = key } });
    }
    for (identities) |identity| {
        for (input_types) |input_type| {
            for ([_]Scope{ .any, .{ .page = 1 }, .{ .page = 2 } }) |page_scope| {
                try resources.append(testing.allocator, .{ .objects = .{
                    .owner = .{ .identity = identity },
                    .input_type = input_type,
                    .page_scope = page_scope,
                } });
            }
        }
        for (keys) |key| {
            try resources.append(testing.allocator, .{ .property = .{
                .owner = .{ .object = .{ .identity = identity } },
                .key = key,
            } });
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
                .identity = .{ .scope = .{ .page = page_id }, .name = "title" },
            } }, "x"));
            try index.addWrite(count * 2 + position, Resource.makePages(page_id));
            try index.addWrite(count * 3 + position, Resource.makeProperty(.{ .object = .{
                .identity = .{ .scope = .{ .page = page_id }, .name = "other" },
            } }, "x"));
        }
        var total: usize = 0;
        for (0..count) |position| {
            const page_id: u32 = @intCast(position);
            const reads = [_]Resource{
                Resource.makeVariable(.{ .page = page_id }, "title"),
                Resource.makeProperty(.{ .object = .{
                    .identity = .{ .scope = .{ .page = page_id }, .name = "title" },
                } }, "x"),
                Resource.makePages(page_id),
                Resource.makeProperty(.{ .object = .{
                    .identity = .{ .scope = .{ .page = page_id }, .name = "other" },
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
        Resource.makeObjects(),
        Resource{ .objects = .{ .input_type = compiler.language.Type.recordType("Heading").inModule(1) } },
        Resource.makeProperty(.any, null),
        Resource.makeProperty(.document, "x"),
        Resource.makeProperty(.page, "layout_h_center_offset"),
        Resource.makeProperty(.{ .object = .{} }, "x"),
        Resource.makeProperty(.{ .object = .{ .identity = .{ .scope = .{ .page = 1 }, .name = "other" } } }, "x"),
        Resource.makeProperty(.{ .object = .{ .identity = .{ .scope = .{ .page = 1 }, .name = "title" } } }, null),
        Resource.makeProperty(.{ .object = .{
            .identity = .{ .scope = .{ .page = 2 }, .name = "title" },
        } }, "x"),
    };
    try allocation_testing.checkAllAllocationFailures(testing.allocator, verifyResourceMatrix, .{&resources});
}

test "resource index: typed subtree reads retain broad writers and exclude distinct roots and input types" {
    const Type = compiler.language.Type;
    const heading = Type.recordType("Heading").inModule(1);
    const other_heading = Type.recordType("Heading").inModule(2);
    const read: Resource = .{ .objects = .{ .input_type = heading, .placement = .{ .call = 10 } } };
    const writers = [_]Resource{
        .{ .objects = .{} },
        .{ .objects = .{ .input_type = heading } },
        .{ .objects = .{ .input_type = heading, .placement = .{ .call = 10 } } },
        .{ .objects = .{ .input_type = heading, .placement = .{ .call = 11 } } },
        .{ .objects = .{ .input_type = other_heading, .placement = .{ .call = 10 } } },
    };
    var index = resource_index.ResourceWriterIndex.init(testing.allocator);
    defer index.deinit();
    for (writers, 0..) |write, unit| try index.addWrite(unit, write);
    var seen: [writers.len]bool = undefined;
    @memset(&seen, false);
    var visitor = MatchingVisitor{ .read = read, .seen = &seen };
    try index.forEachCandidate(read, &visitor);
    try testing.expectEqualSlices(bool, &.{ true, true, true, false, false }, &seen);
}

test "resource index: direct-child depth excludes later descendants while unknown writers remain candidates" {
    const read: Resource = .{ .objects = .{ .placement = .{ .call = 10, .depth = .exact(1) } } };
    const writers = [_]Resource{
        .{ .objects = .{} },
        .{ .objects = .{ .placement = .{ .call = 10, .depth = .exact(0) } } },
        .{ .objects = .{ .placement = .{ .call = 10, .depth = .exact(1) } } },
        .{ .objects = .{ .placement = .{ .call = 10, .depth = .exact(2) } } },
        .{ .objects = .{ .placement = .{ .call = 11, .depth = .exact(1) } } },
        .{ .objects = .{ .placement = .{ .call = 10, .depth = .{ .min = 1 } } } },
    };
    var index = resource_index.ResourceWriterIndex.init(testing.allocator);
    defer index.deinit();
    for (writers, 0..) |write, unit| try index.addWrite(unit, write);
    var seen: [writers.len]bool = undefined;
    @memset(&seen, false);
    var visitor = MatchingVisitor{ .read = read, .seen = &seen };
    try index.forEachCandidate(read, &visitor);
    try testing.expectEqualSlices(bool, &.{ true, false, true, false, false, true }, &seen);
    try testing.expect(!read.eql(writers[3]));
    try allocation_testing.checkAllAllocationFailures(testing.allocator, verifyResourceMatrix, .{&writers});
}

fn verifyDisplayTreeRegions(allocator: std.mem.Allocator) !void {
    const PlacementScope = dependencies.PlacementScope;
    var plan = compiler.core.native_display.Plan{ .allocator = allocator };
    defer plan.deinit();
    const parents = [_]?usize{ null, 0, 1, 0, 3, 0, 2 };
    const paths = [_][]const usize{ &.{}, &.{0}, &.{ 0, 0 }, &.{1}, &.{ 1, 0 }, &.{2}, &.{ 0, 0, 0 } };
    for (parents, paths, 0..) |parent, path, index| {
        const target: compiler.core.native_display.Target = if (index == 4 or index == 5 or index == 6)
            .{ .native = .text }
        else
            .{ .function = .{ .module_id = 0, .name = "display" } };
        try testing.expectEqual(index, try plan.append(compiler.language.Type.recordType("Content"), target, parent));
        try testing.expectEqualSlices(usize, path, plan.steps.items[index].path);
    }
    try testing.expectEqualSlices(usize, &.{ 1, 3, 5 }, plan.steps.items[0].children.items);
    var writers: [parents.len]Resource = undefined;
    for (&writers, plan.steps.items) |*writer, step| writer.* = .{ .objects = .{ .placement = .exact(10, step.path) } };
    const root = PlacementScope.exact(10, plan.steps.items[0].path);
    const left = PlacementScope.exact(10, plan.steps.items[1].path);
    const right = PlacementScope.exact(10, plan.steps.items[3].path);
    const reads = [_]PlacementScope{ root.children(), left.children(), left.descendants(), right.descendants() };
    const expected = [_][parents.len]bool{
        .{ false, true, false, true, false, true, false },
        .{ false, false, true, false, false, false, false },
        .{ false, false, true, false, false, false, true },
        .{ false, false, false, false, true, false, false },
    };
    var index = resource_index.ResourceWriterIndex.init(allocator);
    defer index.deinit();
    for (writers, 0..) |write, unit| try index.addWrite(unit, write);
    for (reads, expected) |scope, matches| {
        const read: Resource = .{ .objects = .{ .placement = scope } };
        var seen: [parents.len]bool = undefined;
        @memset(&seen, false);
        var visitor = MatchingVisitor{ .read = read, .seen = &seen };
        try index.forEachCandidate(read, &visitor);
        try testing.expectEqualSlices(bool, &matches, &seen);
        for (writers, matches) |writer, match| {
            try testing.expectEqual(match, read.intersects(writer));
            try testing.expectEqual(match, writer.intersects(read));
        }
    }
    try verifyResourceMatrix(allocator, &writers);
}

test "resource index: display tree paths distinguish sibling subtrees and nonadjacent descendants" {
    try verifyDisplayTreeRegions(testing.allocator);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, verifyDisplayTreeRegions, .{});
}

test "placement scopes: joins preserve a common ancestor and widen different roots conservatively" {
    const PlacementScope = dependencies.PlacementScope;
    const left = PlacementScope.exact(10, &.{ 0, 1 });
    const right = PlacementScope.exact(10, &.{ 0, 2 });
    const sibling = PlacementScope.exact(10, &.{ 1, 1 });
    const joined = left.join(right);
    try testing.expectEqualSlices(usize, &.{0}, joined.path);
    try testing.expectEqual(@as(?u64, 10), joined.call);
    try testing.expectEqual(@as(usize, 2), joined.depth.min);
    try testing.expectEqual(@as(?usize, 2), joined.depth.max);
    try testing.expect(joined.intersects(left));
    try testing.expect(joined.intersects(right));
    try testing.expect(!joined.intersects(sibling));
    try testing.expect(!left.eql(right));
    const child = PlacementScope.exact(10, &.{ 0, 1, 0 });
    try testing.expect(joined.children().intersects(child));
    try testing.expect(!joined.children().intersects(left));
    const other_root = PlacementScope.exact(11, &.{ 9, 2 });
    const wide = left.join(other_root);
    try testing.expect(wide.call == null);
    try testing.expectEqual(@as(usize, 0), wide.path.len);
    for ([_]PlacementScope{ left, right, sibling, other_root }) |scope| try testing.expect(wide.intersects(scope));
    try testing.expect(!wide.intersects(child));
    try testing.expect(wide.join(.{}).eql(.{}));
}
