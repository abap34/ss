const std = @import("std");
const model = @import("model");

pub const Type = struct {
    tag: Tag,
    param: Tag = .none,
    class_name: ?[]const u8 = null,
    param_class_name: ?[]const u8 = null,
    fn_params: []const Type = &.{},
    fn_result: ?*Type = null,

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

    pub fn functionType(allocator: std.mem.Allocator, params: []const Type, result: Type) anyerror!Type {
        const copied_params = try allocator.alloc(Type, params.len);
        errdefer allocator.free(copied_params);
        for (params, 0..) |param, index| copied_params[index] = try param.clone(allocator);
        errdefer {
            for (copied_params) |*param| param.deinit(allocator);
        }
        const copied_result = try allocator.create(Type);
        errdefer allocator.destroy(copied_result);
        copied_result.* = try result.clone(allocator);
        return .{
            .tag = .function,
            .fn_params = copied_params,
            .fn_result = copied_result,
        };
    }

    pub fn deinit(self: *Type, allocator: std.mem.Allocator) void {
        if (self.tag != .function) return;
        for (self.fn_params) |param| {
            var owned = param;
            owned.deinit(allocator);
        }
        if (self.fn_params.len != 0) allocator.free(self.fn_params);
        if (self.fn_result) |result| {
            result.deinit(allocator);
            allocator.destroy(result);
        }
        self.fn_params = &.{};
        self.fn_result = null;
    }

    pub fn clone(self: Type, allocator: std.mem.Allocator) anyerror!Type {
        if (self.tag != .function) return self;
        const result = self.fn_result orelse return self;
        return try functionType(allocator, self.fn_params, result.*);
    }

    fn normalizeParam(param: Tag) Tag {
        return if (param == .none) .any else param;
    }

    pub fn fromValueTag(tag: model.ValueTag) Type {
        return switch (tag) {
            .code => code(.any),
            .document => .document,
            .page => .page,
            .object => .object,
            .metadata => .metadata,
            .selection => selection(.any),
            .anchor => .anchor,
            .function => .{ .tag = .function },
            .style => .style,
            .string => .string,
            .number => .number,
            .boolean => .boolean,
            .constraints => .constraints,
            .fragment => fragment(.any),
            .void => .{ .tag = .void },
        };
    }

    pub fn toValueTag(self: Type) ?model.ValueTag {
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
        if (a.tag != b.tag) return false;
        if (a.tag == .function) {
            if ((a.fn_result == null) != (b.fn_result == null)) return false;
            if (a.fn_params.len != b.fn_params.len) return false;
            for (a.fn_params, 0..) |param, index| {
                if (!eql(param, b.fn_params[index])) return false;
            }
            if (a.fn_result) |a_result| {
                const b_result = b.fn_result orelse return false;
                if (!eql(a_result.*, b_result.*)) return false;
            }
            return true;
        }
        return normalizeParam(a.param) == normalizeParam(b.param) and
            optionalStringEql(a.class_name, b.class_name) and
            optionalStringEql(a.param_class_name, b.param_class_name);
    }

    pub fn accepts(expected: Type, actual: Type) bool {
        if (expected.tag == .any or actual.tag == .any) return true;
        if (actual.tag == .code and expected.tag == normalizeParam(actual.param)) return true;
        if (expected.tag != actual.tag) return false;
        if (expected.tag == .function) {
            if (expected.fn_result == null or actual.fn_result == null) return false;
            if (expected.fn_params.len != actual.fn_params.len) return false;
            for (expected.fn_params, 0..) |expected_param, index| {
                if (!accepts(expected_param, actual.fn_params[index])) return false;
            }
            return accepts(expected.fn_result.?.*, actual.fn_result.?.*);
        }
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

    pub fn fromSelectionItemTag(tag: model.SelectionItemTag) Type {
        return switch (tag) {
            .page => selection(.page),
            .object => selection(.object),
            .metadata => selection(.metadata),
        };
    }

    pub fn scalarTagFromValueTag(tag: model.ValueTag) Tag {
        return switch (tag) {
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
                try out.appendSlice(allocator, displayName(self.tag));
                try out.append(allocator, '<');
                if (normalizeParam(self.param) == .object and self.param_class_name != null) {
                    try out.appendSlice(allocator, "Object<");
                    try out.appendSlice(allocator, self.param_class_name.?);
                    try out.append(allocator, '>');
                } else {
                    try out.appendSlice(allocator, displayName(normalizeParam(self.param)));
                }
                try out.append(allocator, '>');
            },
            .object => {
                try out.appendSlice(allocator, "Object");
                if (self.class_name) |class_name| {
                    try out.append(allocator, '<');
                    try out.appendSlice(allocator, class_name);
                    try out.append(allocator, '>');
                }
            },
            .function => {
                if (self.fn_result == null) {
                    try out.appendSlice(allocator, "Function");
                    return;
                }
                if (self.fn_params.len == 1) {
                    const param = self.fn_params[0];
                    const needs_parens = param.tag == .function;
                    if (needs_parens) try out.append(allocator, '(');
                    try param.formatInto(allocator, out);
                    if (needs_parens) try out.append(allocator, ')');
                } else {
                    try out.append(allocator, '(');
                    for (self.fn_params, 0..) |param, index| {
                        if (index > 0) try out.appendSlice(allocator, ", ");
                        try param.formatInto(allocator, out);
                    }
                    try out.append(allocator, ')');
                }
                try out.appendSlice(allocator, " -> ");
                try self.fn_result.?.formatInto(allocator, out);
            },
            else => try out.appendSlice(allocator, displayName(self.tag)),
        }
    }

    pub fn label(self: Type) []const u8 {
        return displayName(self.tag);
    }

    fn displayName(tag: Tag) []const u8 {
        return switch (tag) {
            .none => "None",
            .any => "Any",
            .document => "Document",
            .page => "Page",
            .object => "Object",
            .metadata => "Metadata",
            .selection => "Selection",
            .anchor => "Anchor",
            .function => "Function",
            .style => "Style",
            .string => "String",
            .number => "Number",
            .boolean => "Bool",
            .constraints => "Constraints",
            .fragment => "Fragment",
            .code => "Code",
            .list => "List",
            .void => "Void",
        };
    }
};

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}
