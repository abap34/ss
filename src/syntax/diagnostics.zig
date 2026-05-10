const std = @import("std");
const ast = @import("ast");

pub const ParseDiagnostic = struct {
    err: anyerror,
    span: ast.Span,
    expected: ?[]const u8 = null,
    found: ?[]const u8 = null,
};

pub fn expected(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ExpectedString => "string or page name",
        error.ExpectedIdentifier => "identifier",
        error.ExpectedKeyword => "keyword",
        error.ExpectedChar => "punctuation",
        error.ExpectedLineBreak => "line break after block header",
        error.ExpectedEnd => "'end'",
        error.ExpectedNumber => "number",
        error.UnterminatedString => "closing string delimiter",
        error.UnterminatedEscape => "escape target",
        error.InvalidEscape => "valid escape sequence",
        error.InvalidColorLiteral => "valid color literal",
        error.UnknownAnchor => "known anchor name",
        error.InvalidSemanticSort => "semantic sort",
        error.ExpectedTypeAnnotation => "type annotation",
        error.AssignmentRequiresLet => "'let name = expr' for variable bindings",
        error.ZeroArgCallRequiresParens => "'name()' for zero-argument calls",
        error.RequiredParameterAfterDefault => "defaulted parameters must trail required parameters",
        error.ExpectedReturn => "return statement",
        error.ExpectedEqualityOperator => "'=='",
        error.ReservedPageNamePrefix => "page name not starting with '#'",
        else => null,
    };
}

pub fn foundToken(source: []const u8, pos: usize) []const u8 {
    if (pos >= source.len) return "end of file";
    return switch (source[pos]) {
        '\n' => "line break",
        '\r' => "carriage return",
        '\t' => "tab",
        ' ' => "space",
        else => blk: {
            const len = std.unicode.utf8ByteSequenceLength(source[pos]) catch 1;
            break :blk source[pos..@min(pos + len, source.len)];
        },
    };
}
