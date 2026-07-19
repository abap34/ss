const std = @import("std");

pub const Point = struct {
    x: f32,
    y: f32,

    pub fn isFinite(self: Point) bool {
        return std.math.isFinite(self.x) and std.math.isFinite(self.y);
    }
};

pub const Cubic = struct {
    control1: Point,
    control2: Point,
    end: Point,

    pub fn isFinite(self: Cubic) bool {
        return self.control1.isFinite() and self.control2.isFinite() and self.end.isFinite();
    }
};

pub const Command = union(enum) {
    move_to: Point,
    line_to: Point,
    cubic_to: Cubic,
    close: void,

    pub fn isFinite(self: Command) bool {
        return switch (self) {
            .move_to, .line_to => |point| point.isFinite(),
            .cubic_to => |cubic| cubic.isFinite(),
            .close => true,
        };
    }
};

pub const Path = struct {
    commands: []Command,

    pub fn init(commands: []Command) Path {
        return .{ .commands = commands };
    }

    pub fn deinit(self: *Path, allocator: std.mem.Allocator) void {
        allocator.free(self.commands);
        self.commands = &.{};
    }

    pub fn clone(self: Path, allocator: std.mem.Allocator) !Path {
        return .{ .commands = try allocator.dupe(Command, self.commands) };
    }
};
