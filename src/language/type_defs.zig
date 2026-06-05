const std = @import("std");

pub fn enumCasesContain(cases: []const []const u8, expected: []const u8) bool {
    for (cases) |case_name| {
        if (std.mem.eql(u8, case_name, expected)) return true;
    }
    return false;
}

pub fn duplicateEnumCase(allocator: std.mem.Allocator, cases: []const []const u8) !?[]const u8 {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (cases) |case_name| {
        if (seen.contains(case_name)) return case_name;
        try seen.put(case_name, {});
    }
    return null;
}

pub fn enumCasesLabel(allocator: std.mem.Allocator, cases: []const []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (cases) |case_name| {
        if (out.items.len != 0) try out.appendSlice(allocator, " | ");
        try out.appendSlice(allocator, case_name);
    }
    return try out.toOwnedSlice(allocator);
}
