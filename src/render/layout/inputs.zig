const std = @import("std");
const core = @import("core");
const render_text = @import("render_text");
const measurements = @import("render_measurements");
const utils = @import("utils");

/// Valid while object content, render properties, and constraint topology are unchanged.
pub const Inputs = struct {
    pages: core.prepared.PreparedPages,
    layouts: core.layout.Document = .{},
    font_environment: render_text.FontEnvironment,
    measurements: ?measurements.Store = null,
    external_inputs: ?utils.FileInputs = null,

    pub fn deinit(self: *Inputs, allocator: std.mem.Allocator) void {
        self.layouts.deinit(allocator);
        self.pages.deinit(allocator);
        if (self.measurements) |*store| store.deinit();
        if (self.external_inputs) |*inputs| inputs.deinit();
        self.* = undefined;
    }
};
