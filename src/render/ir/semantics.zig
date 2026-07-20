const std = @import("std");
const math = @import("math.zig");

pub const Id = u64;

pub const Role = enum {
    document,
    page,
    heading,
    paragraph,
    list,
    list_item,
    table,
    table_row,
    table_header,
    table_cell,
    figure,
    caption,
    code,
    math,
    link,
    text,
    group,
    decoration,
};

pub const LinkKind = enum {
    uri,
    destination,
};

pub const Node = struct {
    id: Id,
    role: Role,
    heading_level: ?u8 = null,
    list_ordered: ?bool = null,
    list_start: ?usize = null,
    children: []Id = &.{},
    items: []u64 = &.{},
    text: ?[]u8 = null,
    alt_text: ?[]u8 = null,
    language: ?[]u8 = null,
    code_language: ?[]u8 = null,
    math_tree: ?math.TreeId = null,
    link_kind: ?LinkKind = null,
    link_target: ?[]u8 = null,

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.children);
        allocator.free(self.items);
        if (self.text) |value| allocator.free(value);
        if (self.alt_text) |value| allocator.free(value);
        if (self.language) |value| allocator.free(value);
        if (self.code_language) |value| allocator.free(value);
        if (self.link_target) |value| allocator.free(value);
    }
};

pub const Tree = struct {
    root: ?Id = null,
    nodes: []Node = &.{},

    pub fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
        for (self.nodes) |*node| node.deinit(allocator);
        allocator.free(self.nodes);
        self.* = .{};
    }

    pub fn find(self: *const Tree, id: Id) ?*const Node {
        if (id == 0 or id > self.nodes.len) return null;
        const node = &self.nodes[@intCast(id - 1)];
        return if (node.id == id) node else null;
    }
};
