const std = @import("std");
const wrap = @import("render_wrap");

const testing = std.testing;

test "render PDF native wrap spec: overflowing trailing spaces do not add a phantom line" {
    const atoms = [_]wrap.Atom{
        .{ .width = 100, .advance = 100, .is_space = false },
        .{ .width = 8, .advance = 8, .is_space = true },
    };

    try testing.expectEqual(@as(usize, 1), wrap.visualLineCount(&atoms, 100, false));
}

test "render PDF native wrap spec: overflowing separator wraps the following non-space token" {
    const atoms = [_]wrap.Atom{
        .{ .width = 50, .advance = 50, .is_space = false },
        .{ .width = 15, .advance = 15, .is_space = true },
        .{ .width = 5, .advance = 5, .is_space = false },
    };

    try testing.expectEqual(@as(usize, 2), wrap.visualLineCount(&atoms, 60, false));
}
