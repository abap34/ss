const std = @import("std");
const compiler_semantics = @import("compiler_semantics");

const testing = std.testing;

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

test "compiler semantics: imported function return inference diagnostics keep callee origin" {
    try expectOverlayDiagnostic(
        \\import "lib/bad"
        \\import std:themes/default as *
        \\
        \\page ok
        \\  text(bad())
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
        \\import std:themes/default
        \\
        \\page ok
        \\  h2!("bare")
        \\  default::h2!("qualified")
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

test "compiler semantics: stdlib editor variable info keeps theme object classes" {
    try expectVariableObjectClasses(
        \\import std:themes/default
        \\
        \\fn/! h2(content: String) -> Object
        \\  let t = default::h2(content)
        \\  t.text_size = 32
        \\  return t
        \\end
        \\
        \\page ok
        \\  let t = text! "body"
        \\  t.text_size = 20
        \\end
        \\
    , &.{
        .{ .name = "t", .scope_kind = "function", .scope_name = "h2", .object_class = "Sub" },
        .{ .name = "t", .scope_kind = "page", .scope_name = "ok", .object_class = "Body" },
    });
}

test "compiler semantics: core prelude is implicitly open" {
    try buildSource(
        \\page ok
        \\  place!(new("prelude", "body", "text"))
        \\end
        \\
    );
}

test "compiler semantics: default alias supports theme override with prelude placement" {
    try expectObjectContent(
        \\import std:themes/default
        \\
        \\fn/! h2(content: String) -> Object
        \\  let t = default::h2(content)
        \\  t.text_size = 32
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
        \\import std:themes/academic as *
        \\
        \\page ok
        \\  let title = head! <<
        \\large text
        \\next line
        \\>>
        \\  title.text_size = 64
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
        \\
        \\page table_of_contents
        \\  toc!("Contents")
        \\end
        \\
    );
    try buildSource(
        \\import std:themes/academic
        \\
        \\page table_of_contents
        \\  toc!("Contents")
        \\end
        \\
    );
    try buildSource(
        \\import std:themes/pop
        \\
        \\page table_of_contents
        \\  toc!("Contents")
        \\end
        \\
    );
}

test "compiler semantics: stdlib core components build when called directly" {
    try buildSourceWithAssetFixtures(
        \\import std:core/components
        \\
        \\page text_components
        \\  title!("Title")
        \\  subtitle!("Subtitle")
        \\  text!("Body")
        \\  math!("x + y")
        \\  mathtex!("x^2")
        \\  code_l!("const x = 1", "zig")
        \\  code!("print('x')", "python")
        \\  code_file!("snippet.zig", "zig")
        \\  note!("note")
        \\  pageno!()
        \\end
        \\
        \\page frame_components
        \\  frame_s!(text("frame_s"), 8, 6)
        \\  frame!("frame", "body", "text", 96, 96, 8, 6, none, none, 0, 0)
        \\  place!(surround_s(text("surround"), 8, 6))
        \\  place!(border_p(text("border_p"), 8, 6, none, c"0.2,0.2,0.2", 1, 4))
        \\  place!(border(text("border")))
        \\  place!(outline(text("outline")))
        \\end
        \\
        \\page asset_components
        \\  image!("image.svg")
        \\  pdf!("doc.pdf")
        \\end
        \\
        \\page citation_component
        \\  let target = text!("body [1]")
        \\  citation!(target, 1, "reference")
        \\end
        \\
    );
}

test "compiler semantics: stdlib theme components build when imported by theme alias" {
    try buildSourceWithAssetFixtures(
        \\import std:themes/default
        \\
        \\page default_text
        \\  h1!("Title")
        \\  h2!("Subtitle")
        \\  head!("Head")
        \\  subhead!("Subhead")
        \\  text!("Body")
        \\  tex!("x^2")
        \\  code!("print('x')", "python")
        \\  code_file!("snippet.zig", "zig")
        \\  toc!("Contents")
        \\end
        \\
        \\page default_cover
        \\  cover!("Title", "Subtitle", "Author")
        \\end
        \\
    );
    try buildSourceWithAssetFixtures(
        \\import std:themes/academic
        \\
        \\page academic_text
        \\  h1!("Title")
        \\  h2!("Subtitle")
        \\  h3!("Section")
        \\  head!("Head")
        \\  subhead!("Subhead")
        \\  text!("Body")
        \\  code!("print('x')", "python")
        \\  code_file!("snippet.zig", "zig")
        \\  toc!("Contents")
        \\end
        \\
        \\page academic_cover
        \\  cover!("Title", "Subtitle", "Author", "2026")
        \\end
        \\
    );
    try buildSourceWithAssetFixtures(
        \\import std:themes/pop
        \\
        \\page pop_text
        \\  h1!("Title")
        \\  h2!("Subtitle")
        \\  head!("Head")
        \\  subhead!("Subhead")
        \\  text!("Body")
        \\  tex!("x^2")
        \\  figure!("Figure")
        \\  image!("image.svg")
        \\  pdf!("doc.pdf")
        \\  code!("print('x')", "python")
        \\  code_file!("snippet.zig", "zig")
        \\  note!("note")
        \\  toc!("Contents")
        \\end
        \\
        \\page pop_cover
        \\  cover!("Title", "Subtitle", "Author")
        \\end
        \\
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
        \\import std:themes/default as *
        \\
        \\page ok
        \\  h2!("open")
        \\end
        \\
    );
}

test "compiler semantics: import alias does not introduce bare names" {
    try expectDiagnostic(
        \\import std:themes/default as base
        \\
        \\page bad
        \\  h2!("bare")
        \\end
        \\
    , "case.ss:bytes:", "UnknownFunction: unknown function: h2!");

    try buildSource(
        \\import std:themes/default as base
        \\
        \\page ok
        \\  base::h2!("qualified")
        \\end
        \\
    );
}

test "compiler semantics: import as star does not introduce an alias" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  default::h2!("qualified")
        \\end
        \\
    , "case.ss:bytes:", "UnknownModuleAlias: unknown import alias: default");
}

