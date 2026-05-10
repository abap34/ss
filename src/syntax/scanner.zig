const std = @import("std");
const utils = @import("utils");

const source_utils = utils.source;

pub fn startsWith(source: []const u8, pos: usize, text: []const u8) bool {
    if (pos + text.len > source.len) return false;
    return std.mem.eql(u8, source[pos .. pos + text.len], text);
}

pub fn isInlineSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r';
}

pub fn lineCommentStart(source: []const u8, pos: usize) bool {
    if (pos >= source.len) return false;
    if (startsWith(source, pos, "//")) return true;
    if (startsWith(source, pos, ";;")) return true;
    return source[pos] == '#';
}

pub fn skipLineComment(source: []const u8, pos: *usize) void {
    while (pos.* < source.len and source[pos.*] != '\n') pos.* += 1;
}

pub fn skipInlineSpaces(source: []const u8, pos: *usize) void {
    while (pos.* < source.len and isInlineSpace(source[pos.*])) pos.* += 1;
}

pub fn skipTrivia(source: []const u8, pos: *usize) void {
    while (pos.* < source.len) {
        const ch = source[pos.*];
        if (std.ascii.isWhitespace(ch)) {
            pos.* += 1;
            continue;
        }
        if (startsWith(source, pos.*, "//")) {
            pos.* += 2;
            skipLineComment(source, pos);
            continue;
        }
        if (startsWith(source, pos.*, ";;")) {
            pos.* += 2;
            skipLineComment(source, pos);
            continue;
        }
        if (ch == '#') {
            skipLineComment(source, pos);
            continue;
        }
        break;
    }
}

pub fn consumeKeywordNoTrivia(source: []const u8, pos: *usize, keyword: []const u8) bool {
    if (!startsWith(source, pos.*, keyword)) return false;
    const end = pos.* + keyword.len;
    if (end < source.len and source_utils.isIdentifierContinue(source[end])) return false;
    pos.* = end;
    return true;
}

pub fn atStatementBoundary(source: []const u8, pos: usize) bool {
    var probe = pos;
    while (probe < source.len and isInlineSpace(source[probe])) probe += 1;
    if (probe >= source.len) return true;
    return source[probe] == '\n';
}

pub fn scanIdentifier(source: []const u8, pos: *usize) bool {
    if (pos.* >= source.len or !source_utils.isIdentifierStart(source[pos.*])) return false;
    pos.* += 1;
    while (pos.* < source.len and source_utils.isIdentifierContinue(source[pos.*])) pos.* += 1;
    return true;
}
