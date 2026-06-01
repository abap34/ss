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

test "compiler semantics: imported function return inference diagnostics keep callee origin" {
    try expectOverlayDiagnostic(
        \\import "lib/bad.ss"
        \\import std:themes/default
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

test "compiler semantics: default argument effects are checked against function contracts" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\fn creates_by_default(x: Object = obj("x", "body", "text")) -> Object ! Pure
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
        \\fn touch(o: Object) -> String ! WriteProperty
        \\  set_prop(o, "text_color", "1,0,0")
        \\  return ""
        \\end
        \\
        \\fn bad(items: Selection) -> String ! Pure
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
        \\  rewrite(target, "[1]", "world")
        \\  append(target, "!")
        \\end
        \\
    , "hello world!");

    try expectBuildFails(
        \\import std:themes/default
        \\
        \\fn bad(target: Object) -> Object ! Pure
        \\  clear(target)
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
        \\  let target = sty(text("styled"), style("custom"))
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
        \\  style_all(objs(pagectx(), "body"), style("custom"))
        \\end
        \\
    );

    try expectBuildFails(
        \\import std:themes/default
        \\
        \\fn bad(target: Object) -> Object ! Pure
        \\  sty(target, style("custom"))
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

test "compiler semantics: math alignment helpers are stdlib functions" {
    try buildSource(
        \\import std:themes/default
        \\
        \\page ok
        \\  left_math(text("$$x^2$$"))
        \\  math_align(tex("x^2 + y^2 = z^2"), "right")
        \\end
        \\
    );
}

test "compiler semantics: string literal value domains can type function parameters" {
    try expectObjectContent(
        \\import std:themes/default
        \\
        \\type Mode = "alpha" | "beta"
        \\
        \\fn label_mode(mode: Mode) -> String
        \\  return mode
        \\end
        \\
        \\page ok
        \\  text(label_mode("alpha"))
        \\end
        \\
    , "alpha");

    try expectDiagnostic(
        \\import std:themes/default
        \\
        \\type Mode = "alpha" | "beta"
        \\
        \\fn label_mode(mode: Mode) -> String
        \\  return mode
        \\end
        \\
        \\page bad
        \\  text(label_mode("gamma"))
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected \"alpha\" | \"beta\", got String");
}

test "compiler semantics: document math alignment helpers update the document setting" {
    try expectObjectContent(
        \\import std:themes/default
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
        \\import std:themes/default
        \\
        \\page bad
        \\  let body = text("$$x^2$$")
        \\  body.math_align = "sideways"
        \\end
        \\
    , "case.ss:bytes:", "InvalidFieldValue: field 'math_align' expects \"left\" | \"center\" | \"right\", got string");

    try expectDiagnostic(
        \\import std:themes/default
        \\
        \\page bad
        \\  math_align(text("$$x^2$$"), "sideways")
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected \"left\" | \"center\" | \"right\", got String");
}

test "compiler semantics: member sugar reads and writes properties and content" {
    try expectObjectContent(
        \\import std:themes/default
        \\
        \\page ok
        \\  let target = text("hello")
        \\  target.content = target.content ++ "!"
        \\end
        \\
    , "hello!");

    try expectObjectContent(
        \\import std:themes/default
        \\
        \\page ok
        \\  let target = text("styled")
        \\  target.style = style("custom")
        \\  if target.style?
        \\    text(target.style ?? "missing")
        \\  end
        \\end
        \\
    , "custom");

    try expectObjectContent(
        \\import std:themes/default
        \\
        \\document
        \\  docctx().footer_text = "footer"
        \\  footers(docctx().footer_text ?? "")
        \\end
        \\
        \\page ok
        \\end
        \\
    , "footer");
}

test "compiler semantics: pass annotation is rejected" {
    try expectBuildFails(
        \\import std:themes/default
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
        \\import std:themes/default
        \\
        \\document
        \\  pagenos()
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
        \\import std:themes/default
        \\
        \\document
        \\  let label = "from document scope"
        \\  foreach(
        \\    pages(docctx()),
        \\    (page_value: Page) |-> new(page_value, label, "body", "text")
        \\  )
        \\end
        \\
        \\page one
        \\end
        \\
    , "from document scope");
}

test "compiler semantics: void functions may finish without explicit return" {
    try expectObjectContent(
        \\import std:themes/default
        \\
        \\fn add_page_text(page_value: Page) -> Void
        \\  new(page_value, str(page_index(page_value)), "body", "text")
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
        \\import std:themes/default
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
        \\import std:themes/default
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
        \\import std:themes/default
        \\
        \\document
        \\  let add_each = (page_value: Page) |-> new(page_value, "lambda", "body", "text")
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
        \\fn make_label(text_value: String) -> Page -> Object
        \\  return (page_value: Page) |-> new(page_value, text_value, "body", "text")
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
        \\import std:themes/default
        \\
        \\page ok
        \\  text(str(((x: Number) |-> x + 4)(1)))
        \\end
        \\
    , "5");
}

test "compiler semantics: constants can hold function values" {
    try expectObjectContent(
        \\import std:themes/default
        \\
        \\const plus_one: Number -> Number = (x: Number) |-> x + 1
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
        \\import std:themes/default
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
        \\import std:themes/default
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
        \\import std:themes/default
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

test "compiler semantics: lambda bodies cannot be void" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\fn side_effect(page_value: Page) -> Void
        \\  new(page_value, "side", "body", "text")
        \\end
        \\
        \\document
        \\  foreach(pages(docctx()), (page_value: Page) |-> side_effect(page_value))
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
        \\  let f = (x: Number) |-> x + 1
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
        \\import std:themes/default
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

test "compiler semantics: function values cannot be stored as metadata content" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\fn id(x: Number) -> Number
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
        \\import std:themes/default
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
        \\import std:themes/default
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
        \\import std:themes/default
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
        \\import std:themes/default
        \\
        \\fn duplicate_title(title_obj: Object) -> Object
        \\  let page_value = page_of(title_obj)
        \\  new(page_value, "copy", "title", "text")
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
        \\import std:themes/default
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

test "compiler semantics: fold cannot mutate the iterated page selection" {
    try expectBuildFails(
        \\import std:themes/default
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
        \\import std:themes/default
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
        \\  ~ page.left == page.left
        \\end
        \\
    );
}

test "compiler semantics: missing constraint anchors are rejected statically" {
    try expectBuildFails(
        \\import std:themes/default
        \\
        \\page bad
        \\  ~ missing.left == page.left
        \\end
        \\
    );
}

test "compiler semantics: duplicate user functions are rejected" {
    try expectBuildFails(
        \\import std:themes/default
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
        \\import std:themes/default
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
        \\  obj("A", "card", "text")
        \\  let card_obj = first_card(objs_here("card"))
        \\  text(content(card_obj))
        \\end
        \\
    );
}

test "compiler semantics: object class mismatches report concrete type labels" {
    try expectDiagnostic(
        \\import std:themes/default
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
        \\  keep_card(new(pagectx(), "not a card", "body", "text"))
        \\end
        \\
    , "case.ss:bytes:", "TypeMismatch: expected Object<Card>, got Object<Body>");
}

test "compiler semantics: selection item class annotations resolve class names" {
    try expectDiagnostic(
        \\import std:themes/default
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
        \\import std:themes/default
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
