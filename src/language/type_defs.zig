const std = @import("std");

pub fn enumCasesContain(cases: anytype, expected: []const u8) bool {
    for (cases) |case_decl| {
        if (std.mem.eql(u8, case_decl.name, expected)) return true;
    }
    return false;
}

pub fn duplicateEnumCase(allocator: std.mem.Allocator, cases: anytype) !?[]const u8 {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (cases) |case_decl| {
        const case_name = case_decl.name;
        if (seen.contains(case_name)) return case_name;
        try seen.put(case_name, {});
    }
    return null;
}

pub fn enumCasesLabel(allocator: std.mem.Allocator, cases: anytype) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (cases) |case_decl| {
        if (out.items.len != 0) try out.appendSlice(allocator, " | ");
        try out.appendSlice(allocator, case_decl.name);
    }
    return try out.toOwnedSlice(allocator);
}
