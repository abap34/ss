const std = @import("std");
const allocation_testing = @import("allocation_testing");
const compiler = @import("compiler");
const core = compiler.core;
const Type = compiler.language.Type;
const testing = std.testing;

const ExerciseOptions = struct {
    diagnostic: ?[]const u8 = null,
    verify: ?*const fn (*core.DocumentState) anyerror!void = null,
};

fn exercise(source: []const u8, first: []const u8, second: []const u8, expected_diagnostic: ?[]const u8) !void {
    return exerciseWithOptions(source, first, second, .{ .diagnostic = expected_diagnostic });
}

fn exerciseWithOptions(source: []const u8, first: []const u8, second: []const u8, options: ExerciseOptions) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const path = try std.fs.path.join(allocator, &.{ root, "main.ss" });
    var overlay = compiler.module_loader.SourceOverlay.init(allocator);
    defer overlay.deinit();
    try overlay.put(try std.fs.path.join(allocator, &.{ root, "a.ss" }), first);
    try overlay.put(try std.fs.path.join(allocator, &.{ root, "b.ss" }), second);
    var source_buf = try allocator.dupe(u8, source);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, source_buf, path);
    var modules = try compiler.analysis.loadModuleIndex(allocator, testing.io, root, syntax, .{ .overlay = &overlay });
    defer modules.deinit();
    var state = try compiler.analysis.buildDocumentStateWithOptions(allocator, path, root, &source_buf, &syntax, &modules, .{});
    defer state.deinit();
    errdefer for (state.diagnostics.entries.items) |diagnostic| {
        if (diagnostic.data == .user_report) std.debug.print("{f}: {s}\n", .{ diagnostic.origin orelse core.SourceOrigin{}, diagnostic.data.user_report.message });
    };
    if (options.diagnostic) |expected| {
        compiler.analysis.analyzeDocumentState(allocator, &state) catch {};
        for (state.diagnostics.entries.items) |diagnostic| {
            if (diagnostic.data == .user_report and std.mem.eql(u8, diagnostic.code(), std.mem.trimEnd(u8, expected, ":"))) return;
        }
        return error.ExpectedDiagnostic;
    }
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    if (options.verify) |verify| try verify(&state);
    for (state.diagnostics.entries.items) |diagnostic| {
        if (diagnostic.severity == .@"error") return error.UnexpectedDiagnostic;
    }
}

const number_record =
    \\type Style {
    \\  value: Number = 12
    \\}
    \\type Box {
    \\  style: Style = Style {}
    \\}
    \\fn make() -> Box
    \\  return Box {}
    \\end
    \\fn accept(value: Style) -> Number
    \\  return value.value
    \\end
;

const string_record =
    \\type Style {
    \\  value: String = "second"
    \\}
    \\type Box {
    \\  style: Style = Style {}
    \\}
    \\fn make() -> Box
    \\  return Box {}
    \\end
    \\fn accept(value: Style) -> String
    \\  return value.value
    \\end
;

test "nominal records: imported declarations and nested defaults ignore import order" {
    const body =
        \\page main
        \\  let first: a::Box = a::make() with { style.value = 24 }
        \\  let second: b::Box = b::make() with { style.value = "changed" }
        \\  let number: Number = a::accept(first.style)
        \\  text!(b::accept(second.style))
        \\  text!(b::accept(b::Style {}))
        \\end
    ;
    try exercise("import \"a\" as a\nimport \"b\" as b\n" ++ body, number_record, string_record, null);
    try exercise("import \"b\" as b\nimport \"a\" as a\n" ++ body, number_record, string_record, null);
}

test "nominal records: aliases do not expose unqualified type names" {
    try exercise(
        \\import "a" as a
        \\page main
        \\  let invalid = Box {}
        \\end
    , number_record, "", "UnknownType:");
}

test "nominal records: identical shapes from different modules are not assignable" {
    try exercise(
        \\import "a" as a
        \\import "b" as b
        \\page main
        \\  let wrong: a::Box = b::make()
        \\end
    , number_record, number_record, "TypeMismatch:");
}

test "nominal enums: qualified cases and function contracts retain the defining module" {
    const first =
        \\enum Mode { first }
        \\fn accept(value: Mode) -> String
        \\  return "first"
        \\end
    ;
    const second =
        \\enum Mode { second }
        \\fn accept(value: Mode) -> String
        \\  return "second"
        \\end
    ;
    const body =
        \\page main
        \\  text!(a::accept(a::Mode.first))
        \\  text!(b::accept(b::Mode.second))
        \\end
    ;
    try exercise("import \"a\" as a\nimport \"b\" as b\n" ++ body, first, second, null);
    try exercise("import \"b\" as b\nimport \"a\" as a\n" ++ body, first, second, null);
    try exercise(
        \\import "a" as a
        \\import "b" as b
        \\page main
        \\  text!(a::accept(b::Mode.first))
        \\end
    , first, first, "TypeMismatch:");
}