test "compiler semantics: qualified calls bypass local shadowing" {
    const source =
        \\import std:themes/default
        \\
        \\fn/! h2(content: String) -> Object
        \\  return text("local")
        \\end
        \\
        \\page ok
        \\  h2!("ignored")
        \\  default::h2!("qualified")
        \\end
        \\
    ;
    try expectObjectContent(source, "local");
    try expectObjectContent(source, "qualified");
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
        \\  obj.text_size = 41
        \\  return place_on!(pagectx(), obj)
        \\end
        \\
    );
}

test "compiler semantics: later bare-name import overrides earlier imports" {
    try expectObjectProperty(
        \\import std:themes/default as *
        \\import std:themes/academic as *
        \\
        \\page ok
        \\  h2!("later")
        \\end
        \\
    , "text_size", "28");
}

test "compiler semantics: later alias import overrides earlier aliases" {
    try expectObjectProperty(
        \\import std:themes/default as theme
        \\import std:themes/academic as theme
        \\
        \\page ok
        \\  theme::h2!("later")
        \\end
        \\
    , "text_size", "28");
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
        \\fn/! h2(content: String) -> Object
        \\  return text("a " ++ content)
        \\end
        \\
    ,
        \\import std:themes/default
        \\
        \\fn/! h2(content: String) -> Object
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
        \\  text(types::overlay_value() ++ overlay_value())
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
        \\  text(bad("a", "b"))
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
        \\  text(bad("a"))
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
        \\  text(f("a", "b"))
        \\end
        \\
    , "case.ss:bytes:", "DuplicateBinding: binding 'x' is already defined in this scope");
}

test "compiler semantics: lambda parameters cannot shadow visible bindings" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let x = "outer"
        \\  let f = (x: String) |-> x
        \\  text(f("inner"))
        \\end
        \\
    , "case.ss:bytes:", "DuplicateBinding: binding 'x' is already defined in this scope");
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

test "compiler semantics: dynamically built residual text survives lowering" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  text("hello" ++ " " ++ "world")
        \\end
        \\
    , "hello world");
}

test "compiler semantics: content mutation helpers are stdlib functions" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let target = text("hello [1]")
        \\  rewrite(target, "[1]", "world")
        \\  append(target, "!")
        \\end
        \\
    , "hello world!");
}

test "compiler semantics: math alignment helpers are stdlib functions" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  left_math(text("$$x^2$$"))
        \\  math_align(tex("x^2 + y^2 = z^2"), Align.right)
        \\end
        \\
    );
}

test "compiler semantics: TeX preamble helpers extend scoped render environment" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\
        \\document
        \\tex_preamble("doc preamble")
        \\tex_preamble_file("tex/preamble.tex")
        \\end
        \\
        \\page ok
        \\  page_tex_preamble("page preamble")
        \\  page_tex_preamble_file("tex/page.tex")
        \\  tex("x")
        \\end
        \\
    , &.{
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
        \\type Mode = alpha | Beta | READY
        \\type Any = String | Number
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
        \\type Mode = alpha | beta
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
        \\type Mode = alpha | beta
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

test "compiler semantics: enum names can be shadowed by values" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\type Mode = alpha | beta
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
        \\  Mode.custom_mode = current
        \\end
        \\
    );
}

