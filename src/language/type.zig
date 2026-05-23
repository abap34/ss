const std = @import("std");
const model = @import("model");

pub const Type = struct {
    tag: Tag,
    param: Tag = .none,
    class_name: ?[]const u8 = null,
    param_class_name: ?[]const u8 = null,

    pub const Tag = enum {
        none,
        any,
        document,
        page,
        object,
        metadata,
        selection,
        anchor,
        function,
        style,
        string,
        number,
        boolean,
        constraints,
        fragment,
        code,
        list,
        void,
    };

    pub const any = Type{ .tag = .any };
    pub const document = Type{ .tag = .document };
    pub const page = Type{ .tag = .page };
    pub const object = Type{ .tag = .object };
    pub const metadata = Type{ .tag = .metadata };
    pub const anchor = Type{ .tag = .anchor };
    pub const function = Type{ .tag = .function };
    pub const style = Type{ .tag = .style };
    pub const string = Type{ .tag = .string };
    pub const number = Type{ .tag = .number };
    pub const boolean = Type{ .tag = .boolean };
    pub const constraints = Type{ .tag = .constraints };

    pub fn objectClass(name: []const u8) Type {
        return .{ .tag = .object, .class_name = name };
    }

    pub fn selection(item: Tag) Type {
        return .{ .tag = .selection, .param = normalizeParam(item) };
    }

    pub fn selectionType(item: Type) Type {
        return .{
            .tag = .selection,
            .param = normalizeParam(item.tag),
            .param_class_name = if (item.tag == .object) item.class_name else null,
        };
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
            .code => code(.any),
            .document => .document,
            .page => .page,
            .object => .object,
            .metadata => .metadata,
            .selection => selection(.any),
            .anchor => .anchor,
            .function => .function,
            .style => .style,
            .string => .string,
            .number => .number,
            .boolean => .boolean,
            .constraints => .constraints,
            .fragment => fragment(.any),
            .void => .{ .tag = .void },
        };
    }

    pub fn toRuntimeSort(self: Type) ?model.SemanticSort {
        return switch (self.tag) {
            .document => .document,
            .page => .page,
            .object => .object,
            .metadata => .metadata,
            .selection => .selection,
            .anchor => .anchor,
            .function => .function,
            .style => .style,
            .string => .string,
            .number => .number,
            .boolean => .boolean,
            .constraints => .constraints,
            .fragment => .fragment,
            .code => .code,
            .void => .void,
            .none, .any, .list => null,
        };
    }

    pub fn eql(a: Type, b: Type) bool {
        return a.tag == b.tag and
            normalizeParam(a.param) == normalizeParam(b.param) and
            optionalStringEql(a.class_name, b.class_name) and
            optionalStringEql(a.param_class_name, b.param_class_name);
    }

    pub fn accepts(expected: Type, actual: Type) bool {
        if (expected.tag == .any or actual.tag == .any) return true;
        if (actual.tag == .code and expected.tag == normalizeParam(actual.param)) return true;
        if (expected.tag != actual.tag) return false;
        if (expected.tag == .object and expected.class_name != null and actual.class_name != null) {
            if (!std.mem.eql(u8, expected.class_name.?, actual.class_name.?)) return false;
        }
        const expected_param = normalizeParam(expected.param);
        const actual_param = normalizeParam(actual.param);
        if (!(expected_param == .any or actual_param == .any or expected_param == actual_param)) return false;
        if (expected_param == .object and expected.param_class_name != null and actual.param_class_name != null) {
            if (!std.mem.eql(u8, expected.param_class_name.?, actual.param_class_name.?)) return false;
        }
        return true;
    }

    pub fn fromSelectionItemSort(sort: model.SelectionItemSort) Type {
        return switch (sort) {
            .page => selection(.page),
            .object => selection(.object),
            .metadata => selection(.metadata),
        };
    }

    pub fn scalarTagFromSort(sort: model.SemanticSort) Tag {
        return switch (sort) {
            .document => .document,
            .page => .page,
            .object => .object,
            .metadata => .metadata,
            .selection => .selection,
            .anchor => .anchor,
            .function => .function,
            .style => .style,
            .string => .string,
            .number => .number,
            .boolean => .boolean,
            .constraints => .constraints,
            .fragment => .fragment,
            .code => .code,
            .void => .void,
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
                if (normalizeParam(self.param) == .object and self.param_class_name != null) {
                    try out.appendSlice(allocator, "object<");
                    try out.appendSlice(allocator, self.param_class_name.?);
                    try out.append(allocator, '>');
                } else {
                    try out.appendSlice(allocator, @tagName(normalizeParam(self.param)));
                }
                try out.append(allocator, '>');
            },
            .object => {
                try out.appendSlice(allocator, "object");
                if (self.class_name) |class_name| {
                    try out.append(allocator, '<');
                    try out.appendSlice(allocator, class_name);
                    try out.append(allocator, '>');
                }
            },
            else => try out.appendSlice(allocator, @tagName(self.tag)),
        }
    }

    pub fn label(self: Type) []const u8 {
        return @tagName(self.tag);
    }
};

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}
