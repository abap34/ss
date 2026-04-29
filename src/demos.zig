const std = @import("std");
const core = @import("core");

const default_demo = @import("demo_default");

pub const Demo = struct {
    name: []const u8,
    buildFn: *const fn (*core.Engine) anyerror!void,
};

pub const all = [_]Demo{
    .{
        .name = default_demo.name,
        .buildFn = default_demo.build,
    },
};

pub fn find(name: []const u8) ?Demo {
    for (all) |demo| {
        if (std.mem.eql(u8, demo.name, name)) return demo;
    }
    return null;
}
