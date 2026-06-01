const std = @import("std");
const core = @import("core");
const color_utils = @import("utils").color;

pub const ValueType = struct {
    kind: Kind,
    body: []const u8 = "",

    pub const Kind = enum {
        string,
        style,
        scalar_like,
        color_string,
        string_literals,
    };
};

pub fn resolve(ir: *const core.Ir, module_id: core.SourceModuleId, name: []const u8) ?ValueType {
    if (parse(name)) |value_type| return value_type;
    if (infer("", name)) |value_type| return value_type;
    return resolveDeclared(ir, module_id, name);
}

pub fn resolveDeclared(ir: *const core.Ir, module_id: core.SourceModuleId, name: []const u8) ?ValueType {
    if (resolveInModule(ir, module_id, name)) |value_type| return value_type;
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const current_id = ir.module_order.items[index];
        if (current_id == module_id) continue;
        if (resolveInModule(ir, current_id, name)) |value_type| return value_type;
    }
    return null;
}

fn resolveInModule(ir: *const core.Ir, module_id: core.SourceModuleId, name: []const u8) ?ValueType {
    const module = ir.moduleById(module_id) orelse return null;
    return resolveInProgram(module.program, name);
}

fn resolveInProgram(program: anytype, name: []const u8) ?ValueType {
    for (program.types.items) |decl| {
        if (!std.mem.eql(u8, decl.name, name)) continue;
        return resolveDeclaration(decl.name, decl.body);
    }
    return null;
}

pub fn parse(name: []const u8) ?ValueType {
    if (std.mem.eql(u8, name, "string")) return .{ .kind = .string };
    if (std.mem.eql(u8, name, "style")) return .{ .kind = .style };
    if (std.mem.eql(u8, name, "scalar_like")) return .{ .kind = .scalar_like };
    if (std.mem.eql(u8, name, "color_string")) return .{ .kind = .color_string };
    if (std.mem.eql(u8, name, "string_literals")) return .{ .kind = .string_literals };
    return null;
}

pub fn resolveDeclaration(name: []const u8, body: []const u8) ?ValueType {
    return infer(name, body);
}

fn infer(name: []const u8, body: []const u8) ?ValueType {
    if (std.mem.eql(u8, body, "String")) {
        if (std.mem.eql(u8, name, "Color")) return .{ .kind = .color_string, .body = body };
        return .{ .kind = .string, .body = body };
    }
    if (std.mem.eql(u8, body, "Style")) return .{ .kind = .style, .body = body };
    if (std.mem.eql(u8, body, "String | Number")) return .{ .kind = .scalar_like, .body = body };
    if (isStringLiteralUnion(body)) return .{ .kind = .string_literals, .body = body };
    return parse(body);
}

pub fn matches(kind: ValueType, string_literal: ?[]const u8, value_tag: core.ValueTag) bool {
    return switch (kind.kind) {
        .string => value_tag == .string,
        .style => value_tag == .style or value_tag == .string,
        .scalar_like => value_tag == .string or value_tag == .number,
        .color_string => if (string_literal) |text| text.len == 0 or color_utils.parse(text) != null else value_tag == .string,
        .string_literals => if (string_literal) |text|
            stringLiteralUnionContains(kind.body, text)
        else
            value_tag == .string,
    };
}

pub fn label(kind: ValueType) []const u8 {
    return switch (kind.kind) {
        .string => "String",
        .style => "Style",
        .scalar_like => "String or Number",
        .color_string => "color string",
        .string_literals => kind.body,
    };
}

pub fn runtimeValueTag(kind: ValueType) ?core.ValueTag {
    return switch (kind.kind) {
        .string, .color_string, .string_literals => .string,
        .style => .style,
        .scalar_like => null,
    };
}

pub fn nameMatches(ir: *const core.Ir, module_id: core.SourceModuleId, name: []const u8, string_literal: ?[]const u8, value_tag: core.ValueTag) bool {
    const value_type = resolve(ir, module_id, name) orelse return false;
    return matches(value_type, string_literal, value_tag);
}

pub fn nameLabel(ir: *const core.Ir, module_id: core.SourceModuleId, name: []const u8) []const u8 {
    const value_type = resolve(ir, module_id, name) orelse return "known value type";
    return label(value_type);
}

fn isStringLiteralUnion(body: []const u8) bool {
    var scanner = StringLiteralUnionScanner.init(body);
    var count: usize = 0;
    while (scanner.next()) |_| count += 1;
    return count > 0 and scanner.valid and scanner.atEnd();
}

fn stringLiteralUnionContains(body: []const u8, expected: []const u8) bool {
    var scanner = StringLiteralUnionScanner.init(body);
    while (scanner.next()) |literal| {
        if (std.mem.eql(u8, literal, expected)) return true;
    }
    return false;
}

const StringLiteralUnionScanner = struct {
    body: []const u8,
    pos: usize = 0,
    valid: bool = true,

    fn init(body: []const u8) StringLiteralUnionScanner {
        return .{ .body = std.mem.trim(u8, body, " \t\r\n") };
    }

    fn next(self: *StringLiteralUnionScanner) ?[]const u8 {
        self.skipSpaces();
        if (self.pos >= self.body.len) return null;
        if (self.body[self.pos] != '"') {
            self.valid = false;
            return null;
        }
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.body.len and self.body[self.pos] != '"') : (self.pos += 1) {}
        if (self.pos >= self.body.len) {
            self.valid = false;
            return null;
        }
        const literal = self.body[start..self.pos];
        self.pos += 1;
        self.skipSpaces();
        if (self.pos < self.body.len) {
            if (self.body[self.pos] != '|') {
                self.valid = false;
                return literal;
            }
            self.pos += 1;
        }
        return literal;
    }

    fn atEnd(self: *StringLiteralUnionScanner) bool {
        self.skipSpaces();
        return self.pos >= self.body.len;
    }

    fn skipSpaces(self: *StringLiteralUnionScanner) void {
        while (self.pos < self.body.len and std.ascii.isWhitespace(self.body[self.pos])) : (self.pos += 1) {}
    }
};
