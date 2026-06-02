const std = @import("std");
const registry = @import("registry");
const Type = @import("language_type").Type;

const testing = std.testing;

test "language registry spec: primitive names are unique" {
    const descriptors = registry.primitiveDescriptors();
    for (descriptors, 0..) |left, left_index| {
        for (descriptors[left_index + 1 ..]) |right| {
            try testing.expect(!std.mem.eql(u8, left.name, right.name));
            try testing.expect(left.op != right.op);
        }
    }
}

test "language registry spec: semantic contracts live on primitive descriptors" {
    const foreach = registry.lookupPrimitiveCall("foreach").?;
    try testing.expect(foreach.callback != null);
    try testing.expectEqual(@as(usize, 1), foreach.callback.?.function_arg_index);
    try testing.expectEqual(@as(usize, 1), foreach.callback.?.supplied_arg_count);
    try testing.expectEqual(registry.PrimitiveResultPolicy.first_arg, foreach.result_policy);

    const fold = registry.lookupPrimitiveCall("fold").?;
    try testing.expect(fold.callback != null);
    try testing.expectEqual(@as(usize, 2), fold.callback.?.function_arg_index);
    try testing.expectEqual(@as(usize, 2), fold.callback.?.supplied_arg_count);
    try testing.expect(Type.eql(Type.string, fold.callback.?.expected_result_type.?));

    const set_content = registry.lookupPrimitiveCall("set_content").?;
    try testing.expect(Type.eql(Type.object, registry.primitiveResultType(set_content).?));
    try testing.expectEqual(registry.PrimitiveResultPolicy.first_arg, set_content.result_policy);

    const page_index = registry.lookupPrimitiveCall("page_index").?;
    try testing.expect(Type.eql(Type.page, registry.primitiveArgType(page_index, 0).?));

    const frame_height = registry.lookupPrimitiveCall("frame_height").?;
    try testing.expect(Type.eql(Type.number, registry.primitiveResultType(frame_height).?));

    const logical_not = registry.lookupPrimitiveCall("not").?;
    try testing.expect(Type.eql(Type.boolean, registry.primitiveArgType(logical_not, 0).?));
    try testing.expect(Type.eql(Type.boolean, registry.primitiveResultType(logical_not).?));
}

test "language registry spec: query output types are declared in the registry" {
    const pages = registry.lookupQueryOp("document_pages").?;
    try testing.expect(Type.eql(Type.selection(.page), registry.queryOutputType(pages)));

    const objects = registry.lookupQueryOp("page_objects_by_role").?;
    try testing.expect(Type.eql(Type.selection(.object), registry.queryOutputType(objects)));

    const metadata = registry.lookupPrimitiveCall("metadata_in_document").?;
    try testing.expect(Type.eql(Type.selection(.metadata), registry.primitiveResultType(metadata).?));
}

test "language registry spec: stdlib helpers are not kernel primitives" {
    try testing.expect(registry.lookupPrimitiveCall("rewrite") == null);
    try testing.expect(registry.lookupPrimitiveCall("append") == null);
    try testing.expect(registry.lookupPrimitiveCall("clear") == null);
    try testing.expect(registry.lookupPrimitiveCall("sty") == null);
}