test "compiler semantics: enum type names do not depend on capitalization" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\type mode = active | String
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
        \\type Mode = alpha | beta
        \\
    );
}

test "compiler semantics: enum properties serialize as case names" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\type Mode = alpha | beta
        \\type Card = object {
        \\  roles = ["card"]
        \\  custom_mode: Mode = Mode.alpha
        \\}
        \\
        \\page ok
        \\  let card = obj("card", "card", "text")
        \\  card.custom_mode = Mode.beta
        \\  if prop_eq(card, "custom_mode", "beta")
        \\    text("enum-ok")
        \\  end
        \\end
        \\
    , "enum-ok");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Mode = alpha | beta
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
        \\type Mode = alpha | beta
        \\type Other = beta
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
        \\type Color = accent
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "DuplicateType: type 'Color' conflicts with a built-in type");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Mode = alpha
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
        \\type Scalar = Number | String
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
        \\type Mode = alpha | beta | alpha
        \\
        \\page bad
        \\end
        \\
    , "case.ss:bytes:", "DuplicateEnumCase: enum 'Mode' already has case 'alpha'");

    try buildSource(
        \\import std:themes/default as *
        \\
        \\type Mode = Alpha | beta
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
        \\type Mode = Card | local
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
        \\type Mode = RemoteType | local
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
        \\  let body = text("ok")
        \\  body.text_color = keep_color(c"0.1,0.2,0.3")
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
        \\  let body = text("bad")
        \\  body.text_color = keep_color("0.1,0.2,0.3")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color, got String");

    try expectObjectProperty(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let body = text("color")
        \\  body.text_color = c"#334455"
        \\end
        \\
    , "text_color", "0.2,0.26666668,0.33333334");

    try expectObjectProperty(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let body = text("**bold**")
        \\  body.text_markdown_bold_color = c"#884422"
        \\end
        \\
    , "text_markdown_bold_color", "0.53333336,0.26666668,0.13333334");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = text("bad")
        \\  body.text_markdown_code_fill = "red"
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text_markdown_code_fill' expects Color?, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = text("bad")
        \\  body.text_markdown_bold_color = "red"
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text_markdown_bold_color' expects Color?, got String");
}

test "compiler semantics: structured style values expand to render properties" {
    const source =
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let body = text("style")
        \\  body.text = TextStyle {
        \\    size = 33
        \\    color = c"#123456"
        \\    font = FontFace { family = "Menlo", weight = 700 }
        \\  }
        \\end
        \\
    ;
    try expectObjectProperty(source, "text_size", "33");
    try expectObjectProperty(source, "text_color", "0.07058824,0.20392157,0.3372549");
    try expectObjectProperty(source, "text_font_family", "Menlo");
    try expectObjectProperty(source, "text_font_weight", "700");
}

test "compiler semantics: code theme helpers set code and markdown colors" {
    try buildSource(
        \\import std:themes/default as *
        \\
        \\document
        \\  code_theme_all(code_theme_one_dark())
        \\end
        \\
        \\page ok
        \\  code!("fn demo() -> Void\nend", "ss")
        \\  text!("```ss\nfn demo() -> Void\nend\n```")
        \\end
        \\
    );

    const explicit_source =
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let snippet = code("fn demo() -> Void\nend", "ss")
        \\  code_theme(snippet, code_theme_one_dark())
        \\  let body = text("```ss\nfn demo() -> Void\nend\n```")
        \\  code_theme(body, code_theme_one_dark())
        \\end
        \\
    ;
    try expectObjectProperty(explicit_source, "code_keyword_color", "0.7764706,0.47058824,0.8666667");
    try expectObjectProperty(explicit_source, "code_function_color", "0.38039216,0.6862745,0.9372549");
    try expectObjectProperty(explicit_source, "text_markdown_code_keyword_color", "0.7764706,0.47058824,0.8666667");
    try expectObjectProperty(explicit_source, "text_markdown_code_function_color", "0.38039216,0.6862745,0.9372549");
    try expectObjectProperty(explicit_source, "text_markdown_code_fill", "0.15686275,0.17254902,0.20392157");
}

