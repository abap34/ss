const std = @import("std");
const core = @import("core");
const render_text = @import("render_text");

/// Valid while object content, render properties, and constraint topology are unchanged.
pub const Inputs = struct {
    pages: core.prepared.PreparedPages,
    font_environment: render_text.FontEnvironment,

    pub fn deinit(self: *Inputs, allocator: std.mem.Allocator) void {
        self.pages.deinit(allocator);
        self.* = undefined;
    }
};