test "nominal enums: invalid record syntax keeps its qualified declaration" {
    try exercise(
        \\import "a" as a
        \\type Mode {
        \\  value: Number = 0
        \\}
        \\page main
        \\  let invalid = a::Mode {}
        \\end
    , "enum Mode { first }", "", "InvalidTypeConstruction:");
}

test "nominal values: placed inputs and nested updates preserve the defining module" {
    try exercise(
        \\import "a" as a
        \\import "b" as b
        \\page main
        \\  let first = place!(a::Caption {} with { style.value = 23 })
        \\  let second = place!(b::Caption {} with { style.value = "updated" })
        \\  let number: Number = a::accept(first.value.style)
        \\  text!(b::accept(second.value.style))
        \\end
    , number_record ++ "\n" ++
        \\type Caption { style: Style = Style {} }
        \\fn display(self: Placed<Caption>) -> Text = text("Caption")
    , string_record ++ "\n" ++
        \\type Caption { style: Style = Style {} }
        \\fn display(self: Placed<Caption>) -> Text = text("Caption")
    , null);
}

test "nominal records: primitive contracts refer to their declared module" {
    try exercise(
        \\type PathCommand {
        \\  verb: PathVerb = PathVerb.move
        \\  x: Number = 0
        \\  y: Number = 0
        \\}
        \\page main
        \\  let valid = path(move_to(0, 0), line_to(1, 1))
        \\end
    , "", "", null);
    try exercise(
        \\type PathCommand {
        \\  verb: PathVerb = PathVerb.move
        \\  x: Number = 0
        \\  y: Number = 0
        \\}
        \\page main
        \\  let invalid = path(PathCommand {})
        \\end
    , "", "", "TypeMismatch:");
}

test "nominal types: identity survives optional and function type cloning" {
    const a = Type.recordType("Style").inModule(1);
    const b = Type.recordType("Style").inModule(2);
    try testing.expect(!Type.eql(a, b));
    try testing.expect(!Type.accepts(a, b));
    var optional = try Type.optional(testing.allocator, a);
    defer optional.deinit(testing.allocator);
    try testing.expect(Type.accepts(optional, a));
    try testing.expect(!Type.accepts(optional, b));
    var function = try Type.functionType(testing.allocator, &.{optional}, a);
    defer function.deinit(testing.allocator);
    var clone = try function.clone(testing.allocator);
    defer clone.deinit(testing.allocator);
    try testing.expect(Type.eql(function, clone));
    clone.fn_result.?.nominal_module_id = 2;
    try testing.expect(!Type.eql(function, clone));
    try testing.expect(!Type.accepts(function, clone));
}

test "nominal values: tagged defaults and clones retain nested identities" {
    const allocator = testing.allocator;
    var record = core.RecordValue.init(Type.recordType("Style").inModule(1));
    defer record.deinit(allocator);
    try record.fields.append(allocator, .{
        .name = "mode",
        .value = .{ .enum_case = .{ .enum_name = "Mode", .module_id = 2, .case_name = "first" } },
    });
    var clone = try record.clone(allocator);
    defer clone.deinit(allocator);
    try testing.expectEqual(@as(?u32, 1), clone.ty.nominal_module_id);
    const text = try core.value_text.propertyString(allocator, .{ .record = clone });
    defer allocator.free(text);
    var parsed = try core.value_text.typedPropertyValue(allocator, text, Type.recordType("Style").inModule(1));
    defer core.value_text.deinitParsedPropertyValue(allocator, &parsed);
    try testing.expectEqual(@as(?u32, 1), parsed.record.ty.nominal_module_id);
    try testing.expectEqual(@as(?u32, 2), parsed.record.field("mode").?.enum_case.module_id);
    try testing.expectError(error.InvalidValueTag, core.value_text.typedPropertyValue(allocator, text, Type.recordType("Style").inModule(2)));
}

fn cloneNestedTypes(allocator: std.mem.Allocator) !void {
    var record = Type.recordType("Style").inModule(1);
    const optional = Type{ .kind = .optional, .optional_child = &record };
    var function = try Type.functionType(allocator, &.{ optional, optional }, optional);
    defer function.deinit(allocator);
    try testing.expect(Type.eql(optional, function.fn_params[1]));
}

test "nominal types: partially cloned function parameters are released on allocation failure" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, cloneNestedTypes, .{});
}

const first_placed =
    \\type Base { amount: Number = 12 }
    \\type Box { base: Base = Base {} }
    \\fn make() -> Box = Box {}
    \\fn/! box() -> Box = make()
    \\fn display(self: Placed<Box>) -> Text = text(str(self.value.base.amount))
    \\fn accept(value: Placed<Box>) -> Number = value.value.base.amount
