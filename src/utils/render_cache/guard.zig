const std = @import("std");

pub const path = ".ss-cache/render";

pub fn open(io: std.Io, lock: std.Io.File.Lock, nonblocking: bool) !std.Io.File {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, std.fs.path.dirname(path) orelse ".");
    return cwd.createFile(io, path ++ ".lock", .{
        .read = true,
        .truncate = false,
        .lock = lock,
        .lock_nonblocking = nonblocking,
    });
}
