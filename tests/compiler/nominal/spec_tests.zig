const std = @import("std");
const compiler = @import("compiler");
const core = compiler.core;
const Type = compiler.language.Type;
const testing = std.testing;

fn exercise(source: []const u8, first: []const u8, second: []const u8, expected_diagnostic: ?[]const u8) !void {
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
    var state = try compiler.analysis.buildDocumentStateWithOptions(allocator, path, root, &source_buf, &syntax, &modules, .{
        .allow_diagnostics = true,
    });
    defer state.deinit();
    errdefer for (state.diagnostics.items) |diagnostic| {
        if (diagnostic.data == .user_report) std.debug.print("{s}: {s}\n", .{ diagnostic.origin orelse "", diagnostic.data.user_report.message });
    };
    if (expected_diagnostic) |expected| {
        compiler.analysis.analyzeDocumentState(allocator, &state) catch {};
        for (state.diagnostics.items) |diagnostic| {
            if (diagnostic.data == .user_report and std.mem.startsWith(u8, diagnostic.data.user_report.message, expected)) return;
        }
        return error.ExpectedDiagnostic;
    }
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{});
    for (state.diagnostics.items) |diagnostic| {
        if (diagnostic.severity == .@"error") return error.UnexpectedDiagnostic;
    }
}

const number_record =
    \\record Style {
    \\  value: Number = 12
    \\}
    \\record Box {
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
    \\record Style {
    \\  value: String = "second"
    \\}
    \\record Box {
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
    , number_record, "", "UnknownRecordType:");
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
        \\type Mode = first
        \\fn accept(value: Mode) -> String
        \\  return "first"
        \\end
    ;
    const second =
        \\type Mode = second
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
        \\record Mode {
        \\  value: Number = 0
        \\}
        \\page main
        \\  let invalid = a::Mode {}
        \\end
    , "type Mode = first", "", "InvalidRecordLiteral:");
}

test "nominal records: object defaults and nested writes preserve record ownership" {
    try exercise(
        \\import "a" as a
        \\import "b" as b
        \\page main
        \\  let first = new("", "first_nominal", "text")
        \\  let second = new("", "second_nominal", "text")
        \\  first.style.value = 23
        \\  second.style.value = "updated"
        \\  let number: Number = a::accept(first.style ?? a::Style {})
        \\  text!(b::accept(second.style ?? b::Style {}))
        \\end
    , number_record ++ "\n" ++
        \\type FirstNominal = object {
        \\  roles = ["first_nominal"]
        \\  style: Style = Style {}
        \\}
    , string_record ++ "\n" ++
        \\type SecondNominal = object {
        \\  roles = ["second_nominal"]
        \\  style: Style = Style {}
        \\}
    , null);
}

test "nominal records: primitive contracts refer to their declared module" {
    try exercise(
        \\record PathCommand {
        \\  verb: PathVerb = PathVerb.move
        \\  x: Number = 0
        \\  y: Number = 0
        \\}
        \\page main
        \\  let valid = path(move_to(0, 0), line_to(1, 1))
        \\end
    , "", "", null);
    try exercise(
        \\record PathCommand {
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
    var record = core.RecordValue.init("Style");
    record.module_id = 1;
    defer record.deinit(allocator);
    try record.fields.append(allocator, .{
        .name = "mode",
        .value = .{ .enum_case = .{ .enum_name = "Mode", .module_id = 2, .case_name = "first" } },
    });
    var clone = try record.clone(allocator);
    defer clone.deinit(allocator);
    try testing.expectEqual(@as(?u32, 1), clone.module_id);
    const text = try core.value_text.propertyString(allocator, .{ .record = clone });
    defer allocator.free(text);
    var parsed = try core.value_text.typedPropertyValue(allocator, text, Type.recordType("Style").inModule(1));
    defer core.value_text.deinitParsedPropertyValue(allocator, &parsed);
    try testing.expectEqual(@as(?u32, 1), parsed.record.module_id);
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
    try testing.checkAllAllocationFailures(testing.allocator, cloneNestedTypes, .{});
}
