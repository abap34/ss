const std = @import("std");
const compiler_semantics = @import("compiler_semantics");

const testing = std.testing;
const fixture_root = "tests/fixtures/compiler/semantics";

fn fixturePath(allocator: std.mem.Allocator, fixture: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ fixture_root, fixture, "slide.ss" });
}

fn fixtureSource(allocator: std.mem.Allocator, fixture: []const u8) !struct { path: []u8, source: []u8 } {
    const path = try fixturePath(allocator, fixture);
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(256 * 1024));
    return .{ .path = path, .source = source };
}

fn buildFixture(fixture: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const input = try fixtureSource(allocator, fixture);
    try compiler_semantics.buildSource(testing.io, allocator, input.path, input.source);
}

fn expectFixtureDumpContains(fixture: []const u8, needles: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const input = try fixtureSource(allocator, fixture);
    try compiler_semantics.expectDumpContains(testing.io, allocator, input.path, input.source, needles);
}

fn buildSource(source: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.buildSource(testing.io, allocator, path, source);
}

fn buildSourceWithOverlay(source: []const u8, overlay_source: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    const overlay_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/lib/types.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.buildSourceWithOverlay(testing.io, allocator, path, source, overlay_path, overlay_source);
}

fn buildSourceWithTwoOverlays(source: []const u8, first_source: []const u8, second_source: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    const first_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/lib/a.ss", .{tmp.sub_path[0..]});
    const second_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/lib/b.ss", .{tmp.sub_path[0..]});
    const overlays = [_]compiler_semantics.OverlaySource{
        .{ .path = first_path, .source = first_source },
        .{ .path = second_path, .source = second_source },
    };
    try compiler_semantics.buildSourceWithOverlays(testing.io, allocator, path, source, &overlays);
}

fn buildSourceWithAssetFixtures(source: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    try std.Io.Dir.cwd().createDirPath(testing.io, root);

    const slide_path = try std.fs.path.join(allocator, &.{ root, "case.ss" });
    const image_path = try std.fs.path.join(allocator, &.{ root, "image.svg" });
    const pdf_path = try std.fs.path.join(allocator, &.{ root, "doc.pdf" });
    const snippet_path = try std.fs.path.join(allocator, &.{ root, "snippet.zig" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = image_path,
        .data =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="64" height="32">
        \\</svg>
        ,
        .flags = .{ .truncate = true },
    });
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = pdf_path,
        .data = "%PDF-1.7\n1 0 obj <<>> endobj\ntrailer <<>>\n%%EOF\n",
        .flags = .{ .truncate = true },
    });
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = snippet_path,
        .data = "pub fn main() void {}\n",
        .flags = .{ .truncate = true },
    });

    try compiler_semantics.buildSource(testing.io, allocator, slide_path, source);
}

fn expectFixtureObjectFieldPath(fixture: []const u8, root_key: []const u8, field_path: []const []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try fixturePath(allocator, fixture);
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(256 * 1024));
    try compiler_semantics.expectObjectFieldPath(testing.io, allocator, path, source, root_key, field_path, expected);
}

fn expectFixtureLoweringErrorDiagnostic(fixture: []const u8, expected_message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try fixturePath(allocator, fixture);
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(256 * 1024));
    try compiler_semantics.expectLoweringErrorDiagnostic(testing.io, allocator, path, source, expected_message);
}

fn expectObjectContentWithFile(source: []const u8, file_name: []const u8, file_content: []const u8, expected: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    try std.Io.Dir.cwd().createDirPath(testing.io, root);

    const slide_path = try std.fs.path.join(allocator, &.{ root, "case.ss" });
    const file_path = try std.fs.path.join(allocator, &.{ root, file_name });
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = file_path,
        .data = file_content,
        .flags = .{ .truncate = true },
    });

    try compiler_semantics.expectObjectContent(testing.io, allocator, slide_path, source, expected);
}

fn expectObjectPropertyWithFile(source: []const u8, file_name: []const u8, file_content: []const u8, key: []const u8, expected: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    try std.Io.Dir.cwd().createDirPath(testing.io, root);

    const slide_path = try std.fs.path.join(allocator, &.{ root, "case.ss" });
    const file_path = try std.fs.path.join(allocator, &.{ root, file_name });
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = file_path,
        .data = file_content,
        .flags = .{ .truncate = true },
    });

    try compiler_semantics.expectObjectProperty(testing.io, allocator, slide_path, source, key, expected);
}

fn expectBuildFails(source: []const u8) !void {
    buildSource(source) catch {
        return;
    };
    return error.ExpectedBuildFailure;
}

fn expectObjectContent(source: []const u8, expected: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectObjectContent(testing.io, allocator, path, source, expected);
}

fn expectRecordStringDefaultNotEvaluated(source: []const u8, record_name: []const u8, field_name: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectRecordStringDefaultNotEvaluated(
        testing.io,
        allocator,
        path,
        source,
        record_name,
        field_name,
    );
}

fn expectFixtureObjectContent(fixture: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try fixturePath(allocator, fixture);
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(256 * 1024));
    try compiler_semantics.expectObjectContent(testing.io, allocator, path, source, expected);
}

fn expectObjectContentWithTwoOverlays(source: []const u8, first_source: []const u8, second_source: []const u8, expected: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    const first_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/lib/a.ss", .{tmp.sub_path[0..]});
    const second_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/lib/b.ss", .{tmp.sub_path[0..]});
    const overlays = [_]compiler_semantics.OverlaySource{
        .{ .path = first_path, .source = first_source },
        .{ .path = second_path, .source = second_source },
    };
    try compiler_semantics.expectObjectContentWithOverlays(testing.io, allocator, path, source, &overlays, expected);
}

fn expectObjectProperty(source: []const u8, key: []const u8, expected: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectObjectProperty(testing.io, allocator, path, source, key, expected);
}

fn expectObjectPropertyMissing(source: []const u8, key: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectObjectPropertyMissing(testing.io, allocator, path, source, key);
}

fn expectObjectFieldPath(source: []const u8, root_key: []const u8, field_path: []const []const u8, expected: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectObjectFieldPath(testing.io, allocator, path, source, root_key, field_path, expected);
}

fn expectObjectFieldPathNone(source: []const u8, root_key: []const u8, field_path: []const []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectObjectFieldPathNone(testing.io, allocator, path, source, root_key, field_path);
}

fn expectObjectPropertyWithThemeOverlay(source: []const u8, theme_source: []const u8, key: []const u8, expected: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    const theme_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/theme.ss", .{tmp.sub_path[0..]});
    const overlays = [_]compiler_semantics.OverlaySource{
        .{ .path = theme_path, .source = theme_source },
    };
    try compiler_semantics.expectObjectPropertyWithOverlays(testing.io, allocator, path, source, &overlays, key, expected);
}

fn expectObjectFieldPathWithThemeOverlay(
    source: []const u8,
    theme_source: []const u8,
    root_key: []const u8,
    field_path: []const []const u8,
    expected: []const u8,
) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    const theme_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/theme.ss", .{tmp.sub_path[0..]});
    const overlays = [_]compiler_semantics.OverlaySource{
        .{ .path = theme_path, .source = theme_source },
    };
    try compiler_semantics.expectObjectFieldPathWithOverlays(testing.io, allocator, path, source, &overlays, root_key, field_path, expected);
}

fn expectClassDefaultProperty(source: []const u8, role: []const u8, key: []const u8, expected: ?[]const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectClassDefaultProperty(testing.io, allocator, path, source, role, key, expected);
}

fn expectBodyTextDefaults(source: []const u8, expected: compiler_semantics.BodyTextDefaults) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectBodyTextDefaults(testing.io, allocator, path, source, expected);
}

fn expectResolvedCodePaintIsColorful(source: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectResolvedCodePaintIsColorful(testing.io, allocator, path, source);
}

fn expectDumpContains(source: []const u8, expected: []const []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectDumpContains(testing.io, allocator, path, source, expected);
}

fn expectVariableObjectClasses(source: []const u8, expected: []const compiler_semantics.VariableObjectClassExpectation) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectVariableObjectClasses(testing.io, allocator, path, source, expected);
}

fn expectOverlayDiagnostic(source: []const u8, overlay_source: []const u8, expected_origin: []const u8, expected_message: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    const overlay_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/lib/bad.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectOverlayDiagnostic(testing.io, allocator, path, source, overlay_path, overlay_source, expected_origin, expected_message);
}

fn expectDiagnostic(source: []const u8, expected_origin: []const u8, expected_message: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectDiagnostic(testing.io, allocator, path, source, expected_origin, expected_message);
}

fn expectLoweredDiagnostic(source: []const u8, expected_message: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectLoweredDiagnostic(testing.io, allocator, path, source, expected_message);
}

fn expectLoweredDiagnosticWithOrigin(source: []const u8, expected_origin: []const u8, expected_message: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectLoweredDiagnosticWithOrigin(testing.io, allocator, path, source, expected_origin, expected_message);
}

fn expectLoweringErrorDiagnostic(source: []const u8, expected_message: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectLoweringErrorDiagnostic(testing.io, allocator, path, source, expected_message);
}

fn expectNoLoweredDiagnostic(source: []const u8, unexpected_message: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectNoLoweredDiagnostic(testing.io, allocator, path, source, unexpected_message);
}

fn expectLoweredDiagnosticCount(source: []const u8, expected_message: []const u8, expected_count: usize) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectLoweredDiagnosticCount(testing.io, allocator, path, source, expected_message, expected_count);
}

fn expectObjectState(source: []const u8, expected: compiler_semantics.ObjectStateExpectation) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectObjectState(testing.io, allocator, path, source, expected);
}

test "compiler semantics: composition type diagnostics identify the operand" {
    const source =
        \\page example
        \\  let a = text("A")
        \\  a || (a // 123)
        \\end
        \\
    ;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    const start = std.mem.indexOf(u8, source, "123").?;
    const expected_origin = try std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ start, start + 3 });
    try compiler_semantics.expectDiagnostic(testing.io, allocator, path, source, expected_origin, "InvalidGroupInput");
    const typed_source =
        \\import std:text as { Text }
        \\page example
        \\  let a = Text { content = "A" }
        \\  let row = a || (a // 123)
        \\end
    ;
    const typed_start = std.mem.indexOf(u8, typed_source, "123").?;
    const typed_origin = try std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ typed_start, typed_start + 3 });
    try compiler_semantics.expectDiagnostic(testing.io, allocator, path, typed_source, typed_origin, "InvalidGroupInput");
}

test "compiler semantics: imported function return inference diagnostics keep callee origin" {
    try expectOverlayDiagnostic(
        \\import "lib/bad"
        \\import std:themes/default as *
        \\
        \\page ok
        \\  text!(bad())
        \\end
        \\
    ,
        \\fn bad() -> String
        \\  return add(1)
        \\end
        \\
    , "lib/bad.ss:bytes:", "InvalidArity: expected 2, got 1");
}

test "compiler semantics: default import introduces an alias and bare names" {
    try buildSource(
        \\import std:text
        \\
        \\page ok
        \\  text!("bare")
        \\  text::text!("qualified")
        \\end
        \\
    );
}

test "compiler semantics: editor variable info keeps object classes through user calls" {
    try expectVariableObjectClasses(
        \\type Thing = object {
        \\  roles = ["thing"]
        \\  size: Number = 1
        \\}
        \\
        \\fn make(role: String) -> Object
        \\  return new("x", role, "text")
        \\end
        \\
        \\fn wrap() -> Object
        \\  return make("thing")
        \\end
        \\
        \\page ok
        \\  let t = wrap()
        \\  t.size = 2
        \\end
        \\
    , &.{
        .{ .name = "t", .scope_kind = "page", .scope_name = "ok", .object_class = "Thing" },
    });
}

test "compiler semantics: return inference preserves facts for imprecise object and selection types" {
    try expectVariableObjectClasses(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  roles = ["card"]
        \\  size: Number = 1
        \\}
        \\
        \\fn card_role() -> String
        \\  return "card"
        \\end
        \\
        \\fn make_card() -> Object
        \\  let role_name = card_role()
        \\  return new("direct", role_name, "text")
        \\end
        \\
        \\fn cards() -> Selection<Object>
        \\  return objs_here("card")
        \\end
        \\
        \\page ok
        \\  let direct = make_card()
        \\  let source = make_card()
        \\  place_on!(pagectx(), source)
        \\  let selected = first(cards())
        \\end
        \\
    , &.{
        .{ .name = "direct", .scope_kind = "page", .scope_name = "ok", .object_class = "Card" },
        .{ .name = "selected", .scope_kind = "page", .scope_name = "ok", .object_class = "Card" },
    });
}

test "compiler semantics: fact-complete return annotations still validate function bodies" {
    try expectDiagnostic(
        \\type Settings {
        \\  size: Number
        \\}
        \\
        \\fn invalid_settings() -> Settings
        \\  return Settings { size = "large" }
        \\end
        \\
        \\page bad
        \\  let _ = invalid_settings()
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Number, got String");
}

test "compiler semantics: editor variable info keeps object classes through paired placement calls" {
    try expectVariableObjectClasses(
        \\type Thing = object {
        \\  roles = ["thing"]
        \\  size: Number = 1
        \\}
        \\
        \\fn/! thing() -> Object
        \\  return new("x", "thing", "text")
        \\end
        \\
        \\page ok
        \\  let t = thing!()
        \\  t.size = 2
        \\end
        \\
    , &.{
        .{ .name = "t", .scope_kind = "page", .scope_name = "ok", .object_class = "Thing" },
    });
}

test "compiler semantics: obsolete convenience constructors are not public" {
    for ([_][]const u8{ "title", "subtitle", "note", "byline", "label", "h1", "h2", "h3", "h4", "h5", "h6", "title_obj", "sub_obj", "note_obj", "by_obj", "lab_obj", "cite_obj", "rule_obj", "path_obj", "panel_obj", "latex_obj", "fig_obj", "img_obj", "pdf_obj", "icon_obj", "code_obj", "connector_obj", "surround", "spacer", "vspace" }) |name| {
        for ([_][]const u8{ "", "!" }) |suffix| {
            const source = try std.fmt.allocPrint(testing.allocator, "page main\n  {s}{s}(\"Text\")\nend\n", .{ name, suffix });
            defer testing.allocator.free(source);
            try expectDiagnostic(source, "case.ss:bytes:", "UnknownFunction");
        }
    }
}

test "compiler semantics: core prelude is implicitly open" {
    try buildSource(
        \\import std:text as { Text }
        \\page ok
        \\  place!(Text { content = "prelude" })
        \\end
        \\
    );
}

test "compiler semantics: default alias supports theme override with prelude placement" {
    try expectObjectContent(
        \\import std:text
        \\
        \\fn/! h2(content: String) -> Text
        \\  let t = text::text(content, default_theme().h2)
        \\  return t
        \\end
        \\
        \\page ok
        \\  h2!("override")
        \\end
        \\
    , "override");
}

test "compiler semantics: theme text size override keeps automatic line height" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let title = heading!("large text
        \\next line", 1, default_theme().h1 with {
        \\    text.size = 64
        \\    text.line_height = none
        \\  })
        \\end
        \\
    , &.{
        "\"font_size\":64.0,\"line_height\":92.8",
        "\"height\":185.6",
    });
}

test "compiler semantics: stdlib theme toc works through default aliases" {
    try buildSource(
        \\import std:themes/default
        \\page table_of_contents
        \\  toc!("Contents")
        \\end
    );
}

test "compiler semantics: dependency query comments report statement summaries" {
    const page_source =
        \\import std:themes/default as *
        \\
        \\page sample
        \\  let t = heading!("A")
        \\  ;; ^dep?
        \\end
        \\
    ;
    try expectDiagnostic(page_source, "bytes:", "DependencyQuery:");
    try expectDiagnostic(page_source, "bytes:", "write Variable(scope=page:sample, name=t)");

    const document_source =
        \\document
        \\  let t = "A"
        \\  ;; ^dep?
        \\end
        \\
    ;
    try expectDiagnostic(document_source, "bytes:", "write Variable(scope=document:case.ss, name=t)");

    const function_call_source =
        \\fn echo(value: String) -> String
        \\  return value
        \\end
        \\
        \\page sample
        \\  let t = "A"
        \\  let out = echo(t)
        \\  ;; ^dep?
        \\end
        \\
    ;
    try expectDiagnostic(function_call_source, "bytes:", "read Variable(scope=page:sample, name=t)");
    try expectDiagnostic(function_call_source, "bytes:", "write Variable(scope=page:sample, name=out)");

    const property_source =
        \\import std:themes/default as *
        \\
        \\type Claim = object {
        \\  roles = ["claim"]
        \\  suffix: String? = none
        \\}
        \\
        \\fn/! claim(text: String) -> Object = txt_obj(text, "claim")
        \\
        \\fn claim_suffix(item: Object) -> String
        \\  return item.suffix ?? ""
        \\end
        \\
        \\page sample
        \\  let a = claim!("A")
        \\  a.suffix = "!"
        \\  ;; ^dep?
        \\  text!(join(doc_objs(docctx(), "claim"), "", claim_suffix))
        \\  ;; ^dep?
        \\end
        \\
    ;
    try expectDiagnostic(property_source, "bytes:", "write Property(owner=object:Claim#page:sample.a, key=suffix)");
    try expectDiagnostic(property_source, "bytes:", "read Objects(role=claim,");
    try expectDiagnostic(property_source, "bytes:", "read Property(owner=object:Claim.*, key=suffix)");
}

test "compiler semantics: stdlib core components build when called directly" {
    try buildSourceWithAssetFixtures(
        \\import std:prelude
        \\
        \\page text_components
        \\  heading!("Title")
        \\  text!("Subtitle")
        \\  text!("Body")
        \\  latex!("$x + y$")
        \\  code!("const x = 1", "zig")
        \\  code!("print('x')", "python")
        \\  code_file!("snippet.zig", "zig")
        \\  text!("note")
        \\  pageno!()
        \\end
        \\
        \\page asset_components
        \\  image!("image.svg")
        \\  pdf!("doc.pdf")
        \\end
        \\
        \\page citation_component
        \\  let target = text!("body [1]")
        \\  text!("[1] reference")
        \\end
        \\
    );
}

test "compiler semantics: math and latex are public without obsolete aliases" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\page formulas
        \\  math!("x + y")
        \\  latex!("$x + y$")
        \\end
        \\
    );

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  mathtex!("x + y")
        \\end
        \\
    , "case.ss:bytes:", "UnknownFunction: unknown function: mathtex!");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  tex!("$x + y$")
        \\end
        \\
    , "case.ss:bytes:", "UnknownFunction: unknown function: tex!");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  place_on!(pagectx(), math_obj("x + y"))
        \\end
        \\
    , "case.ss:bytes:", "UnknownFunction: unknown function: math_obj");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  place_on!(pagectx(), tex_obj("$x + y$"))
        \\end
        \\
    , "case.ss:bytes:", "UnknownFunction: unknown function: tex_obj");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\document
        \\  tex_preamble("legacy")
        \\end
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "UnknownFunction: unknown function: tex_preamble");
}

test "compiler semantics: stdlib display values build with explicit default theme styles" {
    try buildSourceWithAssetFixtures(
        \\import std:themes/default as base
        \\const theme: Theme = base::default_theme()
        \\page main
        \\  heading!("Heading", 1, theme.h1)
        \\  text!("Body", theme.body)
        \\  code!("print(1)", "python", theme.code)
        \\end
        \\page assets
        \\  image!("image.svg", theme.image)
        \\  pdf!("doc.pdf", theme.pdf)
        \\end
        \\page contents
        \\  toc!("Contents", theme.toc)
        \\  let number = pageno!(theme.page_number)
        \\  ~ number.bottom == page.bottom + 20
        \\  ~ number.right == page.right - 24
        \\end
    );
}

test "compiler semantics: code_file reads source text from asset base" {
    const source =
        \\import std:themes/default as *
        \\
        \\page code
        \\  code_file!("snippet.zig", "zig")
        \\end
        \\
    ;
    const snippet =
        \\pub fn main() void {}
        \\
    ;

    try expectObjectContentWithFile(source, "snippet.zig", snippet, snippet);
    try expectObjectPropertyWithFile(source, "snippet.zig", snippet, "language", "zig");
}

test "compiler semantics: import as star introduces bare names" {
    try buildSource(
        \\import std:text as *
        \\
        \\page ok
        \\  text!("open")
        \\end
        \\
    );
}

test "compiler semantics: import alias does not introduce bare names" {
    try expectDiagnostic(
        \\import std:markdown as base
        \\
        \\page bad
        \\  link("bare", "https://example.com")
        \\end
        \\
    , "case.ss:bytes:", "UnknownFunction: unknown function: link");

    try buildSource(
        \\import std:markdown as base
        \\
        \\page ok
        \\  base::link("qualified", "https://example.com")
        \\end
        \\
    );
}

test "compiler semantics: import as star does not introduce an alias" {
    try expectDiagnostic(
        \\import std:text as *
        \\
        \\page bad
        \\  text::text!("qualified")
        \\end
        \\
    , "case.ss:bytes:", "UnknownModuleAlias: unknown import alias: text");
}

test "compiler semantics: qualified calls bypass local shadowing" {
    const source =
        \\import std:text
        \\
        \\fn/! text(content: String) -> Text
        \\  return Text { content = "local" }
        \\end
        \\
        \\page ok
        \\  text!("ignored")
        \\  text::text!("qualified")
        \\end
        \\
    ;
    try expectObjectContent(source, "local");
    try expectObjectContent(source, "qualified");
}

test "compiler semantics: repeated name resolution keeps module scope" {
    try expectObjectContentWithTwoOverlays(
        \\import std:themes/default as *
        \\import "lib/a" as a
        \\import "lib/b" as b
        \\
        \\page ok
        \\  text!(a::get() ++ b::get() ++ a::get())
        \\end
        \\
    ,
        \\fn label() -> String
        \\  return "a"
        \\end
        \\
        \\fn get() -> String
        \\  return label()
        \\end
        \\
    ,
        \\fn label() -> String
        \\  return "b"
        \\end
        \\
        \\fn get() -> String
        \\  return label()
        \\end
        \\
    , "aba");
}

test "compiler semantics: implicit prelude does not propagate through bare-name imports" {
    try buildSourceWithTwoOverlays(
        \\import "lib/a" as *
        \\import "lib/b" as *
        \\
        \\page ok
        \\  place!(new("custom", "body", "text"))
        \\end
        \\
    ,
        \\
    ,
        \\fn place!(obj: Object) -> Object
        \\  obj.text.size = 41
        \\  return place_on!(pagectx(), obj)
        \\end
        \\
    );
}

test "compiler semantics: later bare-name import overrides earlier imports" {
    try expectObjectContentWithTwoOverlays(
        \\import "lib/a" as *
        \\import "lib/b" as *
        \\page ok
        \\  text!(label())
        \\end
    ,
        \\fn label() -> String = "first"
    ,
        \\fn label() -> String = "second"
    , "second");
}

test "compiler semantics: later alias import overrides earlier aliases" {
    try expectObjectContentWithTwoOverlays(
        \\import "lib/a" as theme
        \\import "lib/b" as theme
        \\page ok
        \\  text!(theme::label())
        \\end
    ,
        \\fn label() -> String = "first"
    ,
        \\fn label() -> String = "second"
    , "second");
}

test "compiler semantics: imported local definitions override their imports" {
    try expectObjectContentWithTwoOverlays(
        \\import "lib/a" as *
        \\import "lib/b" as *
        \\
        \\page ok
        \\  h2!("later")
        \\  text!("base")
        \\end
        \\
    ,
        \\import std:themes/default
        \\
        \\fn/! h2(content: String) -> Text
        \\  return text("a " ++ content)
        \\end
        \\
    ,
        \\import std:themes/default
        \\
        \\fn/! h2(content: String) -> Text
        \\  return text("b " ++ content)
        \\end
        \\
    , "b later");
}

test "compiler semantics: extensionless path imports can be aliased and opened together" {
    try buildSourceWithOverlay(
        \\import std:themes/default as *
        \\import "lib/types"
        \\
        \\page ok
        \\  text!(types::overlay_value() ++ overlay_value())
        \\end
        \\
    ,
        \\fn overlay_value() -> String
        \\  return "ok"
        \\end
        \\
    );
}

test "compiler semantics: branch-local let bindings do not escape their branch" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let x = "a"
        \\  if true
        \\    let branch_value = 1
        \\  end
        \\  let y = concat(x, "b")
        \\end
        \\
    );
}

test "compiler semantics: string search primitives evaluate" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\
        \\page strings
        \\  let source = "abc target xyz"
        \\  text!(str_before(source, "target") ++ "|" ++ str_after(source, "target"))
        \\  if not(str_contains(source, "target"))
        \\    report_error("missing")
        \\  end
        \\end
        \\
    , &.{"\"content\":\"abc | xyz\""});
}

test "compiler semantics: let rebinding is rejected" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let x = "a"
        \\  let x = "b"
        \\end
        \\
    , "case.ss:bytes:", "DuplicateBinding: binding 'x' is already defined in this scope");
}

test "compiler semantics: branch let cannot shadow visible bindings" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let x = "a"
        \\  if true
        \\    let x = "b"
        \\  end
        \\end
        \\
    , "case.ss:bytes:", "DuplicateBinding: binding 'x' is already defined in this scope");
}

test "compiler semantics: duplicate function parameters are rejected" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn bad(x: String, x: String) -> String
        \\  return x
        \\end
        \\
        \\page ok
        \\  text!(bad("a", "b"))
        \\end
        \\
    , "case.ss:bytes:", "DuplicateBinding: binding 'x' is already defined in this scope");
}

test "compiler semantics: function let cannot shadow parameters" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn bad(x: String) -> String
        \\  let x = "b"
        \\  return x
        \\end
        \\
        \\page ok
        \\  text!(bad("a"))
        \\end
        \\
    , "case.ss:bytes:", "DuplicateBinding: binding 'x' is already defined in this scope");
}

test "compiler semantics: duplicate lambda parameters are rejected" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let f = (x: String, x: String) |-> x
        \\  text!(f("a", "b"))
        \\end
        \\
    , "case.ss:bytes:", "DuplicateBinding: binding 'x' is already defined in this scope");
}

test "compiler semantics: lambda parameters can shadow outer bindings" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page good
        \\  let x = "outer"
        \\  let f = (x: String) |-> x
        \\  text!(f("inner"))
        \\end
        \\
    , "inner");
}

test "compiler semantics: singleton selections do not depend on placement collection writes" {
    try buildSource(
        \\import std:prelude as *
        \\fn wrap(item: Placed<Text>) -> Selection<Placed<Text>>
        \\  return select<Text>(item)
        \\end
        \\page Singleton
        \\  let a = text!("A")
        \\  let b = text!("B")
        \\  let items = wrap(a) | wrap(b)
        \\  text!(join(items, "", (item: Placed<Text>) |-> item.value.content))
        \\end
    );
}

