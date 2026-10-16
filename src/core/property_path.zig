const std = @import("std");

// Field identifiers cannot contain dots. Canonical paths use one dot between
// segments, so prefix comparisons must check the segment boundary.
pub fn contains(parent: []const u8, child: []const u8) bool {
    return std.mem.eql(u8, parent, child) or
        (child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '.');
}

pub fn intersects(left: []const u8, right: []const u8) bool {
    return contains(left, right) or contains(right, left);
}

pub fn root(path: []const u8) []const u8 {
    return path[0 .. std.mem.indexOfScalar(u8, path, '.') orelse path.len];
}
