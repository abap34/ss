const utils = @import("utils");

const source = utils.source;

pub fn consumeKeywordNoTrivia(text: []const u8, pos: *usize, keyword: []const u8) bool {
    if (!source.startsWithAt(text, pos.*, keyword)) return false;
    const end = pos.* + keyword.len;
    if (end < text.len and source.isIdentifierContinue(text[end])) return false;
    pos.* = end;
    return true;
}

pub fn atStatementBoundary(text: []const u8, pos: usize) bool {
    var probe = pos;
    source.skipInlineSpaces(text, &probe);
    if (probe >= text.len) return true;
    return text[probe] == '\n';
}

pub fn scanIdentifier(text: []const u8, pos: *usize) bool {
    if (pos.* >= text.len or !source.isIdentifierStart(text[pos.*])) return false;
    pos.* += 1;
    while (pos.* < text.len and source.isIdentifierContinue(text[pos.*])) pos.* += 1;
    return true;
}
