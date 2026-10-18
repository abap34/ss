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
    try testing.expect(Type.accepts(Type.selection(.any), Type.selection(.placement)));
    try testing.expect(!Type.accepts(Type.selection(.page), Type.selection(.placement)));
}

test "type spec: erased selections cannot acquire a concrete element type" {
    const erased = Type.selection(.any);
    try testing.expect(Type.accepts(erased, Type.selection(.page)));
    try testing.expect(Type.accepts(erased, Type.selection(.placement)));
    try testing.expect(!Type.accepts(Type.selection(.page), erased));
    try testing.expect(!Type.accepts(Type.selection(.placement), erased));
    var erased_result = try Type.functionType(testing.allocator, &.{}, erased);
    defer erased_result.deinit(testing.allocator);
    var placement_result = try Type.functionType(testing.allocator, &.{}, Type.selection(.placement));
    defer placement_result.deinit(testing.allocator);
    try testing.expect(!Type.accepts(placement_result, erased_result));
    try testing.expect(Type.accepts(erased_result, placement_result));
}

test "type spec: nominal values require the same declaration identity" {
    const text = Type.recordType("Text").inModule(1);
    const image = Type.recordType("Image").inModule(1);
    try testing.expect(Type.accepts(text, Type.recordType("Text").inModule(1)));
    try testing.expect(!Type.accepts(text, image));
    try testing.expect(!Type.accepts(text, text.inModule(2)));
    try testing.expect(!Type.accepts(text, Type.placement));
    try testing.expect(!Type.accepts(Type.placement, text));
}

test "type spec: selections retain exact inputs and permit only one way placement erasure" {
    var text = try Type.placedOf(testing.allocator, Type.recordType("Text").inModule(1));
    defer text.deinit(testing.allocator);
    var image = try Type.placedOf(testing.allocator, Type.recordType("Image").inModule(1));
    defer image.deinit(testing.allocator);
    var text_selection = try Type.selectionOf(testing.allocator, text);
    defer text_selection.deinit(testing.allocator);
    var image_selection = try Type.selectionOf(testing.allocator, image);
    defer image_selection.deinit(testing.allocator);
    const erased = Type.selection(.placement);
    try testing.expect(Type.accepts(text_selection, text_selection));
    try testing.expect(!Type.accepts(text_selection, image_selection));
    try testing.expect(!Type.accepts(text_selection, erased));
    try testing.expect(Type.accepts(erased, image_selection));
}

