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
        \\  let color = c"#fff"
        \\  theme::text("hi ;; not comment") ;; comment
        \\  x = 12.5
        \\  let quoted = "not a color c\"#000000\""
        \\  ;; c"#111111"
    ;

    try expectTokens(text, &.{
        .{ .kind = .identifier, .text = "fn", .line = 0 },
        .{ .kind = .identifier, .text = "title!", .line = 0 },
        .{ .kind = .identifier, .text = "x", .line = 0 },
        .{ .kind = .identifier, .text = "String", .line = 0 },
        .{ .kind = .identifier, .text = "let", .line = 1 },
        .{ .kind = .identifier, .text = "color", .line = 1 },
        .{ .kind = .color_string, .text = "c\"#fff\"", .line = 1 },
        .{ .kind = .identifier, .text = "theme", .line = 2 },
        .{ .kind = .qualified_access, .text = "::", .line = 2 },
        .{ .kind = .identifier, .text = "text", .line = 2 },
        .{ .kind = .string, .text = "\"hi ;; not comment\"", .line = 2 },
        .{ .kind = .identifier, .text = "x", .line = 3 },
        .{ .kind = .number, .text = "12.5", .line = 3 },
        .{ .kind = .identifier, .text = "let", .line = 4 },
        .{ .kind = .identifier, .text = "quoted", .line = 4 },
        .{ .kind = .string, .text = "\"not a color c\\\"#000000\\\"\"", .line = 4 },
    });
}

test "syntax scanner: classifies semantic tokens without LSP logic" {
    const text =
        \\fn title!(x: String)
        \\  let color = c"#fff"
        \\  theme::text("hi").size = 12
    ;

    const tokens = try scanner.semanticTokens(testing.allocator, text);
    defer testing.allocator.free(tokens);

    try expectSemantic(tokens, text, &.{
        .{ .kind = .keyword, .text = "fn" },
        .{ .kind = .function, .text = "title!" },
        .{ .kind = .type, .text = "String" },
        .{ .kind = .keyword, .text = "let" },
        .{ .kind = .variable, .text = "color" },
        .{ .kind = .string, .text = "c\"#fff\"" },
        .{ .kind = .operator, .text = "::" },
        .{ .kind = .function, .text = "text" },
        .{ .kind = .string, .text = "\"hi\"" },
        .{ .kind = .property, .text = "size" },
        .{ .kind = .number, .text = "12" },
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
