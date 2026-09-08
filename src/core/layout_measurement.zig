const std = @import("std");

/// Coordinates are relative to the object's top-left corner, with y increasing downwards.
pub const Bounds = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn isValid(self: Bounds) bool {
        return std.math.isFinite(self.x) and std.math.isFinite(self.y) and
            std.math.isFinite(self.width) and std.math.isFinite(self.height) and
            self.width >= 0 and self.height >= 0;
    }

    pub fn inFrame(self: Bounds, frame: anytype) @TypeOf(frame) {
        return .{
            .x = frame.x + self.x,
            .y = frame.y + frame.height - self.y - self.height,
            .width = self.width,
            .height = self.height,
            .x_set = frame.x_set,
            .y_set = frame.y_set,
        };
    }

    pub fn expandFrame(frame: anytype, pad_x: f32, pad_y: f32, ink: ?Bounds) @TypeOf(frame) {
        var left = frame.x + pad_x;
        var right = left + @max(frame.width - pad_x * 2, 1);
        var bottom = frame.y + pad_y;
        var top = bottom + @max(frame.height - pad_y * 2, 1);
        if (ink) |bounds| {
            if (bounds.width > 0 and bounds.height > 0) {
                const visual = bounds.inFrame(frame);
                left = @min(left, visual.x);
                right = @max(right, visual.x + visual.width);
                bottom = @min(bottom, visual.y);
                top = @max(top, visual.y + visual.height);
            }
        }
        return .{
            .x = left - pad_x,
            .y = bottom - pad_y,
            .width = @max(right - left, 1) + pad_x * 2,
            .height = @max(top - bottom, 1) + pad_y * 2,
            .x_set = frame.x_set,
            .y_set = frame.y_set,
        };
    }
};

pub const Measurement = struct {
    /// Logical dimensions used to allocate the object's frame.
    width: f32,
    height: f32,
    /// Null means the provider has no ink geometry; a zero rectangle means no ink.
    ink_bounds: ?Bounds = null,
    /// Distance from the object's top edge to its first rendered baseline.
    first_baseline: ?f32 = null,
    measured_width: ?f32 = null,
    cache_key: ?u64 = null,

    pub fn logicalBounds(self: Measurement) Bounds {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn isValid(self: Measurement) bool {
        if (!self.logicalBounds().isValid() or self.width <= 0 or self.height <= 0) return false;
        if (self.ink_bounds) |ink| if (!ink.isValid()) return false;
        if (self.first_baseline) |baseline| if (!std.math.isFinite(baseline)) return false;
        if (self.measured_width) |width| if (!std.math.isFinite(width) or width <= 0) return false;
        return true;
    }
};
