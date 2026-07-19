const std = @import("std");
const fonts = @import("fonts.zig");
const geometry = @import("geometry.zig");

pub const Range = struct {
    start: u32,
    end: u32,
};

pub const Glyph = struct {
    id: u32,
    offset_x: f64,
    offset_y: f64,
    advance_x: f64,
    advance_y: f64,
};

pub const Direction = enum {
    left_to_right,
    right_to_left,
};

pub const Cluster = struct {
    source: Range,
    glyph_range: Range,
    x: f64,
    baseline_y: f64,
    advance_x: f64,
    advance_y: f64,
    logical_bounds: geometry.Rect,
    ink_bounds: geometry.Rect,
};

pub const Run = struct {
    source: Range,
    glyph_range: Range,
    cluster_range: Range,
    x: f64,
    baseline_y: f64,
    advance: f64,
    font_instance: fonts.Id,
    language: [:0]u8,
    direction: Direction,
    bidi_level: u8,

    fn deinit(self: *Run, allocator: std.mem.Allocator) void {
        allocator.free(self.language);
    }
};

pub const Line = struct {
    source: Range,
    run_range: Range,
    baseline_y: f64,
    logical_bounds: geometry.Rect,
    ink_bounds: geometry.Rect,
};

pub const Layout = struct {
    source_text: [:0]u8,
    lines: []Line,
    runs: []Run,
    clusters: []Cluster,
    glyphs: []Glyph,
    logical_bounds: geometry.Rect,
    ink_bounds: geometry.Rect,

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.source_text);
        allocator.free(self.lines);
        for (self.runs) |*run| run.deinit(allocator);
        allocator.free(self.runs);
        allocator.free(self.clusters);
        allocator.free(self.glyphs);
        self.* = empty;
    }

    pub fn firstBaseline(self: *const Layout) f64 {
        return if (self.lines.len == 0) 0 else self.lines[0].baseline_y;
    }
};

pub const empty = Layout{
    .source_text = @constCast(""),
    .lines = &.{},
    .runs = &.{},
    .clusters = &.{},
    .glyphs = &.{},
    .logical_bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    .ink_bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};