test "compiler semantics: structured style value members are typed" {
    try expectObjectProperty(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let body = text("style")
        \\  let style = TextStyle { size = 31 }
        \\  body.text_size = style.size
        \\end
        \\
    , "text_size", "31");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = text("bad")
        \\  body.text = FontFace { family = "Menlo" }
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text' expects TextStyle, got FontFace");
}

test "compiler semantics: user record declarations define typed record values" {
    try expectObjectProperty(
        \\import std:themes/default as *
        \\
        \\record CaptionStyle {
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
        \\  let body = text("caption")
        \\  let style = large(CaptionStyle { size = 20 })
        \\  body.text = TextStyle {
        \\    size = style.size
        \\    color = style.color
        \\  }
        \\end
        \\
    , "text_size", "24");
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
        \\  let body = text("ok")
        \\  body.text_markdown_code_fill = none
        \\  body.text_color = fallback(body.text_markdown_code_fill)
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
        \\  text("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color, got Color?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = text("bad")
        \\  body.text_color = none
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text_color' expects Color, got None");

    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn name(value: None) -> String
        \\  return "none"
        \\end
        \\
        \\page ok
        \\  text(name(none))
        \\end
        \\
    , "none");

    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let body = text("body")
        \\  body.text_markdown_code_fill = c"1,0,0"
        \\  body.text_markdown_code_fill = none
        \\  if body.text_markdown_code_fill?
        \\    text("still-set")
        \\  else
        \\    text("unset")
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
        \\    text("bad")
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
        \\  text("bad")
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
        \\  let body = text("bad")
        \\  body.text_color = take_color(body.text_markdown_code_fill)
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
        \\  let body = text("bad")
        \\  body.text_markdown_code_fill = take_maybe("red")
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
        \\  text("bad")
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
        \\  text("bad")
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
        \\  text("bad")
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
        \\  text("bad")
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
        \\    return target.text_markdown_code_fill
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
        \\  let body = text("report")
        \\  body.text_markdown_code_fill = none
        \\  let x = may_be_none(body, true)
        \\  let y = must_call_by_notnone(x)
        \\  body.text_color = y
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
        \\  text("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color, got Color?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn apply_palette(target: Body, primary: Color?, secondary: Color?) -> Void
        \\  let chosen = primary
        \\  if target.link_id?
        \\    target.text_color = chosen
        \\  else
        \\    target.text_markdown_code_fill = secondary
        \\  end
        \\end
        \\
        \\page bad
        \\  let body = text("body")
        \\  apply_palette(body, none, c"0.3,0.3,0.3")
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text_color' expects Color, got Color?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Status = draft | reviewing | ready
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
        \\    text("missing")
        \\  end
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Status, got Status?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Status = draft | reviewing | ready
        \\type OtherStatus = draft | reviewing | ready
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
        \\  text("bad")
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
        \\  text("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn maybe_accent(target: Body, use_saved: Bool, force_number: Bool) -> Color?
        \\  if use_saved
        \\    return target.text_markdown_code_fill
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
        \\  text("bad")
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
        \\    let chosen = target.text_color
        \\    return chosen
        \\  end
        \\end
        \\
        \\page bad
        \\  text("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Color, got Color?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn paint_target(target: Body, maybe_color: Color?, use_optional: Bool) -> Void
        \\  if use_optional
        \\    target.text_color = maybe_color
        \\  else
        \\    target.text_color = c"0.1,0.1,0.1"
        \\  end
        \\end
        \\
        \\page bad
        \\  let body = text("body")
        \\  paint_target(body, none, true)
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text_color' expects Color, got Color?");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Status = draft | ready
        \\type OtherStatus = draft | ready
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
        \\  text("bad")
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
        \\  text("bad")
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
        \\  text("bad")
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
        \\  text("bad")
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
        \\  text("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Number, got Bool");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn configure_text(target: Body, compact: Bool) -> Void
        \\  if compact
        \\    target.text_size = "small"
        \\  else
        \\    target.text_size = 24
        \\  end
        \\end
        \\
        \\page bad
        \\  let body = text("body")
        \\  configure_text(body, true)
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text_size' expects Number, got String");

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
        \\  text("bad")
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
        \\  text("bad")
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
        \\  text("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Void, got Number");
}

test "compiler semantics: enum optional values reject strings and other enums" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Mode = alpha | beta
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
        \\type Mode = alpha | beta
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
        \\type Mode = alpha | beta
        \\type Other = alpha | beta
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
        \\type Mode = alpha | beta
        \\type Other = alpha | beta
        \\
        \\fn bad_return() -> Mode
        \\  return Other.alpha
        \\end
        \\
        \\page bad
        \\  text("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Mode, got Other");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\type Mode = alpha | beta
        \\type Other = alpha | beta
        \\
        \\fn bad_coalesce(value: Mode?) -> Mode
        \\  return value ?? Other.alpha
        \\end
        \\
        \\page bad
        \\  text("bad")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Mode, got Other");
}

test "compiler semantics: properties require known fields" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = text("bad")
        \\  let key = "text_color"
        \\  set_prop(body, key, c"1,0,0")
        \\end
        \\
    , "case.ss:bytes:", "InvalidProperty: property key must be a known field literal");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = text("bad")
        \\  body.no_such_field = "x"
        \\end
        \\
    , "case.ss:bytes:", "UnknownField: unknown field: no_such_field");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = text("bad")
        \\  let key = "text_color"
        \\  text(prop(body, key, "missing"))
        \\end
        \\
    , "case.ss:bytes:", "InvalidProperty: property key must be a known field literal");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = text("bad")
        \\  has_prop(body, "no_such_field")
        \\end
        \\
    , "case.ss:bytes:", "UnknownField: unknown field: no_such_field");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = text("bad")
        \\  body.text_color = 1
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text_color' expects Color, got Number");
}