test "compiler semantics: selection values can be reused after lookup" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\document
        \\  let pages = select(docctx(), "document_pages")
        \\  let first_count = selection_count(pages)
        \\  let second_count = selection_count(pages)
        \\end
        \\
        \\page ok
        \\end
        \\
    );
}

test "compiler semantics: dynamically built text survives lowering" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  text!("hello" ++ " " ++ "world")
        \\end
        \\
    , "hello world");
}

test "compiler semantics: math alignment uses typed properties" {
    try buildSource(
        \\import std:themes/default as *
        \\import std:math as formulas
        \\
        \\page ok
        \\  let body = body_obj("$$x^2$$")
        \\  body.math_align = Align.left
        \\  let formula = latex!("$x^2 + y^2 = z^2$", formulas::LatexBlockStyle {} with { latex.align = Align.right })
        \\end
        \\
    );
}

test "compiler semantics: LaTeX preamble helpers extend scoped render environment" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\
        \\document
        \\latex_engine(LatexEngine.lualatex)
        \\latex_preamble("doc preamble")
        \\latex_preamble_file("tex/preamble.tex")
        \\end
        \\
        \\page ok
        \\  page_latex_engine(LatexEngine.pdflatex)
        \\  page_latex_preamble("page preamble")
        \\  page_latex_preamble_file("tex/page.tex")
        \\  latex("$x$")
        \\end
        \\
    , &.{
        "\"engine\":\"lualatex\"",
        "\"engine\":\"pdflatex\"",
        "\"source\":\"text\",\"value\":\"doc preamble\"",
        "\"source\":\"file\",\"value\":\"tex/preamble.tex\"",
        "\"source\":\"text\",\"value\":\"page preamble\"",
        "\"source\":\"file\",\"value\":\"tex/page.tex\"",
    });
}

test "compiler semantics: enum cases type function parameters" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha Beta READY }
        \\enum Any { String Number }
        \\
        \\fn keep_mode(mode: Mode) -> Mode
        \\  return mode
        \\end
        \\
        \\fn keep_any(value: Any) -> Any
        \\  return value
        \\end
        \\
        \\page ok
        \\  let mode = keep_mode(Mode.Beta)
        \\  let ready = keep_mode(Mode.READY)
        \\  let named_any = keep_any(Any.String)
        \\end
        \\
    );

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\
        \\fn keep_mode(mode: Mode) -> Mode
        \\  return mode
        \\end
        \\
        \\page bad
        \\  let mode = keep_mode("alpha")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Mode, got String");
}

test "compiler semantics: enum cases are resolved before evaluation" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\
        \\fn keep_mode(mode: Mode) -> Mode
        \\  return mode
        \\end
        \\
        \\page ok
        \\  let mode = keep_mode(Mode.beta)
        \\end
        \\
    , &.{
        "\"kind\":\"enum_case\"",
        "\"enum\":\"Mode\"",
        "\"case\":\"beta\"",
    });
}

test "compiler semantics: qualified type names resolve in annotations records and enum cases" {
    try buildSource(
        \\import std:text as classes
        \\import std:layout as layout_types
        \\
        \\fn keep_style(style: classes::TextStyle) -> classes::TextStyle
        \\  return style
        \\end
        \\
        \\fn keep_align(align: layout_types::Align) -> layout_types::Align
        \\  return align
        \\end
        \\
        \\page ok
        \\  let style = keep_style(classes::TextStyle {
        \\    size = 32
        \\    math = classes::TextMathStyle { align = layout_types::Align.left }
        \\  })
        \\  let align = keep_align(layout_types::Align.left)
        \\  let body = classes::text("qualified", classes::TextBlockStyle { text = style with { math.align = align } })
        \\  layout_types::place!(body)
        \\end
        \\
    );
}

test "compiler semantics: enum type names are not record constructors" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\
        \\page bad
        \\  let mode = Mode {}
        \\end
        \\
    , "case.ss:bytes:", "InvalidTypeConstruction: Mode is an enum type; use Mode.<case>");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let style = FontStyle {}
        \\end
        \\
    , "case.ss:bytes:", "InvalidTypeConstruction: FontStyle is an enum type; use FontStyle.<case>");
}

test "compiler semantics: enum names can be shadowed by values" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\type Card = object {
        \\  roles = ["card"]
        \\  custom_mode: Mode = Mode.alpha
        \\}
        \\
        \\page ok
        \\  let fallback = Mode.beta
        \\  let card = obj("card", "card", "text")
        \\  let Mode = card
        \\  let current = Mode.custom_mode ?? fallback
        \\end
        \\
    );
}

test "compiler semantics: enum type names do not depend on capitalization" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\enum mode { active String }
        \\
        \\fn keep(value: mode) -> mode
        \\  return value
        \\end
        \\
        \\page ok
        \\  let value = keep(mode.String)
        \\end
        \\
    );
}

test "compiler semantics: enum types resolve through imported modules" {
    try buildSourceWithOverlay(
        \\import "lib/types"
        \\import std:themes/default as *
        \\
        \\fn keep_mode(mode: Mode) -> Mode
        \\  return mode
        \\end
        \\
        \\fn keep_maybe(mode: Mode?) -> Mode
        \\  return mode ?? Mode.alpha
        \\end
        \\
        \\page ok
        \\  let first = keep_mode(Mode.beta)
        \\  let second = keep_maybe(none)
        \\end
        \\
    ,
        \\enum Mode { alpha beta }
        \\
    );
}

test "compiler semantics: enum properties serialize as case names" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\type Card = object {
        \\  roles = ["card"]
        \\  custom_mode: Mode = Mode.alpha
        \\}
        \\
        \\page ok
        \\  let card = obj("card", "card", "text")
        \\  card.custom_mode = Mode.beta
        \\  if prop_eq(card, "custom_mode", "beta")
        \\    text!("enum-ok")
        \\  end
        \\end
        \\
    , "enum-ok");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\type Card = object {
        \\  roles = ["card"]
        \\  custom_mode: Mode = Mode.alpha
        \\}
        \\
        \\page bad
        \\  let card = obj("card", "card", "text")
        \\  card.custom_mode = "beta"
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'custom_mode' expects Mode, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\enum Other { beta }
        \\type Card = object {
        \\  roles = ["card"]
        \\  custom_mode: Mode = Mode.alpha
        \\}
        \\
        \\page bad
        \\  let card = obj("card", "card", "text")
        \\  card.custom_mode = Other.beta
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'custom_mode' expects Mode, got Other");
}

test "compiler semantics: type names share one namespace" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Color { accent }
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "DuplicateType: type 'Color' conflicts with a built-in type");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha }
        \\type Mode = object {
        \\}
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "DuplicateType: object type 'Mode' is already defined in this module");

    try buildSource(
        \\import std:themes/default as *
        \\
        \\enum Scalar { Number String }
        \\
        \\fn keep_scalar(value: Scalar) -> Scalar
        \\  return value
        \\end
        \\
        \\page ok
        \\  let number_case = keep_scalar(Scalar.Number)
        \\  let string_case = keep_scalar(Scalar.String)
        \\end
        \\
    );

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta alpha }
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "DuplicateEnumCase: enum 'Mode' already has case 'alpha'");

    try buildSource(
        \\import std:themes/default as *
        \\
        \\enum Mode { Alpha beta }
        \\
        \\page ok
        \\  let mode = Mode.Alpha
        \\end
        \\
    );

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type String = object {
        \\}
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "DuplicateType: type 'String' conflicts with a built-in type");

    try buildSource(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\}
        \\enum Mode { Card local }
        \\
        \\page ok
        \\  let card_case = Mode.Card
        \\end
        \\
    );

    try buildSourceWithOverlay(
        \\import "lib/types"
        \\import std:themes/default as *
        \\
        \\enum Mode { RemoteType local }
        \\
        \\page ok
        \\  let remote_case = Mode.RemoteType
        \\end
        \\
    ,
        \\type RemoteType = object {
        \\}
        \\
    );
}

test "compiler semantics: Color is a static type" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\fn keep_color(value: Color) -> Color
        \\  return value
        \\end
        \\
        \\page ok
        \\  let body = body_obj("ok")
        \\  body.text.color = keep_color(c"0.1,0.2,0.3")
        \\end
        \\
    );

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn keep_color(value: Color) -> Color
        \\  return value
        \\end
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  body.text.color = keep_color("0.1,0.2,0.3")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color, got String");

    try expectObjectFieldPath(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let body = body_obj("color")
        \\  body.text.color = c"#334455"
        \\end
        \\
    , "text", &.{"color"}, "0.2,0.26666668,0.33333334");

    try expectObjectFieldPath(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let body = body_obj("**bold**")
        \\  body.text.markdown.bold_color = c"#884422"
        \\end
        \\
    , "text", &.{ "markdown", "bold_color" }, "0.53333336,0.26666668,0.13333334");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  body.text.markdown.code.chrome.fill = "red"
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text.markdown.code.chrome.fill' expects Color?, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  body.text.markdown.bold_color = "red"
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text.markdown.bold_color' expects Color?, got String");
}

test "compiler semantics: structured style values expand to render properties" {
    const source =
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let body = body_obj("style")
        \\  body.text = TextStyle {
        \\    size = 33
        \\    color = c"#123456"
        \\    font = FontFace { family = "Menlo", weight = 700 }
        \\  }
        \\end
        \\
    ;
    try expectObjectFieldPath(source, "text", &.{"size"}, "33");
    try expectObjectFieldPath(source, "text", &.{"color"}, "0.07058824,0.20392157,0.3372549");
    try expectObjectFieldPath(source, "text", &.{ "font", "family" }, "Menlo");
    try expectObjectFieldPath(source, "text", &.{ "font", "weight" }, "700");
}

test "compiler semantics: markdown underline uses a structured style" {
    const source =
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let body = body_obj("plain _underlined_ text")
        \\  body.text.markdown.underline = MarkdownUnderlineStyle { color = c"#cc3366" opacity = 0.35 width = 5 offset = 3 dash = "8,4" }
        \\end
        \\
    ;

    try expectObjectFieldPath(source, "text", &.{ "markdown", "underline", "color" }, "0.8,0.2,0.4");
    try expectObjectFieldPath(source, "text", &.{ "markdown", "underline", "opacity" }, "0.35");
    try expectObjectFieldPath(source, "text", &.{ "markdown", "underline", "width" }, "5");
    try expectObjectFieldPath(source, "text", &.{ "markdown", "underline", "offset" }, "3");
    try expectObjectFieldPath(source, "text", &.{ "markdown", "underline", "dash" }, "8,4");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("_bad_")
        \\  body.text.markdown.underline.opacity = "opaque"
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text.markdown.underline.opacity' expects Number, got String");
}

test "compiler semantics: set_prop rejects a duplicate property definition" {
    try expectFixtureLoweringErrorDiagnostic(
        "theme/set-prop",
        "DuplicatePropertyDefinition: property 'text' is already defined on this target",
    );
}

test "compiler semantics: text carries themed markdown heading styles" {
    try expectFixtureObjectFieldPath("theme/markdown-heading-text", "markdown_headings", &.{ "h2", "text", "size" }, "35");
    try expectFixtureObjectFieldPath("theme/markdown-heading-text", "markdown_headings", &.{ "h2", "text", "color" }, "0.08235294,0.47843137,0.16862746");
    try expectFixtureObjectFieldPath("theme/markdown-heading-text", "markdown_headings", &.{ "h6", "text", "size" }, "17");
}

test "compiler semantics: shared theme style application keeps text decoration and layout" {
    try expectFixtureObjectFieldPath("theme/text-decoration-layout", "layout", &.{"x"}, "137");
    try expectFixtureObjectFieldPath("theme/text-decoration-layout", "underline", &.{"color"}, "0.6313726,0.14901961,0.30980393");
    try expectFixtureObjectFieldPath("theme/text-decoration-layout", "underline", &.{"width"}, "3");
}

test "compiler semantics: all themed text constructors apply their theme records" {
    try expectFixtureObjectFieldPath("theme/direct-constructors", "text", &.{"size"}, "29");
    try expectFixtureObjectFieldPath("theme/direct-constructors", "text", &.{"size"}, "18");
    try expectFixtureObjectFieldPath("theme/direct-constructors", "text", &.{"size"}, "16");
    try expectFixtureObjectFieldPath("theme/direct-constructors", "text", &.{"size"}, "17");
    try expectFixtureObjectFieldPath("theme/generated-constructors", "text", &.{"size"}, "17");
    try expectFixtureObjectFieldPath("theme/generated-constructors", "text", &.{"size"}, "18");
    try expectFixtureObjectFieldPath("theme/generated-constructors", "text", &.{"size"}, "19");
}

test "compiler semantics: image chrome and typed toc text accept explicit styles" {
    try expectFixtureObjectFieldPath("theme/image", "chrome", &.{"stroke"}, "0.19215687,0.36078432,0.65882355");
    try expectFixtureObjectFieldPath("theme/image", "chrome", &.{"pad_x"}, "17");
    try expectFixtureDumpContains("theme/toc-style", &.{ "\"font_size\":41.0", "\"font_size\":23.0" });
}

test "compiler semantics: nested property assignment updates style records" {
    const source =
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let body = body_obj("style")
        \\  body.text.size = 33
        \\  body.text.color = c"#123456"
        \\  body.text.font.family = "Menlo"
        \\  body.text.font.weight = 650
        \\  body.text.font.style = FontStyle.italic
        \\  body.text.font.stretch = FontStretch.expanded
        \\  body.layout.x = 123
        \\  body.layout.wrap = WrapMode.off
        \\
        \\end
        \\
    ;
    try expectObjectFieldPath(source, "text", &.{"size"}, "33");
    try expectObjectFieldPath(source, "text", &.{"color"}, "0.07058824,0.20392157,0.3372549");
    try expectObjectFieldPath(source, "text", &.{ "font", "family" }, "Menlo");
    try expectObjectFieldPath(source, "text", &.{ "font", "weight" }, "650");
    try expectObjectFieldPath(source, "text", &.{ "font", "style" }, "italic");
    try expectObjectFieldPath(source, "text", &.{ "font", "stretch" }, "expanded");
    try expectObjectFieldPath(source, "layout", &.{"x"}, "123");
    try expectObjectFieldPath(source, "layout", &.{"wrap"}, "off");
}

test "compiler semantics: nested property definitions preserve sibling leaves" {
    const source =
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let body = body_obj("style")
        \\  body.text.size = 21
        \\  body.text.font.family = "Avenir"
        \\  body.text.font.weight = 600
        \\  body.text.markdown.bold_color = c"#445566"
        \\  body.text.color = c"#123456"
        \\  body.text.font.style = FontStyle.italic
        \\end
        \\
    ;
    try expectObjectFieldPath(source, "text", &.{"size"}, "21");
    try expectObjectFieldPath(source, "text", &.{ "font", "family" }, "Avenir");
    try expectObjectFieldPath(source, "text", &.{ "font", "weight" }, "600");
    try expectObjectFieldPath(source, "text", &.{ "font", "style" }, "italic");
    try expectObjectFieldPath(source, "text", &.{ "markdown", "bold_color" }, "0.26666668,0.33333334,0.4");
    try expectObjectFieldPath(source, "text", &.{"color"}, "0.07058824,0.20392157,0.3372549");
}

test "compiler semantics: nested property definitions accept explicit none" {
    const source =
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let body = body_obj("style")
        \\  body.text.markdown.bold_color = none
        \\end
        \\
    ;
    try expectObjectFieldPathNone(source, "text", &.{ "markdown", "bold_color" });
}

test "compiler semantics: nested property assignment rejects invalid paths and values" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  body.text.missing = 1
        \\end
        \\
    , "case.ss:bytes:", "UnknownField: type 'TextStyle' has no field 'missing'");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  body.text.size.value = 1
        \\end
        \\
    , "case.ss:bytes:", "InvalidValueUpdatePath: field 'text.size' has type Number, which has no fields");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  body.link_id.value = "id"
        \\end
        \\
    , "case.ss:bytes:", "InvalidValueUpdatePath: field 'link_id' has type String, which has no fields");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  body.text.size = "large"
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text.size' expects Number, got String");
}

test "compiler semantics: code theme helpers set code and markdown colors" {
    try buildSource(
        \\import std:themes/default as *
        \\import std:code as palettes
        \\
        \\const theme: Theme = default_theme() with { code.highlight = palettes::code_theme_one_dark() }
        \\
        \\page ok
        \\  code!("fn demo() -> Void\nend", "ss", theme.code)
        \\  text!("```ss\nfn demo() -> Void\nend\n```")
        \\end
        \\
    );

    const explicit_source =
        \\import std:themes/default as *
        \\import std:code as palettes
        \\
        \\page ok
        \\  let colors = palettes::code_theme_one_dark()
        \\  let snippet = code!("fn demo() -> Void\nend", "ss", default_theme().code with { highlight = colors })
        \\  let body = text!("```ss\nfn demo() -> Void\nend\n```", default_text_style with { text.markdown.code.colors = colors.code })
        \\end
        \\
    ;
    try expectObjectFieldPath(explicit_source, "code", &.{"keyword"}, "0.7764706,0.47058824,0.8666667");
    try expectObjectFieldPath(explicit_source, "code", &.{"function"}, "0.38039216,0.6862745,0.9372549");
    try expectObjectFieldPath(explicit_source, "text", &.{ "markdown", "code", "colors", "keyword" }, "0.7764706,0.47058824,0.8666667");
    try expectObjectFieldPath(explicit_source, "text", &.{ "markdown", "code", "colors", "function" }, "0.38039216,0.6862745,0.9372549");
}

test "compiler semantics: default theme applies code theme to code and markdown" {
    const source =
        \\import std:themes/default as *
        \\
        \\page ok
        \\  code!("const value = demo(1)", "javascript")
        \\  text!("```javascript\nconst value = demo(1)\n```", default_theme().body with { text.markdown.code.colors = default_theme().code.highlight.code })
        \\end
        \\
    ;
    try expectResolvedCodePaintIsColorful(source);
    try expectObjectFieldPath(source, "code", &.{"plain"}, "0.14117648,0.16078432,0.18431373");
    try expectObjectFieldPath(source, "code", &.{"keyword"}, "0.8117647,0.13333334,0.18039216");
    try expectObjectFieldPath(source, "text", &.{ "markdown", "code", "colors", "plain" }, "0.14117648,0.16078432,0.18431373");
    try expectObjectFieldPath(source, "text", &.{ "markdown", "code", "colors", "keyword" }, "0.8117647,0.13333334,0.18039216");
    try expectObjectFieldPath(source, "text", &.{ "markdown", "code", "chrome", "fill" }, "0.9647059,0.972549,0.98039216");
}

test "compiler semantics: default code fonts use the generic monospace family" {
    const code_source =
        \\import std:themes/default as *
        \\
        \\page ok
        \\  code!("const value = 1", "javascript")
        \\end
        \\
    ;
    try expectObjectFieldPath(code_source, "text", &.{ "font", "family" }, "monospace");
    try expectObjectFieldPath(code_source, "text", &.{ "code_font", "family" }, "monospace");

    const markdown_source =
        \\import std:themes/default as *
        \\
        \\page ok
        \\  text!("```javascript\nconst value = 1\n```")
        \\end
        \\
    ;
    try expectObjectFieldPath(markdown_source, "text", &.{ "code_font", "family" }, "monospace");
}

test "compiler semantics: structured style value members are typed" {
    try expectObjectFieldPath(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let body = body_obj("style")
        \\  let style = TextStyle { size = 31 }
        \\  body.text.size = style.size
        \\end
        \\
    , "text", &.{"size"}, "31");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  body.text = FontFace { family = "Menlo" }
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text' expects TextStyle, got FontFace");
}

test "compiler semantics: ordinary values reject direct and nested field assignment" {
    try expectDiagnostic(
        \\type Inner { size: Number = 20 }
        \\page main
        \\  let value = Inner {}
        \\  value.size = 24
        \\end
    , "case.ss:bytes:", "ImmutableValue: field 'size' belongs to an immutable value; use with to construct an updated value");
    try expectDiagnostic(
        \\type Inner { size: Number = 20 }
        \\type Outer { inner: Inner = Inner {} }
        \\page main
        \\  let value = Outer {}
        \\  value.inner.size = 24
        \\end
    , "case.ss:bytes:", "ImmutableValue: field 'size' belongs to an immutable value; use with to construct an updated value");
}

test "compiler semantics: ordinary value updates copy nested fields" {
    try expectObjectFieldPath(
        \\import std:themes/default as *
        \\
        \\type Inner {
        \\  size: Number = 20
        \\  color: Color = c"#111111"
        \\}
        \\
        \\type LocalTheme {
        \\  body: Inner = Inner {}
        \\}
        \\
        \\page ok
        \\  let base = LocalTheme {}
        \\  let changed = base with {
        \\    body.size = 33
        \\  }
        \\  let body = body_obj("changed")
        \\  body.text = TextStyle {
        \\    size = changed.body.size
        \\    color = changed.body.color
        \\  }
        \\end
        \\
    , "text", &.{"size"}, "33");

    try expectObjectFieldPath(
        \\import std:themes/default as *
        \\
        \\type Inner {
        \\  size: Number = 20
        \\}
        \\
        \\type LocalTheme {
        \\  body: Inner = Inner {}
        \\}
        \\
        \\page ok
        \\  let base = LocalTheme {}
        \\  let changed = base with {
        \\    body.size = 33
        \\  }
        \\  let body = body_obj("base")
        \\  body.text = TextStyle {
        \\    size = base.body.size
        \\  }
        \\end
        \\
    , "text", &.{"size"}, "20");
}

test "compiler semantics: explicit record fields override their defaults" {
    const source =
        \\import std:themes/default as *
        \\
        \\type Label {
        \\  text: String = "default"
        \\}
        \\
        \\page ok
        \\  let label = Label {
        \\    text = "explicit"
        \\  }
        \\  text!(label.text)
        \\end
        \\
    ;
    try expectObjectContent(source, "explicit");
    try expectRecordStringDefaultNotEvaluated(source, "Label", "text");
}

test "compiler semantics: function defaults and closures use callee bindings" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\type Inner {
        \\  size: Number = 20
        \\}
        \\
        \\type LocalTheme {
        \\  body: Inner = Inner {}
        \\}
        \\
        \\fn choose_theme(first: LocalTheme, second: LocalTheme = first) -> LocalTheme
        \\  return second
        \\end
        \\
        \\fn make_reader(theme: LocalTheme) -> Number -> Number
        \\  return (ignored: Number) |-> theme.body.size
        \\end
        \\
        \\page ok
        \\  let selected = choose_theme(LocalTheme {
        \\    body = Inner {
        \\      size = 31
        \\    }
        \\  })
        \\  let read_size = make_reader(selected)
        \\  text!(str(read_size(0)))
        \\end
        \\
    , "31");
}

test "compiler semantics: nested record member reads preserve their source value" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\type Inner {
        \\  size: Number = 20
        \\}
        \\
        \\type LocalTheme {
        \\  body: Inner = Inner {}
        \\}
        \\
        \\page ok
        \\  let base = LocalTheme {}
        \\  let changed = base with {
        \\    body.size = 33
        \\  }
        \\  text!(str(base.body.size) ++ ":" ++ str(changed.body.size) ++ ":" ++ str(base.body.size))
        \\end
        \\
    , "20:33:20");
}

test "compiler semantics: record update makes updated style leaves explicit" {
    try expectObjectFieldPath(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let body = body_obj("style")
        \\  let style = TextStyle {} with {
        \\    size = 31
        \\  }
        \\  body.text = style
        \\end
        \\
    , "text", &.{"size"}, "31");
}

test "compiler semantics: record update rejects invalid paths and values" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let style = TextStyle {} with {
        \\    missing = 1
        \\  }
        \\end
        \\
    , "case.ss:bytes:", "UnknownField: type 'TextStyle' has no field 'missing'");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let style = TextStyle {} with {
        \\    font.family.name = "bad"
        \\  }
        \\end
        \\
    , "case.ss:bytes:", "InvalidValueUpdatePath: field 'font.family' has type String, which has no fields");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let style = TextStyle {} with {
        \\    size = "large"
        \\  }
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Number, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let style = TextStyle {} with {
        \\    font = FontFace {}
        \\    font.family = "Menlo"
        \\  }
        \\end
        \\
    , "case.ss:bytes:", "OverlappingValueUpdate: update path 'font' overlaps 'font.family'");
}

test "compiler semantics: theme values customize imported defaults and local styles" {
    const theme_source =
        \\import std:themes/default as *
        \\import std:text as base
        \\
        \\const presentation: Theme = default_theme() with {
        \\    body.text.size = 22
        \\    h1.text.color = c"#123456"
        \\  }
        \\
        \\fn/! h1(text_value: String, theme: Theme = presentation) -> Text
        \\  return base::text(text_value, theme.h1 with {
        \\    text.size = 44
        \\  })
        \\end
        \\
    ;

    try expectObjectFieldPathWithThemeOverlay(
        \\import "./theme" as *
        \\
        \\page ok
        \\  text!("body", presentation.body)
        \\end
        \\
    , theme_source, "text", &.{"size"}, "22");

    try expectObjectFieldPathWithThemeOverlay(
        \\import "./theme" as *
        \\
        \\page ok
        \\  h1!("title")
        \\end
        \\
    , theme_source, "text", &.{"size"}, "44");

    try expectObjectFieldPathWithThemeOverlay(
        \\import "./theme" as *
        \\
        \\page ok
        \\  let local = presentation with {
        \\    body.text.size = 18
        \\  }
        \\  text!("small", local.body)
        \\end
        \\
    , theme_source, "text", &.{"size"}, "18");
}

test "compiler semantics: user record declarations define typed record values" {
    try expectObjectFieldPath(
        \\import std:themes/default as *
        \\
        \\type CaptionStyle {
        \\  size: Number = 18
        \\  color: Color = c"0.2,0.2,0.2"
        \\}
        \\
        \\fn large(style: CaptionStyle) -> CaptionStyle
        \\  return CaptionStyle {
        \\    size = style.size + 4
        \\    color = style.color
        \\  }
        \\end
        \\
        \\page ok
        \\  let body = body_obj("caption")
        \\  let style = large(CaptionStyle { size = 20 })
        \\  body.text = TextStyle {
        \\    size = style.size
        \\    color = style.color
        \\  }
        \\end
        \\
    , "text", &.{"size"}, "24");
}

