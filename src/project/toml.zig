const std = @import("std");
const source = @import("utils").source;
const c = @cImport({
    @cInclude("tomlc17.h");
});

pub const Value = c.toml_datum_t;

pub const Diagnostic = struct {
    span: ?source.ByteSpan = null,
    detail: [200]u8 = @splat(0),

    pub fn message(self: *const Diagnostic) []const u8 {
        return std.mem.sliceTo(&self.detail, 0);
    }
};

pub const Document = struct {
    parsed: c.toml_result_t,
    text: []const u8,
    diagnostic: ?*Diagnostic,

    pub fn parse(text: []const u8, diagnostic: ?*Diagnostic) !Document {
        if (diagnostic) |value| value.* = .{};
        if (text.len > std.math.maxInt(c_int)) return error.InvalidToml;
        // Avoid changing the parser's process-global options during concurrent loads.
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidToml;
        const parsed = c.toml_parse(text.ptr, @intCast(text.len));
        if (!parsed.ok) {
            defer c.toml_free(parsed);
            const message = std.mem.sliceTo(&parsed.errmsg, 0);
            if (std.mem.indexOf(u8, message, "out of memory") != null) return error.OutOfMemory;
            if (diagnostic) |value| {
                @memcpy(value.detail[0..message.len], message);
                if (std.mem.indexOf(u8, message, "line ")) |start| {
                    const digits = message[start + 5 ..];
                    const end = for (digits, 0..) |byte, i| {
                        if (!std.ascii.isDigit(byte)) break i;
                    } else digits.len;
                    const line = std.fmt.parseUnsigned(usize, digits[0..end], 10) catch 0;
                    value.span = lineSpan(text, line);
                }
            }
            return error.InvalidToml;
        }
        return .{ .parsed = parsed, .text = text, .diagnostic = diagnostic };
    }

    pub fn deinit(self: *Document) void {
        c.toml_free(self.parsed);
        self.* = undefined;
    }

    pub fn root(self: *const Document) Value {
        return self.parsed.toptab;
    }

    pub fn fail(self: *const Document, value: Value, err: anyerror) anyerror {
        if (self.diagnostic) |diagnostic| diagnostic.span = self.span(value);
        return err;
    }

    pub fn span(self: *const Document, value: Value) ?source.ByteSpan {
        return lineSpan(self.text, @intCast(@max(value.lineno, 0)));
    }

    pub fn table(self: *const Document, parent: Value, key: []const u8) !Value {
        const value = get(parent, key);
        if (value.type != c.TOML_UNKNOWN and value.type != c.TOML_TABLE)
            return self.fail(value, error.InvalidConfigTable);
        return value;
    }

    pub fn keys(self: *const Document, table_value: Value, allowed: []const []const u8, err: anyerror) !void {
        if (table_value.type != c.TOML_TABLE) return;
        for (0..@intCast(table_value.u.tab.size)) |i| {
            const name = keyAt(table_value, i);
            for (allowed) |key| {
                if (std.mem.eql(u8, name, key)) break;
            } else return self.fail(table_value.u.tab.value[i], err);
        }
    }

    pub fn string(self: *const Document, parent: Value, key: []const u8, err: anyerror) !?[]const u8 {
        const value = get(parent, key);
        if (value.type == c.TOML_UNKNOWN) return null;
        if (value.type != c.TOML_STRING) return self.fail(value, err);
        return value.u.str.ptr[0..@intCast(value.u.str.len)];
    }

    pub fn boolean(self: *const Document, parent: Value, key: []const u8, default: bool, err: anyerror) !bool {
        const value = get(parent, key);
        if (value.type == c.TOML_UNKNOWN) return default;
        if (value.type != c.TOML_BOOLEAN) return self.fail(value, err);
        return value.u.boolean;
    }

    pub fn integer(self: *const Document, parent: Value, key: []const u8, default: ?u64, min: u64, max: u64, err: anyerror) !?u64 {
        const value = get(parent, key);
        if (value.type == c.TOML_UNKNOWN) return default;
        if (value.type != c.TOML_INT64 or value.u.int64 < 0) return self.fail(value, err);
        const integer_value: u64 = @intCast(value.u.int64);
        if (integer_value < min or integer_value > max) return self.fail(value, err);
        return integer_value;
    }
};

pub fn get(table: Value, key: []const u8) Value {
    if (table.type == c.TOML_TABLE) {
        for (0..@intCast(table.u.tab.size)) |i| {
            if (std.mem.eql(u8, key, keyAt(table, i))) return table.u.tab.value[i];
        }
    }
    return std.mem.zeroes(Value);
}

pub fn keyAt(table: Value, index: usize) []const u8 {
    return table.u.tab.key[index][0..@intCast(table.u.tab.len[index])];
}

pub fn tableSize(table: Value) usize {
    return if (table.type == c.TOML_TABLE) @intCast(table.u.tab.size) else 0;
}

fn lineSpan(text: []const u8, number: usize) ?source.ByteSpan {
    const line = source.lineByNumber(text, number) orelse return null;
    return source.trimInlineSpaceSpan(text, line.span);
}
