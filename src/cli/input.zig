const std = @import("std");

/// Consume a whole line, including any excess bytes, so the next prompt starts cleanly.
pub fn readLine(buffer: []u8) ![]const u8 {
    var len: usize = 0;
    var too_long = false;
    while (true) {
        var byte: [1]u8 = undefined;
        const n = std.c.read(0, &byte, 1);
        if (n < 0) return error.ReadFailed;
        if (n == 0) {
            if (len == 0) return error.EndOfStream;
            break;
        }
        if (byte[0] == '\n') break;
        if (len < buffer.len) {
            buffer[len] = byte[0];
            len += 1;
        } else too_long = true;
    }
    if (too_long) return error.InputTooLong;
    return buffer[0..len];
}
