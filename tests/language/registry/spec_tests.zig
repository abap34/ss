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

    const foreach_enumerate = registry.lookupPrimitiveCall("foreach_enumerate").?;
    try testing.expect(foreach_enumerate.callback != null);
    try testing.expectEqual(@as(usize, 1), foreach_enumerate.callback.?.function_arg_index);
    try testing.expectEqual(@as(usize, 2), foreach_enumerate.callback.?.supplied_arg_count);
    try testing.expectEqual(registry.PrimitiveResultPolicy.first_arg, foreach_enumerate.result_policy);

    const filter = registry.lookupPrimitiveCall("selection_filter").?;
    try testing.expectEqual(registry.PrimitiveResultPolicy.first_arg, filter.result_policy);
    try testing.expectEqual(@as(usize, 1), filter.callback.?.function_arg_index);
    try testing.expectEqual(@as(usize, 1), filter.callback.?.supplied_arg_count);
    try testing.expect(Type.eql(Type.boolean, filter.callback.?.expected_result_type.?));

    const fold = registry.lookupPrimitiveCall("fold").?;
    try testing.expect(fold.callback != null);
    try testing.expectEqual(@as(usize, 2), fold.callback.?.function_arg_index);
    try testing.expectEqual(@as(usize, 2), fold.callback.?.supplied_arg_count);
    try testing.expect(fold.callback.?.expected_result_type == null);
    try testing.expectEqual(registry.PrimitiveResultPolicy.argument_type, fold.result_policy);
    try testing.expectEqual(@as(usize, 1), fold.result_arg_index);

    const page_index = registry.lookupPrimitiveCall("page_index").?;
    try testing.expect(Type.eql(Type.page, registry.primitiveArgType(page_index, 0).?));

    for ([_][]const u8{ "frame_x", "frame_y", "frame_width", "frame_height" }) |name| {
        const frame = registry.lookupPrimitiveCall(name).?;
        try testing.expect(Type.eql(Type.placement, registry.primitiveArgType(frame, 0).?));
        try testing.expect(Type.eql(Type.number, registry.primitiveResultType(frame).?));
    }

    const logical_not = registry.lookupPrimitiveCall("not").?;
    try testing.expect(Type.eql(Type.boolean, registry.primitiveArgType(logical_not, 0).?));
    try testing.expect(Type.eql(Type.boolean, registry.primitiveResultType(logical_not).?));
}

test "language registry spec: query output types are declared in the registry" {
    const pages = registry.lookupQueryOp("document_pages").?;
    try testing.expect(Type.eql(Type.selection(.page), registry.queryOutputType(pages)));

    for ([_][]const u8{ "children", "descendants", "self_placement" }) |name| {
        const query = registry.lookupQueryOp(name).?;
        try testing.expect(Type.eql(Type.placement, registry.queryInputType(query)));
        try testing.expect(Type.eql(Type.selection(.placement), registry.queryOutputType(query)));
        try testing.expectEqual(std.mem.eql(u8, name, "self_placement"), query.preserves_input_type);
    }

    const previous = registry.lookupQueryOp("previous_page").?;
    const previous_type = registry.queryOutputType(previous);
    try testing.expectEqual(Type.Kind.optional, previous_type.kind);
    try testing.expect(Type.eql(Type.page, previous_type.optional_child.?.*));
    try testing.expect(registry.lookupQueryOp("self_object") == null);
    try testing.expect(registry.lookupQueryOp("parent_page") == null);
    try testing.expect(registry.lookupQueryOp("page_objects_by_role") == null);
    try testing.expect(registry.lookupQueryOp("document_objects_by_role") == null);
}

test "language registry spec: stdlib helpers are not kernel primitives" {
    try testing.expect(registry.lookupPrimitiveCall("rewrite") == null);
    try testing.expect(registry.lookupPrimitiveCall("append") == null);
    try testing.expect(registry.lookupPrimitiveCall("clear") == null);
    try testing.expect(registry.lookupPrimitiveCall("sty") == null);
}

test "language registry spec: legacy object primitives are unavailable" {
    for ([_][]const u8{ "new", "content", "prop", "has_prop", "prop_eq", "set_content", "set_prop" }) |name| {
        try testing.expect(registry.lookupPrimitiveCall(name) == null);
    }
    const group = registry.lookupPrimitiveCall("group").?;
    try testing.expect(registry.primitiveAllowsDisplayEvaluation(group.op));
    try testing.expectEqual(Type.Kind.group, registry.primitiveResultType(group).?.kind);
    const place = registry.lookupPrimitiveCall("place_on!").?;
    try testing.expectEqual(registry.PrimitiveResultPolicy.placement, place.result_policy);
    try testing.expect(Type.eql(Type.placement, registry.primitiveResultType(place).?));
}
