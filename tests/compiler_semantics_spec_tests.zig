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

fn expectBuildFails(source: []const u8) !void {
    buildSource(source) catch {
        return;
    };
    return error.ExpectedBuildFailure;
}

test "compiler semantics: default argument effects are checked against function contracts" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\fn creates_by_default(x: object = object("x", "body", "text")) -> object ! Pure
        \\  return x
        \\end
        \\
        \\page bad
        \\  let x = creates_by_default()
        \\end
        \\
    );
}

test "compiler semantics: callback effects are included in higher-order calls" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\fn touch(o: object) -> string ! WriteProperty
        \\  set_prop(o, "text_color", "1,0,0")
        \\  return ""
        \\end
        \\
        \\fn bad(items: selection) -> string ! Pure
        \\  return join(items, "", touch)
        \\end
        \\
        \\page bad
        \\end
        \\
    );
}

test "compiler semantics: branch-local let bindings do not escape their branch" {
    try buildSource(
        \\import std:themes/default
        \\
        \\page ok
        \\  let x = "a"
        \\  if true
        \\    let x = 1
        \\  end
        \\  let y = concat(x, "b")
        \\end
        \\
    );
}

test "compiler semantics: selection values can be reused after lookup" {
    try buildSource(
        \\import std:themes/default
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

test "compiler semantics: return type inference sees branch-local bindings" {
    try buildSource(
        \\import std:themes/default
        \\
        \\fn branch_label(flag: boolean) -> string
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
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\document
        \\  let p = pagectx()
        \\end
        \\
        \\page ok
        \\end
        \\
    );
}

test "compiler semantics: page anchors cannot be constraint targets" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\page bad
        \\  constrain left(page) == left(page)
        \\end
        \\
    );
}

test "compiler semantics: missing constraint anchors are rejected statically" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\page bad
        \\  constrain left(missing) == left(page)
        \\end
        \\
    );
}

test "compiler semantics: duplicate user functions are rejected" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\fn label() -> string
        \\  return "first"
        \\end
        \\
        \\fn label() -> string
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
        \\import std:themes/default
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
