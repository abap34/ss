const std = @import("std");
const scanner = @import("scanner");

const testing = std.testing;

const ExpectedToken = struct {
    kind: scanner.TokenKind,
    text: []const u8,
    line: usize,
};

test "syntax scanner: tokenizes source words and literals without comments" {
    const text =
        \\fn title!(x: String)
        \\fn make() -> Object
        \\  let color = c"#fff"
        \\  theme::text("hi ;; not comment") ;; comment
        \\  let lambda = (x: Number) |-> x
        \\  x = 12.5
        \\  let quoted = "not a color c\"#000000\""
        \\  let multiline = "English Object
        \\inside"
        \\  quote """
        \\English Object
        \\"""
        \\  code <<
        \\English Object
        \\>>
        \\  let after = "done"
        \\  ;; c"#111111"
    ;

    try expectTokens(text, &.{
        .{ .kind = .identifier, .text = "fn", .line = 0 },
        .{ .kind = .identifier, .text = "title!", .line = 0 },
        .{ .kind = .identifier, .text = "x", .line = 0 },
        .{ .kind = .identifier, .text = "String", .line = 0 },
        .{ .kind = .identifier, .text = "fn", .line = 1 },
        .{ .kind = .identifier, .text = "make", .line = 1 },
        .{ .kind = .operator, .text = "->", .line = 1 },
        .{ .kind = .identifier, .text = "Object", .line = 1 },
        .{ .kind = .identifier, .text = "let", .line = 2 },
        .{ .kind = .identifier, .text = "color", .line = 2 },
        .{ .kind = .color_string, .text = "c\"#fff\"", .line = 2 },
        .{ .kind = .identifier, .text = "theme", .line = 3 },
        .{ .kind = .operator, .text = "::", .line = 3 },
        .{ .kind = .identifier, .text = "text", .line = 3 },
        .{ .kind = .string, .text = "\"hi ;; not comment\"", .line = 3 },
        .{ .kind = .identifier, .text = "let", .line = 4 },
        .{ .kind = .identifier, .text = "lambda", .line = 4 },
        .{ .kind = .identifier, .text = "x", .line = 4 },
        .{ .kind = .identifier, .text = "Number", .line = 4 },
        .{ .kind = .operator, .text = "|->", .line = 4 },
        .{ .kind = .identifier, .text = "x", .line = 4 },
        .{ .kind = .identifier, .text = "x", .line = 5 },
        .{ .kind = .number, .text = "12.5", .line = 5 },
        .{ .kind = .identifier, .text = "let", .line = 6 },
        .{ .kind = .identifier, .text = "quoted", .line = 6 },
        .{ .kind = .string, .text = "\"not a color c\\\"#000000\\\"\"", .line = 6 },
        .{ .kind = .identifier, .text = "let", .line = 7 },
        .{ .kind = .identifier, .text = "multiline", .line = 7 },
        .{ .kind = .identifier, .text = "quote", .line = 9 },
        .{ .kind = .identifier, .text = "code", .line = 12 },
        .{ .kind = .identifier, .text = "let", .line = 15 },
        .{ .kind = .identifier, .text = "after", .line = 15 },
        .{ .kind = .string, .text = "\"done\"", .line = 15 },
    });
}

test "syntax scanner: classifies semantic tokens without LSP logic" {
    const text =
        \\fn title!(x: String)
        \\fn make() -> Object
        \\  let color = c"#fff"
        \\  theme::text("hi").size = 12
        \\  let lambda = (x: Number) |-> x
        \\  let multiline = "English Object
        \\inside"
        \\  quote """
        \\English Object
        \\"""
        \\  code <<
        \\English Object
        \\>>
        \\  let after = Object
    ;

    const tokens = try scanner.semanticTokens(testing.allocator, text);
    defer testing.allocator.free(tokens);

    try expectSemantic(tokens, text, &.{
        .{ .kind = .keyword, .text = "fn" },
        .{ .kind = .function, .text = "title!" },
        .{ .kind = .type, .text = "String" },
        .{ .kind = .keyword, .text = "fn" },
        .{ .kind = .function, .text = "make" },
        .{ .kind = .operator, .text = "->" },
        .{ .kind = .type, .text = "Object" },
        .{ .kind = .keyword, .text = "let" },
        .{ .kind = .variable, .text = "color" },
        .{ .kind = .string, .text = "c\"#fff\"" },
        .{ .kind = .operator, .text = "::" },
        .{ .kind = .function, .text = "text" },
        .{ .kind = .string, .text = "\"hi\"" },
        .{ .kind = .property, .text = "size" },
        .{ .kind = .number, .text = "12" },
        .{ .kind = .keyword, .text = "let" },
        .{ .kind = .variable, .text = "lambda" },
        .{ .kind = .type, .text = "Number" },
        .{ .kind = .operator, .text = "|->" },
        .{ .kind = .keyword, .text = "let" },
        .{ .kind = .variable, .text = "multiline" },
        .{ .kind = .keyword, .text = "let" },
        .{ .kind = .variable, .text = "after" },
        .{ .kind = .type, .text = "Object" },
    });
}

fn expectTokens(text: []const u8, expected: []const ExpectedToken) !void {
    var iter = scanner.tokens(text);
    for (expected) |item| {
        const token = iter.next() orelse return error.MissingToken;
        try testing.expectEqual(item.kind, token.kind);
        try testing.expectEqual(item.line, token.line);
        try testing.expectEqualStrings(item.text, text[token.span.start..token.span.end]);
    }
    try testing.expect(iter.next() == null);
}

const ExpectedSemanticToken = struct {
    kind: scanner.SemanticKind,
    text: []const u8,
};

fn expectSemantic(tokens: []const scanner.SemanticToken, text: []const u8, expected: []const ExpectedSemanticToken) !void {
    try testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |item, token| {
        try testing.expectEqual(item.kind, token.kind);
        try testing.expectEqualStrings(item.text, text[token.token.span.start..token.token.span.end]);
    }
}
