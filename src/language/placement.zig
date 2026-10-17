const std = @import("std");
const ast = @import("ast");
const core = @import("core");

pub const input_members = [_][]const u8{ "value", "page", "document" };

pub const Member = union(enum) { value, page, document, anchor: core.Anchor };

pub fn member(name: []const u8) ?Member {
    if (std.mem.eql(u8, name, "value")) return .value;
    if (std.mem.eql(u8, name, "page")) return .page;
    if (std.mem.eql(u8, name, "document")) return .document;
    if (std.meta.stringToEnum(core.Anchor, name)) |anchor| return .{ .anchor = anchor };
    return null;
}

/// Returns a borrowed type. Placement erasure deliberately omits the input;
/// arbitrary record fields remain accessible only through Placed<T>.value.
pub fn memberType(receiver: ast.Type, name: []const u8) ?ast.Type {
    if (receiver.kind != .placed and receiver.kind != .placement) return null;
    return switch (member(name) orelse return null) {
        .value => receiver.placedInput(),
        .page => ast.Type.page,
        .document => ast.Type.document,
        .anchor => ast.Type.anchor,
    };
}
