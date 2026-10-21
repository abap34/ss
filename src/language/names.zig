const std = @import("std");
const core = @import("core");
const scanner = @import("../syntax/scanner.zig");

pub fn isDiscardBindingName(text: []const u8) bool {
    return isSingleUnderscore(text);
}

pub fn isAnonymousPageName(text: []const u8) bool {
    return isSingleUnderscore(text);
}

pub fn hasBangSuffix(text: []const u8) bool {
    return text.len > 0 and text[text.len - 1] == '!';
}

pub fn isKeyword(text: []const u8) bool {
    return scanner.isKeyword(text);
}

pub fn keywordLabels() []const []const u8 {
    return scanner.keywordLabels();
}

pub fn bangName(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}!", .{text});
}

pub fn importSpecHasFileExtension(spec: []const u8) bool {
    return std.fs.path.extension(spec).len != 0;
}

pub fn importPathWithDefaultExtension(allocator: std.mem.Allocator, spec: []const u8) ![]u8 {
    if (importSpecHasFileExtension(spec)) return error.InvalidImportSpec;
    return std.fmt.allocPrint(allocator, "{s}.ss", .{spec});
}

pub fn defaultImportAlias(spec: []const u8) []const u8 {
    var end = spec.len;
    while (end > 0 and (spec[end - 1] == '/' or spec[end - 1] == '\\')) end -= 1;
    const trimmed = spec[0..end];
    const separator = std.mem.lastIndexOfAny(u8, trimmed, "/\\:");
    return if (separator) |index| trimmed[index + 1 ..] else trimmed;
}

fn isSingleUnderscore(text: []const u8) bool {
    return std.mem.eql(u8, text, "_");
}

pub fn parseAnchorName(text: []const u8) ?core.Anchor {
    return std.meta.stringToEnum(core.Anchor, text);
}
