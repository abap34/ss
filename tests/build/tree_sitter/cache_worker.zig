const std = @import("std");
const cache = @import("utils").tree_sitter_cache;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArguments;
    if (std.mem.eql(u8, args[1], "clear")) {
        try cache.clear(init.io, allocator, args[2]);
    } else if (std.mem.eql(u8, args[1], "prune")) {
        _ = try cache.prune(init.io, allocator, args[2], "unused");
    } else {
        return error.InvalidArguments;
    }
}