test "compiler semantics: optional fields accept none and coalesce" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\fn fallback(value: Color?) -> Color
        \\  return value ?? c"0,0,0"
        \\end
        \\
        \\page ok
        \\  let body = body_obj("ok")
        \\  body.text.markdown.code.chrome.fill = none
        \\  body.text.color = fallback(body.text?.markdown?.code?.chrome?.fill)
        \\end
        \\
    );

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn id(c: Color?) -> Color
        \\  return c
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color, got Color?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  body.text.color = none
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text.color' expects Color, got None");

    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn name(value: None) -> String
        \\  return "none"
        \\end
        \\
        \\page ok
        \\  text!(name(none))
        \\end
        \\
    , "none");

    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let body = body_obj("body")
        \\  if body.text?.markdown?.code?.chrome?.fill?
        \\    body_obj("still-set")
        \\  else
        \\    body_obj("unset")
        \\  end
        \\end
        \\
    , "unset");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let color = c"1,0,0"
        \\  if color?
        \\    text!("bad")
        \\  end
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: '?' expects an optional value");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let color = c"1,0,0"
        \\  let value = color ?? c"0,0,0"
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: '??' expects an optional value");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn fallback(value: Color?) -> Color
        \\  return value ?? "black"
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color, got String");
}

test "compiler semantics: optional values are checked at function boundaries" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn take_color(value: Color) -> Color
        \\  return value
        \\end
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  body.text.color = take_color(body.text?.markdown?.code?.chrome?.fill)
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color, got Color?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn take_maybe(value: Color?) -> Color?
        \\  return value
        \\end
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  body.text.markdown.code.chrome.fill = take_maybe("red")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color?, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn bad_return(value: Color?) -> Color
        \\  if true
        \\    return value
        \\  else
        \\    return c"0,0,0"
        \\  end
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color, got Color?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn bad_optional_return() -> Color?
        \\  return 1
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color?, got Number");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn bad_default(value: Color = "red") -> Color
        \\  return value
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn bad_optional_default(value: Color? = "red") -> Color?
        \\  return value
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color?, got String");
}

test "compiler semantics: optional values stay checked through multi-step flows" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn may_be_none(target: Body, prefer_markup: Bool) -> Color?
        \\  if prefer_markup
        \\    return target.text?.markdown?.code?.chrome?.fill
        \\  else
        \\    if target.link_id?
        \\      return c"0.1,0.2,0.3"
        \\    else
        \\      return none
        \\    end
        \\  end
        \\end
        \\
        \\fn must_call_by_notnone(color: Color) -> Color
        \\  return color
        \\end
        \\
        \\page bad
        \\  let body = body_obj("report")
        \\  body.text.markdown.code.chrome.fill = none
        \\  let x = may_be_none(body, true)
        \\  let y = must_call_by_notnone(x)
        \\  body.text.color = y
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color, got Color?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn choose_color(primary: Color?, fallback: Color?, use_primary: Bool, allow_fallback: Bool) -> Color
        \\  let chosen = primary
        \\  if use_primary
        \\    if chosen?
        \\      return chosen
        \\    else
        \\      return c"0,0,0"
        \\    end
        \\  else
        \\    if allow_fallback
        \\      return fallback ?? c"0.2,0.2,0.2"
        \\    else
        \\      return c"0.8,0.8,0.8"
        \\    end
        \\  end
        \\end
        \\
        \\page bad
        \\  body_obj!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color, got Color?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn apply_palette(target: Body, primary: Color?, secondary: Color?) -> Void
        \\  let chosen = primary
        \\  if target.link_id?
        \\    target.text.color = chosen
        \\  else
        \\    target.text.markdown.code.chrome.fill = secondary
        \\  end
        \\end
        \\
        \\page bad
        \\  let body = body_obj("body")
        \\  apply_palette(body, none, c"0.3,0.3,0.3")
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text.color' expects Color, got Color?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Status { draft reviewing ready }
        \\
        \\fn maybe_status(has_owner: Bool, has_review: Bool) -> Status?
        \\  if has_owner
        \\    if has_review
        \\      return Status.ready
        \\    else
        \\      return Status.reviewing
        \\    end
        \\  else
        \\    return none
        \\  end
        \\end
        \\
        \\fn publish(status: Status) -> Status
        \\  return status
        \\end
        \\
        \\page bad
        \\  let status = maybe_status(true, false)
        \\  if status?
        \\    let published = publish(status)
        \\  else
        \\    body_obj!("missing")
        \\  end
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Status, got Status?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Status { draft reviewing ready }
        \\enum OtherStatus { draft reviewing ready }
        \\
        \\fn normalize_status(status: Status?, fallback: OtherStatus, force_fallback: Bool) -> Status
        \\  if force_fallback
        \\    return fallback
        \\  else
        \\    if status?
        \\      return status ?? Status.draft
        \\    else
        \\      return Status.reviewing
        \\    end
        \\  end
        \\end
        \\
        \\page bad
        \\  body_obj!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Status, got OtherStatus");
}

test "compiler semantics: mismatched if branches are rejected statically" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn choose_text_color(use_theme: Bool) -> Color
        \\  if use_theme
        \\    return c"0.1,0.1,0.1"
        \\  else
        \\    return "black"
        \\  end
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn maybe_accent(target: Body, use_saved: Bool, force_number: Bool) -> Color?
        \\  if use_saved
        \\    return target.text?.markdown?.code?.chrome?.fill
        \\  else
        \\    if force_number
        \\      return 1
        \\    else
        \\      return none
        \\    end
        \\  end
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color?, got Number");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn choose_from_branch_local(target: Body, maybe_color: Color?, prefer_saved: Bool) -> Color
        \\  if prefer_saved
        \\    let chosen = maybe_color
        \\    return chosen
        \\  else
        \\    let chosen = target.text?.color ?? c"0,0,0"
        \\    return chosen
        \\  end
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color, got Color?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn paint_target(target: Body, maybe_color: Color?, use_optional: Bool) -> Void
        \\  if use_optional
        \\    target.text.color = maybe_color
        \\  else
        \\    target.text.color = c"0.1,0.1,0.1"
        \\  end
        \\end
        \\
        \\page bad
        \\  let body = text("body")
        \\  paint_target(body, none, true)
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text.color' expects Color, got Color?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Status { draft ready }
        \\enum OtherStatus { draft ready }
        \\
        \\fn choose_status(primary: Status, fallback: OtherStatus, use_primary: Bool) -> Status
        \\  if use_primary
        \\    return primary
        \\  else
        \\    return fallback
        \\  end
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Status, got OtherStatus");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  roles = ["card"]
        \\}
        \\
        \\fn choose_card(card_value: Card, body_value: Body, use_card: Bool) -> Card
        \\  if use_card
        \\    return card_value
        \\  else
        \\    return body_value
        \\  end
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Object<Card>, got Object<Body>");
}

test "compiler semantics: if branch checks do not depend on optional types" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn choose_score(use_score: Bool) -> Number
        \\  if use_score
        \\    return 1
        \\  else
        \\    return "missing"
        \\  end
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Number, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn choose_score(use_score: Bool) -> Number
        \\  if use_score
        \\    if "enabled"
        \\      return 1
        \\    else
        \\      return 2
        \\    end
        \\  else
        \\    return 3
        \\  end
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Bool, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn choose_score(use_score: Bool) -> Number
        \\  if use_score
        \\    return 1
        \\  else
        \\    return true
        \\  end
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Number, got Bool");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn configure_text(target: Body, compact: Bool) -> Void
        \\  if compact
        \\    target.text.size = "small"
        \\  else
        \\    target.text.size = 24
        \\  end
        \\end
        \\
        \\page bad
        \\  let body = text("body")
        \\  configure_text(body, true)
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text.size' expects Number, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn choose_selection(use_pages: Bool) -> Selection<Page>
        \\  if use_pages
        \\    return pages(docctx())
        \\  else
        \\    return objs_here("body")
        \\  end
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Selection<Page>, got Selection<Object>");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\
        \\fn label(x: String) -> String
        \\  return x ++ "!"
        \\end
        \\
        \\fn choose_mapper(use_number: Bool) -> Number -> Number
        \\  if use_number
        \\    return inc
        \\  else
        \\    return label
        \\  end
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Number -> Number, got String -> String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn bad_void_branch(write_number: Bool) -> Void
        \\  if write_number
        \\    return 1
        \\  else
        \\    return
        \\  end
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "VoidReturnValue: Void functions must use return without an expression");
}

test "compiler semantics: enum optional values reject strings and other enums" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\
        \\fn take_mode(value: Mode) -> Mode
        \\  return value
        \\end
        \\
        \\page bad
        \\  let mode = take_mode(none)
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Mode, got None");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\
        \\fn take_maybe(value: Mode?) -> Mode?
        \\  return value
        \\end
        \\
        \\page bad
        \\  let mode = take_maybe("alpha")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Mode?, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\enum Other { alpha beta }
        \\
        \\fn take_maybe(value: Mode?) -> Mode?
        \\  return value
        \\end
        \\
        \\page bad
        \\  let mode = take_maybe(Other.alpha)
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Mode?, got Other");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\enum Other { alpha beta }
        \\
        \\fn bad_return() -> Mode
        \\  return Other.alpha
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Mode, got Other");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\enum Other { alpha beta }
        \\
        \\fn bad_coalesce(value: Mode?) -> Mode
        \\  return value ?? Other.alpha
        \\end
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Mode, got Other");
}

test "compiler semantics: properties require known fields" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  let key = "text_color"
        \\  set_prop(body, key, c"1,0,0")
        \\end
        \\
    , "case.ss:bytes:", "InvalidProperty: property key must be a known field literal");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  body.no_such_field = "x"
        \\end
        \\
    , "case.ss:bytes:", "UnknownField: unknown field: no_such_field");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  let key = "text_color"
        \\  body_obj!(prop(body, key, "missing"))
        \\end
        \\
    , "case.ss:bytes:", "InvalidProperty: property key must be a known field literal");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  has_prop(body, "no_such_field")
        \\end
        \\
    , "case.ss:bytes:", "UnknownField: unknown field: no_such_field");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  body.text.color = 1
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text.color' expects Color, got Number");
}

test "compiler semantics: typed properties reject optional and wrong static values" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  set_prop(body, "text_color", body.text?.markdown?.code?.chrome?.fill)
        \\end
        \\
    , "case.ss:bytes:", "UnknownField: unknown field: text_color");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\document
        \\  docctx().background_fill = "white"
        \\end
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'background_fill' expects Color?, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  body_obj!("body")
        \\  objs_here("body").text.color = none
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text.color' expects Color, got None");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  body.text.markdown.code.chrome.fill = 1
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text.markdown.code.chrome.fill' expects Color?, got Number");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("bad")
        \\  set_prop(body, "text_markdown_code_fill", "red")
        \\end
        \\
    , "case.ss:bytes:", "UnknownField: unknown field: text_markdown_code_fill");
}

test "compiler semantics: object field defaults are statically typed" {
    const defaults_source =
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\type Card = object {
        \\  roles = ["card"]
        \\  size: Number = 1.02
        \\  offset: Number = -1.5
        \\  accent: Color = c"#334455"
        \\  optional_accent: Color? = none
        \\  mode: Mode = Mode.beta
        \\  enabled: Bool = true
        \\  label: String = "default label"
        \\}
        \\
        \\page ok
        \\  let card = obj("card", "card", "text")
        \\end
        \\
    ;
    try expectClassDefaultProperty(defaults_source, "card", "size", "1.02");
    try expectClassDefaultProperty(defaults_source, "card", "offset", "-1.5");
    try expectClassDefaultProperty(defaults_source, "card", "accent", "0.2,0.26666668,0.33333334");
    try expectClassDefaultProperty(defaults_source, "card", "optional_accent", null);
    try expectClassDefaultProperty(defaults_source, "card", "mode", "beta");
    try expectClassDefaultProperty(defaults_source, "card", "enabled", "true");
    try expectClassDefaultProperty(defaults_source, "card", "label", "default label");

    const nested_defaults_source =
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\type Outer {
        \\  inner: Inner = Inner {}
        \\}
        \\type Inner {
        \\  mode: Mode = Mode.beta
        \\}
        \\type Card = object {
        \\  roles = ["card"]
        \\  config: Outer = Outer {}
        \\}
        \\
        \\page ok
        \\  let card = obj("card", "card", "text")
        \\end
        \\
    ;
    try expectClassDefaultProperty(
        nested_defaults_source,
        "card",
        "config",
        "{\"kind\":\"record\",\"type\":{\"kind\":\"record\",\"name\":\"Outer\",\"module\":0},\"fields\":[{\"name\":\"inner\",\"explicit\":false,\"value\":{\"kind\":\"record\",\"type\":{\"kind\":\"record\",\"name\":\"Inner\",\"module\":0},\"fields\":[{\"name\":\"mode\",\"explicit\":false,\"value\":{\"kind\":\"enum\",\"type\":\"Mode\",\"module\":0,\"case\":\"beta\"}}]}}]}",
    );

    try expectBodyTextDefaults(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  text!("body", default_theme().body)
        \\end
        \\
    , .{
        .math_scale = 1.05,
        .inline_math_spacing = 0.08,
        .markdown_table_line_width = 0.8,
    });

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  accent: Color = "red"
        \\}
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldDefault: default value does not match field type Color");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  accent: Color = none
        \\}
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldDefault: default value does not match field type Color");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  accent: Color? = "red"
        \\}
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldDefault");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  count: Number = 1 + 2
        \\}
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldDefault: default value does not match field type Number");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  label: String = "a" ++ "b"
        \\}
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldDefault: default value does not match field type String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\type Card = object {
        \\  mode: Mode = "alpha"
        \\}
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldDefault: default value does not match field type Mode");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\enum Mode { alpha beta }
        \\enum Other { alpha beta }
        \\type Card = object {
        \\  mode: Mode = Other.alpha
        \\}
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldDefault: default value does not match field type Mode");
}

test "compiler semantics: document page and selection properties are typed" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\document
        \\  docctx().math_align = Align.left
        \\end
        \\
        \\page ok
        \\  body_obj!(prop(docctx(), "math_align", "missing"))
        \\  body_obj!("body")
        \\  objs_here("body").layout.wrap = WrapMode.off
        \\end
        \\
    , "left");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\document
        \\  docctx().math_align = "left"
        \\end
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'math_align' expects Align, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  body_obj!("body")
        \\  objs_here("body").layout.wrap = "off"
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'layout.wrap' expects WrapMode, got String");
}

test "compiler semantics: document math alignment uses a typed property" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\document
        \\  docctx().math_align = Align.left
        \\end
        \\
        \\page ok
        \\  body_obj!(prop(docctx(), "math_align", "missing"))
        \\end
        \\
    , "left");
}

test "compiler semantics: math alignment rejects unknown literals" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("$$x^2$$")
        \\  body.math_align = "sideways"
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'math_align' expects Align, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = body_obj("$$x^2$$")
        \\  body.math_align = Align.sideways
        \\end
        \\
    , "case.ss:bytes:", "UnknownEnumCase: enum 'Align' has no case 'sideways'");
}

test "compiler semantics: member sugar reads and writes properties and content" {
    try expectLoweringErrorDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let target = body_obj("hello")
        \\  target.content = target.content ++ "!"
        \\end
        \\
    , "ExecutionDependencyCycle: document evaluation dependencies contain a cycle");

    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let target = body_obj("styled")
        \\  target.link_id = "custom"
        \\  if target.link_id?
        \\    body_obj!(target.link_id ?? "missing")
        \\  end
        \\end
        \\
    , "custom");

    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\document
        \\  docctx().footer_text = "footer"
        \\  foreach(pages(docctx()), (p: Page) |-> place_on!(p, text(docctx().footer_text ?? "")))
        \\end
        \\
        \\page ok
        \\end
        \\
    , "footer");
}

test "compiler semantics: chained member assignment writes through record fields" {
    const source =
        \\import std:themes/default as *
        \\
        \\type Parts {
        \\  root: Object
        \\  middle: Object
        \\}
        \\
        \\fn make_parts() -> Parts
        \\  let middle = body_obj("middle")
        \\  return Parts {
        \\    root = group(middle)
        \\    middle = middle
        \\  }
        \\end
        \\
        \\page ok
        \\  let parts = make_parts()
        \\  place_on!(pagectx(), parts.root)
        \\  parts.middle.link_id = "changed"
        \\  parts.middle.text.color = c"#ff0000"
        \\end
        \\
    ;

    try expectObjectContent(source, "middle");
    try expectObjectProperty(source, "link_id", "changed");
    try expectObjectFieldPath(source, "text", &.{"color"}, "1,0,0");
}

test "compiler semantics: member reads materialize typed property values" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn wrap_label(value: WrapMode) -> String
        \\  return "wrap"
        \\end
        \\
        \\fn link_label(value: String) -> String
        \\  return value
        \\end
        \\
        \\fn render_label(value: RenderKind) -> String
        \\  return "render"
        \\end
        \\
        \\page ok
        \\  let target = body_obj("typed")
        \\  target.layout.wrap = WrapMode.off
        \\  target.text.size = 24
        \\  target.link_id = "custom"
        \\  target.text.markdown.code.chrome.fill = c"0.1,0.2,0.3"
        \\  let panel_obj = new("", "panel", "text")
        \\  let other = body_obj("color")
        \\  other.text.color = target.text?.markdown?.code?.chrome?.fill ?? c"0,0,0"
        \\  body_obj(wrap_label(target.layout?.wrap ?? WrapMode.on) ++ ":" ++ str(target.text?.size ?? 0) ++ ":" ++ link_label(target.link_id ?? "fallback"))
        \\  body_obj(render_label(panel_obj.render_kind ?? RenderKind.text))
        \\end
        \\
    , "wrap:24:custom");

    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn render_label(value: RenderKind) -> String
        \\  return "render"
        \\end
        \\
        \\page ok
        \\  let panel_obj = new("", "panel", "text")
        \\  body_obj(render_label(panel_obj.render_kind ?? RenderKind.text))
        \\end
        \\
    , "render");
}

test "compiler semantics: logical not inverts optional presence checks" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn optional_color_label(target: Body) -> String
        \\  if !target.text?.markdown?.code?.chrome?.fill?
        \\    return "none"
        \\  else
        \\    return "some"
        \\  end
        \\end
        \\
        \\page ok
        \\  let unset = body_obj("unset")
        \\  let set = body_obj("set")
        \\  set.text.markdown.code.chrome.fill = c"0.1,0.2,0.3"
        \\  body_obj(optional_color_label(unset) ++ ":" ++ optional_color_label(set))
        \\end
        \\
    , "none:some");

    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn none_label(value: Bool?) -> String
        \\  if !value?
        \\    return "none"
        \\  else
        \\    return "some"
        \\  end
        \\end
        \\
        \\page ok
        \\  text!(none_label(none) ++ ":" ++ none_label(false) ++ ":" ++ none_label(true))
        \\end
        \\
    , "none:some:some");

    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn none_label(value: String?) -> String
        \\  if !value?
        \\    return "none"
        \\  else
        \\    return "some"
        \\  end
        \\end
        \\
        \\page ok
        \\  text!(none_label(none) ++ ":" ++ none_label("") ++ ":" ++ none_label("value"))
        \\end
        \\
    , "none:some:some");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  if !1
        \\    text!("bad")
        \\  end
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Bool, got Number");
}

test "compiler semantics: page numbers accept default and custom format functions" {
    try expectObjectContent(
        \\document
        \\  foreach(pages(docctx()), (p: Page) |-> place_on!(p, pageno()))
        \\end
        \\page one
        \\end
        \\page two
        \\end
    , "1/2");
    try expectObjectContent(
        \\fn label(p: Page, d: Document) -> String = str(page_index(p)) ++ " of " ++ str(page_count(d))
        \\document
        \\  foreach(pages(docctx()), (p: Page) |-> place_on!(p, pageno(TextBlockStyle {}, label)))
        \\end
        \\page one
        \\end
        \\page two
        \\end
    , "1 of 2");
}

test "compiler semantics: removed render kind chrome case is rejected" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let panel_obj = new("", "panel", "text")
        \\  panel_obj.render_kind = RenderKind.chrome
        \\end
        \\
    , "case.ss:bytes:", "UnknownEnumCase: enum 'RenderKind' has no case 'chrome'");
}

test "compiler semantics: pass annotation is rejected" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\@pass
        \\fn old_pass(doc: Document) -> Document
        \\  return doc
        \\end
        \\
        \\page bad
        \\  text!("hello")
        \\end
        \\
    );
}

test "compiler semantics: page number display reads the completed page graph" {
    try expectObjectContent(
        \\page one
        \\  pageno!()
        \\end
        \\page two
        \\end
    , "1/2");
}

test "compiler semantics: scheduled document statements share document scope" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\document
        \\  let label = "from document scope"
        \\  foreach(
        \\    pages(docctx()),
        \\    (page_value: Page) |-> place_on!(page_value, new(label, "body", "text"))
        \\  )
        \\end
        \\
        \\page one
        \\end
        \\
    , "from document scope");
}

test "compiler semantics: scheduled page statements share page scope" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page one
        \\  let label = "from page scope"
        \\  text!(label)
        \\end
        \\
    , "from page scope");
}

test "compiler semantics: variable resources keep let bindings before references" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page one
        \\  let label_text = "from variable"
        \\  text!(label_text)
        \\end
        \\
    , "from variable");
}

test "compiler semantics: document property writes schedule before reads" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\document
        \\  docctx().footer_text = "before"
        \\end
        \\
        \\page first
        \\  text!(docctx().footer_text ?? "unset")
        \\end
        \\
    , "before");

    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page first
        \\  text!(docctx().footer_text ?? "unset")
        \\end
        \\
        \\document
        \\  docctx().footer_text = "after"
        \\end
        \\
    , "after");
}

test "compiler semantics: content definitions cannot replace constructor content" {
    try expectLoweringErrorDiagnostic(
        \\import std:themes/default as *
        \\
        \\page one
        \\  let item = new("old", "body", "text")
        \\  let observed = new(content(item), "note", "text")
        \\  set_content(item, "new")
        \\end
        \\
    , "DuplicateContentDefinition: object content is already defined");
}

test "compiler semantics: repeated content definitions are rejected" {
    try expectLoweringErrorDiagnostic(
        \\import std:themes/default as *
        \\
        \\page one
        \\  let item = new("old", "body", "text")
        \\  set_content(item, "one")
        \\  set_content(item, "two")
        \\  let observed = new(content(item), "note", "text")
        \\end
        \\
    , "DuplicateContentDefinition: object content is already defined");
}

test "compiler semantics: independent claim properties join before summary reads" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\import std:internal/classes as { Text }
        \\
        \\type Claim = object {
        \\  base = Text
        \\  roles = ["claim"]
        \\  suffix: String? = none
        \\  number_prefix: String? = none
        \\}
        \\
        \\fn/! claim(text_value: String) -> Object
        \\  return txt_obj(text_value, "claim")
        \\end
        \\
        \\fn number_claim(item: Object, index: Number) -> Object
        \\  item.number_prefix = str(index) ++ ":"
        \\  return item
        \\end
        \\
        \\fn claim_text(item: Object) -> String
        \\  let prefix = item.number_prefix ?? ""
        \\  let suffix = item.suffix ?? ""
        \\  return prefix ++ item.content ++ suffix
        \\end
        \\
        \\document
        \\  foreach_enumerate(doc_objs(docctx(), "claim"), number_claim)
        \\end
        \\
        \\page summary
        \\  text!(join(doc_objs(docctx(), "claim"), ",", claim_text))
        \\end
        \\
        \\page one
        \\  let a = claim!("A")
        \\  a.suffix = "!"
        \\end
        \\
        \\page two
        \\  claim!("B")
        \\end
        \\
    , "1:A!,2:B");
}

test "compiler semantics: typed displays materialize immutable input fields" {
    try expectObjectContent(
        \\type Claim { content: String suffix: String = "!" }
        \\fn display(self: Placed<Claim>) -> Text = text(self.value.content ++ self.value.suffix)
        \\page one
        \\  place!(Claim { content = "A" })
        \\end
    , "A!");
}

test "compiler semantics: pure optional higher order display helpers are accepted" {
    try expectObjectContent(
        \\type Label { content: String format: (String -> String)? = none }
        \\fn apply(value: String, format: String -> String) -> String = format(value)
        \\fn display(self: Placed<Label>) -> Text
        \\  let format = self.value.format ?? ((value: String) |-> value)
        \\  return text(apply(self.value.content, format))
        \\end
        \\page main
        \\  place!(Label { content = "A" format = (value: String) |-> value ++ "!" })
        \\  place!(Label { content = "B" })
        \\end
    , "A!");
}

test "compiler semantics: typed displays keep separate constructor captures" {
    try expectFixtureObjectContent("display-captures", "A!");
    try expectFixtureObjectContent("display-captures", "B?");
}

test "compiler semantics: typed display chains retain nested callback captures" {
    try expectFixtureObjectContent("display-chain", "leaf!!");
}

test "compiler semantics: imported display helpers use their definition environment" {
    try expectOverlayDiagnostic(
        \\import "./lib/bad" as lib
        \\fn helper() -> String = "safe"
        \\page main
        \\  place!(lib::Label {})
        \\end
    ,
        \\type Label {}
        \\fn helper() -> String = readlines("missing.txt")
        \\fn display(self: Placed<Label>) -> Text = text(helper())
    , "lib/bad.ss:bytes:", "ImpureDisplayFunction");
    try buildSourceWithOverlay(
        \\import "./lib/types" as lib
        \\fn helper() -> String = readlines("missing.txt")
        \\page main
        \\  place!(lib::Label {})
        \\end
    ,
        \\type Label {}
        \\fn helper() -> String = "safe"
        \\fn display(self: Placed<Label>) -> Text = text(helper())
    );
}

test "compiler semantics: cached ordinary calls cannot bypass display purity" {
    try expectDiagnostic(
        \\type Label {}
        \\fn helper() -> String
        \\  report_warning("called")
        \\  return "label"
        \\end
        \\fn display(self: Placed<Label>) -> Text = text(helper())
        \\page main
        \\  let value = helper()
        \\  place!(Label {})
        \\end
    , "case.ss:bytes:", "ImpureDisplayFunction");
}

test "compiler semantics: lazy constant initialization cannot bypass display purity" {
    try expectDiagnostic(
        \\type Label {}
        \\fn initialize() -> String
        \\  report_warning("initializing")
        \\  return "label"
        \\end
        \\const label: String = initialize()
        \\fn display(self: Placed<Label>) -> Text = text(label)
        \\page main
        \\  let cached = label
        \\  place!(Label {})
        \\end
    , "case.ss:bytes:", "ImpureDisplayFunction");
}

test "compiler semantics: displays cannot create pages or read external files" {
    try expectDiagnostic(
        \\type Label {}
        \\fn display(self: Placed<Label>) -> Text
        \\  new_page(self.document, "unexpected")
        \\  return text("label")
        \\end
        \\page main
        \\  place!(Label {})
        \\end
    , "case.ss:bytes:", "ImpureDisplayFunction");
    try expectDiagnostic(
        \\type Label {}
        \\fn display(self: Placed<Label>) -> Text = text(readlines("unavailable.txt"))
        \\page main
        \\  place!(Label {})
        \\end
    , "case.ss:bytes:", "ImpureDisplayFunction");
}

