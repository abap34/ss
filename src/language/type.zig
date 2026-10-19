const std = @import("std");
pub const SourceOrigin = @import("source_origin").Origin;

pub const SourceSpan = @import("source_origin").Span;

pub const GroupComposition = enum {
    overlay,
    horizontal,
    vertical,
    equal_horizontal,
    equal_vertical,

    pub fn isHorizontal(self: GroupComposition) bool {
        return self == .horizontal or self == .equal_horizontal;
    }

    pub fn equal(self: GroupComposition) bool {
        return self == .equal_horizontal or self == .equal_vertical;
    }
};

pub const NominalId = struct {
    module_id: u32,
    name: []const u8,

    pub fn optionalEql(a: ?NominalId, b: ?NominalId) bool {
        if ((a == null) != (b == null)) return false;
        return if (a) |id| id.eql(b.?) else true;
    }

    pub fn eql(a: NominalId, b: NominalId) bool {
        return a.module_id == b.module_id and std.mem.eql(u8, a.name, b.name);
    }
};

pub const Type = struct {
    pub fn groupMemberType(name: []const u8) ?Type {
        return if (std.mem.eql(u8, name, "gap")) Type.number else null;
    }

    kind: Kind,
    nominal_module_id: ?u32 = null,
    class_name: ?[]const u8 = null,
    class_name_span: ?SourceSpan = null,
    arguments: []const Type = &.{},
    owns_arguments: bool = false,
    enum_name: ?[]const u8 = null,
    enum_name_span: ?SourceSpan = null,
    optional_child: ?*Type = null,
    fn_params: []Type = &.{},
    fn_result: ?*Type = null,
    hole_id: ?u32 = null,
    parameter_id: ?ParameterId = null,

    pub const ParameterId = struct {
        module_id: u32,
        declaration_start: usize,
        index: u32,
    };

    pub const Kind = enum {
        none,
        any,
        document,
        page,
        unresolved,
        placed,
        group,
        placement,
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
        path,
        optional,
        hole,
        parameter,
        void,
    };

    pub const none = Type{ .kind = .none };
    pub const any = Type{ .kind = .any };
    pub const document = Type{ .kind = .document };
    pub const page = Type{ .kind = .page };
    pub const placement = Type{ .kind = .placement };
    pub const anchor = Type{ .kind = .anchor };
    pub const function = Type{ .kind = .function };
    pub const string = Type{ .kind = .string };
    pub const color = Type{ .kind = .color };
    pub const number = Type{ .kind = .number };
    pub const boolean = Type{ .kind = .boolean };
    pub const constraints = Type{ .kind = .constraints };
    pub const path = Type{ .kind = .path };

    /// A source-level name awaiting resolution in its declaration environment.
    pub fn unresolvedNameAt(name: []const u8, span: SourceSpan) Type {
        return .{ .kind = .unresolved, .class_name = name, .class_name_span = span };
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

    pub fn inModule(self: Type, module_id: u32) Type {
        std.debug.assert(self.kind == .record or self.kind == .enum_type);
        var resolved = self;
        resolved.nominal_module_id = module_id;
        return resolved;
    }

    pub fn nominalId(self: Type) ?NominalId {
        if (self.kind == .unresolved) return null;
        return .{
            .module_id = self.nominal_module_id orelse return null,
            .name = (if (self.kind == .enum_type) self.enum_name else self.class_name) orelse return null,
        };
    }

    pub fn hole(hole_id: u32) Type {
        return .{ .kind = .hole, .hole_id = hole_id };
    }

    pub fn parameter(id: ParameterId, name: []const u8, span: ?SourceSpan) Type {
        return .{ .kind = .parameter, .parameter_id = id, .class_name = name, .class_name_span = span };
    }

    pub fn optional(allocator: std.mem.Allocator, child: Type) !Type {
        const copied = try allocator.create(Type);
        errdefer allocator.destroy(copied);
        copied.* = try child.clone(allocator);
        return .{ .kind = .optional, .optional_child = copied };
    }

    pub fn selection(comptime item: Kind) Type {
        return selectionType(.{ .kind = if (item == .none) .any else item });
    }

    pub fn selectionType(comptime item: Type) Type {
        return .{ .kind = .selection, .arguments = &.{item} };
    }

    pub fn selectionOf(allocator: std.mem.Allocator, item: Type) !Type {
        return (Type{ .kind = .selection }).withArguments(allocator, &.{item});
    }

    pub fn selectionItem(self: Type) Type {
        return if (self.kind == .selection and self.arguments.len == 1) self.arguments[0] else Type.any;
    }

    pub fn placedOf(allocator: std.mem.Allocator, input: Type) !Type {
        return (Type{ .kind = .placed }).withArguments(allocator, &.{input});
    }

    pub fn placedInput(self: Type) ?Type {
        return if (self.kind == .placed and self.arguments.len == 1) self.arguments[0] else null;
    }

    pub fn mutableArguments(self: *Type) []Type {
        std.debug.assert(self.arguments.len == 0 or self.owns_arguments);
        return @constCast(self.arguments);
    }

    pub fn withArguments(self: Type, allocator: std.mem.Allocator, arguments: []const Type) !Type {
        var base = self;
        base.arguments = &.{};
        base.owns_arguments = false;
        var result = try base.clone(allocator);
        errdefer result.deinit(allocator);
        result.arguments = try cloneArguments(allocator, arguments);
        result.owns_arguments = true;
        return result;
    }

    fn cloneArguments(allocator: std.mem.Allocator, arguments: []const Type) ![]Type {
        const result = try allocator.alloc(Type, arguments.len);
        errdefer allocator.free(result);
        var initialized: usize = 0;
        errdefer for (result[0..initialized]) |*argument| argument.deinit(allocator);
        for (arguments, result) |argument, *copy| {
            copy.* = try argument.clone(allocator);
            initialized += 1;
        }
        return result;
    }

    fn deinitArguments(self: *Type, allocator: std.mem.Allocator) void {
        if (self.owns_arguments) {
            for (self.arguments) |argument| {
                var owned = argument;
                owned.deinit(allocator);
            }
            allocator.free(self.arguments);
        }
        self.arguments = &.{};
        self.owns_arguments = false;
    }

    pub fn functionType(allocator: std.mem.Allocator, params: []const Type, result: Type) anyerror!Type {
        const copied_params = try allocator.alloc(Type, params.len);
        errdefer allocator.free(copied_params);
        var initialized: usize = 0;
        errdefer for (copied_params[0..initialized]) |*param| param.deinit(allocator);
        for (params, 0..) |param, index| {
            copied_params[index] = try param.clone(allocator);
            initialized += 1;
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
        self.deinitArguments(allocator);
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
        var result = switch (self.kind) {
            .function => blk: {
                const result_type = self.fn_result orelse break :blk self;
                break :blk try functionType(allocator, self.fn_params, result_type.*);
            },
            .optional => blk: {
                const child = self.optional_child orelse break :blk self;
                break :blk try optional(allocator, child.*);
            },
            else => self,
        };
        result.arguments = &.{};
        result.owns_arguments = false;
        errdefer result.deinit(allocator);
        if (self.arguments.len != 0) {
            result.arguments = try cloneArguments(allocator, self.arguments);
            result.owns_arguments = true;
        }
        return result;
    }

    pub const Substitution = struct {
        parameter: ParameterId,
        replacement: Type,
    };

    /// Returns an independently owned type. Replacements are simultaneous:
    /// parameters inside a replacement belong to its original environment.
    pub fn substitute(self: Type, allocator: std.mem.Allocator, bindings: []const Substitution) !Type {
        var result = try self.clone(allocator);
        errdefer result.deinit(allocator);
        try result.substituteOwned(allocator, bindings);
        return result;
    }

    fn substituteOwned(self: *Type, allocator: std.mem.Allocator, bindings: []const Substitution) anyerror!void {
        if (self.kind == .parameter) {
            const id = self.parameter_id orelse return;
            for (bindings) |binding| {
                if (!std.meta.eql(id, binding.parameter)) continue;
                const replacement = try binding.replacement.clone(allocator);
                self.deinit(allocator);
                self.* = replacement;
                return;
            }
            return;
        }
        for (self.mutableArguments()) |*argument| try argument.substituteOwned(allocator, bindings);
        for (self.fn_params) |*parameter_type| try parameter_type.substituteOwned(allocator, bindings);
        if (self.fn_result) |result| try result.substituteOwned(allocator, bindings);
        if (self.optional_child) |child| try child.substituteOwned(allocator, bindings);
    }

    pub fn containsParameter(self: Type) bool {
        if (self.kind == .parameter) return true;
        for (self.arguments) |argument| if (argument.containsParameter()) return true;
        for (self.fn_params) |parameter_type| if (parameter_type.containsParameter()) return true;
        if (self.fn_result) |result| if (result.containsParameter()) return true;
        if (self.optional_child) |child| if (child.containsParameter()) return true;
        return false;
    }

    pub fn containsUnresolvedName(self: Type) bool {
        if (self.kind == .unresolved) return true;
        for (self.arguments) |argument| if (argument.containsUnresolvedName()) return true;
        for (self.fn_params) |param| if (param.containsUnresolvedName()) return true;
        if (self.fn_result) |result| if (result.containsUnresolvedName()) return true;
        if (self.optional_child) |child| if (child.containsUnresolvedName()) return true;
        return false;
    }

    pub fn eql(a: Type, b: Type) bool {
        if (a.kind != b.kind or a.arguments.len != b.arguments.len) return false;
        for (a.arguments, b.arguments) |left, right| if (!eql(left, right)) return false;
        if (a.kind == .hole) return a.hole_id == b.hole_id;
        if (a.kind == .parameter) return std.meta.eql(a.parameter_id, b.parameter_id);
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
        return a.nominal_module_id == b.nominal_module_id and
            optionalStringEql(a.class_name, b.class_name) and
            optionalStringEql(a.enum_name, b.enum_name);
    }

    pub fn accepts(expected: Type, actual: Type) bool {
        if (expected.containsUnresolvedName() or actual.containsUnresolvedName()) return false;
        return acceptsResolved(expected, actual);
    }

    fn acceptsResolved(expected: Type, actual: Type) bool {
        if (expected.kind == .hole or actual.kind == .hole) return false;
        if (expected.kind == .any or actual.kind == .any) return expected.kind != .parameter and actual.kind != .parameter;
        if (expected.kind == .optional) {
            if (actual.kind == .none) return true;
            const child = expected.optional_child orelse return false;
            if (actual.kind == .optional) {
                const actual_child = actual.optional_child orelse return false;
                return acceptsResolved(child.*, actual_child.*);
            }
            return acceptsResolved(child.*, actual);
        }
        if (actual.kind == .optional) return false;
        if (expected.kind == .placement and actual.kind == .placed) return actual.placedInput() != null;
        if (expected.kind == .parameter or actual.kind == .parameter) return eql(expected, actual);
        if (expected.kind == .color or actual.kind == .color) {
            return expected.kind == .color and actual.kind == .color;
        }
        if (expected.kind == .enum_type or actual.kind == .enum_type) {
            return expected.kind == .enum_type and
                actual.kind == .enum_type and
                expected.nominal_module_id == actual.nominal_module_id and
                eql(expected, actual);
        }
        if (expected.kind == .record or actual.kind == .record) {
            return expected.kind == .record and
                actual.kind == .record and
                expected.nominal_module_id == actual.nominal_module_id and
                eql(expected, actual);
        }
        if (expected.kind != actual.kind) return false;
        if (expected.kind == .function) {
            if (expected.fn_result == null) return true;
            if (actual.fn_result == null) return false;
            if (expected.fn_params.len != actual.fn_params.len) return false;
            for (expected.fn_params, 0..) |expected_param, index| {
                if (!acceptsResolved(actual.fn_params[index], expected_param)) return false;
            }
            return acceptsResolved(expected.fn_result.?.*, actual.fn_result.?.*);
        }
        if (expected.kind == .selection) {
            const wanted = expected.selectionItem();
            const received = actual.selectionItem();
            if (wanted.kind == .any) return true;
            if (received.kind == .any) return false;
            return acceptsResolved(wanted, received);
        }
        // Erase only a group's child tuple. Other generic arguments remain invariant.
        if (expected.kind == .group and expected.arguments.len == 0) return true;
        if (expected.kind == .placed) {
            const wanted = expected.placedInput() orelse return false;
            const received = actual.placedInput() orelse return false;
            return if (wanted.kind == .group and received.kind == .group) acceptsResolved(wanted, received) else eql(wanted, received);
        }
        if (expected.arguments.len != actual.arguments.len) return false;
        for (expected.arguments, actual.arguments) |left, right| if (!eql(left, right)) return false;
        return true;
    }

    pub fn hashInto(self: Type, hasher: *std.hash.Wyhash) void {
        std.hash.autoHash(hasher, self.kind);
        std.hash.autoHash(hasher, self.arguments.len);
        for (self.arguments) |argument| argument.hashInto(hasher);
        switch (self.kind) {
            .hole => std.hash.autoHash(hasher, self.hole_id),
            .parameter => std.hash.autoHash(hasher, self.parameter_id),
            .function => {
                std.hash.autoHash(hasher, self.fn_params.len);
                for (self.fn_params) |param| param.hashInto(hasher);
                std.hash.autoHash(hasher, self.fn_result != null);
                if (self.fn_result) |result| result.hashInto(hasher);
            },
            .optional => {
                std.hash.autoHash(hasher, self.optional_child != null);
                if (self.optional_child) |child| child.hashInto(hasher);
            },
            else => {
                std.hash.autoHash(hasher, self.nominal_module_id);
                hashName(hasher, self.class_name);
                hashName(hasher, self.enum_name);
            },
        }
    }

    fn hashName(hasher: *std.hash.Wyhash, name: ?[]const u8) void {
        std.hash.autoHash(hasher, name != null);
        if (name) |text| {
            std.hash.autoHash(hasher, text.len);
            hasher.update(text);
        }
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
                try self.selectionItem().formatInto(allocator, out);
                try out.append(allocator, '>');
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
            .record, .parameter, .unresolved => if (self.class_name) |name|
                try out.appendSlice(allocator, name)
            else
                try out.appendSlice(allocator, displayName(self.kind)),
            .hole => try out.appendSlice(allocator, displayName(self.kind)),
            else => try out.appendSlice(allocator, displayName(self.kind)),
        }
        if (self.kind != .selection and self.arguments.len != 0) {
            try out.append(allocator, '<');
            for (self.arguments, 0..) |argument, index| {
                if (index > 0) try out.appendSlice(allocator, ", ");
                try argument.formatInto(allocator, out);
            }
            try out.append(allocator, '>');
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
            .unresolved => "UnresolvedType",
            .placed => "Placed",
            .group => "Group",
            .placement => "Placement",
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
            .path => "Path",
            .optional => "Optional",
            .hole => "HoleType",
            .parameter => "TypeParameter",
            .void => "Void",
        };
    }
};

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}