test "compiler semantics: typed properties reject optional and wrong static values" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = text("bad")
        \\  set_prop(body, "text_color", body.text_markdown_code_fill)
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text_color' expects Color, got Color?");

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
        \\  text("body")
        \\  objs_here("body").text_color = none
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text_color' expects Color, got None");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = text("bad")
        \\  body.text_markdown_code_fill = 1
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text_markdown_code_fill' expects Color?, got Number");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = text("bad")
        \\  set_prop(body, "text_markdown_code_fill", "red")
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'text_markdown_code_fill' expects Color?, got String");
}

test "compiler semantics: object field defaults are statically typed" {
    const defaults_source =
        \\import std:themes/default as *
        \\
        \\type Mode = alpha | beta
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

    try expectBodyTextDefaults(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  text("body")
        \\end
        \\
    , .{
        .link_underline_width = 0.8,
        .link_underline_offset = -1.5,
        .inline_math_height_factor = 1.02,
        .inline_math_spacing = 0.08,
        .markdown_table_line_width = 0.8,
        .cjk_bold_dx = 0.05,
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
        \\type Mode = alpha | beta
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
        \\type Mode = alpha | beta
        \\type Other = alpha | beta
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
        \\  text(prop(docctx(), "math_align", "missing"))
        \\  text("body")
        \\  objs_here("body").wrap = WrapMode.off
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
        \\  text("body")
        \\  objs_here("body").wrap = "off"
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'wrap' expects WrapMode, got String");
}

test "compiler semantics: document math alignment helpers update the document setting" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\document
        \\  left_math_all()
        \\end
        \\
        \\page ok
        \\  text(prop(docctx(), "math_align", "missing"))
        \\end
        \\
    , "left");
}

test "compiler semantics: math alignment rejects unknown literals" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let body = text("$$x^2$$")
        \\  body.math_align = "sideways"
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'math_align' expects Align, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  math_align(text("$$x^2$$"), Align.sideways)
        \\end
        \\
    , "case.ss:bytes:", "UnknownEnumCase: enum 'Align' has no case 'sideways'");
}

test "compiler semantics: member sugar reads and writes properties and content" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let target = text("hello")
        \\  target.content = target.content ++ "!"
        \\end
        \\
    , "hello!");

    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let target = text("styled")
        \\  target.link_id = "custom"
        \\  if target.link_id?
        \\    text(target.link_id ?? "missing")
        \\  end
        \\end
        \\
    , "custom");

    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\document
        \\  docctx().footer_text = "footer"
        \\  footers!(docctx().footer_text ?? "")
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
        \\record Parts {
        \\  root: Object
        \\  middle: Object
        \\}
        \\
        \\fn make_parts() -> Parts
        \\  let middle = text("middle")
        \\  return Parts {
        \\    root = group(middle)
        \\    middle = middle
        \\  }
        \\end
        \\
        \\page ok
        \\  let parts = make_parts()
        \\  place!(parts.root)
        \\  parts.middle.content = "changed"
        \\  parts.middle.text_color = c"#ff0000"
        \\end
        \\
    ;

    try expectObjectContent(source, "changed");
    try expectObjectProperty(source, "text_color", "1,0,0");
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
        \\  let target = text("typed")
        \\  target.wrap = WrapMode.off
        \\  target.text_size = 24
        \\  target.link_id = "custom"
        \\  target.text_markdown_code_fill = c"0.1,0.2,0.3"
        \\  let panel_obj = panel()
        \\  let other = text("color")
        \\  other.text_color = target.text_markdown_code_fill ?? c"0,0,0"
        \\  text(wrap_label(target.wrap ?? WrapMode.on) ++ ":" ++ str(target.text_size ?? 0) ++ ":" ++ link_label(target.link_id ?? "fallback"))
        \\  text(render_label(panel_obj.render_kind ?? RenderKind.text))
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
        \\  let panel_obj = panel()
        \\  text(render_label(panel_obj.render_kind ?? RenderKind.text))
        \\end
        \\
    , "render");
}