test "compiler semantics: variable and property dependencies reject inverse cycles" {
    try expectLoweringErrorDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let item = body_obj("old")
        \\  let current = content(item)
        \\  set_content(item, current)
        \\end
        \\
    , "ExecutionDependencyCycle: document evaluation dependencies contain a cycle");
}

test "compiler semantics: void functions may finish without explicit return" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn remember() -> Void
        \\  docctx().footer_text = "remembered"
        \\end
        \\
        \\document
        \\  remember()
        \\end
        \\
        \\page one
        \\  text!(docctx().footer_text ?? "missing")
        \\end
        \\
    , "remembered");
}

test "compiler semantics: expression-bodied functions evaluate like return statements" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn bang(value: String) -> String = value ++ "!"
        \\
        \\fn remember() -> Void =
        \\  set_prop(docctx(), "footer_text", bang("saved"))
        \\
        \\document
        \\  remember()
        \\end
        \\
        \\page one
        \\  text!(docctx().footer_text ?? "missing")
        \\end
        \\
    , "saved!");
}

test "compiler semantics: paired expression-bodied functions place returned objects" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn/! badge(value: String) -> Object = body_obj(value)
        \\
        \\page one
        \\  badge!("paired")
        \\end
        \\
    , "paired");
}

test "compiler semantics: expression-bodied functions are checked against result types" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn bad_number() -> Number = "missing"
        \\
        \\page bad
        \\  text!("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Number, got String");

    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\fn side_effect() -> Void =
        \\  set_prop(docctx(), "footer_text", "done")
        \\
        \\page bad
        \\  let value = side_effect()
        \\end
        \\
    );
}

test "compiler semantics: bare return is only valid for void functions" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\fn stop() -> Void
        \\  return
        \\end
        \\
        \\document
        \\  stop()
        \\end
        \\
        \\page ok
        \\end
        \\
    );

    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\fn bad() -> String
        \\  return
        \\end
        \\
        \\page bad
        \\end
        \\
    );
}

test "compiler semantics: void results cannot be used as values" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\fn side_effect() -> Void
        \\end
        \\
        \\page bad
        \\  let value = side_effect()
        \\end
        \\
    );
}

test "compiler semantics: lambda callbacks can create objs over a document selection" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\document
        \\  let add_each = (page_value: Page) |-> place_on!(page_value, new("lambda", "body", "text"))
        \\  foreach(pages(docctx()), add_each)
        \\end
        \\
        \\page one
        \\end
        \\
    , "lambda");
}

test "compiler semantics: functions can return captured function values" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn make_label!(text_value: String) -> Page -> Object
        \\  return (page_value: Page) |-> place_on!(page_value, new(text_value, "body", "text"))
        \\end
        \\
        \\document
        \\  foreach(pages(docctx()), make_label!("made"))
        \\end
        \\
        \\page one
        \\end
        \\
    , "made");
}

test "compiler semantics: callbacks keep their defining module scope" {
    try expectFixtureObjectContent("functions/module-callback", "module");
}

test "compiler semantics: closures returned through branch scopes own captured records" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\type Box {
        \\  value: Number = 7
        \\}
        \\fn make() -> Number -> Box
        \\  let original = Box {}
        \\  if true
        \\    let captured = original with { value = 11 }
        \\    return (amount: Number) |-> captured with { value = captured.value + amount }
        \\  end
        \\  return (amount: Number) |-> original with { value = amount }
        \\end
        \\page ok
        \\  let callback = make()
        \\  let first = callback(2)
        \\  let second = callback(4)
        \\  text!(str(first.value) ++ ":" ++ str(second.value))
        \\end
    , "13:15");
}

test "compiler semantics: borrowed arguments and defaults preserve record updates" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\type Box {
        \\  value: Number = 7
        \\}
        \\fn update(original: Box, same: Box = original) -> Box
        \\  return same with { value = 9 }
        \\end
        \\page ok
        \\  let original = Box {}
        \\  let direct = update(original)
        \\  let callback = (input: Box) |-> update(input)
        \\  let indirect = callback(original)
        \\  text!(str(original.value) ++ ":" ++ str(direct.value) ++ ":" ++ str(indirect.value))
        \\end
    , "7:9:9");
}

test "compiler semantics: nested captured frames survive growth of the closure store" {
    var source = std.ArrayList(u8).empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator,
        \\import std:themes/default as *
        \\fn make(seed: Number) -> Number -> Number -> Number
        \\  return (left: Number) |-> (right: Number) |-> seed + left + right
        \\end
        \\page ok
        \\  let saved = make(3)(4)
        \\
    );
    for (0..64) |index| {
        const statement = try std.fmt.allocPrint(std.testing.allocator, "  let unused{d} = make({d})({d})\n", .{ index, index, index });
        defer std.testing.allocator.free(statement);
        try source.appendSlice(std.testing.allocator, statement);
    }
    try source.appendSlice(std.testing.allocator, "  text!(str(saved(5)))\nend\n");
    try expectObjectContent(source.items, "12");
}

test "compiler semantics: function values use ordinary application" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn apply(f: Number -> Number, x: Number) -> Number
        \\  return f(x)
        \\end
        \\
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\
        \\page ok
        \\  text!(str(apply(inc, 2)))
        \\end
        \\
    , "3");
}

test "compiler semantics: direct lambda application works" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  text!(str(((x: Number) |-> x + 4)(1)))
        \\end
        \\
    , "5");
}

test "compiler semantics: constants can hold function values" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\const plus_one: Number -> Number = (x: Number) |-> x + 1
        \\
        \\page ok
        \\  text!(str(plus_one(2)))
        \\end
        \\
    , "3");
}

test "compiler semantics: constants are evaluated once as value bindings" {
    const source =
        \\import std:themes/default as *
        \\
        \\type Parts {
        \\  root: Object
        \\  middle: Object
        \\}
        \\
        \\fn make_parts() -> Parts
        \\  let middle = body_obj("middle")
        \\  return Parts {
        \\    root = group(middle)
        \\    middle = middle
        \\  }
        \\end
        \\
        \\const parts: Parts = make_parts()
        \\
        \\page ok
        \\  parts.middle.link_id = "changed"
        \\  parts.middle.text.color = c"#ff0000"
        \\  place_on!(pagectx(), parts.root)
        \\end
        \\
    ;

    try expectObjectProperty(source, "link_id", "changed");
    try expectObjectFieldPath(source, "text", &.{"color"}, "1,0,0");
}

test "compiler semantics: constants cannot require a page context" {
    try expectDiagnostic(
        \\const current: Page = pagectx()
        \\
        \\page ok
        \\end
        \\
    , "case.ss:bytes:", "NoCurrentPage: 'pagectx' is only valid inside a page block");
}

test "compiler semantics: returned lambdas are directly applicable" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn add_two() -> Number -> Number
        \\  return (x: Number) |-> x + 2
        \\end
        \\
        \\page ok
        \\  text!(str(add_two()(1)))
        \\end
        \\
    , "3");
}

test "compiler semantics: returned named functions flow through branches" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\
        \\fn dec(x: Number) -> Number
        \\  return x - 1
        \\end
        \\
        \\fn choose(flag: Bool) -> Number -> Number
        \\  if flag
        \\    return inc
        \\  else
        \\    return dec
        \\  end
        \\end
        \\
        \\page ok
        \\  text!(str(choose(true)(2)) ++ "," ++ str(choose(false)(2)))
        \\end
        \\
    , "3,1");
}

test "compiler semantics: join accepts an inline typed lambda" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page one
        \\  text!(join(pages(docctx()), ",", (page_value: Page) |-> str(page_index(page_value))))
        \\end
        \\
        \\page two
        \\end
        \\
    , "1,2");
}

test "compiler semantics: fold accepts an inline typed lambda" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page one
        \\  text!(fold(pages(docctx()), "", (acc: String, page_value: Page) |-> acc ++ str(page_index(page_value))))
        \\end
        \\
        \\page two
        \\end
        \\
    , "12");
}

test "compiler semantics: foreach_enumerate passes one-based indices" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn number_body(item: Object, index: Number) -> Object
        \\  item.link_id = str(index)
        \\  return item
        \\end
        \\
        \\fn link_text(item: Object) -> String
        \\  return item.link_id ?? "missing"
        \\end
        \\
        \\page one
        \\  body_obj!("A")
        \\end
        \\
        \\page two
        \\  body_obj!("B")
        \\end
        \\
        \\document
        \\  foreach_enumerate(doc_objs(docctx(), "body"), number_body)
        \\end
        \\
        \\page summary
        \\  text!(join(doc_objs(docctx(), "body"), ",", link_text))
        \\end
        \\
    , "1,2");
}

test "compiler semantics: foreach_enumerate checks callback argument order" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\fn wrong(index: String, item: Object) -> Object
        \\  return item
        \\end
        \\
        \\page bad
        \\  text!("A")
        \\  foreach_enumerate(doc_objs(docctx(), "body"), wrong)
        \\end
        \\
    );
}

const numbered_claim_source =
    \\type Claim {
    \\  series: Number = 1
    \\  label: String = "Claim"
    \\  title: String
    \\  style: TextBlockStyle = default_text_style
    \\}
    \\fn display(self: Placed<Claim>) -> Text
    \\  let series = self.value.series
    \\  let items = filter(select<Claim>(self.document), (item: Placed<Claim>) |-> item.value.series == series)
    \\  return text(self.value.label ++ " " ++ str(number_of(self, items) ?? 0) ++ ": " ++ self.value.title, self.value.style)
    \\end
    \\fn/! claim(title: String) -> Claim = Claim { title = title }
    \\
;

test "compiler semantics: number_of formats typed placements across pages" {
    try expectObjectContent(numbered_claim_source ++
        \\page one
        \\  claim!("A")
        \\end
        \\page two
        \\  claim!("B")
        \\end
    , "Claim 2: B");
}

test "compiler semantics: number_of includes inputs returned by user constructors" {
    try expectObjectContent(numbered_claim_source ++
        \\fn/! captioned(title: String) -> Claim
        \\  return claim(title) with { style.text.size = 12 }
        \\end
        \\page one
        \\  captioned!("A")
        \\end
        \\page two
        \\  captioned!("B")
        \\end
    , "Claim 2: B");
}

test "compiler semantics: number_of includes explicitly placed inputs" {
    try expectObjectContent(numbered_claim_source ++
        \\page one
        \\  let item = claim("A")
        \\  place_on!(pagectx(), item)
        \\end
    , "Claim 1: A");
}

test "compiler semantics: document object counts wait for titles on any page" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page one
        \\  let bonus = 100
        \\  let n_title_plus_bonus = selection_count(select<Heading>(docctx())) + bonus
        \\  text!(str(n_title_plus_bonus))
        \\  heading!("A")
        \\end
        \\
        \\page two
        \\  heading!("B")
        \\end
        \\
    , "102");
}

test "compiler semantics: number_of can be read repeatedly without mutating the input" {
    try expectObjectContent(numbered_claim_source ++
        \\page one
        \\  let item = claim!("A")
        \\  let items = select<Claim>(docctx())
        \\  let first = number_of(item, items) ?? 0
        \\  let again = number_of(item, items) ?? 0
        \\  text!(str(first) ++ ":" ++ str(again) ++ ":" ++ item.value.title)
        \\end
    , "1:1:A");
}

test "compiler semantics: number_of keeps filtered series separate" {
    const source = numbered_claim_source ++
        \\page one
        \\  claim!("A")
        \\  place!(Claim { series = 2 label = "Definition" title = "B" })
        \\end
    ;
    try expectObjectContent(source, "Claim 1: A");
    try expectObjectContent(source, "Definition 1: B");
}

test "compiler semantics: void lambda callbacks execute their effects" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn side_effect!(page_value: Page) -> Void
        \\  place_on!(page_value, new("side", "body", "text"))
        \\end
        \\
        \\document
        \\  foreach(pages(docctx()), (page_value: Page) |-> side_effect!(page_value))
        \\end
        \\
        \\page bad
        \\end
        \\
    , "side");
}

test "compiler semantics: function value application checks argument types" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let f = (x: Number) |-> x + 1
        \\  text!(str(f("oops")))
        \\end
        \\
    );

    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let value = 1
        \\  text!(str(value(2)))
        \\end
        \\
    );
}

test "compiler semantics: function return annotations are checked for function values" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\fn bad() -> Number -> Number
        \\  return (text_value: String) |-> text_value
        \\end
        \\
        \\page bad
        \\  text!(str(bad()(1)))
        \\end
        \\
    );
}

test "compiler semantics: function values cannot be stored as properties" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\fn id(x: Number) -> Number
        \\  return x
        \\end
        \\
        \\page bad
        \\  let obj = text("bad")
        \\  set_prop(obj, "wrap", id)
        \\end
        \\
    );
}

test "compiler semantics: function-value recursion is rejected" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\fn bad(x: Number) -> Number
        \\  let f = bad
        \\  return f(x)
        \\end
        \\
        \\page bad
        \\  text!(str(bad(1)))
        \\end
        \\
    );

    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\fn apply(f: Number -> Number, x: Number) -> Number
        \\  return f(x)
        \\end
        \\
        \\fn bad(x: Number) -> Number
        \\  return apply(bad, x)
        \\end
        \\
        \\page bad
        \\  text!(str(bad(1)))
        \\end
        \\
    );
}

test "compiler semantics: cross-module lambda recursion is rejected before evaluation" {
    try expectOverlayDiagnostic(
        \\import "./lib/bad" as lib
        \\fn bad(x: Number) -> Number
        \\  return lib::apply_fn((y: Number) |-> bad(y), x)
        \\end
        \\page main
        \\  let value = bad(1)
        \\end
    ,
        \\fn apply_fn(f: Number -> Number, x: Number) -> Number
        \\  return f(x)
        \\end
    , "case.ss:bytes:", "RecursiveFunction");
}

test "compiler semantics: imported recursive lambdas report their defining source" {
    const library =
        \\fn make_bad() -> Number -> Number
        \\  return (x: Number) |-> make_bad()(x)
        \\end
    ;
    const start = std.mem.indexOf(u8, library, "(x: Number)").?;
    const end = std.mem.indexOf(u8, library, "\nend").?;
    const expected_origin = try std.fmt.allocPrint(testing.allocator, "lib/bad.ss:bytes:{d}-{d}", .{ start, end });
    defer testing.allocator.free(expected_origin);
    try expectOverlayDiagnostic(
        \\import "./lib/bad" as lib
        \\page main
        \\  let value = lib::make_bad()(1)
        \\end
    , library, expected_origin, "RecursiveFunction");
}

test "compiler semantics: equal lambda spans in different modules remain distinct" {
    const library =
        \\fn wrap(f: Number -> Number) -> Number -> Number
        \\  return (x: Number) |-> f(x)
        \\end
    ;
    try expectObjectContentWithTwoOverlays(
        \\import "./lib/a" as a
        \\import "./lib/b" as b
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\page main
        \\  text!(str(a::wrap(b::wrap(inc))(1)))
        \\end
    , library, library, "2");
}

test "compiler semantics: nested cross-module lambdas retain defining imports and captures" {
    try expectObjectContentWithTwoOverlays(
        \\import "./lib/a" as a
        \\fn suffix(value: String) -> String
        \\  return value ++ "!"
        \\end
        \\page main
        \\  text!(a::make(suffix)("A"))
        \\end
    ,
        \\import "./b" as b
        \\fn make(f: String -> String) -> String -> String
        \\  return (x: String) |-> b::apply_fn((y: String) |-> f(y), x)
        \\end
    ,
        \\fn apply_fn(f: String -> String, x: String) -> String
        \\  return f(x)
        \\end
    , "A!");
}

test "compiler semantics: nested captured cross-module lambdas cannot hide recursion" {
    try expectOverlayDiagnostic(
        \\import "./lib/bad" as lib
        \\fn bad(x: Number) -> Number
        \\  let recurse = bad
        \\  return lib::apply_fn((y: Number) |-> ((z: Number) |-> recurse(z))(y), x)
        \\end
        \\page main
        \\  let value = bad(1)
        \\end
    ,
        \\fn apply_fn(f: Number -> Number, x: Number) -> Number
        \\  return f(x)
        \\end
    , "case.ss:bytes:", "RecursiveFunction");
}

test "compiler semantics: record argument recursion is rejected before evaluation" {
    try expectDiagnostic(
        \\type Box {
        \\  f: Number -> Number
        \\}
        \\fn call_box(b: Box, x: Number) -> Number
        \\  return b.f(x)
        \\end
        \\fn bad(x: Number) -> Number
        \\  return call_box(Box { f = bad }, x)
        \\end
        \\page main
        \\  let value = bad(1)
        \\end
    , "case.ss:bytes:", "RecursiveFunction");
}

test "compiler semantics: optional function argument recursion is rejected before evaluation" {
    try expectDiagnostic(
        \\type Box { f: Number -> Number }
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\
        \\fn invoke(f: (Number -> Number)?, x: Number) -> Number
        \\  return (f ?? inc)(x)
        \\end
        \\fn bad(x: Number) -> Number
        \\  return invoke(bad, x)
        \\end
        \\page main
        \\  let value = bad(1)
        \\end
    , "case.ss:bytes:", "RecursiveFunction");
}

test "compiler semantics: record and optional function arguments retain terminating candidates" {
    try expectObjectContent(
        \\type Box { f: Number -> Number }
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\
        \\fn invoke(b: Box, f: (Number -> Number)?, x: Number) -> Number
        \\  return b.f((f ?? inc)(x))
        \\end
        \\page main
        \\  text!(str(invoke(Box { f = inc }, inc, 1)) ++ ":" ++ str(invoke(Box { f = inc }, none, 1)))
        \\end
    , "3:3");
}

test "compiler semantics: record fields do not mix callable candidates" {
    try expectObjectContent(
        \\type Box { f: Number -> Number }
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\
        \\type Pair {
        \\  first: Number -> Number
        \\  second: Number -> Number
        \\}
        \\fn first(p: Pair, x: Number) -> Number
        \\  return p.first(x)
        \\end
        \\fn good(x: Number) -> Number
        \\  return first(Pair { first = inc, second = good }, x)
        \\end
        \\page main
        \\  text!(str(good(1)))
        \\end
    , "2");
}

test "compiler semantics: nested record updates replace only the selected callable field" {
    try expectObjectContent(
        \\type Box { f: Number -> Number }
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\
        \\type Nested {
        \\  box: Box
        \\  other: Number -> Number
        \\}
        \\fn invoke(n: Nested, x: Number) -> Number
        \\  return n.box.f(x)
        \\end
        \\fn good(x: Number) -> Number
        \\  let original = Nested { box = Box { f = good }, other = good }
        \\  let changed = original with { box.f = inc }
        \\  return invoke(changed, x)
        \\end
        \\page main
        \\  text!(str(good(1)))
        \\end
    , "2");
}

test "compiler semantics: record updates retain recursion in untouched fields" {
    try expectDiagnostic(
        \\type Box { f: Number -> Number }
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\
        \\type Pair {
        \\  first: Number -> Number
        \\  second: Number -> Number
        \\}
        \\fn invoke(p: Pair, x: Number) -> Number
        \\  return p.second(x)
        \\end
        \\fn bad(x: Number) -> Number
        \\  let original = Pair { first = inc, second = bad }
        \\  return invoke(original with { first = inc }, x)
        \\end
        \\page main
        \\  let value = bad(1)
        \\end
    , "case.ss:bytes:", "RecursiveFunction");
}

test "compiler semantics: returned captured records retain recursive candidates" {
    try expectDiagnostic(
        \\type Box { f: Number -> Number }
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\
        \\type Nested { box: Box }
        \\fn wrap(n: Nested) -> Number -> Number
        \\  return (x: Number) |-> n.box.f(x)
        \\end
        \\fn identity(n: Nested) -> Nested
        \\  return n
        \\end
        \\fn bad(x: Number) -> Number
        \\  return wrap(identity(Nested { box = Box { f = bad } }))(x)
        \\end
        \\page main
        \\  let value = bad(1)
        \\end
    , "case.ss:bytes:", "RecursiveFunction");
}

test "compiler semantics: returned captured records retain terminating candidates" {
    try expectObjectContent(
        \\type Box { f: Number -> Number }
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\
        \\type Nested { box: Box }
        \\fn wrap(n: Nested) -> Number -> Number
        \\  return (x: Number) |-> n.box.f(x)
        \\end
        \\fn identity(n: Nested) -> Nested
        \\  return n
        \\end
        \\page main
        \\  text!(str(wrap(identity(Nested { box = Box { f = inc } }))(1)))
        \\end
    , "2");
}

test "compiler semantics: record return paths merge candidates by field" {
    try expectDiagnostic(
        \\type Box { f: Number -> Number }
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\
        \\fn choose(flag: Bool) -> Box
        \\  if flag
        \\    return Box { f = inc }
        \\  else
        \\    return Box { f = bad }
        \\  end
        \\end
        \\fn bad(x: Number) -> Number
        \\  return choose(false).f(x)
        \\end
        \\page main
        \\  let value = bad(1)
        \\end
    , "case.ss:bytes:", "RecursiveFunction");
}

test "compiler semantics: record parameter defaults retain recursive candidates" {
    try expectDiagnostic(
        \\type Box { f: Number -> Number }
        \\fn invoke(b: Box = Box { f = bad }) -> Number
        \\  return b.f(1)
        \\end
        \\fn bad(x: Number) -> Number
        \\  return invoke()
        \\end
        \\page main
        \\  let value = bad(1)
        \\end
    , "case.ss:bytes:", "RecursiveFunction");
}

test "compiler semantics: optional record defaults preserve explicit function fields" {
    try expectObjectContent(
        \\type Box { f: Number -> Number }
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\
        \\type DefaultBox { f: (Number -> Number)? = none }
        \\fn invoke(b: DefaultBox = DefaultBox { f = inc }) -> Number
        \\  return (b.f ?? inc)(1)
        \\end
        \\fn good(x: Number) -> Number
        \\  return invoke()
        \\end
        \\page main
        \\  text!(str(good(1)))
        \\end
    , "2");
}

test "compiler semantics: record field placement distinguishes cached calls" {
    try expectDiagnostic(
        \\type Box { f: Number -> Number }
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\
        \\type Pair {
        \\  first: Number -> Number
        \\  second: Number -> Number
        \\}
        \\fn invoke(p: Pair, x: Number) -> Number
        \\  return p.first(x)
        \\end
        \\fn bad(x: Number) -> Number
        \\  let safe = invoke(Pair { first = inc, second = bad }, x)
        \\  return invoke(Pair { first = bad, second = inc }, x)
        \\end
        \\page main
        \\  let value = bad(1)
        \\end
    , "case.ss:bytes:", "RecursiveFunction");
}

test "compiler semantics: unknown property callbacks cannot establish termination" {
    try expectDiagnostic(
        \\type Box { f: Number -> Number }
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\
        \\type Holder = object {
        \\  roles = ["holder"]
        \\  callback: (Number -> Number)?
        \\}
        \\fn invoke(h: Holder) -> Number
        \\  return (h.callback ?? inc)(1)
        \\end
        \\page main
        \\  let holder = obj("holder", "holder", "text")
        \\  let value = invoke(holder)
        \\end
    , "case.ss:bytes:", "InvalidPropertyType");
}

test "compiler semantics: cached higher-order calls distinguish captured records" {
    try expectDiagnostic(
        \\type Box { f: Number -> Number }
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\fn wrap(b: Box) -> Number -> Number
        \\  return (x: Number) |-> b.f(x)
        \\end
        \\fn invoke(f: Number -> Number, x: Number) -> Number
        \\  return f(x)
        \\end
        \\fn bad(x: Number) -> Number
        \\  let safe = invoke(wrap(Box { f = inc }), x)
        \\  return invoke(wrap(Box { f = bad }), x)
        \\end
        \\page main
        \\  let value = bad(1)
        \\end
    , "case.ss:bytes:", "RecursiveFunction");
}

test "compiler semantics: record updates replace recursive function fields before calls" {
    try expectObjectContent(
        \\type Box { f: Number -> Number }
        \\fn inc(x: Number) -> Number = x + 1
        \\fn invoke(box: Box) -> Number
        \\  let value = box with { f = inc }
        \\  return value.f(1)
        \\end
        \\fn replaced(x: Number) -> Number = invoke(Box { f = replaced })
        \\page main
        \\  text!(str(replaced(1)))
        \\end
    , "2");
}

test "compiler semantics: cross-module captured record closures remain distinct" {
    try expectObjectContentWithTwoOverlays(
        \\import "./lib/a" as a
        \\import "./lib/b" as b
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\fn twice(x: Number) -> Number
        \\  return x * 2
        \\end
        \\page main
        \\  let first = a::wrap(a::pack(inc))
        \\  let second = a::wrap(a::pack(twice))
        \\  text!(str(b::invoke(first, 3)) ++ ":" ++ str(b::invoke(second, 3)))
        \\end
    ,
        \\type Box { f: Number -> Number }
        \\fn pack(f: Number -> Number) -> Box
        \\  return Box { f = f }
        \\end
        \\fn wrap(b: Box) -> Number -> Number
        \\  return (x: Number) |-> b.f(x)
        \\end
    ,
        \\fn invoke(f: Number -> Number, x: Number) -> Number
        \\  return f(x)
        \\end
    , "4:6");
}

test "compiler semantics: callbacks cannot hide unknown function properties" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\type Holder = object {
        \\  roles = ["holder"]
        \\  callback: (Number -> Number)?
        \\}
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\fn invoke(h: Holder) -> Number
        \\  return (h.callback ?? inc)(1)
        \\end
        \\page main
        \\  let holder = obj("holder", "holder", "text")
        \\  let _ = foreach(objs(pagectx(), "holder"), invoke)
        \\end
    , "case.ss:bytes:", "InvalidPropertyType");
}

test "compiler semantics: record return joins retain recursive fields after known fields" {
    try expectDiagnostic(
        \\type Box { f: Number -> Number }
        \\fn inc(x: Number) -> Number = x + 1
        \\fn choose(box: Box, flag: Bool) -> Box
        \\  if flag
        \\    return Box { f = inc }
        \\  else
        \\    return box
        \\  end
        \\end
        \\fn recursive(x: Number) -> Number = choose(Box { f = recursive }, true).f(x)
        \\page main
        \\  let value = recursive(1)
        \\end
    , "case.ss:bytes:", "RecursiveFunction");
}

test "compiler semantics: record return joins retain recursive fields before known fields" {
    try expectDiagnostic(
        \\type Box { f: Number -> Number }
        \\fn inc(x: Number) -> Number = x + 1
        \\fn choose(box: Box, flag: Bool) -> Box
        \\  if flag
        \\    return box
        \\  else
        \\    return Box { f = inc }
        \\  end
        \\end
        \\fn recursive(x: Number) -> Number = choose(Box { f = recursive }, true).f(x)
        \\page main
        \\  let value = recursive(1)
        \\end
    , "case.ss:bytes:", "RecursiveFunction");
}

