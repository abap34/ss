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

fn expectObjectContent(source: []const u8, expected: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/case.ss", .{tmp.sub_path[0..]});
    try compiler_semantics.expectObjectContent(testing.io, allocator, path, source, expected);
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

test "compiler semantics: dynamically built residual text survives lowering" {
    try expectObjectContent(
        \\import std:themes/default
        \\
        \\page ok
        \\  text("hello" ++ " " ++ "world")
        \\end
        \\
    , "hello world");
}

test "compiler semantics: content mutation helpers are stdlib functions" {
    try expectObjectContent(
        \\import std:themes/default
        \\
        \\page ok
        \\  let target = text("hello [1]")
        \\  rewrite_text(target, "[1]", "world")
        \\  append_content(target, "!")
        \\end
        \\
    , "hello world!");

    try expectBuildFails(
        \\import std:themes/default
        \\
        \\fn bad(target: object) -> object ! Pure
        \\  clear_content(target)
        \\  return target
        \\end
        \\
        \\page bad
        \\  let target = text("bad")
        \\  bad(target)
        \\end
        \\
    );
}

test "compiler semantics: style mutation is stdlib over properties" {
    try expectObjectContent(
        \\import std:themes/default
        \\
        \\page ok
        \\  let target = set_style(text("styled"), style("custom"))
        \\  text(prop(target, "style", "missing"))
        \\end
        \\
    , "custom");

    try buildSource(
        \\import std:themes/default
        \\
        \\page ok
        \\  text("a")
        \\  text("b")
        \\  with_style_all(objects(pagectx(), "body"), style("custom"))
        \\end
        \\
    );

    try expectBuildFails(
        \\import std:themes/default
        \\
        \\fn bad(target: object) -> object ! Pure
        \\  set_style(target, style("custom"))
        \\  return target
        \\end
        \\
        \\page bad
        \\  let target = text("bad")
        \\  bad(target)
        \\end
        \\
    );
}

test "compiler semantics: pass annotation is rejected" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\@pass
        \\fn old_pass(doc: document) -> document
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
        \\import std:themes/default
        \\
        \\document
        \\  page_no_all()
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

test "compiler semantics: void functions may finish without explicit return" {
    try expectObjectContent(
        \\import std:themes/default
        \\
        \\fn add_page_text(page: page) -> void
        \\  new_object(page, str(page_index(page)), "body", "text")
        \\end
        \\
        \\document
        \\  foreach(pages(docctx()), add_page_text)
        \\end
        \\
        \\page one
        \\end
        \\
        \\page two
        \\end
        \\
    , "1");
}

test "compiler semantics: bare return is only valid for void functions" {
    try buildSource(
        \\import std:themes/default
        \\
        \\fn stop() -> void
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
        \\import std:themes/default
        \\
        \\fn bad() -> string
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
        \\import std:themes/default
        \\
        \\fn side_effect() -> void
        \\end
        \\
        \\page bad
        \\  let value = side_effect()
        \\end
        \\
    );
}

test "compiler semantics: lambda callbacks can create objects over a document selection" {
    try expectObjectContent(
        \\import std:themes/default
        \\
        \\document
        \\  let add_each = (page_value: page) |-> new_object(page_value, "lambda", "body", "text")
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
        \\import std:themes/default
        \\
        \\fn make_label(text_value: string) -> page -> object
        \\  return (page_value: page) |-> new_object(page_value, text_value, "body", "text")
        \\end
        \\
        \\document
        \\  foreach(pages(docctx()), make_label("made"))
        \\end
        \\
        \\page one
        \\end
        \\
    , "made");
}

test "compiler semantics: function values use ordinary application" {
    try expectObjectContent(
        \\import std:themes/default
        \\
        \\fn apply(f: number -> number, x: number) -> number
        \\  return f(x)
        \\end
        \\
        \\fn inc(x: number) -> number
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
        \\import std:themes/default
        \\
        \\page ok
        \\  text(str(((x: number) |-> x + 4)(1)))
        \\end
        \\
    , "5");
}

test "compiler semantics: constants can hold function values" {
    try expectObjectContent(
        \\import std:themes/default
        \\
        \\const plus_one: number -> number = (x: number) |-> x + 1
        \\
        \\page ok
        \\  text(str(plus_one(2)))
        \\end
        \\
    , "3");
}

test "compiler semantics: returned lambdas are directly applicable" {
    try expectObjectContent(
        \\import std:themes/default
        \\
        \\fn add_two() -> number -> number
        \\  return (x: number) |-> x + 2
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
        \\import std:themes/default
        \\
        \\fn inc(x: number) -> number
        \\  return x + 1
        \\end
        \\
        \\fn dec(x: number) -> number
        \\  return x - 1
        \\end
        \\
        \\fn choose(flag: boolean) -> number -> number
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
        \\import std:themes/default
        \\
        \\page one
        \\  text(join(pages(docctx()), ",", (page_value: page) |-> str(page_index(page_value))))
        \\end
        \\
        \\page two
        \\end
        \\
    , "1,2");
}

test "compiler semantics: fold accepts an inline typed lambda" {
    try expectObjectContent(
        \\import std:themes/default
        \\
        \\page one
        \\  text(fold(pages(docctx()), "", (acc: string, page_value: page) |-> acc ++ str(page_index(page_value))))
        \\end
        \\
        \\page two
        \\end
        \\
    , "12");
}

test "compiler semantics: lambda bodies cannot be void" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\fn side_effect(page_value: page) -> void
        \\  new_object(page_value, "side", "body", "text")
        \\end
        \\
        \\document
        \\  foreach(pages(docctx()), (page_value: page) |-> side_effect(page_value))
        \\end
        \\
        \\page bad
        \\end
        \\
    );
}

