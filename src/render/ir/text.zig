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

    pub fn clone(self: *const Layout, allocator: std.mem.Allocator) !Layout {
        const source_text = try allocator.dupeZ(u8, self.source_text);
        errdefer allocator.free(source_text);
        const lines = try allocator.dupe(Line, self.lines);
        errdefer allocator.free(lines);
        const runs = try allocator.alloc(Run, self.runs.len);
        var initialized_runs: usize = 0;
        errdefer {
            for (runs[0..initialized_runs]) |*run| run.deinit(allocator);
            allocator.free(runs);
        }
        for (self.runs, 0..) |run, index| {
            runs[index] = run;
            runs[index].language = try allocator.dupeZ(u8, run.language);
            initialized_runs += 1;
        }
        const clusters = try allocator.dupe(Cluster, self.clusters);
        errdefer allocator.free(clusters);
        const glyphs = try allocator.dupe(Glyph, self.glyphs);
        return .{
            .source_text = source_text,
            .lines = lines,
            .runs = runs,
            .clusters = clusters,
            .glyphs = glyphs,
            .logical_bounds = self.logical_bounds,
            .ink_bounds = self.ink_bounds,
        };
    }

    pub fn ownedByteSize(self: *const Layout) usize {
        var total = self.source_text.len +| 1;
        total +|= self.lines.len *| @sizeOf(Line);
        total +|= self.runs.len *| @sizeOf(Run);
        for (self.runs) |run| total +|= run.language.len +| 1;
        total +|= self.clusters.len *| @sizeOf(Cluster);
        total +|= self.glyphs.len *| @sizeOf(Glyph);
        return total;
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