test "compiler semantics: logical not inverts optional presence checks" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn optional_color_label(target: Body) -> String
        \\  if !target.text_markdown_code_fill?
        \\    return "none"
        \\  else
        \\    return "some"
        \\  end
        \\end
        \\
        \\page ok
        \\  let unset = body_obj("unset")
        \\  let set = body_obj("set")
        \\  set.text_markdown_code_fill = c"0.1,0.2,0.3"
        \\  text(optional_color_label(unset) ++ ":" ++ optional_color_label(set))
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
        \\  text(none_label(none) ++ ":" ++ none_label(false) ++ ":" ++ none_label(true))
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
        \\  text(none_label(none) ++ ":" ++ none_label("") ++ ":" ++ none_label("value"))
        \\end
        \\
    , "none:some:some");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  if !1
        \\    text("bad")
        \\  end
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Bool, got Number");
}

test "compiler semantics: generated page numbers keep optional format semantics" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\document
        \\  pagenos!(none)
        \\end
        \\
        \\page one
        \\end
        \\
        \\page two
        \\end
        \\
    , "1/2");

    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\document
        \\  pagenos!("{page} of {total}")
        \\end
        \\
        \\page one
        \\end
        \\
        \\page two
        \\end
        \\
    , "1 of 2");
}

test "compiler semantics: removed render kind chrome case is rejected" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let panel_obj = panel()
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
        \\  text("hello")
        \\end
        \\
    );
}

test "compiler semantics: generated page numbers run after page graph exists" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\document
        \\  pagenos!()
        \\end
        \\
        \\page one
        \\end
        \\
        \\page two
        \\end
        \\
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
        \\  text(label)
        \\end
        \\
    , "from page scope");
}

test "compiler semantics: document blocks preserve top-level order" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\document
        \\  docctx().footer_text = "before"
        \\end
        \\
        \\page first
        \\  text(docctx().footer_text ?? "unset")
        \\end
        \\
    , "before");

    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page first
        \\  text(docctx().footer_text ?? "unset")
        \\end
        \\
        \\document
        \\  docctx().footer_text = "after"
        \\end
        \\
    , "unset");
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
        \\  text(str(apply(inc, 2)))
        \\end
        \\
    , "3");
}

test "compiler semantics: direct lambda application works" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  text(str(((x: Number) |-> x + 4)(1)))
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
        \\  text(str(plus_one(2)))
        \\end
        \\
    , "3");
}

test "compiler semantics: constants are evaluated once as value bindings" {
    const source =
        \\import std:themes/default as *
        \\
        \\record Parts {
        \\  root: Object
        \\  middle: Object
        \\}
        \\
        \\fn make_parts() -> Parts
        \\  let middle = text("middle")
        \\  return Parts {
        \\    root = group(middle)
        \\    middle = middle
        \\  }
        \\end
        \\
        \\const parts: Parts = make_parts()
        \\
        \\page ok
        \\  parts.middle.content = "changed"
        \\  parts.middle.text_color = c"#ff0000"
        \\  place!(parts.root)
        \\end
        \\
    ;

    try expectObjectContent(source, "changed");
    try expectObjectProperty(source, "text_color", "1,0,0");
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
        \\  text(str(add_two()(1)))
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
        \\  text(str(choose(true)(2)) ++ "," ++ str(choose(false)(2)))
        \\end
        \\
    , "3,1");
}

