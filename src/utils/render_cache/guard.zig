const std = @import("std");

pub const path = ".ss-cache/render";

pub fn open(io: std.Io, lock: std.Io.File.Lock, nonblocking: bool) !std.Io.File {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, ".ss-cache");
    return cwd.createFile(io, ".ss-cache/render.lock", .{
        .read = true,
        .truncate = false,
        .lock = lock,
        .lock_nonblocking = nonblocking,
    });
}
