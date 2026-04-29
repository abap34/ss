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

pub fn parsePayloadName(text: []const u8) ?ParsedPayload {
    if (std.mem.eql(u8, text, "text")) return .{ .object_kind = .text, .payload_kind = .text };
    if (std.mem.eql(u8, text, "code")) return .{ .object_kind = .source, .payload_kind = .code };
    if (std.mem.eql(u8, text, "math_text")) return .{ .object_kind = .source, .payload_kind = .math_text };
    if (std.mem.eql(u8, text, "math_tex")) return .{ .object_kind = .asset, .payload_kind = .math_tex };
    if (std.mem.eql(u8, text, "figure_text")) return .{ .object_kind = .source, .payload_kind = .figure_text };
    if (std.mem.eql(u8, text, "image_ref")) return .{ .object_kind = .asset, .payload_kind = .image_ref };
    if (std.mem.eql(u8, text, "pdf_ref")) return .{ .object_kind = .asset, .payload_kind = .pdf_ref };
    return null;
}

pub fn parseAnchorName(text: []const u8) ?core.Anchor {
    if (std.mem.eql(u8, text, "left")) return .left;
    if (std.mem.eql(u8, text, "right")) return .right;
    if (std.mem.eql(u8, text, "top")) return .top;
    if (std.mem.eql(u8, text, "bottom")) return .bottom;
    if (std.mem.eql(u8, text, "center_x")) return .center_x;
    if (std.mem.eql(u8, text, "center_y")) return .center_y;
    return null;
}
