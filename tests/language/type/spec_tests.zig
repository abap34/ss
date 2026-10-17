const std = @import("std");
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

test "type spec: erased selections cannot acquire a concrete element type" {
    const erased = Type.selection(.any);
    try testing.expect(Type.accepts(erased, Type.selection(.page)));
    try testing.expect(Type.accepts(erased, Type.selection(.object)));
    try testing.expect(!Type.accepts(Type.selection(.page), erased));
    try testing.expect(!Type.accepts(Type.selection(.object), erased));
    var erased_result = try Type.functionType(testing.allocator, &.{}, erased);
    defer erased_result.deinit(testing.allocator);
    var object_result = try Type.functionType(testing.allocator, &.{}, Type.selection(.object));
    defer object_result.deinit(testing.allocator);
    try testing.expect(!Type.accepts(object_result, erased_result));
    try testing.expect(Type.accepts(erased_result, object_result));
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

test "type spec: function parameters are contravariant and results are covariant" {
    var maybe = try Type.optional(testing.allocator, Type.number);
    defer maybe.deinit(testing.allocator);
    var narrow = try Type.functionType(testing.allocator, &.{Type.number}, Type.number);
    defer narrow.deinit(testing.allocator);
    var broad = try Type.functionType(testing.allocator, &.{maybe}, Type.number);
    defer broad.deinit(testing.allocator);
    var optional_result = try Type.functionType(testing.allocator, &.{Type.number}, maybe);
    defer optional_result.deinit(testing.allocator);
    try testing.expect(Type.accepts(narrow, broad));
    try testing.expect(!Type.accepts(broad, narrow));
    try testing.expect(Type.accepts(optional_result, narrow));
    try testing.expect(!Type.accepts(narrow, optional_result));
}

fn typeHash(ty: Type) u64 {
    var hasher = std.hash.Wyhash.init(0);
    ty.hashInto(&hasher);
    return hasher.final();
}

test "type arguments preserve nested nominal identities and formatting" {
    var box = try Type.recordType("Box").inModule(1).withArguments(testing.allocator, &.{Type.recordType("Text").inModule(2)});
    defer box.deinit(testing.allocator);
    var selected = try Type.selectionOf(testing.allocator, box);
    defer selected.deinit(testing.allocator);
    var other_box = try Type.recordType("Box").inModule(1).withArguments(testing.allocator, &.{Type.recordType("Text").inModule(3)});
    defer other_box.deinit(testing.allocator);
    var other_selection = try Type.selectionOf(testing.allocator, other_box);
    defer other_selection.deinit(testing.allocator);

    try expectFormat(selected, "Selection<Box<Text>>");
    try testing.expect(!Type.eql(selected, other_selection));
    try testing.expect(!Type.accepts(selected, other_selection));
    try testing.expect(typeHash(selected) != typeHash(other_selection));
    try testing.expectEqual(@as(?u32, 2), selected.selectionItem().arguments[0].nominal_module_id);
}

test "type argument ownership and source spans do not affect equality or hashing" {
    const borrowed = Type.selectionType(Type.objectClass("Text").inModule(7));
    var owned = try borrowed.clone(testing.allocator);
    defer owned.deinit(testing.allocator);
    owned.mutableArguments()[0].class_name_span = .{ .start = 10, .end = 14 };
    try testing.expect(Type.eql(borrowed, owned));
    try testing.expectEqual(typeHash(borrowed), typeHash(owned));
    try testing.expect(borrowed.arguments.ptr != owned.arguments.ptr);
}

fn exerciseNestedTypeOwnership(allocator: std.mem.Allocator) !void {
    var box = try Type.recordType("Box").withArguments(allocator, &.{Type.number});
    defer box.deinit(allocator);
    var selected = try Type.selectionOf(allocator, box);
    defer selected.deinit(allocator);
    var callback = try Type.functionType(allocator, &.{selected}, box);
    defer callback.deinit(allocator);
    var maybe = try Type.optional(allocator, callback);
    defer maybe.deinit(allocator);
    var cloned = try maybe.clone(allocator);
    defer cloned.deinit(allocator);
    try testing.expect(Type.eql(maybe, cloned));
    try testing.expectEqual(typeHash(maybe), typeHash(cloned));
    try testing.expect(maybe.optional_child.?.fn_params[0].arguments.ptr != cloned.optional_child.?.fn_params[0].arguments.ptr);
    var replaced = try box.withArguments(allocator, &.{Type.string});
    defer replaced.deinit(allocator);
    try testing.expect(!Type.eql(box, replaced));
    const formatted = try cloned.formatAlloc(allocator);
    defer allocator.free(formatted);
    try testing.expectEqualStrings("(Selection<Box<Number>> -> Box<Number>)?", formatted);
}

test "nested type arguments clean up every failed allocation" {
    try testing.checkAllAllocationFailures(testing.allocator, exerciseNestedTypeOwnership, .{});
}

test "type parameters use declaration identity instead of spelling" {
    const id = Type.ParameterId{ .module_id = 1, .declaration_start = 10, .index = 0 };
    const original = Type.parameter(id, "T", .{ .start = 15, .end = 16 });
    const renamed = Type.parameter(id, "Renamed", null);
    try testing.expect(Type.eql(original, renamed));
    try testing.expectEqual(typeHash(original), typeHash(renamed));
    for ([_]Type.ParameterId{
        .{ .module_id = 2, .declaration_start = 10, .index = 0 },
        .{ .module_id = 1, .declaration_start = 20, .index = 0 },
        .{ .module_id = 1, .declaration_start = 10, .index = 1 },
    }) |other_id| {
        const other = Type.parameter(other_id, "T", null);
        try testing.expect(!Type.eql(original, other));
        try testing.expect(!Type.accepts(original, other));
        try testing.expect(typeHash(original) != typeHash(other));
    }
    try testing.expect(!Type.accepts(original, Type.any));
    try testing.expect(!Type.accepts(Type.any, original));
    try expectFormat(original, "T");
}

fn exerciseTypeSubstitution(allocator: std.mem.Allocator) !void {
    const id = Type.ParameterId{ .module_id = 1, .declaration_start = 10, .index = 0 };
    const param = Type.parameter(id, "T", null);
    var box = try Type.recordType("Box").inModule(2).withArguments(allocator, &.{param});
    defer box.deinit(allocator);
    var selection = try Type.selectionOf(allocator, box);
    defer selection.deinit(allocator);
    var maybe = try Type.optional(allocator, selection);
    defer maybe.deinit(allocator);
    var callback = try Type.functionType(allocator, &.{maybe}, box);
    defer callback.deinit(allocator);
    var result = try callback.substitute(allocator, &.{.{ .parameter = id, .replacement = Type.number }});
    defer result.deinit(allocator);
    try testing.expect(callback.containsParameter());
    try testing.expect(!result.containsParameter());
    try testing.expectEqual(Type.Kind.number, result.fn_result.?.arguments[0].kind);
    try testing.expectEqual(@as(?u32, 2), result.fn_result.?.nominal_module_id);
    try testing.expectEqual(Type.Kind.number, result.fn_params[0].optional_child.?.selectionItem().arguments[0].kind);
    try testing.expectEqual(Type.Kind.parameter, callback.fn_result.?.arguments[0].kind);
}

test "type substitution traverses nested arguments optional and function types" {
    try testing.checkAllAllocationFailures(testing.allocator, exerciseTypeSubstitution, .{});
}

test "type substitution preserves free parameters and does not capture replacement parameters" {
    const first = Type.ParameterId{ .module_id = 1, .declaration_start = 10, .index = 0 };
    const second = Type.ParameterId{ .module_id = 1, .declaration_start = 20, .index = 0 };
    const t = Type.parameter(first, "T", null);
    const other_t = Type.parameter(second, "T", null);
    var result = try t.substitute(testing.allocator, &.{
        .{ .parameter = first, .replacement = other_t },
        .{ .parameter = second, .replacement = Type.number },
    });
    defer result.deinit(testing.allocator);
    try testing.expect(Type.eql(result, other_t));
    var free = try other_t.substitute(testing.allocator, &.{.{ .parameter = first, .replacement = Type.number }});
    defer free.deinit(testing.allocator);
    try testing.expect(Type.eql(free, other_t));
}

test "rigid type parameters still support optional lifting" {
    const param = Type.parameter(.{ .module_id = 1, .declaration_start = 10, .index = 0 }, "T", null);
    var optional = try Type.optional(testing.allocator, param);
    defer optional.deinit(testing.allocator);
    try testing.expect(Type.accepts(optional, param));
    try testing.expect(Type.accepts(optional, Type.none));
    try testing.expect(!Type.accepts(param, optional));
}