test "compiler semantics: growing closure environments exhaust analysis before evaluation" {
    try expectDiagnostic(
        \\type Box { f: Number -> Number }
        \\fn wrap(b: Box) -> Number -> Number
        \\  return (x: Number) |-> b.f(x)
        \\end
        \\fn repeat(b: Box, x: Number) -> Number
        \\  return repeat(Box { f = wrap(b) }, x)
        \\end
        \\fn inc(x: Number) -> Number
        \\  return x + 1
        \\end
        \\page main
        \\  let value = repeat(Box { f = inc }, 1)
        \\end
    , "case.ss:bytes:", "FunctionAnalysisLimitExceeded");
}

test "compiler semantics: mutual recursion is rejected" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\fn first(x: Number) -> Number
        \\  return second(x)
        \\end
        \\
        \\fn second(x: Number) -> Number
        \\  return first(x)
        \\end
        \\
        \\page bad
        \\  text!(str(first(1)))
        \\end
        \\
    );
}

test "compiler semantics: function-returning lambda recursion is rejected" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\fn make_bad() -> Number -> Number
        \\  return (x: Number) |-> make_bad()(x)
        \\end
        \\
        \\page bad
        \\  text!(str(make_bad()(1)))
        \\end
        \\
    );
}

test "compiler semantics: foreach cannot add placements to its selected input type" {
    try expectBuildFails(
        \\fn duplicate(item: Placed<Heading>) -> Placed<Heading>
        \\  place_on!(item.page, heading("copy"))
        \\  return item
        \\end
        \\page bad
        \\  heading!("A")
        \\  foreach(select<Heading>(pagectx()), duplicate)
        \\end
    );
}

test "compiler semantics: foreach permits unplaced values without changing membership" {
    try expectObjectContent(
        \\fn duplicate(item: Placed<Heading>) -> Placed<Heading>
        \\  let copy = heading("copy")
        \\  return item
        \\end
        \\fn visit(items: Selection<Placed<Heading>>) -> Selection<Placed<Heading>>
        \\  return foreach(items, duplicate)
        \\end
        \\page main
        \\  heading!("A")
        \\  let items = visit(select<Heading>(pagectx()))
        \\  text!(str(selection_count(items)))
        \\end
    , "1");
}

test "compiler semantics: foreach cannot create pages while iterating pages" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\document
        \\  foreach(pages(docctx()), (page_value: Page) |-> new_page(docctx(), "extra"))
        \\end
        \\
        \\page bad
        \\end
        \\
    );
}

test "compiler semantics: foreach_enumerate cannot create pages while iterating pages" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\document
        \\  foreach_enumerate(pages(docctx()), (page_value: Page, index: Number) |-> new_page(docctx(), str(index)))
        \\end
        \\
        \\page bad
        \\end
        \\
    );
}

test "compiler semantics: fold cannot mutate the iterated page selection" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\fn add_page(acc: String, page_value: Page) -> String
        \\  new_page(docctx(), "extra")
        \\  return acc
        \\end
        \\
        \\page bad
        \\  text!(fold(pages(docctx()), "", add_page))
        \\end
        \\
    );
}

test "compiler semantics: join cannot mutate the iterated page selection" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\fn add_page(page_value: Page) -> String
        \\  new_page(docctx(), "extra")
        \\  return str(page_index(page_value))
        \\end
        \\
        \\page bad
        \\  text!(join(pages(docctx()), "", add_page))
        \\end
        \\
    );
}

test "compiler semantics: layout reads cannot feed layout input" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let t = text("hello")
        \\  let h = frame_height(t)
        \\  text!(str(h))
        \\end
        \\
    );
}

test "compiler semantics: return type inference sees branch-local bindings" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\fn branch_label(flag: Bool) -> String
        \\  if flag
        \\    let text_value = "yes"
        \\    return text_value
        \\  else
        \\    let text_value = "no"
        \\    return text_value
        \\  end
        \\end
        \\
        \\page ok
        \\  let title = branch_label(true)
        \\  text!(title)
        \\end
        \\
    );
}

test "compiler semantics: page-only primitives are rejected in document context" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\document
        \\  let p = pagectx()
        \\end
        \\
        \\page ok
        \\end
        \\
    , "case.ss:bytes:", "NoCurrentPage: 'pagectx' is only valid inside a page block");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\document
        \\  heading!("bad")
        \\end
        \\
        \\page ok
        \\end
        \\
    , "case.ss:bytes:", "NoCurrentPage");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\document
        \\  foreach(pages(docctx()), (page_value: Page) |-> heading!("bad"))
        \\end
        \\
        \\page ok
        \\end
        \\
    , "case.ss:bytes:", "NoCurrentPage");
}

test "compiler semantics: missing page relationships return none" {
    try expectObjectContent(
        \\page first
        \\  let previous: Page? = previous_page(pagectx())
        \\  if previous?
        \\    text!("Unexpected page")
        \\  else
        \\    text!("No previous page")
        \\  end
        \\end
    , "No previous page");

    try expectDiagnostic(
        \\page detached
        \\  let item = text("detached")
        \\  let page = item.page
        \\end
    , "case.ss:bytes:", "UnknownField");
}

test "compiler semantics: document callbacks may use explicit pages without current page" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn decorate!(page_value: Page) -> Object
        \\  let item = place_on!(page_value, new("explicit", "body", "text"))
        \\  page_value ~ (item.left == page_value.left + 72)
        \\  return item
        \\end
        \\
        \\document
        \\  foreach(pages(docctx()), (page_value: Page) |-> decorate!(page_value))
        \\end
        \\
        \\page ok
        \\end
        \\
    , "explicit");
}

test "compiler semantics: document callbacks reject current page access" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\document
        \\  foreach(
        \\    pages(docctx()),
        \\    (page_value: Page) |-> pagectx()
        \\  )
        \\end
        \\
        \\page ok
        \\end
        \\
    , "case.ss:bytes:", "NoCurrentPage: 'pagectx' is only valid inside a page block");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn make_implicit!() -> Placed<Heading>
        \\  return heading!("bad")
        \\end
        \\
        \\document
        \\  foreach(
        \\    pages(docctx()),
        \\    (page_value: Page) |-> make_implicit!()
        \\  )
        \\end
        \\
        \\page ok
        \\end
        \\
    , "case.ss:bytes:", "NoCurrentPage");
}

test "compiler semantics: detached objects are valid values" {
    try expectNoLoweredDiagnostic(
        \\import std:themes/default as *
        \\
        \\page loose
        \\  new("loose", "body", "text")
        \\end
        \\
    , "UnplacedObject");

    try expectNoLoweredDiagnostic(
        \\import std:themes/default as *
        \\
        \\page placed
        \\  place_on!(pagectx(), new("placed", "body", "text"))
        \\end
        \\
    , "UnplacedObject");

    try expectNoLoweredDiagnostic(
        \\import std:themes/default as *
        \\
        \\page placed
        \\  place_on!(pagectx(), new("placed", "body", "text"))
        \\end
        \\
    , "UnplacedObject");

    try expectNoLoweredDiagnostic(
        \\import std:themes/default as *
        \\
        \\page discarded
        \\  let _ = new("discarded", "body", "text")
        \\end
        \\
    , "UnplacedObject");
}

test "compiler semantics: detached groups are valid values" {
    const source =
        \\import std:themes/default as *
        \\
        \\page loose
        \\  group(
        \\    new("one", "body", "text"),
        \\    new("two", "note", "text")
        \\  )
        \\end
        \\
    ;

    try expectNoLoweredDiagnostic(source, "UnplacedObject");
    try expectObjectState(source, .{ .role = "group", .attached = false, .discarded = false });
    try expectObjectState(source, .{ .content = "one", .attached = false, .discarded = false });
    try expectObjectState(source, .{ .content = "two", .attached = false, .discarded = false });
}

test "compiler semantics: constraint-referenced groups are layout values" {
    try expectNoLoweredDiagnostic(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let left = text "left"
        \\  let detail = text "detail"
        \\  let right = text "right"
        \\  place!(group(left, detail) || right)
        \\end
        \\
    , "UnplacedObject");
}

test "compiler semantics: constraints resolve record member object anchors" {
    try expectNoLoweredDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Parts {
        \\  root: Object
        \\  left: Object
        \\  right: Object
        \\}
        \\
        \\fn make_parts(left: Object, right: Object) -> Parts
        \\  return Parts {
        \\    root = group(left, right)
        \\    left = left
        \\    right = right
        \\  }
        \\end
        \\
        \\page ok
        \\  let left = body_obj! "left"
        \\  let right = body_obj! "right"
        \\  let parts = make_parts(left, right)
        \\  let caption = text! "caption"
        \\  ~ caption.top == parts.root.bottom - 16
        \\  ~ caption.left == parts.right.left
        \\end
        \\
    , "UnplacedObject");
}

test "compiler semantics: placing or discarding a group covers its children" {
    const placed_source =
        \\import std:themes/default as *
        \\
        \\page placed
        \\  place_on!(pagectx(), group(
        \\    new("one", "body", "text"),
        \\    new("two", "note", "text")
        \\  ))
        \\end
        \\
    ;
    try expectNoLoweredDiagnostic(placed_source, "UnplacedObject");
    try expectObjectState(placed_source, .{ .role = "group", .attached = true, .discarded = false });
    try expectObjectState(placed_source, .{ .content = "one", .attached = true, .discarded = false });
    try expectObjectState(placed_source, .{ .content = "two", .attached = true, .discarded = false });

    const discarded_source =
        \\import std:themes/default as *
        \\
        \\page discarded
        \\  let _ = group(
        \\    new("one", "body", "text"),
        \\    new("two", "note", "text")
        \\  )
        \\end
        \\
    ;
    try expectNoLoweredDiagnostic(discarded_source, "UnplacedObject");
    try expectObjectState(discarded_source, .{ .role = "group", .attached = false, .discarded = true });
    try expectObjectState(discarded_source, .{ .content = "one", .attached = false, .discarded = true });
    try expectObjectState(discarded_source, .{ .content = "two", .attached = false, .discarded = true });
}

test "compiler semantics: object generation works outside page context when discarded" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\document
        \\  let _ = group(
        \\    new("doc-one", "body", "text"),
        \\    new("doc-two", "note", "text")
        \\  )
        \\end
        \\
        \\page ok
        \\end
        \\
    );
}

test "compiler semantics: returned object placement covers connected generated objects" {
    try expectNoLoweredDiagnostic(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  place_on!(pagectx(), text("Connected helper") // text("Child"))
        \\end
        \\
    , "UnplacedObject");

    try expectNoLoweredDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn make_card() -> Object
        \\  let visible = new("visible", "body", "text")
        \\  let extra = new("extra", "note", "text")
        \\  return visible
        \\end
        \\
        \\page loose
        \\  place_on!(pagectx(), make_card())
        \\end
        \\
    , "UnplacedObject");

    try expectNoLoweredDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn make_discarded() -> Object
        \\  return new("discarded", "body", "text")
        \\end
        \\
        \\page discarded
        \\  let _ = make_discarded()
        \\end
        \\
    , "UnplacedObject");
}

test "compiler semantics: page overflow points at generated object call site" {
    const source =
        \\import std:themes/default as *
        \\
        \\fn make_box() -> Object
        \\  return new("wide", "body", "text")
        \\end
        \\
        \\page overflow
        \\  let box = place_on!(pagectx(), make_box())
        \\  ~ box.left == page.right + 10
        \\  ~ box.bottom == page.bottom + 20
        \\end
        \\
    ;
    const marker = "let box = place_on!(pagectx(), make_box())";
    const start = std.mem.indexOf(u8, source, marker) orelse return error.ExpectedMarker;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const expected_origin = try std.fmt.allocPrint(allocator, "case.ss:bytes:{d}-", .{start});
    try expectLoweredDiagnosticWithOrigin(source, expected_origin, "PageOverflow: object extends");
}

test "compiler semantics: returned objects place only explicit group children" {
    const constrained_source =
        \\import std:themes/default as *
        \\
        \\fn connected_pair() -> Object
        \\  let main = new("main", "body", "text")
        \\  let helper = new("helper", "note", "text")
        \\  ~ helper.top == main.bottom - 8
        \\  return main
        \\end
        \\
        \\page ok
        \\  place_on!(pagectx(), connected_pair())
        \\end
        \\
    ;
    try expectLoweringErrorDiagnostic(constrained_source, "UnownedLayoutObject");

    const grouped_source =
        \\import std:themes/default as *
        \\
        \\fn grouped_pair() -> Object
        \\  let left = new("left", "body", "text")
        \\  let right = new("right", "note", "text")
        \\  return group(left, right)
        \\end
        \\
        \\page ok
        \\  place_on!(pagectx(), grouped_pair())
        \\end
        \\
    ;
    try expectNoLoweredDiagnostic(grouped_source, "UnplacedObject");
    try expectObjectState(grouped_source, .{ .role = "group", .attached = true, .discarded = false });
    try expectObjectState(grouped_source, .{ .content = "left", .attached = true, .discarded = false });
    try expectObjectState(grouped_source, .{ .content = "right", .attached = true, .discarded = false });
}

test "compiler semantics: connected return objects error when the result is not placed" {
    const source =
        \\import std:themes/default as *
        \\
        \\fn connected_pair() -> Object
        \\  let main = new("main", "body", "text")
        \\  let helper = new("helper", "note", "text")
        \\  ~ helper.top == main.bottom - 8
        \\  return main
        \\end
        \\
        \\page loose
        \\  connected_pair()
        \\end
        \\
    ;

    try expectLoweringErrorDiagnostic(source, "UnownedLayoutObject");
}

test "compiler semantics: disconnected generated objects are not hidden by placing the return value" {
    const source =
        \\import std:themes/default as *
        \\
        \\fn disconnected_pair() -> Object
        \\  let main = new("main", "body", "text")
        \\  let helper = new("helper", "note", "text")
        \\  return main
        \\end
        \\
        \\page loose
        \\  place_on!(pagectx(), disconnected_pair())
        \\end
        \\
    ;

    try expectNoLoweredDiagnostic(source, "UnplacedObject");
    try expectNoLoweredDiagnostic(source, "object 'note'");
    try expectObjectState(source, .{ .content = "main", .attached = true, .discarded = false });
    try expectObjectState(source, .{ .content = "helper", .attached = false, .discarded = false });
}

test "compiler semantics: underscore discard follows explicit group children" {
    const source =
        \\import std:themes/default as *
        \\
        \\fn connected_pair() -> Object
        \\  let main = new("main", "body", "text")
        \\  let helper = new("helper", "note", "text")
        \\  ~ helper.top == main.bottom - 8
        \\  return group(main, helper)
        \\end
        \\
        \\page discarded
        \\  let _ = connected_pair()
        \\end
        \\
    ;

    try expectNoLoweredDiagnostic(source, "UnplacedObject");
    try expectObjectState(source, .{ .content = "main", .attached = false, .discarded = true });
    try expectObjectState(source, .{ .content = "helper", .attached = false, .discarded = true });
}

test "compiler semantics: unused detached objects have no placement diagnostics" {
    try expectNoLoweredDiagnostic(
        \\import std:themes/default as *
        \\
        \\page loose
        \\  new("loose", "body", "text")
        \\end
        \\
    , "UnplacedObject");
}

test "compiler semantics: dump preserves direct and nested object properties" {
    try expectFixtureDumpContains("object-property-dump", &.{ "referent", "wrapped", "\\\"kind\\\":\\\"object\\\"" });
}

test "compiler semantics: underscore let binding is not a variable" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let _ = new("discarded", "body", "text")
        \\  text!(_)
        \\end
        \\
    , "case.ss:bytes:", "UnknownIdentifier: unknown identifier: _");
}

test "compiler semantics: placing calls require bang-marked functions" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn bad() -> Object
        \\  return place_on!(pagectx(), new("bad", "body", "text"))
        \\end
        \\
        \\page ok
        \\end
        \\
    , "case.ss:bytes:", "PlacementEffect: function 'bad' calls a placing operation and must end with '!'");

    try buildSource(
        \\import std:themes/default as *
        \\
        \\fn ok!() -> Object
        \\  return new("ok", "body", "text")
        \\end
        \\
        \\page ok
        \\end
        \\
    );

    try buildSource(
        \\import std:themes/default as *
        \\
        \\fn ok!() -> Object
        \\  return new("ok", "body", "text")
        \\end
        \\
        \\fn bad() -> Object
        \\  return ok!()
        \\end
        \\
        \\page ok
        \\end
        \\
    );
}

test "compiler semantics: paired placement functions desugar through existing checks" {
    const placed_source =
        \\import std:themes/default as *
        \\
        \\fn/! badge(content: String, role_name: String = "body") -> Object
        \\  return new(content, role_name, "text")
        \\end
        \\
        \\page ok
        \\  badge!("visible")
        \\end
        \\
    ;

    try expectNoLoweredDiagnostic(placed_source, "UnplacedObject");
    try expectObjectState(placed_source, .{ .content = "visible", .attached = true, .discarded = false });

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn/! bad() -> String
        \\  return "bad"
        \\end
        \\
        \\page ok
        \\end
        \\
    , "case.ss:bytes:", "InvalidPlacementInput: placement requires an unplaced presentation value");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn/! bad() -> Object
        \\  return place_on!(pagectx(), new("bad", "body", "text"))
        \\end
        \\
        \\page ok
        \\end
        \\
    , "case.ss:bytes:", "PlacementEffect: function 'bad' calls a placing operation and must end with '!'");
}

test "compiler semantics: placement effect is detected through primitive calls and lambdas" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn bad(page_value: Page) -> Object
        \\  return place_on!(page_value, new("bad", "body", "text"))
        \\end
        \\
        \\page ok
        \\end
        \\
    , "case.ss:bytes:", "PlacementEffect: function 'bad' calls a placing operation and must end with '!'");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn bad() -> Page -> Object
        \\  return (page_value: Page) |-> place_on!(page_value, new("bad", "body", "text"))
        \\end
        \\
        \\page ok
        \\end
        \\
    , "case.ss:bytes:", "PlacementEffect: function 'bad' calls a placing operation and must end with '!'");
}

test "compiler semantics: placement effect follows constant function values" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\const delayed_place: Page -> Object = (page_value: Page) |-> place_on!(page_value, new("bad", "body", "text"))
        \\
        \\fn bad() -> Page -> Object
        \\  return delayed_place
        \\end
        \\
        \\page ok
        \\end
        \\
    , "case.ss:bytes:", "PlacementEffect: function 'bad' calls a placing operation and must end with '!'");
}

test "compiler semantics: placement effect follows named primitive callbacks" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn place_each(page_value: Page) -> Object
        \\  return place_on!(page_value, new("bad", "body", "text"))
        \\end
        \\
        \\fn bad() -> Void
        \\  let _ = foreach(pages(docctx()), place_each)
        \\end
        \\
        \\page ok
        \\end
        \\
    , "case.ss:bytes:", "PlacementEffect: function 'bad' calls a placing operation and must end with '!'");
}

test "compiler semantics: non-placement effects do not require bang-marked functions" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\fn add_page(doc: Document) -> Void
        \\  let _ = new_page(doc, "generated")
        \\end
        \\
        \\document
        \\  add_page(docctx())
        \\end
        \\
        \\page first
        \\end
        \\
    );

    try buildSource(
        \\import std:themes/default as *
        \\
        \\fn mark(obj: Object) -> Object
        \\  obj.link_id = "marked"
        \\  return obj
        \\end
        \\
        \\page ok
        \\  let item = place_on!(pagectx(), new("body", "body", "text"))
        \\  mark(item)
        \\end
        \\
    );
}

test "compiler semantics: bang-marked functions may generate without placing" {
    const source =
        \\import std:themes/default as *
        \\
        \\fn make!() -> Object
        \\  return new("made", "body", "text")
        \\end
        \\
        \\page ok
        \\  let _ = make!()
        \\end
        \\
    ;

    try expectNoLoweredDiagnostic(source, "UnplacedObject");
    try expectObjectState(source, .{ .content = "made", .attached = false, .discarded = true });
}

test "compiler semantics: removed object placement APIs are rejected" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  new(pagectx(), "old", "body", "text")
        \\end
        \\
    , "case.ss:bytes:", "InvalidArity: expected 3, got 4");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  new_group(pagectx(), objs_here("body"))
        \\end
        \\
    , "case.ss:bytes:", "UnknownFunction: unknown function: new_group");
}

test "compiler semantics: page anchors cannot be constraint targets" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  ~ page.left == page.left
        \\end
        \\
    );
}

test "compiler semantics: aliased object self-anchor constraints are rejected" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let a = text("a")
        \\  place_on!(pagectx(), a)
        \\  let b = a
        \\  ~ b.top == a.top + 100
        \\end
        \\
    );
}

test "compiler semantics: aliased tautological self-anchor constraints are accepted" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let a = text!("a")
        \\  let b = a
        \\  ~ b.top == a.top
        \\end
        \\
    );
}

test "compiler semantics: explicit layout conflicts are rejected" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let a = text("a")
        \\  place_on!(pagectx(), a)
        \\  ~ a.left == page.left + 100
        \\  ~ a.left == page.left + 120
        \\end
        \\
    );

    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let a = text("a")
        \\  place_on!(pagectx(), a)
        \\  ~ a.left == a.right + 10
        \\end
        \\
    );
}

test "compiler semantics: page constraint updates replace component positioning and preserve size" {
    try buildFixture("constraints/update/position");
    try expectFixtureDumpContains("constraints/update/position", &.{
        "\"constraint_updates\":[",
        "\"overridden_constraints\":[",
        "\"active\":true",
        "\"from_update\":true",
        "\"role\":\"size\"",
    });
}

test "compiler semantics: pure constraint updates leave fallback placement available" {
    try buildFixture("constraints/update/pure");
}

test "compiler semantics: caller constraint updates override component updates" {
    try buildFixture("constraints/update/caller");
}

test "compiler semantics: later constraint updates overwrite earlier updates on one axis" {
    try buildFixture("constraints/update/order");
}

test "compiler semantics: size constraint updates replace inherited dimensions" {
    try buildFixture("constraints/update/size");
    try expectFixtureDumpContains("constraints/update/size", &.{
        "\"target_anchor\":\"right\"",
        "\"offset\":320.0",
        "\"role\":\"size\"",
        "\"from_update\":true",
    });
}

test "compiler semantics: missing constraint anchors are rejected statically" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  ~ missing.left == page.left
        \\end
        \\
    );
}

test "compiler semantics: duplicate user functions are rejected" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\fn label() -> String
        \\  return "first"
        \\end
        \\
        \\fn label() -> String
        \\  return "second"
        \\end
        \\
        \\page bad
        \\end
        \\
    );
}

test "compiler semantics: duplicate object classes are rejected" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\type Thing = object {
        \\}
        \\
        \\type Thing = object {
        \\}
        \\
        \\page bad
        \\end
        \\
    );
}

test "compiler semantics: user object class names can be used as annotations" {
    try buildSource(
        \\type Card = object {
        \\}
        \\
        \\fn keep(value: Card) -> Card
        \\  return value
        \\end
        \\
        \\page ok
        \\end
        \\
    );
}

test "compiler semantics: object class annotations are checked through selections" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  roles = ["card"]
        \\}
        \\
        \\fn first_card(items: Selection<Card>) -> Card
        \\  return first(items)
        \\end
        \\
        \\page ok
        \\  place_on!(pagectx(), obj("A", "card", "text"))
        \\  let card_obj = first_card(objs_here("card"))
        \\  text!(content(card_obj))
        \\end
        \\
    );

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  roles = ["card"]
        \\}
        \\
        \\fn accept_body(item: Body) -> Object
        \\  return item
        \\end
        \\
        \\page bad
        \\  place_on!(pagectx(), obj("A", "card", "text"))
        \\  foreach(select(pagectx(), "page_objects_by_role", "card"), accept_body)
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Object<Body>, got Object<Card>");
}

test "compiler semantics: object class mismatches report concrete type labels" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  roles = ["card"]
        \\}
        \\
        \\fn keep_card(value: Card) -> Card
        \\  return value
        \\end
        \\
        \\page bad
        \\  keep_card(new("not a card", "body", "text"))
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Object<Card>, got Object<Body>");
}

test "compiler semantics: object class optional and selection mismatches are rejected" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  roles = ["card"]
        \\}
        \\
        \\fn bad_return(value: Body) -> Card
        \\  return value
        \\end
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Object<Card>, got Object<Body>");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  roles = ["card"]
        \\}
        \\
        \\fn bad_optional_return(value: Card?) -> Card
        \\  return value
        \\end
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Object<Card>, got Object<Card>?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  roles = ["card"]
        \\}
        \\
        \\fn bad_selection(items: Selection<Body>) -> Selection<Card>
        \\  return items
        \\end
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Selection<Object<Card>>, got Selection<Object<Body>>");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  roles = ["card"]
        \\}
        \\
        \\fn keep_body(items: Selection<Body>) -> Selection<Body>
        \\  return items
        \\end
        \\
        \\fn first_card(items: Selection<Card>) -> Card
        \\  return first(items)
        \\end
        \\
        \\page bad
        \\  text!("body")
        \\  first_card(keep_body(objs_here("body")))
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Selection<Object<Card>>, got Selection<Object<Body>>");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  roles = ["card"]
        \\}
        \\
        \\fn take_card(value: Card?) -> Card?
        \\  return value
        \\end
        \\
        \\page bad
        \\  take_card(new("not a card", "body", "text"))
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Object<Card>?, got Object<Body>");
}

test "compiler semantics: selection item class annotations resolve class names" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn count_missing(items: Selection<Missing>) -> Number
        \\  return selection_count(items)
        \\end
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "UnknownType: unknown type: Missing");
}

test "compiler semantics: default argument expressions are checked for nested type annotations" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Card = object {
        \\  roles = ["card"]
        \\}
        \\
        \\fn label(callback: Card -> String = (item: Missing) |-> "missing") -> String
        \\  return "ok"
        \\end
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "UnknownType: unknown type: Missing");
}

test "compiler semantics: unknown annotation types report UnknownType" {
    try expectDiagnostic(
        \\const bad: string = "x"
        \\
        \\page ok
        \\end
        \\
    , "case.ss:bytes:", "UnknownType: unknown type: string");
}

test "compiler semantics: numeric comparisons evaluate both outcomes" {
    const failures = [_][]const u8{
        "not(1==1)",
        "1==2",
        "2==1",
        "1!=1",
        "not(1!=2)",
        "not(2!=1)",
        "1<1",
        "not(1<2)",
        "2<1",
        "not(1<=1)",
        "not(1<=2)",
        "2<=1",
        "1>1",
        "1>2",
        "not(2>1)",
        "not(1>=1)",
        "1>=2",
        "not(2>=1)",
    };
    for (failures) |condition| {
        const source = try std.fmt.allocPrint(
            testing.allocator,
            "page comparisons\n  if {s}\n    report_error(\"incorrect comparison\")\n  end\nend\n",
            .{condition},
        );
        defer testing.allocator.free(source);
        try buildSource(source);
    }
}

