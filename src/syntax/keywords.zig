// Kept independent of the parser and diagnostics so both can share the vocabulary.
const std = @import("std");

const keywords = [_][]const u8{
    "import",
    "as",
    "with",
    "const",
    "document",
    "page",
    "fn",
    "fn/!",
    "let",
    "bind",
    "return",
    "end",
    "type",
    "record",
    "protocol",
    "extend",
    "base",
    "implements",
    "roles",
    "if",
    "then",
    "else",
    "for",
    "in",
    "property",
};

pub fn contains(text: []const u8) bool {
    for (keywords) |keyword| if (std.mem.eql(u8, text, keyword)) return true;
    return false;
}

pub fn labels() []const []const u8 {
    return &keywords;
}
