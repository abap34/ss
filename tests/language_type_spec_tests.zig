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
    try expectFormat(Type.number, "Number");
    try expectFormat(Type.objectClass("Text"), "Object<Text>");
    try expectFormat(Type.selectionType(Type.objectClass("Text")), "Selection<Object<Text>>");
    try expectFormat(Type.fragment(.page), "Fragment<Page>");
    try expectFormat(Type.code(.number), "Code<Number>");
    try expectFormat(Type.list(.string), "List<String>");
}

test "type spec: function types format as source-level arrows" {
    var unary = try Type.functionType(testing.allocator, &.{Type.page}, Type.object);
    defer unary.deinit(testing.allocator);
    try expectFormat(unary, "Page -> Object");

    var multi = try Type.functionType(testing.allocator, &.{ Type.page, Type.document }, Type.object);
    defer multi.deinit(testing.allocator);
    try expectFormat(multi, "(Page, Document) -> Object");

    var zero = try Type.functionType(testing.allocator, &.{}, Type.number);
    defer zero.deinit(testing.allocator);
    try expectFormat(zero, "() -> Number");

    var callback = try Type.functionType(testing.allocator, &.{Type.page}, Type.object);
    defer callback.deinit(testing.allocator);
    var higher_order = try Type.functionType(testing.allocator, &.{callback}, Type.document);
    defer higher_order.deinit(testing.allocator);
    try expectFormat(higher_order, "(Page -> Object) -> Document");
}

test "type spec: function acceptance checks parameters and result types" {
    var number_to_number = try Type.functionType(testing.allocator, &.{Type.number}, Type.number);
    defer number_to_number.deinit(testing.allocator);
    var number_to_string = try Type.functionType(testing.allocator, &.{Type.number}, Type.string);
    defer number_to_string.deinit(testing.allocator);
    var string_to_number = try Type.functionType(testing.allocator, &.{Type.string}, Type.number);
    defer string_to_number.deinit(testing.allocator);
    var binary_number = try Type.functionType(testing.allocator, &.{ Type.number, Type.number }, Type.number);
    defer binary_number.deinit(testing.allocator);

    try testing.expect(Type.accepts(number_to_number, number_to_number));
    try testing.expect(!Type.accepts(number_to_number, number_to_string));
    try testing.expect(!Type.accepts(number_to_number, string_to_number));
    try testing.expect(!Type.accepts(number_to_number, binary_number));
}
