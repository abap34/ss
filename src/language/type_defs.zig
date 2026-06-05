const std = @import("std");

pub const EnumCaseIterator = struct {
    body: []const u8,
    pos: usize = 0,
    valid: bool = true,
    needs_case: bool = false,

    pub fn init(body: []const u8) EnumCaseIterator {
        return .{ .body = std.mem.trim(u8, body, " \t\r\n") };
    }

    pub fn next(self: *EnumCaseIterator) ?[]const u8 {
        self.skipSpaces();
        if (self.pos >= self.body.len) {
            if (self.needs_case) self.valid = false;
            return null;
        }
        const start = self.pos;
        if (!isIdentifierStart(self.body[self.pos])) {
            self.valid = false;
            return null;
        }
        self.needs_case = false;
        self.pos += 1;
        while (self.pos < self.body.len and isIdentifierContinue(self.body[self.pos])) : (self.pos += 1) {}
        const name = self.body[start..self.pos];
        self.skipSpaces();
        if (self.pos < self.body.len) {
            if (self.body[self.pos] != '|') {
                self.valid = false;
                return name;
            }
            self.pos += 1;
            self.needs_case = true;
        }
        return name;
    }

    pub fn atEnd(self: *EnumCaseIterator) bool {
        self.skipSpaces();
        return self.pos >= self.body.len;
    }

    fn skipSpaces(self: *EnumCaseIterator) void {
        while (self.pos < self.body.len and std.ascii.isWhitespace(self.body[self.pos])) : (self.pos += 1) {}
    }
};

pub fn isEnumBody(body: []const u8) bool {
    var iter = EnumCaseIterator.init(body);
    var count: usize = 0;
    while (iter.next()) |_| count += 1;
    return count > 0 and iter.valid and iter.atEnd();
}

pub fn enumContains(body: []const u8, expected: []const u8) bool {
    var iter = EnumCaseIterator.init(body);
    var found = false;
    while (iter.next()) |case_name| {
        if (std.mem.eql(u8, case_name, expected)) found = true;
    }
    return found and iter.valid and iter.atEnd();
}

pub fn duplicateEnumCase(allocator: std.mem.Allocator, body: []const u8) !?[]const u8 {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var iter = EnumCaseIterator.init(body);
    while (iter.next()) |case_name| {
        if (seen.contains(case_name)) return case_name;
        try seen.put(case_name, {});
    }
    return null;
}

pub fn enumLabel(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var iter = EnumCaseIterator.init(body);
    while (iter.next()) |case_name| {
        if (out.items.len != 0) try out.appendSlice(allocator, " | ");
        try out.appendSlice(allocator, case_name);
    }
    return try out.toOwnedSlice(allocator);
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentifierContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}
