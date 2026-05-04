const std = @import("std");
const core = @import("core");

pub const Type = union(enum) {
    document,
    page,
    object,
    selection,
    anchor,
    function,
    style,
    string,
    number,
    constraints,
    fragment,
    code: *Type,
    list: *Type,

    pub fn fromSort(sort: core.SemanticSort) Type {
        return switch (sort) {
            .document => .document,
            .page => .page,
            .object => .object,
            .selection => .selection,
            .anchor => .anchor,
            .function => .function,
            .style => .style,
            .string => .string,
            .number => .number,
            .constraints => .constraints,
            .fragment => .fragment,
        };
    }

    pub fn deinit(self: *Type, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .code, .list => |inner| {
                inner.deinit(allocator);
                allocator.destroy(inner);
            },
            else => {},
        }
    }
};
