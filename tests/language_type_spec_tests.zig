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

test "type spec: value tag conversion covers concrete value types" {
    try testing.expectEqual(.document, Type.document.toValueTag().?);
    try testing.expectEqual(.page, Type.page.toValueTag().?);
    try testing.expectEqual(.object, Type.object.toValueTag().?);
    try testing.expectEqual(.selection, Type.selection(.object).toValueTag().?);
    try testing.expectEqual(.number, Type.number.toValueTag().?);
    try testing.expectEqual(.string, Type.color.toValueTag().?);
    try testing.expectEqual(.string, Type.enumType("Align").toValueTag().?);
    try testing.expectEqual(.none, Type.none.toValueTag().?);
    try testing.expectEqual(.void, (Type{ .tag = .void }).toValueTag().?);
    try testing.expectEqual(@as(?model.ValueTag, null), Type.any.toValueTag());
}

test "type spec: formatting exposes the source-level type constructor shape" {
    var maybe_color = try Type.optional(testing.allocator, Type.color);
    defer maybe_color.deinit(testing.allocator);

    try expectFormat(Type.number, "Number");
    try expectFormat(Type.color, "Color");
    try expectFormat(Type.none, "None");
    try expectFormat(Type.enumType("Align"), "Align");
    try expectFormat(maybe_color, "Color?");
    try expectFormat(Type.objectClass("Text"), "Object<Text>");
    try expectFormat(Type.selectionType(Type.objectClass("Text")), "Selection<Object<Text>>");
}

test "type spec: optional acceptance covers none and the child type" {
    var maybe_color = try Type.optional(testing.allocator, Type.color);
    defer maybe_color.deinit(testing.allocator);
    var maybe_align = try Type.optional(testing.allocator, Type.enumType("Align"));
    defer maybe_align.deinit(testing.allocator);

    try testing.expect(Type.accepts(maybe_color, Type.none));
    try testing.expect(Type.accepts(maybe_color, Type.color));
    try testing.expect(Type.accepts(maybe_color, maybe_color));
    try testing.expect(!Type.accepts(Type.color, Type.none));
    try testing.expect(!Type.accepts(maybe_color, Type.string));
    try testing.expect(Type.accepts(maybe_align, Type.none));
    try testing.expect(Type.accepts(maybe_align, Type.enumType("Align")));
    try testing.expect(!Type.accepts(maybe_align, Type.enumType("Other")));
    try testing.expect(!Type.accepts(Type.enumType("Align"), maybe_align));
}

test "type spec: enum and color are not plain strings statically" {
    try testing.expect(Type.accepts(Type.color, Type.color));
    try testing.expect(!Type.accepts(Type.color, Type.string));
    try testing.expect(!Type.accepts(Type.string, Type.color));
    try testing.expect(Type.accepts(Type.enumType("Align"), Type.enumType("Align")));
    try testing.expect(!Type.accepts(Type.enumType("Align"), Type.enumType("Mode")));
    try testing.expect(!Type.accepts(Type.string, Type.enumType("Align")));
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

test "type spec: optional function types preserve their child shape" {
    var callback = try Type.functionType(testing.allocator, &.{Type.page}, Type.objectClass("Text"));
    defer callback.deinit(testing.allocator);
    var maybe_callback = try Type.optional(testing.allocator, callback);
    defer maybe_callback.deinit(testing.allocator);

    try expectFormat(maybe_callback, "(Page -> Object<Text>)?");
    try testing.expect(Type.accepts(maybe_callback, Type.none));
    try testing.expect(Type.accepts(maybe_callback, callback));
    try testing.expect(!Type.accepts(callback, maybe_callback));
}
