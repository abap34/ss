const std = @import("std");

pub const SourceSpan = struct {
    start: usize,
    end: usize,
};

pub const Type = struct {
    kind: Kind,
    param: Kind = .none,
    class_name: ?[]const u8 = null,
    class_name_span: ?SourceSpan = null,
    param_class_name: ?[]const u8 = null,
    param_class_name_span: ?SourceSpan = null,
    enum_name: ?[]const u8 = null,
    enum_name_span: ?SourceSpan = null,
    optional_child: ?*Type = null,
    fn_params: []Type = &.{},
    fn_result: ?*Type = null,
    hole_id: ?u32 = null,

    pub const Kind = enum {
        none,
        any,
        document,
        page,
        object,
        selection,
        anchor,
        function,
        string,
        color,
        number,
        boolean,
        constraints,
        enum_type,
        record,
        optional,
        hole,
        void,
    };

    pub const none = Type{ .kind = .none };
    pub const any = Type{ .kind = .any };
    pub const document = Type{ .kind = .document };
    pub const page = Type{ .kind = .page };
    pub const object = Type{ .kind = .object };
    pub const anchor = Type{ .kind = .anchor };
    pub const function = Type{ .kind = .function };
    pub const string = Type{ .kind = .string };
    pub const color = Type{ .kind = .color };
    pub const number = Type{ .kind = .number };
    pub const boolean = Type{ .kind = .boolean };
    pub const constraints = Type{ .kind = .constraints };

    pub fn objectClass(name: []const u8) Type {
        return .{ .kind = .object, .class_name = name };
    }

    pub fn objectClassAt(name: []const u8, span: SourceSpan) Type {
        return .{ .kind = .object, .class_name = name, .class_name_span = span };
    }

    pub fn enumType(name: []const u8) Type {
        return .{ .kind = .enum_type, .enum_name = name };
    }

    pub fn enumTypeAt(name: []const u8, span: SourceSpan) Type {
        return .{ .kind = .enum_type, .enum_name = name, .enum_name_span = span };
    }

    pub fn recordType(name: []const u8) Type {
        return .{ .kind = .record, .class_name = name };
    }

    pub fn recordTypeAt(name: []const u8, span: SourceSpan) Type {
        return .{ .kind = .record, .class_name = name, .class_name_span = span };
    }

    pub fn hole(hole_id: u32) Type {
        return .{ .kind = .hole, .hole_id = hole_id };
    }

    pub fn optional(allocator: std.mem.Allocator, child: Type) !Type {
        const copied = try allocator.create(Type);
        errdefer allocator.destroy(copied);
        copied.* = try child.clone(allocator);
        return .{ .kind = .optional, .optional_child = copied };
    }

    pub fn selection(item: Kind) Type {
        return .{ .kind = .selection, .param = normalizeParam(item) };
    }

    pub fn selectionType(item: Type) Type {
        return .{
            .kind = .selection,
            .param = normalizeParam(item.kind),
            .param_class_name = if (item.kind == .object) item.class_name else null,
            .param_class_name_span = if (item.kind == .object) item.class_name_span else null,
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
            .kind = .function,
            .fn_params = copied_params,
            .fn_result = copied_result,
        };
    }

    pub fn deinit(self: *Type, allocator: std.mem.Allocator) void {
        switch (self.kind) {
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
        return switch (self.kind) {
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

    fn normalizeParam(param: Kind) Kind {
        return if (param == .none) .any else param;
    }

    pub fn eql(a: Type, b: Type) bool {
        if (a.kind != b.kind) return false;
        if (a.kind == .hole) return a.hole_id == b.hole_id;
        if (a.kind == .function) {
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
        if (a.kind == .optional) {
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
        if (expected.kind == .hole or actual.kind == .hole) return false;
        if (expected.kind == .any or actual.kind == .any) return true;
        if (expected.kind == .optional) {
            if (actual.kind == .none) return true;
            const child = expected.optional_child orelse return false;
            if (actual.kind == .optional) {
                const actual_child = actual.optional_child orelse return false;
                return accepts(child.*, actual_child.*);
            }
            return accepts(child.*, actual);
        }
        if (actual.kind == .optional) return false;
        if (expected.kind == .color or actual.kind == .color) {
            return expected.kind == .color and actual.kind == .color;
        }
        if (expected.kind == .enum_type or actual.kind == .enum_type) {
            return expected.kind == .enum_type and
                actual.kind == .enum_type and
                optionalStringEql(expected.enum_name, actual.enum_name);
        }
        if (expected.kind == .record or actual.kind == .record) {
            return expected.kind == .record and
                actual.kind == .record and
                optionalStringEql(expected.class_name, actual.class_name);
        }
        if (expected.kind != actual.kind) return false;
        if (expected.kind == .function) {
            if (expected.fn_result == null) return true;
            if (actual.fn_result == null) return false;
            if (expected.fn_params.len != actual.fn_params.len) return false;
            for (expected.fn_params, 0..) |expected_param, index| {
                if (!accepts(expected_param, actual.fn_params[index])) return false;
            }
            return accepts(expected.fn_result.?.*, actual.fn_result.?.*);
        }
        if (expected.kind == .object and expected.class_name != null and actual.class_name != null) {
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

    pub fn formatAlloc(self: Type, allocator: std.mem.Allocator) ![]const u8 {
        var text = std.ArrayList(u8).empty;
        errdefer text.deinit(allocator);
        try self.formatInto(allocator, &text);
        return text.toOwnedSlice(allocator);
    }

    pub fn formatInto(self: Type, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        switch (self.kind) {
            .selection => {
                try out.appendSlice(allocator, displayName(self.kind));
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
                    const needs_parens = param.kind == .function;
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
                    const needs_parens = child.kind == .function;
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
                try out.appendSlice(allocator, displayName(self.kind)),
            .record => if (self.class_name) |name|
                try out.appendSlice(allocator, name)
            else
                try out.appendSlice(allocator, displayName(self.kind)),
            .hole => try out.appendSlice(allocator, displayName(self.kind)),
            else => try out.appendSlice(allocator, displayName(self.kind)),
        }
    }

    pub fn label(self: Type) []const u8 {
        return displayName(self.kind);
    }

    fn displayName(kind: Kind) []const u8 {
        return switch (kind) {
            .none => "None",
            .any => "Any",
            .document => "Document",
            .page => "Page",
            .object => "Object",
            .selection => "Selection",
            .anchor => "Anchor",
            .function => "Function",
            .string => "String",
            .color => "Color",
            .number => "Number",
            .boolean => "Bool",
            .constraints => "Constraints",
            .enum_type => "Enum",
            .record => "Record",
            .optional => "Optional",
            .hole => "HoleType",
            .void => "Void",
        };
    }
};

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}
