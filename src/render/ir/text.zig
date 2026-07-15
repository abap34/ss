const std = @import("std");
const geometry = @import("geometry.zig");
const resources = @import("resources.zig");

pub const Range = struct {
    start: u32,
    end: u32,
};

pub const Glyph = struct {
    id: u32,
    source_index: u32,
    offset_x: f64,
    offset_y: f64,
    advance_x: f64,
    advance_y: f64,
};

pub const Cluster = struct {
    source: Range,
    glyph_range: Range,
    x: f64,
    advance: f64,
};

pub const Run = struct {
    source: Range,
    glyph_range: Range,
    cluster_range: Range,
    x: f64,
    baseline_y: f64,
    advance: f64,
    font_family: [:0]u8,
    font_resource: ?resources.Id,
    font_index: u32,
    font_postscript_name: [:0]u8,

    fn deinit(self: *Run, allocator: std.mem.Allocator) void {
        allocator.free(self.font_family);
        allocator.free(self.font_postscript_name);
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

    pub fn simple(
        allocator: std.mem.Allocator,
        source: []const u8,
        font_family: []const u8,
        font_size: f64,
        width: f64,
    ) !Layout {
        const owned_source = try allocator.dupeZ(u8, source);
        errdefer allocator.free(owned_source);
        const lines = try allocator.alloc(Line, 1);
        errdefer allocator.free(lines);
        const runs = try allocator.alloc(Run, 1);
        errdefer allocator.free(runs);
        const family = try allocator.dupeZ(u8, font_family);
        errdefer allocator.free(family);
        const postscript_name = try allocator.dupeZ(u8, "");
        errdefer allocator.free(postscript_name);
        const glyphs = try allocator.alloc(Glyph, 0);
        errdefer allocator.free(glyphs);
        const clusters = try allocator.alloc(Cluster, 0);
        errdefer allocator.free(clusters);
        const bounds = geometry.Rect{ .x = 0, .y = 0, .width = @max(width, 0), .height = @max(font_size, 0) };
        lines[0] = .{
            .source = .{ .start = 0, .end = @intCast(source.len) },
            .run_range = .{ .start = 0, .end = 1 },
            .baseline_y = font_size,
            .logical_bounds = bounds,
            .ink_bounds = bounds,
        };
        runs[0] = .{
            .source = .{ .start = 0, .end = @intCast(source.len) },
            .glyph_range = .{ .start = 0, .end = 0 },
            .cluster_range = .{ .start = 0, .end = 0 },
            .x = 0,
            .baseline_y = font_size,
            .advance = width,
            .font_family = family,
            .font_resource = null,
            .font_index = 0,
            .font_postscript_name = postscript_name,
        };
        return .{
            .source_text = owned_source,
            .lines = lines,
            .runs = runs,
            .clusters = clusters,
            .glyphs = glyphs,
            .logical_bounds = bounds,
            .ink_bounds = bounds,
        };
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
