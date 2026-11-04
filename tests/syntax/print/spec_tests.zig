const std = @import("std");
const syntax = @import("syntax");
const testing = std.testing;
const allocation_testing = @import("allocation_testing");

const example =
    \\page _
    \\  stages s { first second }
    \\  text! "Title"
    \\  show s >= s.second
    \\    let detail = text! "Details"
    \\  end
    \\end
    \\
;

test "print: stage expansion retains generated names calls and unfurled predicates" {
    var module = try syntax.parseWithSourceName(testing.allocator, example, "example.ss");
    defer module.deinit(testing.allocator);
    const output = try syntax.printExpandedAlloc(testing.allocator, module);
    defer testing.allocator.free(output);
    const expected = try std.fmt.allocPrint(testing.allocator,
        \\page "{s}"
        \\  text!("Title")
        \\  let #drawing-58 = (() |-> num_ge(0, 1))
        \\  draw_when!(0, #drawing-58)
        \\  let detail = draw_when!(text!("Details"), #drawing-58)
        \\end
        \\
        \\page "{s}"
        \\  text!("Title")
        \\  let #drawing-58 = (() |-> num_ge(1, 1))
        \\  draw_when!(0, #drawing-58)
        \\  let detail = draw_when!(text!("Details"), #drawing-58)
        \\end
        \\
    , .{ module.pages.items[0].name, module.pages.items[1].name });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, output);
}

test "print: declarations paired functions and every expanded expression retain their structure" {
    const source =
        \\import "./labels" as { Label }
        \\enum Tone { soft strong }
        \\type Box<T> { value: T count: Number = 1 + 2 }
        \\const color: Color = c"#000000"
        \\fn/! label<T>(value: T) -> Box<T> = Box<T> { value = value }
        \\document
        \\  let current = 1.2345678
        \\end
        \\page Demo
        \\  let a: Box<Number> = label<Number>(42)
        \\  let b = a with { count = 3 }
        \\  let c = b.value
        \\  let d = b?.value
        \\  let e = none ?? 4
        \\  let f = b?
        \\  let g = ((x: Number) |-> x)(5)
        \\  let h = Tone.soft
        \\  let raw = "a\nb"
        \\  let quoted = <<
        \\quote"line
        \\>>
        \\  if 1 < 2
        \\    a.value = 4
        \\  else
        \\    a.value = 5
        \\  end
        \\  let row = text("A") || text("B")
        \\  ~ row.width == 300
        \\  ~!~ row.left == page.left + 10
        \\end
        \\
    ;
    var module = try syntax.parse(testing.allocator, source);
    defer module.deinit(testing.allocator);
    const output = try syntax.printExpandedAlloc(testing.allocator, module);
    defer testing.allocator.free(output);
    for ([_][]const u8{
        "import \"./labels\" as { Label }",
        "enum Tone { soft strong }",
        "count: Number = add(1, 2)",
        "const color: Color = c\"0,0,0\"",
        "fn label!<T>(value: T) -> Placed<Box<T>>",
        "return place_on!(pagectx(), label<T>(value))",
        "let current = 1.2345678",
        "let a: Box<Number> = label<Number>(42)",
        "let b = (a) with { count = 3 }",
        "let c = (b).value",
        "let d = (b)?.value",
        "let e = (none ?? 4)",
        "let f = (b)?",
        "let g = (((x: Number) |-> x))(5)",
        "let h = (Tone).soft",
        "let raw = \"a\\nb\"",
        "let quoted = <<\n\nquote\"line\n>>\n",
        "if num_lt(1, 2)",
        "a.value = 4",
        ";; composition: horizontal",
        "~ row.right == row.left + 300",
        "~!~ row.left == page.left + 10",
    }) |fragment| {
        try testing.expect(std.mem.indexOf(u8, output, fragment) != null);
    }
}

fn allocateOutput(allocator: std.mem.Allocator, module: @import("ast").Module) !void {
    const text = try syntax.printExpandedAlloc(allocator, module);
    defer allocator.free(text);
}

test "print: string contents survive source output including literal backslashes quotes and newlines" {
    const source =
        \\const raw: String = "a\nb"
        \\const multiline: String = "
        \\A
        \\"
        \\const quoted: String = <<
        \\
        \\
        \\"Q"
        \\
        \\>>
        \\
    ;
    var original = try syntax.parse(testing.allocator, source);
    defer original.deinit(testing.allocator);
    const output = try syntax.printExpandedAlloc(testing.allocator, original);
    defer testing.allocator.free(output);
    var printed = try syntax.parse(testing.allocator, output);
    defer printed.deinit(testing.allocator);
    try testing.expectEqual(original.constants.items.len, printed.constants.items.len);
    for (original.constants.items, printed.constants.items) |a, b| {
        try testing.expectEqualStrings(a.value.string.text, b.value.string.text);
    }
}

test "print: allocation failures release the output and leave the tree reusable" {
    var module = try syntax.parse(testing.allocator, example);
    defer module.deinit(testing.allocator);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, allocateOutput, .{module});
}
