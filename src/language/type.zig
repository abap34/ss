const std = @import("std");
const model = @import("model");

pub const Type = struct {
    tag: Tag,
    param: Tag = .none,

    pub const Tag = enum {
        none,
        any,
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
        code,
        list,
    };

    pub const any = Type{ .tag = .any };
    pub const document = Type{ .tag = .document };
    pub const page = Type{ .tag = .page };
    pub const object = Type{ .tag = .object };
    pub const anchor = Type{ .tag = .anchor };
    pub const function = Type{ .tag = .function };
    pub const style = Type{ .tag = .style };
    pub const string = Type{ .tag = .string };
    pub const number = Type{ .tag = .number };
    pub const constraints = Type{ .tag = .constraints };

    pub fn selection(item: Tag) Type {
        return .{ .tag = .selection, .param = normalizeParam(item) };
    }

    pub fn fragment(root: Tag) Type {
        return .{ .tag = .fragment, .param = normalizeParam(root) };
    }

    pub fn code(inner: Tag) Type {
        return .{ .tag = .code, .param = normalizeParam(inner) };
    }

    pub fn list(inner: Tag) Type {
        return .{ .tag = .list, .param = normalizeParam(inner) };
    }

    fn normalizeParam(param: Tag) Tag {
        return if (param == .none) .any else param;
    }

    pub fn fromSort(sort: model.SemanticSort) Type {
        return switch (sort) {
            .document => .document,
            .page => .page,
            .object => .object,
            .selection => selection(.any),
            .anchor => .anchor,
            .function => .function,
            .style => .style,
            .string => .string,
            .number => .number,
            .constraints => .constraints,
            .fragment => fragment(.any),
        };
    }

    pub fn toRuntimeSort(self: Type) ?model.SemanticSort {
        return switch (self.tag) {
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
            .none, .any, .code, .list => null,
        };
    }

    pub fn eql(a: Type, b: Type) bool {
        return a.tag == b.tag and normalizeParam(a.param) == normalizeParam(b.param);
    }

    pub fn accepts(expected: Type, actual: Type) bool {
        if (expected.tag == .any or actual.tag == .any) return true;
        if (expected.tag != actual.tag) return false;
        const expected_param = normalizeParam(expected.param);
        const actual_param = normalizeParam(actual.param);
        return expected_param == .any or actual_param == .any or expected_param == actual_param;
    }

    pub fn fromSelectionItemSort(sort: model.SelectionItemSort) Type {
        return switch (sort) {
            .page => selection(.page),
            .object => selection(.object),
        };
    }

    pub fn scalarTagFromSort(sort: model.SemanticSort) Tag {
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

    pub fn formatAlloc(self: Type, allocator: std.mem.Allocator) ![]const u8 {
        var text = std.ArrayList(u8).empty;
        errdefer text.deinit(allocator);
        try self.formatInto(allocator, &text);
        return text.toOwnedSlice(allocator);
    }

    pub fn formatInto(self: Type, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        switch (self.tag) {
            .selection, .fragment, .code, .list => {
                try out.appendSlice(allocator, @tagName(self.tag));
                try out.append(allocator, '<');
                try out.appendSlice(allocator, @tagName(normalizeParam(self.param)));
                try out.append(allocator, '>');
            },
            else => try out.appendSlice(allocator, @tagName(self.tag)),
        }
    }

    pub fn label(self: Type) []const u8 {
        return @tagName(self.tag);
    }
};