test "compiler semantics: numeric comparisons require numeric operands" {
    try expectDiagnostic(
        \\page comparisons
        \\  let result = "one" == 1
        \\end
    , "case.ss:bytes:", "TypeMismatch");
    try expectDiagnostic(
        \\page comparisons
        \\  let result = 1 < "two"
        \\end
    , "case.ss:bytes:", "TypeMismatch");
    try expectDiagnostic(
        \\page comparisons
        \\  let result = 1 == 2 == 3
        \\end
    , "case.ss:bytes:", "TypeMismatch");
}

test "compiler semantics: local callable wins in statement and expression positions" {
    try expectObjectContent(
        \\fn label(n: Number) -> String
        \\  return str(n)
        \\end
        \\page main
        \\  let label = (s: String) |-> s
        \\  label("statement")
        \\  text!(label("expression"))
        \\end
    , "expression");
}

test "compiler semantics: non-callable locals shadow functions and primitives" {
    try expectDiagnostic(
        \\fn label(n: Number) -> Number
        \\  return n
        \\end
        \\page main
        \\  let label = 1
        \\  label(2)
        \\end
    , "case.ss:bytes:", "local binding 'label' is not callable");
    try expectDiagnostic(
        \\page main
        \\  let str = 1
        \\  str(2)
        \\end
    , "case.ss:bytes:", "local binding 'str' is not callable");
}

test "compiler semantics: scheduled local object wins over same-named constructor" {
    try expectObjectContent(
        \\page main
        \\  let figure = text(docctx().footer_text ?? "unset")
        \\  place_on!(pagectx(), figure)
        \\end
        \\document
        \\  docctx().footer_text = "after"
        \\end
    , "after");
}

test "compiler semantics: scheduled bindings remain visible across document blocks" {
    try buildSource(
        \\fn label(n: Number) -> Number
        \\  return n
        \\end
        \\document
        \\  let label = (s: String) |-> s
        \\end
        \\document
        \\  let value = label("local")
        \\end
        \\page main
        \\end
    );
}

test "compiler semantics: page requirement follows the selected callable" {
    try buildSource(
        \\fn f(n: Number) -> Number
        \\  let p = pagectx()
        \\  return n
        \\end
        \\document
        \\  let f = (n: Number) |-> n
        \\  let result = f(1)
        \\  let pagectx = (n: Number) |-> n
        \\  let other = pagectx(2)
        \\end
        \\page main
        \\end
    );
    try expectDiagnostic(
        \\document
        \\  let f = (n: Number) |-> pagectx()
        \\  let result = f(1)
        \\end
    , "case.ss:bytes:", "NoCurrentPage");
}

test "compiler semantics: constants shadow enum receivers in expressions" {
    try expectObjectContent(
        \\enum Mode { alpha beta }
        \\type Settings {
        \\  size: Number = 17
        \\}
        \\const Mode: Settings = Settings {}
        \\page main
        \\  text!(str(Mode.size))
        \\end
    , "17");
}

test "compiler semantics: qualified calls bypass local values" {
    try expectObjectContent(
        \\import std:text as theme
        \\page main
        \\  let text = 1
        \\  theme::text!("qualified")
        \\end
    , "qualified");
}

test "compiler semantics: local function values shadow constants" {
    try expectObjectContent(
        \\const label: Number = 7
        \\page main
        \\  let label = (s: String) |-> s
        \\  label("statement")
        \\  text!(label("local"))
        \\end
    , "local");
}

test "compiler semantics: constant function values shadow primitive calls" {
    try expectObjectContent(
        \\const str: Number -> String = (n: Number) |-> "constant"
        \\page main
        \\  text!(str(7))
        \\end
    , "constant");
}

test "compiler semantics: unknown and conflicting return facts cannot recover a literal" {
    const bodies = [_][]const u8{
        \\  if flag
        \\    return "parent_page"
        \\  end
        \\  return str(1)
        ,
        \\  if flag
        \\    return str(1)
        \\  end
        \\  return "parent_page"
        ,
        \\  if flag
        \\    return "parent_page"
        \\  else
        \\    if flag
        \\      return "children"
        \\    end
        \\  end
        \\  return "parent_page"
        ,
    };
    for (bodies) |body| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\fn query_name(flag: Bool) -> String
            \\{s}
            \\end
            \\page main
            \\  let item = text!("x")
            \\  let result = select(item, query_name(false))
            \\end
        , .{body});
        defer testing.allocator.free(source);
        try expectDiagnostic(source, "case.ss:bytes:", "UnknownQuery: select query must be a statically known string");
    }
}

test "compiler semantics: equal branch returns retain query facts and stop at returns" {
    try buildSource(
        \\fn query_name(flag: Bool) -> String
        \\  if flag
        \\    let query = "parent_page"
        \\    return query
        \\    return "children"
        \\  else
        \\    let query = "parent_page"
        \\    return query
        \\  end
        \\  return "children"
        \\end
        \\page main
        \\  let item = body_obj!("x")
        \\  let result = select(item, query_name(false))
        \\  let index = page_index(result ?? pagectx())
        \\end
    );
}

test "compiler semantics: constant concatenation and argument facts resolve query kinds" {
    try buildSource(
        \\const query: String = "parent_" ++ "page"
        \\fn identity(value: String) -> String
        \\  return value
        \\end
        \\page main
        \\  let item = body_obj!("x")
        \\  let result = select(item, identity(query))
        \\  let index = page_index(result ?? pagectx())
        \\end
    );
}

test "compiler semantics: return joins and selection algebra preserve only justified classes" {
    try expectVariableObjectClasses(
        \\type Card = object { roles = ["card"] }
        \\fn choose(flag: Bool, value: Object) -> Object
        \\  if flag
        \\    return new("card", "card", "text")
        \\  end
        \\  return value
        \\end
        \\fn reverse(flag: Bool, value: Object) -> Object
        \\  if flag
        \\    return value
        \\  end
        \\  return new("card", "card", "text")
        \\end
        \\page main
        \\  let untyped = new("x", "untyped", "text")
        \\  let chosen = choose(false, untyped)
        \\  let reversed = reverse(true, untyped)
        \\  let cards = select(new("card", "card", "text"), "self_object")
        \\  let others = select(untyped, "self_object")
        \\  let combined = selection_union(cards, others)
        \\  let common = selection_intersection(others, cards)
        \\  let remaining = selection_difference(others, cards)
        \\  let kept = selection_difference(cards, others)
        \\end
    , &.{
        .{ .name = "chosen", .scope_kind = "page", .scope_name = "main", .object_class = null },
        .{ .name = "reversed", .scope_kind = "page", .scope_name = "main", .object_class = null },
        .{ .name = "combined", .scope_kind = "page", .scope_name = "main", .object_class = null },
        .{ .name = "common", .scope_kind = "page", .scope_name = "main", .object_class = "Card" },
        .{ .name = "remaining", .scope_kind = "page", .scope_name = "main", .object_class = null },
        .{ .name = "kept", .scope_kind = "page", .scope_name = "main", .object_class = "Card" },
    });
}

test "compiler semantics: dependency roles include nested and fallthrough returns" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\fn role_for(important: Bool) -> String
        \\  if important
        \\    if important
        \\      let role = "claim"
        \\      return role
        \\    end
        \\  end
        \\  return "aside"
        \\end
        \\page summary
        \\  text!("claims=" ++ join(doc_objs(docctx(), "claim"), ",", (o: Object) |-> content(o)))
        \\end
        \\page body
        \\  txt_obj!("A", role_for(true))
        \\end
    , "claims=A");
}

test "compiler semantics: dependency role joins include unknown return expressions" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\fn role_for(flag: Bool) -> String
        \\  if flag
        \\    return str(123)
        \\  end
        \\  return "aside"
        \\end
        \\page summary
        \\  text!("items=" ++ join(doc_objs(docctx(), "123"), ",", (o: Object) |-> content(o)))
        \\end
        \\page body
        \\  txt_obj!("A", role_for(true))
        \\end
    , "items=A");
}

test "compiler semantics: property target returns join identities across branches" {
    try expectObjectContent(
        \\type Card = object { roles = ["card"] label: String = "old" }
        \\fn pick(flag: Bool, a: Card, b: Card) -> Object
        \\  if flag
        \\    return a
        \\  end
        \\  return b
        \\end
        \\page main
        \\  let a = new("A", "card", "text")
        \\  let b = new("B", "card", "text")
        \\  text!("picked=" ++ (pick(true, a, b).label ?? ""))
        \\  a.label = "new A"
        \\end
    , "picked=new A");
}

test "compiler semantics: returned object roles join all branches before placement" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\fn pick(flag: Bool) -> Object
        \\  if flag
        \\    return txt_obj("A", "claim")
        \\  end
        \\  return txt_obj("B", "aside")
        \\end
        \\page summary
        \\  text!("claims=" ++ join(doc_objs(docctx(), "claim"), ",", (o: Object) |-> content(o)))
        \\end
        \\page body
        \\  place_on!(pagectx(), pick(true))
        \\end
    , "claims=A");
}

test "compiler semantics: static string construction has a finite size limit" {
    var source = std.ArrayList(u8).empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "page main\n  let s0 = \"x\"\n");
    for (1..18) |index| {
        const line = try std.fmt.allocPrint(testing.allocator, "  let s{d} = concat(s{d}, s{d})\n", .{ index, index - 1, index - 1 });
        defer testing.allocator.free(line);
        try source.appendSlice(testing.allocator, line);
    }
    try source.appendSlice(testing.allocator, "  let result = select(pagectx(), s17)\nend\n");
    try expectDiagnostic(source.items, "case.ss:bytes:", "UnknownQuery: select query must be a statically known string");
}

test "compiler semantics: higher order writes determine execution order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = try fixtureSource(arena.allocator(), "higher-order-effects");
    try compiler_semantics.expectObjectContent(testing.io, arena.allocator(), input.path, input.source, "marked");
}

test "compiler semantics: returned closures keep captured property targets" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\fn reader(item: Object) -> (() -> String)
        \\  return () |-> (item.link_id ?? "missing")
        \\end
        \\page main
        \\  let item = body_obj!("A")
        \\  let read = reader(item)
        \\  text!(read())
        \\  item.link_id = "marked"
        \\end
    , "marked");
}

test "compiler semantics: record and optional function calls retain write effects" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\type Action { run: (Object -> Object)? }
        \\fn mark(item: Object) -> Object = set_prop(item, "link_id", "marked")
        \\fn apply_to(item: Object, action: Action) -> Object
        \\  let callback = action.run ?? ((value: Object) |-> value)
        \\  return callback(item)
        \\end
        \\page main
        \\  let item = body_obj!("A")
        \\  text!(item.link_id ?? "missing")
        \\  apply_to(item, Action { run = mark })
        \\end
    , "marked");
}

test "compiler semantics: unused closures do not execute property writes" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\page main
        \\  let item = body_obj!("A")
        \\  let unused = () |-> set_prop(item, "link_id", "unused")
        \\  item.link_id = "marked"
        \\  text!(item.link_id ?? "missing")
        \\end
    , "marked");
}

test "compiler semantics: selected callback aliases retain transitive reads" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\fn label(item: Object) -> String = (item.link_id ?? "missing")
        \\page main
        \\  let item = body_obj!("A")
        \\  let callback = label
        \\  text!(join(objs_here("body"), ",", callback))
        \\  item.link_id = "marked"
        \\end
    , "marked");
}

test "compiler semantics: nested imported closures preserve callback effects and definition environments" {
    try expectObjectContentWithTwoOverlays(
        \\import std:themes/default as *
        \\import "./lib/a" as a
        \\import "./lib/b" as b
        \\fn mark(item: Object) -> Object = set_prop(item, "link_id", "marked")
        \\fn helper(item: Object) -> String = "wrong"
        \\page main
        \\  let item = body_obj!("A")
        \\  let callback = a::wrap(mark)
        \\  text!(a::reader(item)())
        \\  b::invoke(callback, item)
        \\end
    ,
        \\fn helper(item: Object) -> String = (item.link_id ?? "missing")
        \\fn wrap(callback: Object -> Object) -> Object -> Object
        \\  return (item: Object) |-> callback(item)
        \\end
        \\fn reader(item: Object) -> (() -> String)
        \\  return () |-> helper(item)
        \\end
    ,
        \\fn invoke(callback: Object -> Object, item: Object) -> Object = callback(item)
    , "marked");
}

test "compiler semantics: default callbacks contribute effects in their definition environment" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\fn mark(item: Object) -> Object = set_prop(item, "link_id", "marked")
        \\fn apply_to(item: Object, callback: Object -> Object = mark) -> Object = callback(item)
        \\page main
        \\  let item = body_obj!("A")
        \\  text!(item.link_id ?? "missing")
        \\  apply_to(item)
        \\end
    , "marked");
}

test "compiler semantics: omitted theme arguments read later document definitions" {
    try expectFixtureObjectFieldPath("default-arguments", "text", &.{"size"}, "22");
}

test "compiler semantics: unused default arguments still contribute writes" {
    try expectObjectContent(
        \\fn initialize(item: Object, ignored: Object = set_prop(item, "link_id", "Ready")) -> String = "done"
        \\page main
        \\  let item = body_obj!("Target")
        \\  text!(item.link_id ?? "missing")
        \\  text!(initialize(item))
        \\end
    , "Ready");
}

test "compiler semantics: default reads use preceding parameters and distinguish call arguments" {
    try expectObjectContent(
        \\fn read(item: Object, selected: Object = item, value: String = selected.link_id ?? "missing") -> String = value
        \\page main
        \\  let first = body_obj!("First")
        \\  let second = body_obj!("Second")
        \\  text!(read(first) ++ ":" ++ read(second))
        \\  first.link_id = "A"
        \\  second.link_id = "B"
        \\end
    , "A:B");
}

test "compiler semantics: explicit arguments do not evaluate default effects" {
    try expectObjectContent(
        \\fn label(item: Object, value: String = item.link_id ?? "missing") -> String = value
        \\page main
        \\  let item = body_obj!("Target")
        \\  item.link_id = label(item, "Ready")
        \\  text!(item.link_id ?? "missing")
        \\end
    , "Ready");
}

test "compiler semantics: default object allocations retain distinct identities" {
    try expectObjectContent(
        \\fn make(item: Object = new("Target", "custom", "text")) -> Object = item
        \\page main
        \\  let first = make()
        \\  let second = make()
        \\  first.link_id = second.link_id ?? "missing"
        \\  second.link_id = "Ready"
        \\  text!(first.link_id ?? "missing")
        \\end
    , "Ready");
}

test "compiler semantics: default selections retain collection dependencies" {
    try expectObjectContent(
        \\fn label(item: Object) -> String = content(item)
        \\fn labels(items: Selection<Object> = objs_here("tagged")) -> String = join(items, ",", label)
        \\page main
        \\  text!(labels())
        \\  txt_obj!("A", "tagged")
        \\end
    , "A");
}

test "compiler semantics: later parameters do not shadow names in earlier defaults" {
    try expectObjectContent(
        \\fn source(item: Object) -> String = item.link_id ?? "missing"
        \\fn other(item: Object) -> String = "wrong"
        \\fn read(item: Object, value: String = source(item), source: Object -> String = other) -> String = value
        \\page main
        \\  let item = body_obj!("Target")
        \\  text!(read(item))
        \\  item.link_id = "Ready"
        \\end
    , "Ready");
}

test "compiler semantics: default facts and effects use the definition module" {
    try expectObjectContentWithTwoOverlays(
        \\import ./lib/a as a
        \\import ./lib/b as b
        \\const selected_role: String = "other"
        \\page main
        \\  let item = body_obj!("Target")
        \\  text!(b::read(item))
        \\  item.link_id = "Ready"
        \\  txt_obj!("A", "tagged")
        \\end
    ,
        \\const selected_role: String = "tagged"
        \\fn role(value: String = selected_role) -> String = value
        \\fn identity(item: Object, selected: Object = item) -> Object = selected
    ,
        \\import ./a as a
        \\const selected_role: String = "wrong"
        \\fn read(item: Object, value: String = a::identity(item).link_id ?? "missing") -> String
        \\  return value ++ ":" ++ str(selection_count(doc_objs(docctx(), a::role())))
        \\end
    , "Ready:1");
}

test "compiler semantics: callback effects distinguish specializations and returned record updates" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\type Action { run: Object -> Object }
        \\fn mark(item: Object) -> Object = set_prop(item, "link_id", "marked")
        \\fn identity(item: Object) -> Object = item
        \\fn pack(callback: Object -> Object) -> Action = Action { run = callback }
        \\fn apply_to(item: Object, action: Action) -> Object = action.run(item)
        \\page main
        \\  let item = body_obj!("A")
        \\  apply_to(item, pack(identity))
        \\  text!(item.link_id ?? "missing")
        \\  apply_to(item, pack(identity) with { run = mark })
        \\end
    , "marked");
}

test "compiler semantics: function aliases retain effects across document blocks" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\fn label(item: Object) -> String = (item.link_id ?? "missing")
        \\document
        \\  let callback = label
        \\end
        \\document
        \\  let item = body_obj("A")
        \\  let value = callback(item)
        \\  item.link_id = "marked"
        \\  let output = body_obj(value)
        \\  place_on!(new_page(docctx(), "main"), output)
        \\end
    , "marked");
}

test "compiler semantics: finite higher order reentry retains inner callback effects" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\fn mark(item: Object) -> Object = set_prop(item, "link_id", "marked")
        \\fn apply_to(item: Object, callback: Object -> Object) -> Object = callback(item)
        \\fn indirect(item: Object) -> Object = apply_to(item, mark)
        \\page main
        \\  let item = body_obj!("A")
        \\  text!(item.link_id ?? "missing")
        \\  apply_to(item, indirect)
        \\end
    , "marked");
}

test "compiler semantics: finite higher order reentry preserves returned function effects" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\fn label(item: Object) -> String = item.link_id ?? "missing"
        \\fn direct() -> Object -> String = label
        \\fn apply_factory(factory: () -> (Object -> String)) -> Object -> String = factory()
        \\fn nested() -> Object -> String = apply_factory(direct)
        \\page main
        \\  let item = body_obj!("A")
        \\  let callback = apply_factory(nested)
        \\  text!(callback(item))
        \\  item.link_id = "marked"
        \\end
    , "marked");
}

test "compiler semantics: broad reads survive narrower overlapping reads" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\import std:internal/classes as { Text }
        \\type Tagged = object {
        \\  base = Text
        \\  roles = ["tagged"]
        \\  badge: String? = none
        \\  summary: String? = none
        \\}
        \\page main
        \\  let a = txt_obj!("A", "tagged")
        \\  let b = txt_obj!("B", "tagged")
        \\  a.summary = (a.badge ?? "-") ++ join(doc_objs(docctx(), "tagged"), ",", (item: Object) |-> item.badge ?? "-")
        \\  b.badge = "X"
        \\  text!(a.summary ?? "missing")
        \\end
    , "--,X");
}

test "compiler semantics: selected aliases retain object property dependencies" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\fn identity(item: Object) -> Object = item
        \\page main
        \\  let a = txt_obj!("A", "tagged")
        \\  let label = a.link_id ?? "none"
        \\  let b = identity(first(objs(pagectx(), "tagged")))
        \\  b.link_id = "X"
        \\  text!("label=" ++ label)
        \\end
    , "label=X");
}

test "compiler semantics: constant object aliases retain shared identity" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\const shared: Object = body_obj("A")
        \\fn identity(item: Object) -> Object = item
        \\page main
        \\  let a = shared
        \\  let b = identity(shared)
        \\  text!(a.link_id ?? "none")
        \\  b.link_id = "X"
        \\end
    , "X");
}

test "compiler semantics: separate constructor calls retain distinct identities" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\fn make() -> Object
        \\  let item = body_obj("A")
        \\  return item
        \\end
        \\page main
        \\  let a = make()
        \\  let b = make()
        \\  a.link_id = "A"
        \\  b.link_id = a.link_id ?? "none"
        \\  text!(b.link_id ?? "none")
        \\end
    , "A");
}

test "compiler semantics: typed display callbacks wait for captured document property reads" {
    try expectFixtureObjectContent("display-dependencies", "A!");
}

test "compiler semantics: typed display collection reads wait for all matching inputs" {
    try expectObjectContent(
        \\type Item {}
        \\fn display(self: Placed<Item>) -> Text = text(str(selection_count(select<Item>(self.document))))
        \\page main
        \\  place!(Item {})
        \\end
        \\page later
        \\  place!(Item {})
        \\end
    , "2");
}

test "compiler semantics: typed displays combine selected input fields with scheduled document reads" {
    try expectObjectContent(
        \\type Item { prefix: String }
        \\type Summary {}
        \\fn display(self: Placed<Item>) -> Text = text(self.value.prefix)
        \\fn display(self: Placed<Summary>) -> Text
        \\  let item = first(select<Item>(self.document))
        \\  return text("selected=" ++ item.value.prefix ++ (self.document.footer_text ?? "missing"))
        \\end
        \\page main
        \\  place!(Summary {})
        \\end
        \\page later
        \\  place!(Item { prefix = "A" })
        \\end
        \\document
        \\  docctx().footer_text = "X"
        \\end
    , "selected=AX");
}

test "compiler semantics: records require fields without declared defaults" {
    try expectDiagnostic(
        \\type Settings { size: Number }
        \\page main
        \\  let settings = Settings {}
        \\end
    , "bytes:", "MissingField");
    try expectDiagnostic(
        \\type Settings { size: Number? }
        \\page main
        \\  let settings = Settings {}
        \\end
    , "bytes:", "MissingField");
}

test "compiler semantics: explicit none and declared defaults satisfy record fields" {
    try expectObjectContent(
        \\type Settings {
        \\  size: Number
        \\  suffix: String? = none
        \\}
        \\page main
        \\  let settings = Settings { size = 2 } with { size = 3 }
        \\  text!(str(settings.size) ++ (settings.suffix ?? "!"))
        \\end
    , "3!");
    try buildSource(
        \\type Settings { size: Number? }
        \\page main
        \\  let settings = Settings { size = none }
        \\end
    );
}

test "compiler semantics: callbacks must accept every supplied argument" {
    try expectDiagnostic(
        \\fn call_with_none(callback: (Number?) -> String) -> String = callback(none)
        \\fn show(value: Number) -> String = str(value)
        \\page main
        \\  text!(call_with_none(show))
        \\end
    , "bytes:", "TypeMismatch");
    try expectObjectContent(
        \\fn apply(callback: Number -> String) -> String = callback(3)
        \\fn show(value: Number?) -> String = str(value ?? 0)
        \\page main
        \\  text!(apply(show))
        \\end
    , "3");
}

test "compiler semantics: primitive callbacks accept broader parameter types" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\fn label(item: Object?) -> String = "X"
        \\page main
        \\  txt_obj!("A", "tagged")
        \\  text!(join(doc_objs(docctx(), "tagged"), "", label))
        \\end
    , "X");
}

test "compiler semantics: property reads reject selections and nonobject content" {
    try expectDiagnostic(
        \\page main
        \\  let value = objs_here("body").link_id
        \\end
    , "bytes:", "InvalidProperty");
    try expectDiagnostic(
        \\page main
        \\  let value = pagectx().content
        \\end
    , "bytes:", "InvalidProperty");
    try expectDiagnostic(
        \\document
        \\  let value = docctx().content
        \\end
    , "bytes:", "InvalidProperty");
    try expectDiagnostic(
        \\page main
        \\  let value = prop(objs_here("body"), "link_id", "none")
        \\end
    , "bytes:", "InvalidProperty");
}

test "compiler semantics: selections remain writable and individual objects readable" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\page main
        \\  let item = txt_obj!("A", "tagged")
        \\  objs(pagectx(), "tagged").link_id = "X"
        \\  text!(item.link_id ?? "missing")
        \\end
    , "X");
}

test "compiler semantics: stored property declarations reject functions recursively" {
    try expectDiagnostic(
        \\type Holder = object {
        \\  roles = ["holder"]
        \\  callback: Number -> Number
        \\}
        \\page main
        \\end
    , "bytes:", "InvalidPropertyType");
    try expectDiagnostic(
        \\type Action { callback: Number -> Number }
        \\type Wrapper { action: Action? = none }
        \\type Holder = object {
        \\  roles = ["holder"]
        \\  wrapper: Wrapper?
        \\}
        \\page main
        \\end
    , "bytes:", "InvalidPropertyType");
}

test "compiler semantics: property assignment and set_prop reject embedded function values" {
    try expectDiagnostic(
        \\fn identity(value: Number) -> Number = value
        \\page main
        \\  let item = body_obj!("A")
        \\  item.link_id = identity
        \\end
    , "bytes:", "InvalidProperty");
    try expectDiagnostic(
        \\type Action { callback: Number -> Number }
        \\type Wrapper { action: Action }
        \\fn identity(value: Number) -> Number = value
        \\page main
        \\  let item = body_obj!("A")
        \\  item.link_id = Wrapper { action = Action { callback = identity } }
        \\end
    , "bytes:", "InvalidProperty");
    try expectDiagnostic(
        \\type Action { callback: Number -> Number }
        \\fn identity(value: Number) -> Number = value
        \\page main
        \\  let item = body_obj!("A")
        \\  set_prop(item, "link_id", Action { callback = identity })
        \\end
    , "bytes:", "InvalidProperty");
}

test "compiler semantics: immutable inputs may contain functions used by displays" {
    try expectObjectContent(
        \\type Action { callback: () -> String }
        \\fn label() -> String = "X"
        \\fn display(self: Placed<Action>) -> Text = text(self.value.callback())
        \\page main
        \\  place!(Action { callback = label })
        \\end
    , "X");
}

test "compiler semantics: optional records require explicit optional member access" {
    try expectDiagnostic(
        \\page main
        \\  let style = LineStyle {}
        \\  text!(str(style.marker_start.width ?? 0))
        \\end
    , "bytes:", "InvalidOptionalMember");
    try expectObjectContent(
        \\type Leaf { width: Number = 5 }
        \\type Branch { leaf: Leaf? = none }
        \\fn width(branch: Branch?) -> Number = branch?.leaf?.width ?? 0
        \\page main
        \\  let missing = Branch {}
        \\  let present = Branch { leaf = Leaf {} }
        \\  text!(str(width(none)) ++ ":" ++ str(width(missing)) ++ ":" ++ str(width(present)))
        \\end
    , "0:0:5");
    try expectObjectContent(
        \\type Leaf { width: Number = 5 }
        \\fn width(leaf: Leaf) -> Number = leaf?.width
        \\page main
        \\  text!(str(width(Leaf {})))
        \\end
    , "5");
    try expectDiagnostic(
        \\type Leaf { width: Number = 5 }
        \\type Branch { leaf: Leaf = Leaf {} }
        \\fn width(branch: Branch?) -> Number = branch?.leaf.width
        \\page main
        \\end
    , "bytes:", "InvalidOptionalMember");
    try expectDiagnostic(
        \\page main
        \\  let mode = WrapMode?.on
        \\end
    , "bytes:", "InvalidOptionalMember");
}