test "compiler semantics: join accepts an inline typed lambda" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page one
        \\  text(join(pages(docctx()), ",", (page_value: Page) |-> str(page_index(page_value))))
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
        \\  text(fold(pages(docctx()), "", (acc: String, page_value: Page) |-> acc ++ str(page_index(page_value))))
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
        \\  return set_content(item, str(index) ++ ":" ++ content(item))
        \\end
        \\
        \\page one
        \\  text!("A")
        \\end
        \\
        \\page two
        \\  text!("B")
        \\end
        \\
        \\document
        \\  foreach_enumerate(doc_objs(docctx(), "body"), number_body)
        \\end
        \\
    , "2:B");
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
        \\  text("A")
        \\  foreach_enumerate(doc_objs(docctx(), "body"), wrong)
        \\end
        \\
    );
}

test "compiler semantics: stdlib numbering formats numbered items" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page one
        \\  numbered_item!("claim", "A")
        \\end
        \\
        \\page two
        \\  numbered_item!("claim", "B")
        \\end
        \\
        \\document
        \\  numbering!("claim", "Claim {number}: {text}")
        \\end
        \\
    , "Claim 2: B");
}

test "compiler semantics: stdlib numbering keeps source text across repeated formatting" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\page one
        \\  numbered_item!("claim", "A")
        \\end
        \\
        \\document
        \\  numbering!("claim", "First {number}: {text}")
        \\  numbering!("claim", "Second {number}: {text}")
        \\end
        \\
    , "Second 1: A");
}

test "compiler semantics: stdlib numbering keeps counters separate" {
    const source =
        \\import std:themes/default as *
        \\
        \\page one
        \\  numbered_item!("claim", "A")
        \\  numbered_item!("definition", "B")
        \\end
        \\
        \\document
        \\  numbering!("claim", "Claim {number}: {text}")
        \\  numbering!("definition", "Definition {number}: {text}")
        \\end
        \\
    ;
    try expectObjectContent(source, "Claim 1: A");
    try expectObjectContent(source, "Definition 1: B");
}

test "compiler semantics: lambda bodies cannot be void" {
    try expectBuildFails(
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
    );
}

test "compiler semantics: function value application checks argument types" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let f = (x: Number) |-> x + 1
        \\  text(str(f("oops")))
        \\end
        \\
    );

    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let value = 1
        \\  text(str(value(2)))
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
        \\  text(str(bad()(1)))
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
        \\  text(str(bad(1)))
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
        \\  text(str(bad(1)))
        \\end
        \\
    );
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
        \\  text(str(first(1)))
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
        \\  text(str(make_bad()(1)))
        \\end
        \\
    );
}

test "compiler semantics: foreach cannot mutate the iterated object selection" {
    try expectBuildFails(
        \\import std:themes/default as *
        \\
        \\fn duplicate_title(title_obj: Object) -> Object
        \\  let page_value = page_of(title_obj)
        \\  place_on!(page_value, new("copy", "title", "text"))
        \\  return title_obj
        \\end
        \\
        \\page bad
        \\  title("A")
        \\  foreach(objs(pagectx(), "title"), duplicate_title)
        \\end
        \\
    );
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
        \\  text(fold(pages(docctx()), "", add_page))
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
        \\  text(join(pages(docctx()), "", add_page))
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
        \\  text(str(h))
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
        \\  text(title)
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
        \\  title!("bad")
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
        \\  foreach(pages(docctx()), (page_value: Page) |-> title!("bad"))
        \\end
        \\
        \\page ok
        \\end
        \\
    , "case.ss:bytes:", "NoCurrentPage");
}

