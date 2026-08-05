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

const SharedStorage = struct {
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),
    words: []u64,

    fn retain(self: *SharedStorage) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    fn release(self: *SharedStorage) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        self.allocator.free(self.words);
        self.allocator.destroy(self);
    }
};

pub const Layout = struct {
    source_text: [:0]u8,
    lines: []Line,
    runs: []Run,
    clusters: []Cluster,
    glyphs: []Glyph,
    logical_bounds: geometry.Rect,
    ink_bounds: geometry.Rect,
    shared_storage: ?*SharedStorage = null,

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        if (self.shared_storage) |storage| {
            storage.release();
        } else {
            allocator.free(self.source_text);
            allocator.free(self.lines);
            for (self.runs) |*run| run.deinit(allocator);
            allocator.free(self.runs);
            allocator.free(self.clusters);
            allocator.free(self.glyphs);
        }
        self.* = empty;
    }

    pub fn clone(self: *const Layout, allocator: std.mem.Allocator) !Layout {
        if (self.shared_storage) |storage| {
            storage.retain();
            return self.*;
        }
        return try self.deepClone(allocator);
    }

    pub fn share(self: *Layout, allocator: std.mem.Allocator) !void {
        if (self.shared_storage != null) return;
        const shared = try self.deepClone(allocator);
        self.deinit(allocator);
        self.* = shared;
    }

    pub fn makeUnique(self: *Layout) !void {
        const storage = self.shared_storage orelse return;
        if (storage.references.load(.acquire) == 1) return;
        const unique = try self.deepClone(storage.allocator);
        storage.release();
        self.* = unique;
    }

    fn deepClone(self: *const Layout, allocator: std.mem.Allocator) !Layout {
        comptime {
            std.debug.assert(@alignOf(Line) <= @alignOf(u64));
            std.debug.assert(@alignOf(Run) <= @alignOf(u64));
            std.debug.assert(@alignOf(Cluster) <= @alignOf(u64));
            std.debug.assert(@alignOf(Glyph) <= @alignOf(u64));
        }
        const allocation_count = self.runs.len +| 5;
        const padding = allocation_count *| (@alignOf(u64) - 1);
        const byte_count = self.contentByteSize() +| padding;
        if (byte_count > std.math.maxInt(usize) - (@sizeOf(u64) - 1)) return error.OutOfMemory;
        const words = try allocator.alloc(u64, (byte_count + @sizeOf(u64) - 1) / @sizeOf(u64));
        errdefer allocator.free(words);
        const storage = try allocator.create(SharedStorage);
        errdefer allocator.destroy(storage);
        storage.* = .{ .allocator = allocator, .words = words };
        var fixed = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(words));
        const fixed_allocator = fixed.allocator();

        const source_text = try fixed_allocator.dupeZ(u8, self.source_text);
        const lines = try fixed_allocator.dupe(Line, self.lines);
        const runs = try fixed_allocator.alloc(Run, self.runs.len);
        for (self.runs, 0..) |run, index| {
            runs[index] = run;
            runs[index].language = try fixed_allocator.dupeZ(u8, run.language);
        }
        const clusters = try fixed_allocator.dupe(Cluster, self.clusters);
        const glyphs = try fixed_allocator.dupe(Glyph, self.glyphs);
        return .{
            .source_text = source_text,
            .lines = lines,
            .runs = runs,
            .clusters = clusters,
            .glyphs = glyphs,
            .logical_bounds = self.logical_bounds,
            .ink_bounds = self.ink_bounds,
            .shared_storage = storage,
        };
    }

    pub fn ownedByteSize(self: *const Layout) usize {
        if (self.shared_storage) |storage| {
            return @sizeOf(SharedStorage) +| storage.words.len *| @sizeOf(u64);
        }
        return self.contentByteSize();
    }

    fn contentByteSize(self: *const Layout) usize {
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
    .shared_storage = null,
};
