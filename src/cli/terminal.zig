const std = @import("std");
const error_report = @import("utils").err;

pub const Output = enum { stdout, stderr };

pub fn useColor(output: Output) bool {
    return switch (error_report.colorMode()) {
        .auto => std.c.getenv("NO_COLOR") == null and !envEquals("CLICOLOR", "0") and outputIsTty(output),
        .always => true,
        .never => false,
    };
}

fn outputIsTty(output: Output) bool {
    const fd: c_int = switch (output) {
        .stdout => 1,
        .stderr => 2,
    };
    return std.c.isatty(fd) == 1;
}

fn envEquals(name: [:0]const u8, expected: []const u8) bool {
    const value = std.c.getenv(name) orelse return false;
    return std.mem.eql(u8, std.mem.span(value), expected);
}
