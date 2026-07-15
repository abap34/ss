const std = @import("std");

pub const CoordinateSpace = struct {
    pub const unit = "pt";
    pub const origin = "page-top-left";
    pub const x_axis = "right";
    pub const y_axis = "down";
};

pub const Point = struct {
    x: f64,
    y: f64,
};

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn isValid(self: Rect) bool {
        return std.math.isFinite(self.x) and
            std.math.isFinite(self.y) and
            std.math.isFinite(self.width) and
            std.math.isFinite(self.height) and
            self.width >= 0 and self.height >= 0;
    }

    pub fn unioned(self: Rect, other: Rect) Rect {
        const left = @min(self.x, other.x);
        const top = @min(self.y, other.y);
        const right = @max(self.x + self.width, other.x + other.width);
        const bottom = @max(self.y + self.height, other.y + other.height);
        return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    }
};

pub const Transform = struct {
    xx: f64 = 1,
    yx: f64 = 0,
    xy: f64 = 0,
    yy: f64 = 1,
    x0: f64 = 0,
    y0: f64 = 0,

    pub fn isFinite(self: Transform) bool {
        return std.math.isFinite(self.xx) and
            std.math.isFinite(self.yx) and
            std.math.isFinite(self.xy) and
            std.math.isFinite(self.yy) and
            std.math.isFinite(self.x0) and
            std.math.isFinite(self.y0);
    }
};

pub const Clip = union(enum) {
    rect: Rect,
};
