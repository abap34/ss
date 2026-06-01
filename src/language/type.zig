const std = @import("std");
const model = @import("model");

pub const Type = struct {
    tag: Tag,
    param: Tag = .none,
    class_name: ?[]const u8 = null,
    param_class_name: ?[]const u8 = null,
    enum_name: ?[]const u8 = null,
    optional_child: ?*Type = null,
    fn_params: []Type = &.{},
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
        color,
        number,
        boolean,
        constraints,
        enum_type,
        optional,
        void,
    };

    pub const none = Type{ .tag = .none };
    pub const any = Type{ .tag = .any };
    pub const document = Type{ .tag = .document };
    pub const page = Type{ .tag = .page };
    pub const object = Type{ .tag = .object };
    pub const metadata = Type{ .tag = .metadata };
    pub const anchor = Type{ .tag = .anchor };
    pub const style = Type{ .tag = .style };
    pub const string = Type{ .tag = .string };
    pub const color = Type{ .tag = .color };
    pub const number = Type{ .tag = .number };
    pub const boolean = Type{ .tag = .boolean };
    pub const constraints = Type{ .tag = .constraints };

    pub fn objectClass(name: []const u8) Type {
        return .{ .tag = .object, .class_name = name };
    }

    pub fn enumType(name: []const u8) Type {
        return .{ .tag = .enum_type, .enum_name = name };
    }

    pub fn optional(allocator: std.mem.Allocator, child: Type) !Type {
        const copied = try allocator.create(Type);
        errdefer allocator.destroy(copied);
        copied.* = try child.clone(allocator);
        return .{ .tag = .optional, .optional_child = copied };
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
        switch (self.tag) {
            .function => {
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
            },
            .optional => {
                if (self.optional_child) |child| {
                    child.deinit(allocator);
                    allocator.destroy(child);
                }
                self.optional_child = null;
            },
            else => {},
        }
    }

    pub fn clone(self: Type, allocator: std.mem.Allocator) anyerror!Type {
        return switch (self.tag) {
            .function => blk: {
                const result = self.fn_result orelse break :blk self;
                break :blk try functionType(allocator, self.fn_params, result.*);
            },
            .optional => blk: {
                const child = self.optional_child orelse break :blk self;
                break :blk try optional(allocator, child.*);
            },
            else => self,
        };
    }

    fn normalizeParam(param: Tag) Tag {
        return if (param == .none) .any else param;
    }

    pub fn fromValueTag(tag: model.ValueTag) Type {
        return switch (tag) {
            .none => .none,
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
            .void => .{ .tag = .void },
        };
    }

    pub fn toValueTag(self: Type) ?model.ValueTag {
        return switch (self.tag) {
            .none => .none,
            .document => .document,
            .page => .page,
            .object => .object,
            .metadata => .metadata,
            .selection => .selection,
            .anchor => .anchor,
            .function => .function,
            .style => .style,
            .string => .string,
            .color => .string,
            .number => .number,
            .boolean => .boolean,
            .constraints => .constraints,
            .enum_type => .string,
            .void => .void,
            .optional, .any => null,
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
        if (a.tag == .optional) {
            if ((a.optional_child == null) != (b.optional_child == null)) return false;
            if (a.optional_child) |a_child| {
                const b_child = b.optional_child orelse return false;
                return eql(a_child.*, b_child.*);
            }
            return true;
        }
        return normalizeParam(a.param) == normalizeParam(b.param) and
            optionalStringEql(a.class_name, b.class_name) and
            optionalStringEql(a.param_class_name, b.param_class_name) and
            optionalStringEql(a.enum_name, b.enum_name);
    }

    pub fn accepts(expected: Type, actual: Type) bool {
        if (expected.tag == .any or actual.tag == .any) return true;
        if (expected.tag == .optional) {
            if (actual.tag == .none) return true;
            const child = expected.optional_child orelse return false;
            if (actual.tag == .optional) {
                const actual_child = actual.optional_child orelse return false;
                return accepts(child.*, actual_child.*);
            }
            return accepts(child.*, actual);
        }
        if (actual.tag == .optional) return false;
        if (expected.tag == .color or actual.tag == .color) {
            return expected.tag == .color and actual.tag == .color;
        }
        if (expected.tag == .enum_type or actual.tag == .enum_type) {
            return expected.tag == .enum_type and
                actual.tag == .enum_type and
                optionalStringEql(expected.enum_name, actual.enum_name);
        }
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
            .none => .none,
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
            .selection => {
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
            .optional => {
                if (self.optional_child) |child| {
                    const needs_parens = child.tag == .function;
                    if (needs_parens) try out.append(allocator, '(');
                    try child.formatInto(allocator, out);
                    if (needs_parens) try out.append(allocator, ')');
                } else {
                    try out.appendSlice(allocator, "Any");
                }
                try out.append(allocator, '?');
            },
            .enum_type => if (self.enum_name) |name|
                try out.appendSlice(allocator, name)
            else
                try out.appendSlice(allocator, displayName(self.tag)),
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
            .color => "Color",
            .number => "Number",
            .boolean => "Bool",
            .constraints => "Constraints",
            .enum_type => "Enum",
            .optional => "Optional",
            .void => "Void",
        };
    }
};

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}
