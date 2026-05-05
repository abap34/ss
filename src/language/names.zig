const std = @import("std");
const core = @import("core");

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
