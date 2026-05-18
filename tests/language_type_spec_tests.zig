const std = @import("std");
const model = @import("model");
const Type = @import("language_type").Type;

const testing = std.testing;

fn expectFormat(ty: Type, expected: []const u8) !void {
    const actual = try ty.formatAlloc(testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "type spec: any is the explicit wildcard in acceptance checks" {
    try testing.expect(Type.accepts(Type.any, Type.number));
    try testing.expect(Type.accepts(Type.string, Type.any));
    try testing.expect(Type.accepts(Type.selection(.any), Type.selection(.page)));
    try testing.expect(Type.accepts(Type.selection(.any), Type.selection(.object)));
    try testing.expect(!Type.accepts(Type.selection(.page), Type.selection(.object)));
}

test "type spec: residual code values are consumable at their inner runtime sort" {
    try testing.expect(Type.accepts(Type.number, Type.code(.number)));
    try testing.expect(Type.accepts(Type.page, Type.code(.page)));
    try testing.expect(!Type.accepts(Type.string, Type.code(.number)));
    try testing.expect(!Type.accepts(Type.number, Type.code(.any)));
}

test "type spec: object class names refine only when both sides specify a class" {
    const text = Type.objectClass("Text");
    const image = Type.objectClass("Image");

    try testing.expect(Type.accepts(text, Type.objectClass("Text")));
    try testing.expect(!Type.accepts(text, image));
    try testing.expect(Type.accepts(text, Type.object));
    try testing.expect(Type.accepts(Type.object, image));
}

test "type spec: selection item class names follow object class refinement" {
    const text_selection = Type.selectionType(Type.objectClass("Text"));
    const image_selection = Type.selectionType(Type.objectClass("Image"));
    const unclassified_object_selection = Type.selection(.object);

    try testing.expect(Type.accepts(text_selection, Type.selectionType(Type.objectClass("Text"))));
    try testing.expect(!Type.accepts(text_selection, image_selection));
    try testing.expect(Type.accepts(text_selection, unclassified_object_selection));
    try testing.expect(Type.accepts(unclassified_object_selection, image_selection));
}

test "type spec: runtime sort conversion is defined only for runtime semantic sorts" {
    try testing.expectEqual(.number, Type.number.toRuntimeSort().?);
    try testing.expectEqual(.fragment, Type.fragment(.page).toRuntimeSort().?);
    try testing.expectEqual(@as(?model.SemanticSort, null), Type.any.toRuntimeSort());
    try testing.expectEqual(@as(?model.SemanticSort, null), Type.list(.number).toRuntimeSort());
}

test "type spec: formatting exposes the source-level type constructor shape" {
    try expectFormat(Type.number, "number");
    try expectFormat(Type.objectClass("Text"), "object<Text>");
    try expectFormat(Type.selectionType(Type.objectClass("Text")), "selection<object<Text>>");
    try expectFormat(Type.fragment(.page), "fragment<page>");
    try expectFormat(Type.code(.number), "code<number>");
    try expectFormat(Type.list(.string), "list<string>");
}
