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
        error.ReservedIdentifier => "non-keyword identifier",
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
        error.InvalidValueTag => "value type",
        error.InvalidTypeAnnotation => "type annotation",
        error.ExpectedTypeAnnotation => "type annotation",
        error.AssignmentRequiresLet => "'let name = expr' for variable bindings",
        error.BindRemoved => "'let name = expr' for lexical bindings; 'bind' was removed",
        error.ZeroArgCallRequiresParens => "a call with parentheses or a value passed to a placing function",
        error.RequiredParameterAfterDefault => "defaulted parameters must trail required parameters",
        error.ExpectedReturn => "return statement",
        error.ExpectedEqualityOperator => "'=='",
        error.ExpectedConstraintMarker => "'~' before a constraint",
        error.ReservedPageNamePrefix => "page name not starting with '#'",
        error.PairedFunctionNameCannotEndWithBang => "function name without '!'",
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
