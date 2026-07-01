const std = @import("std");
const core = @import("core");

pub fn isDiscardBindingName(text: []const u8) bool {
    return isSingleUnderscore(text);
}

pub fn isAnonymousPageName(text: []const u8) bool {
    return isSingleUnderscore(text);
}

pub fn hasBangSuffix(text: []const u8) bool {
    return text.len > 0 and text[text.len - 1] == '!';
}

pub fn isCallableNameChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '!';
}

pub fn isKeyword(text: []const u8) bool {
    for (keywords) |keyword| if (std.mem.eql(u8, text, keyword)) return true;
    return false;
}

pub fn keywordLabels() []const []const u8 {
    return &keywords;
}

const keywords = [_][]const u8{
    "import",
    "as",
    "with",
    "const",
    "document",
    "page",
    "fn",
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

pub fn parseRoleName(text: []const u8) ?core.Role {
    if (text.len == 0) return null;
    return text;
}

pub const ParsedPayload = struct {
    object_kind: core.ObjectKind,
    payload_kind: core.PayloadKind,
};

const payload_table = [_]struct { name: []const u8, parsed: ParsedPayload }{
    .{ .name = "text", .parsed = .{ .object_kind = .text, .payload_kind = .text } },
    .{ .name = "code", .parsed = .{ .object_kind = .source, .payload_kind = .code } },
    .{ .name = "math_text", .parsed = .{ .object_kind = .source, .payload_kind = .math_text } },
    .{ .name = "math_tex", .parsed = .{ .object_kind = .asset, .payload_kind = .math_tex } },
    .{ .name = "figure_text", .parsed = .{ .object_kind = .source, .payload_kind = .figure_text } },
    .{ .name = "image_ref", .parsed = .{ .object_kind = .asset, .payload_kind = .image_ref } },
    .{ .name = "pdf_ref", .parsed = .{ .object_kind = .asset, .payload_kind = .pdf_ref } },
};

pub fn parsePayloadName(text: []const u8) ?ParsedPayload {
    for (payload_table) |entry| {
        if (std.mem.eql(u8, text, entry.name)) return entry.parsed;
    }
    return null;
}

pub fn parseAnchorName(text: []const u8) ?core.Anchor {
    return std.meta.stringToEnum(core.Anchor, text);
}
