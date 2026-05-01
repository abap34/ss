const std = @import("std");

pub fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

pub fn isIdentifierContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

pub fn skipTriviaFrom(source: []const u8, pos: *usize) void {
    while (pos.* < source.len) {
        switch (source[pos.*]) {
            ' ', '\t', '\r', '\n' => pos.* += 1,
            '/' => {
                if (pos.* + 1 < source.len and source[pos.* + 1] == '/') {
                    pos.* += 2;
                    while (pos.* < source.len and source[pos.*] != '\n') pos.* += 1;
                } else return;
            },
            ';' => {
                if (pos.* + 1 < source.len and source[pos.* + 1] == ';') {
                    pos.* += 2;
                    while (pos.* < source.len and source[pos.*] != '\n') pos.* += 1;
                } else return;
            },
            '#' => {
                while (pos.* < source.len and source[pos.*] != '\n') pos.* += 1;
            },
            else => return,
        }
    }
}