;
const second_placed =
    \\type Base { amount: String = "second" }
    \\type Box { base: Base = Base {} }
    \\fn make() -> Box = Box {}
    \\fn/! box() -> Box = make()
    \\fn display(self: Placed<Box>) -> Text = text(self.value.base.amount)
    \\fn accept(value: Placed<Box>) -> String = value.value.base.amount
;

test "nominal placements: nested inputs and function arguments ignore import order" {
    const body =
        \\page main
        \\  let first: Placed<a::Box> = place!(a::make() with { base.amount = 24 })
        \\  let second: Placed<b::Box> = place!(b::make() with { base.amount = "changed" })
        \\  let amount: Number = a::accept(first)
        \\  text!(b::accept(second))
        \\end
    ;
    try exercise("import \"a\" as a\nimport \"b\" as b\n" ++ body, first_placed, second_placed, null);
    try exercise("import \"b\" as b\nimport \"a\" as a\n" ++ body, first_placed, second_placed, null);
}

test "nominal placements: same named imported inputs are not interchangeable" {
    try exercise(
        \\import "a" as a
        \\import "b" as b
        \\page main
        \\  let invalid: Placed<a::Box> = b::box!()
        \\end
    , first_placed, second_placed, "TypeMismatch:");
    try exercise(
        \\import "a" as a
        \\page main
        \\  let invalid: Box = a::make()
        \\end
    , first_placed, "", "UnknownType:");
}

test "nominal values: qualified nested updates preserve both modules and their defaults" {
    try exerciseWithOptions(
        \\import "a" as a
        \\import "b" as b
        \\page main
        \\  place!(a::make() with { base.amount = 35 })
        \\  place!(b::make() with { base.amount = "updated" })
        \\  a::box!()
        \\  b::box!()
        \\end
    , first_placed, second_placed, .{ .verify = struct {
        fn verify(state: *core.DocumentState) !void {
            const roots = state.placementRootsOf(state.graph.page_order.items[0]);
            try testing.expectEqual(@as(usize, 4), roots.len);
            const a_type = state.getNode(roots[0]).?.placement.?.value.record.ty;
            const b_type = state.getNode(roots[1]).?.placement.?.value.record.ty;
            try testing.expect(!Type.eql(a_type, b_type));
            for (roots, 0..) |root, index| {
                const value = state.getNode(root).?.placement.?.value.record;
                try testing.expect(Type.eql(if (index % 2 == 0) a_type else b_type, value.ty));
                const base = value.field("base").?.record;
                try testing.expectEqual(value.ty.nominal_module_id, base.ty.nominal_module_id);
                const amount = base.field("amount").?;
                switch (index) {
                    0 => try testing.expectEqual(@as(f32, 35), amount.number),
                    1 => try testing.expectEqualStrings("updated", amount.string),
                    2 => try testing.expectEqual(@as(f32, 12), amount.number),
                    3 => try testing.expectEqualStrings("second", amount.string),
                    else => unreachable,
                }
            }
        }
    }.verify });
}

test "nominal values: a shadowing type name does not capture its imported field type" {
    try exercise(
        \\import "a" as a
        \\type Base { parent: a::Base = a::Base {} }
        \\page main
        \\  let child = Base {}
        \\  let number: Number = child.parent.amount
        \\end
    , first_placed, "", null);
}

test "nominal placements: selections retain their input declaration module" {
    var first = try Type.placedOf(testing.allocator, Type.recordType("Box").inModule(1));
    defer first.deinit(testing.allocator);
    var second = try Type.placedOf(testing.allocator, Type.recordType("Box").inModule(2));
    defer second.deinit(testing.allocator);
    var selection = try Type.selectionOf(testing.allocator, first);
    defer selection.deinit(testing.allocator);
    var other_selection = try Type.selectionOf(testing.allocator, second);
    defer other_selection.deinit(testing.allocator);
    try testing.expect(!Type.eql(first, second));
    try testing.expect(!Type.accepts(first, second));
    try testing.expect(!Type.eql(selection, other_selection));
    try testing.expect(!Type.accepts(selection, other_selection));
    var cloned = try selection.clone(testing.allocator);
    defer cloned.deinit(testing.allocator);
    try testing.expect(selection.selectionItem().placedInput().?.nominalId().?.eql(cloned.selectionItem().placedInput().?.nominalId().?));
}

test "nominal placements: erased receivers do not select an arbitrary input field" {
    try exercise(
        \\import "a" as a
        \\import "b" as b
        \\fn read(value: Placement) -> String
        \\  return value.amount
        \\end
    , first_placed, second_placed, "UnknownField:");
}

test "nominal placements: erasure cannot defer incompatible input arguments to evaluation" {
    try exercise(
        \\import "a" as a
        \\import "b" as b
        \\fn erase(value: Placed<b::Box>) -> Placement = value
        \\page main
        \\  let value = erase(b::box!())
        \\  let invalid = a::accept(value)
        \\end
    , first_placed, second_placed, "TypeMismatch:");
}