test "compiler semantics: document callbacks may use explicit pages without current page" {
    try expectObjectContent(
        \\import std:themes/default as *
        \\
        \\fn decorate!(page_value: Page) -> Object
        \\  let item = place_on!(page_value, new("explicit", "body", "text"))
        \\  pin_l(item, 72)
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
        \\fn make_implicit!() -> Object
        \\  return title!("bad")
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

test "compiler semantics: generated objects must be placed or discarded" {
    try expectLoweredDiagnostic(
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
        \\  place!(new("placed", "body", "text"))
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

test "compiler semantics: unplaced group warns once for the root object" {
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

    try expectLoweredDiagnosticCount(source, "UnplacedObject", 1);
    try expectObjectState(source, .{ .role = "group", .attached = false, .discarded = false });
    try expectObjectState(source, .{ .content = "one", .attached = false, .discarded = false });
    try expectObjectState(source, .{ .content = "two", .attached = false, .discarded = false });
}

test "compiler semantics: constraint-referenced groups are layout values" {
    try expectNoLoweredDiagnostic(
        \\import std:themes/default as *
        \\
        \\page ok
        \\  let left = text! "left"
        \\  let detail = text! "detail"
        \\  let right = text! "right"
        \\  cols2(group(left, detail), right)
        \\end
        \\
    , "UnplacedObject");
}

test "compiler semantics: placing or discarding a group covers its children" {
    const placed_source =
        \\import std:themes/default as *
        \\
        \\page placed
        \\  place!(group(
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
        \\  place!(head("Connected helper"))
        \\end
        \\
    , "UnplacedObject");

    try expectLoweredDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn make_card() -> Object
        \\  let visible = new("visible", "body", "text")
        \\  let extra = new("extra", "note", "text")
        \\  return visible
        \\end
        \\
        \\page loose
        \\  place!(make_card())
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

test "compiler semantics: returned object placement follows constraints and group edges" {
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
        \\  place!(connected_pair())
        \\end
        \\
    ;
    try expectNoLoweredDiagnostic(constrained_source, "UnplacedObject");
    try expectObjectState(constrained_source, .{ .content = "main", .attached = true, .discarded = false });
    try expectObjectState(constrained_source, .{ .content = "helper", .attached = true, .discarded = false });

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
        \\  place!(grouped_pair())
        \\end
        \\
    ;
    try expectNoLoweredDiagnostic(grouped_source, "UnplacedObject");
    try expectObjectState(grouped_source, .{ .role = "group", .attached = true, .discarded = false });
    try expectObjectState(grouped_source, .{ .content = "left", .attached = true, .discarded = false });
    try expectObjectState(grouped_source, .{ .content = "right", .attached = true, .discarded = false });
}

test "compiler semantics: connected return objects still warn when the result is not placed" {
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

    try expectLoweredDiagnosticCount(source, "UnplacedObject", 1);
    try expectObjectState(source, .{ .content = "main", .attached = false, .discarded = false });
    try expectObjectState(source, .{ .content = "helper", .attached = false, .discarded = false });
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
        \\  place!(disconnected_pair())
        \\end
        \\
    ;

    try expectLoweredDiagnosticCount(source, "UnplacedObject", 1);
    try expectLoweredDiagnostic(source, "object 'note'");
    try expectObjectState(source, .{ .content = "main", .attached = true, .discarded = false });
    try expectObjectState(source, .{ .content = "helper", .attached = false, .discarded = false });
}

test "compiler semantics: underscore discard applies after return object connection" {
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
        \\page discarded
        \\  let _ = connected_pair()
        \\end
        \\
    ;

    try expectNoLoweredDiagnostic(source, "UnplacedObject");
    try expectObjectState(source, .{ .content = "main", .attached = false, .discarded = true });
    try expectObjectState(source, .{ .content = "helper", .attached = false, .discarded = true });
}

test "compiler semantics: dump includes unplaced object diagnostics" {
    try expectDumpContains(
        \\import std:themes/default as *
        \\
        \\page loose
        \\  new("loose", "body", "text")
        \\end
        \\
    , &.{ "diagnostics", "UnplacedObject", "object 'body' was generated but not placed" });
}

test "compiler semantics: underscore let binding is not a variable" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\page bad
        \\  let _ = new("discarded", "body", "text")
        \\  text(_)
        \\end
        \\
    , "case.ss:bytes:", "UnknownIdentifier: unknown identifier: _");
}

test "compiler semantics: placing calls require bang-marked functions" {
    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn bad() -> Object
        \\  return place!(new("bad", "body", "text"))
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

    try expectDiagnostic(
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
    , "case.ss:bytes:", "PlacementEffect: function 'bad' calls a placing operation and must end with '!'");
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
    , "case.ss:bytes:", "TypeMismatch: expected Object, got String");

    try expectDiagnostic(
        \\import std:themes/default as *
        \\
        \\fn/! bad() -> Object
        \\  return place!(new("bad", "body", "text"))
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
        \\  let item = place!(new("body", "body", "text"))
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
        \\  place!(a)
        \\  let b = a
        \\  place!(b)
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
        \\  let a = text("a")
        \\  place!(a)
        \\  let b = a
        \\  place!(b)
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
        \\  place!(a)
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
        \\  place!(a)
        \\  ~ a.left == a.right + 10
        \\end
        \\
    );
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
        \\  place!(obj("A", "card", "text"))
        \\  let card_obj = first_card(objs_here("card"))
        \\  text(content(card_obj))
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
        \\  place!(obj("A", "card", "text"))
        \\  foreach(select(pagectx(), "page_objects_by_role", "card"), accept_body)
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Object<Card>, got Object<Body>");
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
        \\  text("body")
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