test "compiler semantics: function value application checks argument types" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\page bad
        \\  let f = (x: number) |-> x + 1
        \\  text(str(f("oops")))
        \\end
        \\
    );

    try expectBuildFails(
        \\import std:themes/default
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
        \\import std:themes/default
        \\
        \\fn bad() -> number -> number
        \\  return (text_value: string) |-> text_value
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
        \\import std:themes/default
        \\
        \\fn id(x: number) -> number
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

test "compiler semantics: function values cannot be stored as metadata content" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\fn id(x: number) -> number
        \\  return x
        \\end
        \\
        \\document
        \\  emit_metadata(docctx(), "kind", id)
        \\end
        \\
        \\page bad
        \\end
        \\
    );
}

test "compiler semantics: function-value recursion is rejected" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\fn bad(x: number) -> number
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
        \\import std:themes/default
        \\
        \\fn apply(f: number -> number, x: number) -> number
        \\  return f(x)
        \\end
        \\
        \\fn bad(x: number) -> number
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
        \\import std:themes/default
        \\
        \\fn first(x: number) -> number
        \\  return second(x)
        \\end
        \\
        \\fn second(x: number) -> number
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
        \\import std:themes/default
        \\
        \\fn make_bad() -> number -> number
        \\  return (x: number) |-> make_bad()(x)
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
        \\import std:themes/default
        \\
        \\fn duplicate_title(title_obj: object) -> object
        \\  let page_value = parent_page(title_obj)
        \\  new_object(page_value, "copy", "title", "text")
        \\  return title_obj
        \\end
        \\
        \\page bad
        \\  title("A")
        \\  foreach(objects(pagectx(), "title"), duplicate_title)
        \\end
        \\
    );
}

test "compiler semantics: foreach cannot create pages while iterating pages" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\document
        \\  foreach(pages(docctx()), (page_value: page) |-> new_page(docctx(), "extra"))
        \\end
        \\
        \\page bad
        \\end
        \\
    );
}

test "compiler semantics: fold cannot mutate the iterated page selection" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\fn add_page(acc: string, page_value: page) -> string
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
        \\import std:themes/default
        \\
        \\fn add_page(page_value: page) -> string
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
        \\import std:themes/default
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