test "type spec: formatting exposes the source-level type constructor shape" {
    var maybe_color = try Type.optional(testing.allocator, Type.color);
    defer maybe_color.deinit(testing.allocator);

    try expectFormat(Type.number, "Number");
    try expectFormat(Type.color, "Color");
    try expectFormat(Type.none, "None");
    try expectFormat(Type.enumType("Align"), "Align");
    try expectFormat(maybe_color, "Color?");
    try expectFormat(Type.recordType("Text"), "Text");
    var placed = try Type.placedOf(testing.allocator, Type.recordType("Text"));
    defer placed.deinit(testing.allocator);
    var selection = try Type.selectionOf(testing.allocator, placed);
    defer selection.deinit(testing.allocator);
    try expectFormat(placed, "Placed<Text>");
    try expectFormat(selection, "Selection<Placed<Text>>");
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
    var unary = try Type.functionType(testing.allocator, &.{Type.page}, Type.placement);
    defer unary.deinit(testing.allocator);
    try expectFormat(unary, "Page -> Placement");

    var multi = try Type.functionType(testing.allocator, &.{ Type.page, Type.document }, Type.placement);
    defer multi.deinit(testing.allocator);
    try expectFormat(multi, "(Page, Document) -> Placement");

    var zero = try Type.functionType(testing.allocator, &.{}, Type.number);
    defer zero.deinit(testing.allocator);
    try expectFormat(zero, "() -> Number");

    var callback = try Type.functionType(testing.allocator, &.{Type.page}, Type.placement);
    defer callback.deinit(testing.allocator);
    var higher_order = try Type.functionType(testing.allocator, &.{callback}, Type.document);
    defer higher_order.deinit(testing.allocator);
    try expectFormat(higher_order, "(Page -> Placement) -> Document");
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
    var callback = try Type.functionType(testing.allocator, &.{Type.page}, Type.recordType("Text"));
    defer callback.deinit(testing.allocator);
    var maybe_callback = try Type.optional(testing.allocator, callback);
    defer maybe_callback.deinit(testing.allocator);

    try expectFormat(maybe_callback, "(Page -> Text)?");
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
    const borrowed = Type.selectionType(Type.recordType("Text").inModule(7));
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

test "type spec: placed inputs remain invariant while placement erasure is one way" {
    var inner = try Type.recordType("Box").inModule(4).withArguments(testing.allocator, &.{Type.number});
    defer inner.deinit(testing.allocator);
    var placed = try Type.placedOf(testing.allocator, inner);
    defer placed.deinit(testing.allocator);
    var different = try Type.placedOf(testing.allocator, inner.inModule(5));
    defer different.deinit(testing.allocator);
    try expectFormat(placed, "Placed<Box<Number>>");
    try expectFormat(Type.placement, "Placement");
    try testing.expect(Type.accepts(Type.placement, placed));
    try testing.expect(!Type.accepts(placed, Type.placement));
    try testing.expect(!Type.accepts(placed, different));
    try testing.expect(!Type.accepts(placed, inner));
    try testing.expect(!Type.accepts(inner, placed));
    var selection = try Type.selectionOf(testing.allocator, placed);
    defer selection.deinit(testing.allocator);
    try testing.expect(Type.accepts(Type.selection(.placement), selection));
    try testing.expect(!Type.accepts(selection, Type.selection(.placement)));
    var copy = try placed.clone(testing.allocator);
    defer copy.deinit(testing.allocator);
    try testing.expect(Type.eql(copy, placed));
    var a = std.hash.Wyhash.init(0);
    var b = std.hash.Wyhash.init(0);
    placed.hashInto(&a);
    copy.hashInto(&b);
    try testing.expectEqual(a.final(), b.final());
}

test "type spec: groups retain child order, arity and nested nominal types" {
    const text = Type.recordType("Text").inModule(1);
    const image = Type.recordType("Image").inModule(2);
    var pair = try (Type{ .kind = .group }).withArguments(testing.allocator, &.{ text, image });
    defer pair.deinit(testing.allocator);
    var reversed = try (Type{ .kind = .group }).withArguments(testing.allocator, &.{ image, text });
    defer reversed.deinit(testing.allocator);
    var nested = try (Type{ .kind = .group }).withArguments(testing.allocator, &.{ text, pair });
    defer nested.deinit(testing.allocator);
    var repeated = try (Type{ .kind = .group }).withArguments(testing.allocator, &.{ text, image, image });
    defer repeated.deinit(testing.allocator);
    var clone = try nested.clone(testing.allocator);
    defer clone.deinit(testing.allocator);
    try expectFormat(nested, "Group<Text, Group<Text, Image>>");
    try testing.expect(Type.eql(nested, clone));
    try testing.expect(Type.accepts(nested, clone));
    try testing.expect(!Type.accepts(pair, reversed));
    try testing.expect(!Type.accepts(pair, repeated));
    try testing.expect(!Type.accepts(pair, nested));
    try testing.expect(!Type.accepts(Type.placement, pair));
}

fn exerciseUnresolvedNames(allocator: std.mem.Allocator) !void {
    const name = Type.unresolvedNameAt("library::Box", .{ .start = 12, .end = 24 });
    var applied = try name.withArguments(allocator, &.{Type.number});
    defer applied.deinit(allocator);
    var optional = try Type.optional(allocator, applied);
    defer optional.deinit(allocator);
    var callback = try Type.functionType(allocator, &.{optional}, applied);
    defer callback.deinit(allocator);
    var cloned = try callback.clone(allocator);
    defer cloned.deinit(allocator);
    try testing.expect(Type.eql(callback, cloned));
    try testing.expect(callback.fn_params.ptr != cloned.fn_params.ptr);
    try testing.expect(callback.containsUnresolvedName());
    try testing.expect(applied.nominalId() == null);
    try testing.expect(!Type.accepts(optional, Type.none));
    try testing.expect(!Type.accepts(Type.any, callback));
    try testing.expect(!Type.accepts(callback, Type.any));
    const formatted = try callback.formatAlloc(allocator);
    defer allocator.free(formatted);
    try testing.expectEqualStrings("library::Box<Number>? -> library::Box<Number>", formatted);
}

test "type spec: unresolved source names retain structure and cannot act as semantic types" {
    const name = Type.unresolvedNameAt("Box", .{ .start = 2, .end = 5 });
    const same = Type.unresolvedNameAt("Box", .{ .start = 20, .end = 23 });
    try testing.expect(Type.eql(name, same));
    try testing.expect(!Type.eql(name, Type.unresolvedNameAt("Other", .{ .start = 2, .end = 7 })));
    try testing.expect(!Type.eql(name, Type.recordType("Box").inModule(0)));
    try testing.expect(!Type.accepts(name, same));
    const id = Type.ParameterId{ .module_id = 1, .declaration_start = 0, .index = 0 };
    var unchanged = try name.substitute(testing.allocator, &.{.{ .parameter = id, .replacement = Type.number }});
    defer unchanged.deinit(testing.allocator);
    try testing.expect(Type.eql(name, unchanged));
    try testing.checkAllAllocationFailures(testing.allocator, exerciseUnresolvedNames, .{});
}