test "compiler semantics: optional object members retain property dependencies" {
    try expectObjectContent(
        \\fn label(item: Object?) -> String = item?.link_id ?? "missing"
        \\page main
        \\  let item = body_obj!("Target")
        \\  text!(label(item))
        \\  item.link_id = "Ready"
        \\end
    , "Ready");
    try expectObjectContent(
        \\fn label(item: Object?) -> String = item?.content ?? "missing"
        \\page main
        \\  body_obj!(label(none))
        \\end
    , "missing");
}

test "compiler semantics: optional function members retain termination checking" {
    try expectObjectContent(
        \\type Action { callback: Number -> Number }
        \\fn identity(value: Number) -> Number = value
        \\fn apply(action: Action?) -> Number = (action?.callback ?? identity)(3)
        \\page main
        \\  text!(str(apply(none)) ++ ":" ++ str(apply(Action { callback = identity })))
        \\end
    , "3:3");
    try expectDiagnostic(
        \\type Action { callback: Number -> Number }
        \\fn identity(value: Number) -> Number = value
        \\fn apply(action: Action?, value: Number) -> Number = (action?.callback ?? identity)(value)
        \\fn recursive(value: Number) -> Number = apply(Action { callback = recursive }, value)
        \\page main
        \\  text!(str(recursive(1)))
        \\end
    , "bytes:", "RecursiveFunction");
}

test "compiler semantics: optional member results cannot be assignment targets" {
    try expectDiagnostic(
        \\type Holder { item: Object? = none }
        \\page main
        \\  let holder = Holder { item = text!("A") }
        \\  (holder?.item).link_id = "X"
        \\end
    , "bytes:", "InvalidProperty");
}

test "compiler semantics: void calls share direct indirect apply record and callback behavior" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\type Action {
        \\  run: (Object, String) -> Void
        \\}
        \\fn mark(item: Object, value: String) -> Void
        \\  item.link_id = value
        \\end
        \\fn invoke(action: (Object, String) -> Void, item: Object, value: String) -> Void
        \\  action(item, value)
        \\end
        \\page main
        \\  let a = body_obj!("A")
        \\  let b = body_obj!("B")
        \\  let c = body_obj!("C")
        \\  let d = body_obj!("D")
        \\  let e = body_obj!("E")
        \\  let f = body_obj!("F")
        \\  mark(a, "direct")
        \\  let apply_mark = mark
        \\  apply_mark(b, "indirect")
        \\  (apply_mark)(c, "apply")
        \\  let action = Action { run = mark }
        \\  action.run(d, "record")
        \\  invoke(mark, e, "callback")
        \\  let lambda = (item: Object, value: String) |-> mark(item, value)
        \\  lambda(f, "lambda")
        \\  text!((a.link_id ?? "missing") ++ ":" ++ (b.link_id ?? "missing") ++ ":" ++ (c.link_id ?? "missing") ++ ":" ++ (d.link_id ?? "missing") ++ ":" ++ (e.link_id ?? "missing") ++ ":" ++ (f.link_id ?? "missing"))
        \\end
    , "direct:indirect:apply:record:callback:lambda");
}

test "compiler semantics: void indirect bare returns stop the body" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\fn stop() -> Void
        \\  docctx().footer_text = "stopped"
        \\  return
        \\  docctx().footer_text = "unreachable"
        \\end
        \\document
        \\  let f = stop
        \\  f()
        \\end
        \\page main
        \\  text!(docctx().footer_text ?? "missing")
        \\end
    , "stopped");
}

test "compiler semantics: void return expressions are rejected even when their expression is void" {
    try expectDiagnostic(
        \\fn noop() -> Void
        \\end
        \\fn invalid() -> Void
        \\  return noop()
        \\end
        \\page main
        \\end
    , "case.ss:bytes:", "VoidReturnValue");
}

test "compiler semantics: void calls cannot supply primitive argument values" {
    try expectDiagnostic(
        \\fn noop() -> Void
        \\end
        \\page main
        \\  str(noop())
        \\end
    , "case.ss:bytes:", "VoidValue");
}

test "compiler semantics: void types are restricted to function results" {
    try expectDiagnostic(
        \\fn invalid(value: Void) -> Void
        \\end
        \\page main
        \\end
    , "case.ss:bytes:", "InvalidVoidType");
    try expectDiagnostic(
        \\type Invalid {
        \\  value: Void
        \\}
        \\page main
        \\end
    , "case.ss:bytes:", "InvalidVoidType");
    try expectDiagnostic(
        \\fn invalid() -> Void? = none
        \\page main
        \\end
    , "case.ss:bytes:", "InvalidVoidType");
    try expectDiagnostic(
        \\const invalid: Void = noop()
        \\fn noop() -> Void
        \\end
        \\page main
        \\end
    , "case.ss:bytes:", "InvalidVoidType");
}

test "compiler semantics: imported void function values keep definition module defaults and effects" {
    try buildSourceWithOverlay(
        \\import "./lib/types" as lib
        \\page main
        \\  let a = body_obj!("A")
        \\  let b = body_obj!("B")
        \\  lib::mark(a)
        \\  let f = lib::action()
        \\  f(b, "indirect")
        \\end
    ,
        \\const label: String = "default"
        \\fn mark(item: Object, value: String = label) -> Void
        \\  item.link_id = value
        \\end
        \\fn action() -> (Object, String) -> Void
        \\  return mark
        \\end
    );
}

test "compiler semantics: explicit constraints solve a representative layout" {
    try buildFixture("explicit-constraints");
}

test "compiler semantics: explicit constraint registration rejects page anchor mismatches" {
    try expectLoweringErrorDiagnostic(
        \\document
        \\  let p = new_page(docctx(), "First")
        \\  let q = new_page(docctx(), "Second")
        \\  let item = new("Item", "body", "text")
        \\  p ~ (item.left == q.left + 40)
        \\  place_on!(p, item)
        \\end
    , "CrossPageConstraint");
}

test "compiler semantics: constraint registration rejects layout feedback" {
    try expectLoweringErrorDiagnostic(
        \\page main
        \\  let item = body_obj!("Item")
        \\  ~ (item.left == pagectx().left + frame_x(item))
        \\end
    , "LayoutDependencyCycle");
}

test "compiler semantics: functions with constraint statements require a current page" {
    try expectDiagnostic(
        \\fn pin(item: Object) -> Void
        \\  ~ item.left == page.left + 40
        \\end
        \\document
        \\  let item = new("Item", "body", "text")
        \\  pin(item)
        \\end
        \\page main
        \\end
    , "case.ss:bytes:", "NoCurrentPage");
}

test "compiler semantics: function constraint anchors are checked without invocation" {
    try expectDiagnostic(
        \\fn pin(item: Object, label: String) -> Void
        \\  ~ item.left == label.right
        \\end
        \\page main
        \\end
    , "case.ss:bytes:", "TypeMismatch: expected Object, got String");
    try expectDiagnostic(
        \\fn pin(item: Object) -> Void
        \\  ~ item.left == missing.right
        \\end
        \\page main
        \\end
    , "case.ss:bytes:", "UnknownIdentifier");
}

test "compiler semantics: constraint registration in display helpers is an effect" {
    try expectDiagnostic(
        \\type Label {}
        \\fn describe(item: Placed<Label>) -> String
        \\  item.page ~ (item.left == item.page.left + 40)
        \\  return "Item"
        \\end
        \\fn display(self: Placed<Label>) -> Text = text(describe(self))
        \\page main
        \\  place!(Label {})
        \\end
    , "case.ss:bytes:", "ImpureDisplayFunction");
}

test "compiler semantics: saved constraint values cannot feed solved geometry back into layout" {
    try expectLoweringErrorDiagnostic(
        \\page main
        \\  let item = body_obj!("Item")
        \\  let rules = (item.left == pagectx().left + frame_x(item))
        \\  ~ rules
        \\end
    , "PostLayoutComputationUnsupported");
}

test "compiler semantics: constraint anchors wait for delayed object bindings" {
    try buildSource(
        \\page main
        \\  let item = text!(docctx().footer_text ?? "missing")
        \\  ~ item.left == page.left + 40
        \\end
        \\document
        \\  docctx().footer_text = "Ready"
        \\end
    );
}

test "compiler semantics: nested record anchors wait for both delayed root bindings" {
    try buildSource(
        \\type Inner { item: Object }
        \\type Outer { inner: Inner }
        \\page main
        \\  let target = Outer { inner = Inner { item = body_obj!(docctx().footer_text ?? "missing") } }
        \\  let source = Outer { inner = Inner { item = body_obj!(docctx().watermark ?? "missing") } }
        \\  ~ target.inner.item.left == source.inner.item.right + 24
        \\end
        \\document
        \\  docctx().footer_text = "Target"
        \\  docctx().watermark = "Source"
        \\end
    );
}

test "compiler semantics: generic anchor paths retain nested arguments and delayed bindings" {
    try buildSource(
        \\type Box<T> { value: T }
        \\page main
        \\  let target = Box { value = Box { value = text!(docctx().footer_text ?? "missing") } }
        \\  let source = Box { value = Box { value = text!(docctx().watermark ?? "missing") } }
        \\  ~ target.value.value.left == source.value.value.right + 24
        \\end
        \\document
        \\  docctx().footer_text = "Target"
        \\  docctx().watermark = "Source"
        \\end
    );
}

test "compiler semantics: generic anchor paths reject nonplacement fields" {
    try expectDiagnostic(
        \\type Box<T> { value: T }
        \\page main
        \\  let target = Box { value = Box { value = "Text" } }
        \\  ~ target.value.value.left == page.left + 24
        \\end
    , "case.ss:bytes:", "TypeMismatch");
    try expectDiagnostic(
        \\type Box<T> { value: T }
        \\page main
        \\  let target = Box { value = Box { value = text!("Text") } }
        \\  ~ target.value.missing.left == page.left + 24
        \\end
    , "case.ss:bytes:", "UnknownField");
}

test "compiler semantics: anchor paths reject mutable object property traversal" {
    try expectDiagnostic(
        \\page main
        \\  let item = body_obj!("Item")
        \\  ~ item.text.left == page.left + 40
        \\end
    , "case.ss:bytes:", "InvalidConstraintObject");
}

test "compiler semantics: erased selections support counting without exposing elements" {
    try expectObjectContent(
        \\fn size(items: Selection) -> Number
        \\  return selection_count(items)
        \\end
        \\page main
        \\  text!(str(size(pages(docctx()))))
        \\end
    , "1");
}

test "compiler semantics: first and callbacks retain explicit page element types" {
    try expectObjectContent(
        \\fn ids(items: Selection<Page>) -> String
        \\  return str(page_index(first(items))) ++ ":" ++ join(items, ",", (p: Page) |-> str(page_index(p)))
        \\end
        \\page main
        \\  text!(ids(pages(docctx())))
        \\end
    , "1:1");
    try expectDiagnostic(
        \\page main
        \\  let query = "document" ++ "_pages"
        \\  text!(content(first(select(docctx(), query))))
        \\end
    , "case.ss:bytes:", "TypeMismatch: expected Object, got Page");
}

test "compiler semantics: first requires a known selection element type" {
    try expectDiagnostic(
        \\fn invalid(items: Selection) -> Object
        \\  return first(items)
        \\end
        \\page main
        \\end
    , "case.ss:bytes:", "UnknownSelectionItemType");
}

test "compiler semantics: selection callbacks require known element types" {
    const operations = [_][]const u8{
        "foreach(items, (item: Object) |-> content(item))",
        "foreach_enumerate(items, (item: Object, index: Number) |-> content(item))",
        "join(items, \",\", (item: Object) |-> content(item))",
        "fold(items, \"\", (acc: String, item: Object) |-> acc ++ content(item))",
    };
    for (operations) |operation| {
        const source = try std.fmt.allocPrint(testing.allocator, "fn invalid(items: Selection) -> Void\n  {s}\nend\npage main\nend\n", .{operation});
        defer testing.allocator.free(source);
        try expectDiagnostic(source, "case.ss:bytes:", "UnknownSelectionItemType");
    }
}

test "compiler semantics: erased selections cannot be returned as object selections or grouped" {
    try expectDiagnostic(
        \\fn invalid(items: Selection) -> Selection<Object>
        \\  return items
        \\end
        \\page main
        \\end
    , "case.ss:bytes:", "TypeMismatch");
    try expectDiagnostic(
        \\fn invalid(items: Selection) -> Object
        \\  return group(items)
        \\end
        \\page main
        \\end
    , "case.ss:bytes:", "TypeMismatch");
}

test "compiler semantics: erased selections cannot receive object properties" {
    try expectDiagnostic(
        \\fn invalid(items: Selection) -> Void
        \\  items.link_id = "invalid"
        \\end
        \\page main
        \\end
    , "case.ss:bytes:", "InvalidProperty");
    try expectDiagnostic(
        \\fn invalid(items: Selection) -> Void
        \\  set_prop(items, "link_id", "invalid")
        \\end
        \\page main
        \\end
    , "case.ss:bytes:", "InvalidProperty");
}

test "compiler semantics: selection algebra cannot recover erased element types" {
    for ([_][]const u8{ "selection_union", "selection_intersection", "selection_difference" }) |operation| {
        const source = try std.fmt.allocPrint(testing.allocator, "fn invalid(left: Selection, right: Selection<Page>) -> Selection\n  return {s}(left, right)\nend\npage main\nend\n", .{operation});
        defer testing.allocator.free(source);
        try expectDiagnostic(source, "case.ss:bytes:", "UnknownSelectionItemType");
    }
}

test "compiler semantics: lambda parameters shadow captured names in their own scopes" {
    try expectObjectContent(
        \\page main
        \\  let x = "Outer"
        \\  let f = (x: Number) |-> ((x: Number) |-> x + 1)(x)
        \\  text!(str(f(2)) ++ ":" ++ x)
        \\end
    , "3:Outer");
    try expectDiagnostic(
        \\page main
        \\  let f = (x: Number, x: Number) |-> x
        \\end
    , "case.ss:bytes:", "DuplicateBinding");
}

test "compiler semantics: property definitions reject overlapping paths in both orders" {
    const pairs = [_][]const u8{
        "a.layout.x = 100\na.layout.x = 200",
        "a.layout = LayoutStyle { x = 100 }\na.layout.x = 200",
        "a.layout.x = 100\na.layout = LayoutStyle { x = 200 }",
        "a.text.font = FontFace {}\na.text.font.family = \"Avenir\"",
        "a.text.markdown.bold_color = none\na.text.markdown.bold_color = none",
        "a.optional_label = none\nset_prop(select(a, \"self_object\"), \"optional_label\", none)",
    };
    for (pairs) |pair| {
        const source = try std.fmt.allocPrint(testing.allocator, "import std:themes/default as *\nextend Flow {{ optional_label: String? = none }}\npage main\nlet a = txt_obj!(\"A\", \"body\")\n{s}\nend\n", .{pair});
        defer testing.allocator.free(source);
        try expectLoweringErrorDiagnostic(source, "DuplicatePropertyDefinition");
    }
}

test "compiler semantics: aliased nested property definitions conflict" {
    try expectLoweringErrorDiagnostic(
        \\import std:themes/default as *
        \\page main
        \\  let a = txt_obj!("A", "body")
        \\  let b = a
        \\  a.layout.x = 100
        \\  b.layout.x = 200
        \\end
    , "DuplicatePropertyDefinition");
}

test "compiler semantics: nested reads wait for whole property definitions" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\page main
        \\  let a = txt_obj!("A", "body")
        \\  text!("x=" ++ str(a.layout?.x ?? 0))
        \\  a.layout = LayoutStyle { x = 300 }
        \\end
    , &.{"x=300"});
}

test "compiler semantics: whole property reads wait for sibling definitions" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\page main
        \\  let a = txt_obj!("A", "body")
        \\  let style = a.layout ?? LayoutStyle {}
        \\  text!("x=" ++ str(style.x) ++ ",y=" ++ str(style.right_inset))
        \\  a.layout.x = 300
        \\  a.layout.right_inset = 200
        \\end
    , &.{"x=300,y=200"});
}

test "compiler semantics: property paths preserve objects carried through returned records" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\type Box { item: Object }
        \\fn wrap(item: Object) -> Box
        \\  return Box { item = item }
        \\end
        \\page main
        \\  let a = txt_obj!("A", "body")
        \\  let box = wrap(a)
        \\  text!("x=" ++ str(box.item.layout?.x ?? 0))
        \\  box.item.layout.x = 300
        \\end
    , &.{"x=300"});
}

test "compiler semantics: property paths detect record aliases of an object" {
    try expectLoweringErrorDiagnostic(
        \\import std:themes/default as *
        \\type Box { item: Object }
        \\page main
        \\  let a = txt_obj!("A", "body")
        \\  let box = Box { item = a }
        \\  a.layout.x = 100
        \\  box.item.layout.x = 200
        \\end
    , "DuplicatePropertyDefinition");
}

test "compiler semantics: fresh local property definitions satisfy subsequent reads" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\fn make_label() -> String
        \\  let item = txt_obj("A", "body")
        \\  item.layout.x = 123
        \\  let style = item.layout ?? LayoutStyle {}
        \\  return "x=" ++ str(style.x)
        \\end
        \\page main
        \\  text!(make_label())
        \\end
    , &.{"x=123"});
}

test "compiler semantics: fresh local reads cannot precede their definitions" {
    try expectLoweringErrorDiagnostic(
        \\import std:themes/default as *
        \\fn make_label() -> String
        \\  let item = txt_obj("A", "body")
        \\  let x = item.layout?.x ?? 0
        \\  item.layout.x = 123
        \\  return "x=" ++ str(x)
        \\end
        \\page main
        \\  text!(make_label())
        \\end
    , "ExecutionDependencyCycle");
}

test "compiler semantics: property definition cannot read its own final value" {
    try expectLoweringErrorDiagnostic(
        \\import std:themes/default as *
        \\page main
        \\  let item = txt_obj!("A", "body")
        \\  item.layout.x = (item.layout?.x ?? 0) + 1
        \\end
    , "ExecutionDependencyCycle");
}

test "compiler semantics: optional nested reads retain sibling property precision" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\page main
        \\  let item = txt_obj!("A", "body")
        \\  item.layout.x = (item.layout?.right_inset ?? 0) + 1
        \\  item.layout.right_inset = 123
        \\  text!(str(item.layout?.x ?? 0))
        \\end
    , &.{"124"});
}

test "compiler semantics: escaping local objects retain unresolved final property reads" {
    try expectLoweringErrorDiagnostic(
        \\import std:themes/default as *
        \\fn make_item() -> Object
        \\  let item = txt_obj("A", "body")
        \\  let x = item.layout?.x ?? 0
        \\  item.link_id = str(x)
        \\  return item
        \\end
        \\page main
        \\  let item = make_item()
        \\  item.layout.x = 123
        \\  place_on!(pagectx(), item)
        \\end
    , "ExecutionDependencyCycle");
}

test "compiler semantics: returned initialized objects keep internal reads satisfied" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\fn make_item() -> Object
        \\  let item = txt_obj("A", "body")
        \\  item.layout.x = 123
        \\  item.link_id = str(item.layout?.x ?? 0)
        \\  return item
        \\end
        \\page main
        \\  let item = make_item()
        \\  text!(item.link_id ?? "missing")
        \\  place_on!(pagectx(), item)
        \\end
    , &.{"123"});
}

test "compiler semantics: dump preserves explicitly absent optional properties" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\extend Flow { optional_label: String? = none }
        \\page main
        \\  let item = txt_obj!("A", "body")
        \\  item.optional_label = none
        \\end
    , &.{"\"optional_label\":null"});
}

test "compiler semantics: absent property values use string accessor fallbacks" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\extend Flow { optional_label: String? = none }
        \\page main
        \\  let item = txt_obj!("A", "body")
        \\  set_prop(item, "optional_label", none)
        \\  if prop_eq(item, "optional_label", "none")
        \\    text!("Unexpected equality")
        \\  else
        \\    text!(prop(item, "optional_label", "Missing"))
        \\  end
        \\end
    , &.{"Missing"});
}

test "compiler semantics: explicit none refines an optional callable in a record" {
    try expectObjectContent(
        \\type Box { callback: (Number -> Number)? }
        \\fn inc(x: Number) -> Number = x + 1
        \\fn cleared(box: Box) -> Number
        \\  let updated = box with { callback = none }
        \\  let callback = updated.callback ?? inc
        \\  return callback(1)
        \\end
        \\fn unused(x: Number) -> Number = cleared(Box { callback = unused })
        \\page main
        \\  text!(str(unused(1)))
        \\end
    , "2");
}

test "compiler semantics: object-valued properties start a new property owner" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\import std:internal/classes as { Text }
        \\type Linked = object {
        \\  base = Text
        \\  roles = ["linked"]
        \\  peer: Object? = none
        \\}
        \\page main
        \\  let a = txt_obj!("A", "linked")
        \\  let b = txt_obj!("B", "body")
        \\  text!("peer=" ++ str(a.peer?.layout?.x ?? 0))
        \\  a.peer = b
        \\  b.layout.x = 432
        \\end
    , &.{"peer=432"});
}

test "compiler semantics: numbering queries wait for nested typed group descendants" {
    const source = numbered_claim_source ++
        \\page main
        \\  let a = claim("First")
        \\  let b = claim("Second")
        \\  text!("items=" ++ join(select<Claim>(docctx()), ",", (item: Placed<Claim>) |-> item.value.title))
        \\  place_on!(pagectx(), group(a, group(b)))
        \\end
    ;
    try expectObjectContent(source, "Claim 1: First");
    try expectObjectContent(source, "Claim 2: Second");
    try expectObjectContent(source, "items=First,Second");
}

test "compiler semantics: child page reads follow typed group display expansion" {
    try expectObjectContent(
        \\page main
        \\  let root = place!(group(text("A")))
        \\  let child = first(children(root))
        \\  text!(str(page_index(child.page)))
        \\end
    , "1");
}

test "compiler semantics: unplaced objects do not belong to document queries" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\page main
        \\  let a = txt_obj("Detached", "body")
        \\  text!("members=" ++ str(selection_count(doc_objs(docctx(), "body"))))
        \\end
    , &.{"members=0"});
}

test "compiler semantics: placement facts follow returned groups and record aliases" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\type Parts { root: Object }
        \\fn bundle(a: Object, b: Object) -> Parts
        \\  return Parts { root = group(a, group(b)) }
        \\end
        \\page main
        \\  let a = txt_obj("A", "body")
        \\  let b = txt_obj("B", "body")
        \\  let parts = bundle(a, b)
        \\  text!("members=" ++ str(selection_count(doc_objs(docctx(), "body"))))
        \\  place_on!(pagectx(), parts.root)
        \\end
    , &.{"members=2"});
}

test "compiler semantics: local placement satisfies a later parent page read" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\fn make_item!() -> Object
        \\  let item = txt_obj("A", "body")
        \\  place_on!(pagectx(), item)
        \\  if page_of(item)?
        \\    item.link_id = "placed"
        \\  end
        \\  return item
        \\end
        \\page main
        \\  let item = make_item!()
        \\  text!(item.link_id ?? "missing")
        \\end
    , &.{"placed"});
}

test "compiler semantics: repeated placement is rejected" {
    try expectLoweringErrorDiagnostic(
        \\import std:themes/default as *
        \\page main
        \\  let a = txt_obj!("A", "body")
        \\  place_on!(pagectx(), a)
        \\end
    , "DuplicatePlacement");
}

test "compiler semantics: cached placement summaries retain their caller page" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\page first
        \\  text!("first=" ++ str(selection_count(select<Heading>(pagectx()))))
        \\  heading!("A")
        \\end
        \\page second
        \\  text!("second=" ++ str(selection_count(select<Heading>(pagectx()))))
        \\  heading!("B")
        \\end
    , &.{ "first=1", "second=1" });
}

test "compiler semantics: queries retain placement order across dependency scheduling" {
    try expectDumpContains(
        \\page main
        \\  body_obj!(docctx().footer_text ?? "unset")
        \\  body_obj!("Second")
        \\  text!("order=" ++ join(objs_here("body"), ",", (o: Object) |-> content(o)))
        \\end
        \\document
        \\  docctx().footer_text = "First"
        \\end
    , &.{"order=First,Second"});
}

test "compiler semantics: explicit group argument order determines descendant query order" {
    try expectDumpContains(
        \\page main
        \\  let a = body_obj("A")
        \\  let b = body_obj("B")
        \\  let c = body_obj("C")
        \\  place_on!(pagectx(), group(c, group(b, a)))
        \\  text!("order=" ++ join(objs_here("body"), ",", (o: Object) |-> content(o)))
        \\end
    , &.{"order=C,B,A"});
}

test "compiler semantics: dynamic pages retain authored positions among static pages" {
    try expectDumpContains(
        \\document
        \\  let first = new_page(docctx(), docctx().footer_text ?? "unset")
        \\  place_on!(first, body_obj("Dynamic first"))
        \\end
        \\page middle
        \\  text!("middle=" ++ str(page_index(pagectx())))
        \\end
        \\document
        \\  let last = new_page(docctx(), "last")
        \\  place_on!(last, body_obj("Dynamic last"))
        \\  docctx().footer_text = "first"
        \\  docctx().watermark = "order=" ++ join(doc_objs(docctx(), "body"), ",", (o: Object) |-> content(o))
        \\end
        \\page report
        \\  text!(docctx().watermark ?? "missing")
        \\end
    , &.{ "middle=2", "order=Dynamic first,Dynamic last" });
}

test "compiler semantics: optional fallback preserves an optional result" {
    try buildSource(
        \\fn choose(primary: Color?, fallback: Color?) -> Color?
        \\  return primary ?? fallback
        \\end
        \\page main
        \\  let body = new("Optional colors", "body", "text")
        \\  body.text.color = choose(none, c"#123456") ?? c"#000000"
        \\end
    );
    try expectDiagnostic(
        \\fn choose(primary: Color?, fallback: Number?) -> Color?
        \\  return primary ?? fallback
        \\end
    , "case.ss:bytes:", "TypeMismatch");
}

test "compiler semantics: constraint operators reject numbers and wrong registration targets" {
    try expectDiagnostic(
        \\page main
        \\  let item = text!("Item")
        \\  let invalid = item.left == 40
        \\end
    , "case.ss:bytes:", "TypeMismatch");
    try expectDiagnostic(
        \\page main
        \\  ~ true
        \\end
    , "case.ss:bytes:", "TypeMismatch");
    try expectDiagnostic(
        \\page main
        \\  let item = text!("Item")
        \\  item ~ item.left == pagectx().left
        \\end
    , "case.ss:bytes:", "TypeMismatch");
}

