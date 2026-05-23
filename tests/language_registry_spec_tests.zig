const std = @import("std");
const core = @import("core");
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
    try testing.expectEqual(core.SemanticSort.string, fold.callback.?.expected_result_sort.?);

    const set_content = registry.lookupPrimitiveCall("set_content").?;
    try testing.expect(registry.primitiveEffects(set_content).contains(.WriteContent));
    try testing.expectEqual(registry.PrimitiveResultPolicy.first_arg, set_content.result_policy);

    const page_index = registry.lookupPrimitiveCall("page_index").?;
    try testing.expect(registry.primitiveEffects(page_index).contains(.ReadGraph));

    const frame_height = registry.lookupPrimitiveCall("frame_height").?;
    try testing.expect(registry.primitiveEffects(frame_height).contains(.ReadLayout));
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
    try testing.expect(registry.lookupPrimitiveCall("rewrite_text") == null);
    try testing.expect(registry.lookupPrimitiveCall("append_content") == null);
    try testing.expect(registry.lookupPrimitiveCall("clear_content") == null);
    try testing.expect(registry.lookupPrimitiveCall("set_style") == null);
}