test "compiler semantics: symbolic anchor names cannot be shadowed by object fields" {
    try expectDiagnostic(
        \\type Card = object { base = Flow left: Number = 10 }
    , "case.ss:bytes:", "ReservedAnchorField");
    try buildSource(
        \\type Margins { left: Number = 10 right: Number = 20 }
        \\page main
        \\  let margins = Margins {}
        \\  let item = text!("Margins")
        \\  ~ item.left == page.left + margins.left
        \\end
    );
}

test "compiler semantics: nested selection arguments validate their annotations" {
    try expectDiagnostic(
        \\fn invalid(value: Selection<Selection<Void>>) -> Void
        \\end
        \\page main
        \\end
    , "case.ss:bytes:", "InvalidVoidType");
    try expectDiagnostic(
        \\fn invalid(value: Selection<Selection<Missing>>) -> Void
        \\end
        \\page main
        \\end
    , "case.ss:bytes:", "UnknownType: unknown type: Missing");
}

test "compiler semantics: explicit type arguments cannot be ignored" {
    try expectDiagnostic(
        \\fn keep(value: Number) -> Number = value
        \\page main
        \\  let value = keep<String>(1)
        \\end
    , "case.ss:bytes:", "InvalidTypeArity");
    try expectDiagnostic(
        \\type Value { count: Number }
        \\page main
        \\  let value = Value<String> { count = 1 }
        \\end
    , "case.ss:bytes:", "InvalidTypeArity");
    try expectDiagnostic(
        \\type Value { count: Number }
        \\fn read(value: Value<Number>) -> Number = value.count
        \\page main
        \\end
    , "case.ss:bytes:", "InvalidTypeArity");
    try expectDiagnostic(
        \\fn read(value: Selection<Page, Object>) -> Void
        \\end
        \\page main
        \\end
    , "case.ss:bytes:", "InvalidTypeArity");
    try expectDiagnostic(
        \\fn keep(value: Number) -> Number = value
        \\page main
        \\  let value = keep<Missing>(1)
        \\end
    , "case.ss:bytes:", "UnknownType: unknown type: Missing");
}

test "compiler semantics spec: generic parameters cannot shadow built-in types" {
    try expectDiagnostic("fn identity<Number>(x: Number) -> Number = x\n", "case.ss:bytes:", "InvalidTypeParameter");
    try expectDiagnostic("type Box<Selection> { value: Selection }\n", "case.ss:bytes:", "InvalidTypeParameter");
}

test "compiler semantics: void results reject type arguments" {
    try expectDiagnostic("fn run() -> Void<Number>\nend\n", "case.ss:bytes:", "InvalidTypeArity");
    try expectDiagnostic("fn run(action: () -> Void<Number>) -> Void\nend\n", "case.ss:bytes:", "InvalidTypeArity");
}

test "compiler semantics: generic functions specialize explicit and inferred calls" {
    try expectDumpContains(
        \\fn identity<T>(value: T) -> T = value
        \\fn forward<T>(value: T) -> T = identity<T>(value)
        \\page main
        \\  let number: Number = forward<Number>(7)
        \\  let title: String = forward("Generic")
        \\  let inferred: Number = identity(number)
        \\  text!(title)
        \\end
    , &.{"\"content\":\"Generic\""});
}

test "compiler semantics: generic bodies are checked for each concrete argument" {
    try expectDiagnostic(
        \\fn increment<T>(value: T) -> T = value + 1
        \\page main
        \\  let valid = increment(1)
        \\  let invalid = increment("Text")
        \\end
    , "case.ss:bytes:", "InvalidInstantiation");
    try expectDiagnostic(
        \\fn first<T>(left: T, right: T) -> T = left
        \\page main
        \\  let invalid = first(1, "Text")
        \\end
    , "case.ss:bytes:", "ConflictingTypeArguments");
    try expectDiagnostic(
        \\fn unused<T>() -> Number = 1
        \\page main
        \\  let invalid = unused()
        \\end
    , "case.ss:bytes:", "CannotInferTypeArgument");
}

test "compiler semantics: generic defaults and closures retain concrete bindings" {
    try buildSource(
        \\fn identity<T>(value: T) -> T = value
        \\fn repeat<T>(value: T, copy: T = identity<T>(value)) -> T = copy
        \\fn closure<T>(value: T) -> () -> T = () |-> identity<T>(value)
        \\fn apply<T>(action: (T) -> T, value: T) -> T = action(value)
        \\page main
        \\  let number: Number = repeat(4)
        \\  let title: String = repeat("Default")
        \\  let first = closure(3)
        \\  let second = closure("Closure")
        \\  let n: Number = first()
        \\  let s: String = second()
        \\  let result: Number = apply((x: Number) |-> x + 1, 2)
        \\  text!(s)
        \\end
    );
}

test "compiler semantics: generic imports retain definition module and nominal arguments" {
    try buildSourceWithOverlay(
        \\import "lib/types" as lib
        \\type Item { value: String }
        \\page main
        \\  let local: Item = lib::identity(Item { value = "Local" })
        \\  let imported: lib::Item = lib::identity(lib::Item { value = 4 })
        \\  let title: String = lib::label("Caller")
        \\  text!(title)
        \\end
    ,
        \\type Item { value: Number }
        \\fn identity<T>(value: T) -> T = value
        \\fn private_label(value: String) -> String = value
        \\fn label<T>(value: T) -> String = private_label("Library")
    );
}

test "compiler semantics: generic calls reject mismatches and polymorphic values" {
    try expectDiagnostic(
        \\fn identity<T>(value: T) -> T = value
        \\page main
        \\  let invalid = identity<Number>("Text")
        \\end
    , "case.ss:bytes:", "TypeMismatch");
    try expectDiagnostic(
        \\fn identity<T>(value: T) -> T = value
        \\page main
        \\  let invalid = identity
        \\end
    , "case.ss:bytes:", "UninstantiatedFunction");
}

test "compiler semantics: generic concrete bodies preserve deferred property reads" {
    try expectDumpContains(
        \\fn read<T>(value: T) -> String = value.link_id ?? "missing"
        \\page main
        \\  let input = body_obj!("Input")
        \\  let output = body_obj!(read(input))
        \\  input.link_id = "Forward"
        \\end
    , &.{"\"content\":\"Forward\""});
}

test "compiler semantics: changing type arguments cannot conceal recursion" {
    try expectDiagnostic(
        \\fn grow<T>() -> Number = grow<T?>()
        \\page main
        \\  let invalid = grow<Number>()
        \\end
    , "case.ss:bytes:", "RecursiveFunction");
}

test "compiler semantics: generic operator results are checked after substitution" {
    try expectDiagnostic(
        \\fn same<T>(left: T, right: T) -> Bool = left == right
        \\page main
        \\  let valid = same(1, 2)
        \\  let a = text!("A")
        \\  let b = text!("B")
        \\  let invalid = same(a.left, b.left)
        \\end
    , "case.ss:bytes:", "InvalidInstantiation");
}

test "compiler semantics: generic optional values and generated placing calls" {
    try buildSource(
        \\import std:text/content as native
        \\fn unwrap<T>(value: T?, fallback: T) -> T = value ?? fallback
        \\fn/! wrapped<T>(value: T) -> T = value
        \\page main
        \\  let missing: Number? = none
        \\  let n: Number = unwrap(missing, 2)
        \\  let s: String = unwrap<String>(none, "Fallback")
        \\  let first: Placed<native::Text> = wrapped!<native::Text>(native::Text { content = s })
        \\  let second = wrapped!(native::Text { content = "Created" })
        \\end
    );
}

test "compiler semantics: paired typed constructors validate display and placement inputs" {
    try expectDiagnostic(
        \\type Hidden { content: String }
        \\fn/! hidden() -> Hidden = Hidden { content = "Missing" }
        \\page main
        \\  hidden!()
        \\end
    , "case.ss:bytes:", "MissingDisplay");
    try expectDiagnostic(
        \\import std:text/content as native
        \\fn/! already(value: Placed<native::Text>) -> Placed<native::Text> = value
        \\page main
        \\end
    , "case.ss:bytes:", "InvalidPlacementInput");
    try expectDiagnostic(
        \\fn/! action() -> Void
        \\  return
        \\end
        \\page main
        \\end
    , "case.ss:bytes:", "InvalidVoidType");
}

test "compiler semantics: generic values infer arguments and preserve nested updates" {
    try expectDumpContains(
        \\type Box<T> { value: T }
        \\fn wrap<T>(value: T) -> Box<T> = Box<T> { value = value }
        \\fn unwrap<T>(box: Box<T>) -> T = box.value
        \\page main
        \\  let number: Box<Number> = Box { value = 3 }
        \\  let original = wrap(wrap("Original"))
        \\  let changed = original with { value.value = "Changed" }
        \\  let amount: Number = unwrap(number)
        \\  text!(original.value.value)
        \\  text!(changed.value.value)
        \\  text!(unwrap(wrap("Inferred")))
        \\end
    , &.{ "\"content\":\"Original\"", "\"content\":\"Changed\"", "\"content\":\"Inferred\"" });
}

test "compiler semantics: concrete type defaults own distinct generic callbacks" {
    try expectDumpContains(
        \\fn identity<T>(value: T) -> T = value
        \\type Handler<T> {
        \\  apply: (T) -> T = (value: T) |-> identity<T>(value)
        \\  fallback: T? = none
        \\}
        \\page main
        \\  let numbers = Handler<Number> {}
        \\  let strings = Handler<String> {}
        \\  let n: Number = numbers.apply(7)
        \\  let missing: Number? = numbers.fallback
        \\  text!(strings.apply("Default callback"))
        \\end
    , &.{"\"content\":\"Default callback\""});
}

test "compiler semantics: generic type defaults preserve deferred callback reads" {
    try expectDumpContains(
        \\type Reader<T> {
        \\  read: (T) -> String = (value: T) |-> value.link_id ?? "Missing"
        \\}
        \\page main
        \\  let reader = Reader<Body> {}
        \\  let input = body_obj!("Input")
        \\  body_obj!(reader.read(input))
        \\  input.link_id = "Deferred generic default"
        \\end
    , &.{"\"content\":\"Deferred generic default\""});
}

test "compiler semantics: applied types reject incompatible fields and updates" {
    try expectDiagnostic(
        \\type Box<T> { value: T }
        \\page main
        \\  let invalid = Box<Number> { value = "Text" }
        \\end
    , "case.ss:bytes:", "TypeMismatch");
    try expectDiagnostic(
        \\type Box<T> { value: T }
        \\page main
        \\  let original = Box { value = Box { value = 1 } }
        \\  let invalid = original with { value.value = "Text" }
        \\end
    , "case.ss:bytes:", "TypeMismatch");
    try expectDiagnostic(
        \\type Same<T> { left: T right: T }
        \\page main
        \\  let invalid = Same { left = 1 right = "Text" }
        \\end
    , "case.ss:bytes:", "ConflictingTypeArguments");
    try expectDiagnostic(
        \\type Missing<T> { value: T? = none }
        \\page main
        \\  let invalid = Missing {}
        \\end
    , "case.ss:bytes:", "CannotInferTypeArgument");
}

test "compiler semantics: generic type defaults cannot expand without termination" {
    try expectDiagnostic(
        \\type Growing<T> {
        \\  next: Growing<T?> = Growing<T?> {}
        \\}
        \\page main
        \\  let invalid = Growing<Number> {}
        \\end
    , "case.ss:bytes:", "RecursiveInstantiation");
}

test "compiler semantics: type defaults read document collections in dependency order" {
    try expectDumpContains(
        \\type Count<T> { amount: Number = selection_count(select<Heading>(docctx())) }
        \\page first
        \\  let count = Count<Number> {}
        \\  text!(str(count.amount))
        \\end
        \\page second
        \\  heading!("First heading")
        \\  heading!("Second heading")
        \\end
    , &.{"\"content\":\"2\""});
}

test "compiler semantics: generic type construction retains imported nominal identity" {
    try buildSourceWithOverlay(
        \\import "lib/types" as lib
        \\type Item { value: String }
        \\page main
        \\  let a: lib::Box<Item> = lib::Box { value = Item { value = "Local" } }
        \\  let b: lib::Box<lib::Item> = lib::Box { value = lib::Item { value = 3 } }
        \\  let n: Number = b.value.value
        \\  text!(a.value.value)
        \\end
    ,
        \\type Item { value: Number }
        \\type Box<T> { value: T }
    );
}

test "compiler semantics: concrete type defaults preserve placement effects" {
    try expectDiagnostic(
        \\type Component<T> { child: Object = body_obj!("Implicit placement") }
        \\fn make() -> Component<Number> = Component<Number> {}
        \\page main
        \\  let invalid = make()
        \\end
    , "case.ss:bytes:", "PlacementEffect");
}

test "compiler semantics: type defaults use their definition module and concrete arguments" {
    try expectObjectContentWithTwoOverlays(
        \\import ./lib/a as a
        \\import ./lib/b as b
        \\fn label<T>(value: T) -> String = "Caller"
        \\page main
        \\  let number = a::Label<Number> {}
        \\  let string = b::Label<String> {}
        \\  text!(number.apply(3) ++ ":" ++ string.apply("Value"))
        \\end
    ,
        \\fn label<T>(value: T) -> String = "First"
        \\type Label<T> { apply: (T) -> String = (value: T) |-> label<T>(value) }
    ,
        \\fn label<T>(value: T) -> String = "Second"
        \\type Label<T> { apply: (T) -> String = (value: T) |-> label<T>(value) }
    , "First:Second");
}

test "compiler semantics: incompatible concrete defaults report the definition and use" {
    const source =
        \\import ./lib/bad as lib
        \\page main
        \\  let invalid = lib::Default<String> {}
        \\end
    ;
    const imported =
        \\type Default<T> { value: T = 1 }
    ;
    try expectOverlayDiagnostic(source, imported, "bad.ss:bytes:", "TypeMismatch");
    try expectOverlayDiagnostic(source, imported, "case.ss:bytes:", "InvalidInstantiation");
}

test "compiler semantics: placed parameters expose typed input ownership and anchors" {
    try buildSource(
        \\type Box<T> { value: T }
        \\fn unwrap<T>(item: Placed<T>) -> T = item.value
        \\fn read(item: Placed<Box<Number>>) -> Number = unwrap(item).value
        \\fn optional(item: Placed<Box<Number>>?) -> Number = item?.value?.value ?? 0
        \\fn owner(item: Placement) -> Page = item.page
        \\fn document_of(item: Placement) -> Document = item.document
        \\fn erase(item: Placed<Box<Number>>) -> Placement = item
        \\fn left(item: Placement) -> Anchor = item.left
        \\fn align(a: Placement, b: Placed<Box<Number>>) -> Constraints
        \\  return a.left == b.right + 12
        \\end
        \\page main
        \\end
    );
}

test "compiler semantics: placement references reject missing arguments and arbitrary input access" {
    const cases = [_]struct { source: []const u8, diagnostic: []const u8 }{
        .{ .source = "fn read(item: Placed) -> Void\nend\n", .diagnostic = "InvalidTypeArity" },
        .{ .source = "fn read(item: Placed<Number, String>) -> Void\nend\n", .diagnostic = "InvalidTypeArity" },
        .{ .source = "fn read(item: Placement<Number>) -> Void\nend\n", .diagnostic = "InvalidTypeArity" },
        .{ .source = "fn read(item: Placed<Void>) -> Void\nend\n", .diagnostic = "InvalidVoidType" },
        .{ .source = "fn read(item: Placement) -> Number = item.value\n", .diagnostic = "UnknownField" },
        .{ .source = "type Item { title: String }\nfn read(item: Placed<Item>) -> String = item.title\n", .diagnostic = "UnknownField" },
        .{ .source = "fn read(item: Placement) -> Placed<Number> = item\n", .diagnostic = "TypeMismatch" },
        .{ .source = "fn mutate(item: Placed<Number>) -> Void\nitem.value = 3\nend\n", .diagnostic = "ImmutablePlacement" },
        .{ .source = "page main\nlet fake = Placed<Number> {}\nend\n", .diagnostic = "InvalidTypeConstruction" },
        .{ .source = "page main\nlet fake = Placement {}\nend\n", .diagnostic = "InvalidTypeConstruction" },
    };
    for (cases) |case| try expectDiagnostic(case.source, "bytes:", case.diagnostic);
}

test "compiler semantics: each display declaration body is checked independently" {
    try expectDiagnostic(
        \\type A { value: String }
        \\type B { value: Number }
        \\fn display(self: Placed<A>) -> B = B { value = self.value.value }
        \\fn display(self: Placed<B>) -> B = self.value
        \\page main
        \\end
    , "bytes:", "TypeMismatch");
}

test "compiler semantics: display declarations require an owned type and one unspecialized receiver" {
    const cases = [_]struct { source: []const u8, diagnostic: []const u8 }{
        .{ .source = "fn display() -> Number = 1\n", .diagnostic = "InvalidDisplaySignature" },
        .{ .source = "fn display(self: Placement) -> Number = 1\n", .diagnostic = "InvalidDisplaySignature" },
        .{ .source = "fn display(self: Placed<Number>) -> Number = self.value\n", .diagnostic = "InvalidDisplaySignature" },
        .{ .source = "type A {}\nfn display(self: Placed<A>) -> Void\nend\n", .diagnostic = "InvalidDisplaySignature" },
        .{ .source = "type A {}\nfn display(self: Placed<A>) -> Placed<A> = self\n", .diagnostic = "InvalidDisplaySignature" },
        .{ .source = "type A {}\nfn display(self: Placed<A>) -> A = self.value\nfn display(other: Placed<A>) -> A = other.value\n", .diagnostic = "DuplicateDisplay" },
        .{ .source = "type Box<T> { value: T }\nfn display(self: Placed<Box<Number>>) -> Box<Number> = self.value\n", .diagnostic = "InvalidDisplaySignature" },
        .{ .source = "type Box<A, B> {}\nfn display<T, U>(self: Placed<Box<T, T>>) -> T = self.value\n", .diagnostic = "InvalidDisplaySignature" },
        .{ .source = "type Box<T> { value: T }\nfn display<T, U>(self: Placed<Box<T>>) -> T = self.value.value\n", .diagnostic = "InvalidDisplaySignature" },
        .{ .source = "type A {}\nfn display!(self: Placed<A>) -> A = self.value\n", .diagnostic = "InvalidDisplaySignature" },
    };
    for (cases) |case| try expectDiagnostic(case.source, "bytes:", case.diagnostic);
    try expectOverlayDiagnostic(
        \\import "./lib/bad" as lib
        \\fn display(self: Placed<lib::A>) -> lib::A = self.value
    , "type A {}\n", "bytes:", "ForeignDisplayDeclaration");
}

test "compiler semantics: display names in different modules do not collide under imports" {
    try buildSourceWithTwoOverlays(
        \\import "./lib/a" as *
        \\import "./lib/b" as *
        \\page main
        \\end
    ,
        \\type A { value: Number }
        \\type RenderA { value: Number }
        \\fn display(self: Placed<A>) -> RenderA = RenderA { value = self.value.value }
    ,
        \\type B { value: Number }
        \\type RenderB { value: Number }
        \\fn display(self: Placed<B>) -> RenderB = RenderB { value = self.value.value }
    );
}

test "compiler semantics: typed displays reject writes through ordinary helpers" {
    try expectDiagnostic(
        \\type A { value: Number }
        \\type Output { value: Number }
        \\fn change_owner(item: Placed<A>) -> Number
        \\  item.page.layout.x = 12
        \\  return item.value.value
        \\end
        \\fn display(self: Placed<A>) -> Output
        \\  return Output { value = change_owner(self) }
        \\end
    , "bytes:", "ImpureDisplayFunction");
    try expectDiagnostic(
        \\type A {}
        \\type Output {}
        \\fn display(self: Placed<A>) -> Output
        \\  ~ self.left == self.page.left
        \\  return Output {}
        \\end
    , "bytes:", "ImpureDisplayFunction");
}

test "compiler semantics: fold preserves numeric and record accumulator types" {
    try expectObjectContent(
        \\type Count { total: Number = 0 }
        \\fn add(acc: Count, p: Page, amount: Number) -> Count = acc with { total = acc.total + amount }
        \\page first
        \\  let all = pages(docctx())
        \\  let numeric = fold(all, 0, (acc: Number, p: Page) |-> acc + page_index(p))
        \\  let seed = Count { total = 10 }
        \\  let result = fold(all, seed, add, 2)
        \\  text!(str(numeric) ++ "/" ++ str(result.total) ++ "/" ++ str(seed.total))
        \\end
        \\page second
        \\end
    , "3/14/10");
}

test "compiler semantics: fold on an empty selection returns an independent seed" {
    try expectObjectContent(
        \\type Count { total: Number = 12 }
        \\fn unreachable_step(acc: Count, p: Page) -> Count = Count { total = 999 }
        \\page example
        \\  let all = pages(docctx())
        \\  let result = fold(all - all, Count {}, unreachable_step)
        \\  text!(str(result.total))
        \\end
    , "12");
}

test "compiler semantics: fold rejects accumulator input and output mismatches" {
    try expectBuildFails(
        \\page example
        \\  fold(pages(docctx()), 0, (acc: String, p: Page) |-> 1)
        \\end
    );
    try expectBuildFails(
        \\page example
        \\  fold(pages(docctx()), 0, (acc: Number, p: Page) |-> "wrong")
        \\end
    );
}

test "compiler semantics: fold does not retain a literal fact from its initial value" {
    try expectDiagnostic(
        \\page example
        \\  let query = fold(pages(docctx()), "self_placement", (acc: String, p: Page) |-> "invalid")
        \\  let item = text!("Item")
        \\  select(item, query)
        \\end
    , "bytes:", "select query must be a statically known string");
}

test "compiler semantics: excluded standard components are not available as implicit functions" {
    for ([_][]const u8{ "box", "figure", "callout", "head", "annotate", "cols2", "connect", "footers!", "watermark!", "logos!", "csv_map" }) |name| {
        const source = try std.fmt.allocPrint(testing.allocator, "page example\n  {s}()\nend\n", .{name});
        defer testing.allocator.free(source);
        try expectDiagnostic(source, "bytes:", "UnknownFunction");
    }
}

test "compiler semantics: public display type names agree with constructors and typed queries" {
    for ([_][]const u8{ "", "import std:themes/default as *\n" }) |imports| {
        const body =
            \\const words: Text = text("Unused")
            \\const program: Code = code("unused = 1", "python")
            \\const picture: Image = image("unused.svg")
            \\const sheet: Pdf = pdf("unused.pdf")
            \\const symbol: Icon = icon("unused")
            \\const formula: Math = math("unused")
            \\const latex_body: Latex = latex("unused")
            \\const shape: PathShape = rectangle()
            \\page example
            \\  let words = select<Text>(pagectx())
            \\  let programs = select<Code>(pagectx())
            \\  let pictures = select<Image>(pagectx())
            \\  let sheets = select<Pdf>(pagectx())
            \\  let symbols = select<Icon>(pagectx())
            \\  let formulas = select<Math>(pagectx())
            \\  let latex_bodies = select<Latex>(pagectx())
            \\  let shapes = select<PathShape>(pagectx())
            \\end
        ;
        const source = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ imports, body });
        defer testing.allocator.free(source);
        try buildSource(source);
    }
}

test "compiler semantics: mutable document theme APIs are unavailable" {
    try expectDiagnostic(
        \\page example
        \\  set_theme(default_theme())
        \\end
    , "bytes:", "UnknownFunction");
    try expectDiagnostic(
        \\page example
        \\  let theme = current_theme()
        \\end
    , "bytes:", "UnknownFunction");
}

test "compiler semantics: obsolete document generation helpers are unavailable" {
    for ([_][]const u8{ "pagenos!()", "numbered_item!(\"claim\", \"A\")", "numbering!(\"claim\")", "need_titles()", "citation!(1, \"A\")", "page_bg(none)", "doc_bg(none)" }) |call| {
        const source = try std.fmt.allocPrint(testing.allocator, "page example\n{s}\nend", .{call});
        defer testing.allocator.free(source);
        try expectDiagnostic(source, "bytes:", "UnknownFunction");
    }
}

test "compiler semantics: qualified constants preserve nominal values updates and shadowing" {
    try expectObjectContentWithTwoOverlays(
        \\import std:prelude as *
        \\import ./lib/a as styles
        \\page main
        \\  let defaults = "local"
        \\  let changed = styles::defaults with { size = 24 }
        \\  text!(defaults ++ ":" ++ str(styles::defaults.size) ++ ":" ++ str(changed.size))
        \\end
    ,
        \\import ./b as { defaults }
    ,
        \\type Style { size: Number = 18 }
        \\const defaults: Style = Style {}
    , "local:18:24");
    try buildSource(
        \\import std:text as text
        \\import std:layout as layout
        \\page main
        \\  layout::place!(text::text("Styled", text::default_text_style with { text.size = 24 }))
        \\end
    );
}

test "compiler semantics: qualified function values and constants retain defining modules" {
    try expectObjectContentWithTwoOverlays(
        \\import std:prelude as *
        \\import ./lib/a as first
        \\import ./lib/b as second
        \\fn format(value: String) -> String = "local"
        \\page main
        \\  let left = first::format
        \\  let right = second::formatter
        \\  text!(left("A") ++ ":" ++ right("B"))
        \\end
    ,
        \\const prefix: String = "first-"
        \\fn format(value: String) -> String = prefix ++ value
    ,
        \\const prefix: String = "second-"
        \\fn format(value: String) -> String = prefix ++ value
        \\const formatter: String -> String = format
    , "first-A:second-B");
}

test "compiler semantics: qualified constants preserve scheduled reads" {
    try expectObjectContentWithTwoOverlays(
        \\import std:prelude as *
        \\import ./lib/a as config
        \\page main
        \\  text!(config::caption)
        \\end
        \\document
        \\  docctx().footer_text = "Scheduled"
        \\end
    ,
        \\import ./b as values
        \\const caption: String = values::caption
    ,
        \\import std:prelude as *
        \\const caption: String = docctx().footer_text ?? "Missing"
    , "Scheduled");
}

test "compiler semantics: qualified values cannot bypass display purity" {
    try expectOverlayDiagnostic(
        \\import std:prelude as *
        \\import ./lib/bad as effects
        \\type Item { label: String }
        \\fn display(self: Placed<Item>) -> Text
        \\  let change = effects::change
        \\  change()
        \\  return text(self.value.label)
        \\end
        \\page main
        \\  place!(Item { label = "Item" })
        \\end
    ,
        \\import std:prelude as *
        \\fn change() -> Void
        \\  docctx().footer_text = "Changed"
        \\end
    , "lib/bad.ss:bytes:", "ImpureDisplayFunction");
}
