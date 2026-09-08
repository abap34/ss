const std = @import("std");
const core = @import("core");
const c = @import("pdf_ffi").c;
const utils = @import("utils");

const Allocator = std.mem.Allocator;
const Key = [32]u8;
pub const Style = struct {
    start: usize,
    end: usize,
    font: core.font.Face,
    letter_spacing: f64 = 0,
};
pub const Object = c.SsParagraphObject;
pub const Position = c.SsInlinePosition;
pub const Request = struct {
    source: []const u8,
    font: core.font.Face,
    font_size: f64,
    line_height: f64,
    width: f64,
    wrap: bool,
    emoji_spacing: f64 = 0,
    styles: []const Style = &.{},
    objects: []const Object = &.{},
};

/// Retains native glyphs and line geometry independently of output font resources.
pub const Layout = struct {
    allocator: Allocator,
    references: std.atomic.Value(usize) = .init(1),
    source: [:0]u8,
    native: c.SsTextShape,
    objects: []Position,
    default_ascent: f64,
    byte_size: usize,

    pub fn retain(self: *Layout) *Layout {
        _ = self.references.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *Layout) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        c.ss_text_shape_free(&self.native);
        self.allocator.free(self.source);
        self.allocator.free(self.objects);
        self.allocator.destroy(self);
    }
};

const Entry = struct { layout: *Layout, previous: ?Key, next: ?Key };

pub const Cache = struct {
    allocator: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    entries: std.AutoHashMap(Key, Entry),
    oldest: ?Key = null,
    newest: ?Key = null,
    bytes: usize = 0,
    max_entries: usize = 2048,
    max_bytes: usize = 128 * 1024 * 1024,

    pub fn init(allocator: Allocator, io: std.Io) Cache {
        return .{ .allocator = allocator, .io = io, .entries = std.AutoHashMap(Key, Entry).init(allocator) };
    }

    pub fn deinit(self: *Cache) void {
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry| entry.layout.release();
        self.entries.deinit();
        self.* = undefined;
    }

    fn unlink(self: *Cache, entry: Entry) void {
        if (entry.previous) |previous| self.entries.getPtr(previous).?.next = entry.next else self.oldest = entry.next;
        if (entry.next) |next| self.entries.getPtr(next).?.previous = entry.previous else self.newest = entry.previous;
    }

    fn getLocked(self: *Cache, key: Key) ?*Layout {
        const entry = self.entries.getPtr(key) orelse return null;
        if (entry.next != null) {
            self.unlink(entry.*);
            entry.previous = self.newest;
            entry.next = null;
            if (self.newest) |newest| self.entries.getPtr(newest).?.next = key;
            self.newest = key;
            if (self.oldest == null) self.oldest = key;
        }
        return entry.layout.retain();
    }

    pub fn get(self: *Cache, request: Request, environment: c.SsFontEnvironment) !*Layout {
        const profile_start = utils.measure_profile.start();
        var hit = false;
        defer utils.measure_profile.recordTextShape(hit, profile_start);
        const key = requestKey(request, environment);
        try self.mutex.lock(self.io);
        const cached = self.getLocked(key);
        self.mutex.unlock(self.io);
        if (cached) |layout| {
            hit = true;
            return layout;
        }
        const layout = try shape(self.allocator, self.io, request, environment);
        errdefer layout.release();
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.getLocked(key)) |existing| {
            layout.release();
            return existing;
        }
        if (self.max_entries == 0 or layout.byte_size > self.max_bytes) return layout;
        try self.entries.ensureUnusedCapacity(1);
        while (self.entries.count() >= self.max_entries or self.bytes > self.max_bytes - layout.byte_size) {
            const oldest = self.oldest.?;
            const removed = self.entries.fetchRemove(oldest).?.value;
            self.unlink(removed);
            self.bytes -= removed.layout.byte_size;
            removed.layout.release();
        }
        self.entries.putAssumeCapacity(key, .{ .layout = layout.retain(), .previous = self.newest, .next = null });
        if (self.newest) |newest| self.entries.getPtr(newest).?.next = key else self.oldest = key;
        self.newest = key;
        self.bytes += layout.byte_size;
        return layout;
    }
};

fn requestKey(request: Request, environment: c.SsFontEnvironment) Key {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&environment.id);
    hashBytes(&hash, request.source);
    hashFont(&hash, request.font);
    for ([_]f64{ request.font_size, request.line_height, request.width, request.emoji_spacing }) |value| hash.update(std.mem.asBytes(&value));
    hash.update(&.{@intFromBool(request.wrap)});
    hash.update(std.mem.asBytes(&request.styles.len));
    for (request.styles) |style| {
        hash.update(std.mem.asBytes(&style.start));
        hash.update(std.mem.asBytes(&style.end));
        hashFont(&hash, style.font);
        hash.update(std.mem.asBytes(&style.letter_spacing));
    }
    hash.update(std.mem.asBytes(&request.objects.len));
    for (request.objects) |object| {
        hash.update(std.mem.asBytes(&object.source_start));
        for ([_]f64{ object.width, object.height, object.baseline_from_bottom, object.spacing }) |value| hash.update(std.mem.asBytes(&value));
    }
    return hash.finalResult();
}

fn hashBytes(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    hash.update(std.mem.asBytes(&bytes.len));
    hash.update(bytes);
}

fn hashFont(hash: *std.crypto.hash.sha2.Sha256, font: core.font.Face) void {
    hashBytes(hash, font.family);
    hash.update(std.mem.asBytes(&font.weight));
    hash.update(&.{ @intFromEnum(font.style), @intFromEnum(font.stretch) });
}

pub fn shape(allocator: Allocator, io: std.Io, request: Request, environment: c.SsFontEnvironment) !*Layout {
    try std.Io.checkCancel(io);
    if (!std.math.isFinite(request.line_height) or request.line_height <= 0) return error.InvalidParagraphGeometry;
    const source = try allocator.dupeZ(u8, request.source);
    errdefer allocator.free(source);
    var temporary = std.heap.ArenaAllocator.init(allocator);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    const family = try scratch.dupeZ(u8, request.font.family);
    const styles = try scratch.alloc(c.SsParagraphStyle, request.styles.len);
    for (request.styles, styles) |input, *style| style.* = .{
        .source_start = input.start,
        .source_end = input.end,
        .font_family = (try scratch.dupeZ(u8, input.font.family)).ptr,
        .font_weight = @intCast(input.font.weight),
        .font_style = core.font.styleCode(input.font.style),
        .font_stretch = core.font.stretchCode(input.font.stretch),
        .letter_spacing = input.letter_spacing,
    };
    const positions = try allocator.alloc(Position, request.objects.len);
    errdefer allocator.free(positions);
    const options = c.SsParagraphOptions{
        .font_family = family.ptr,
        .font_weight = @intCast(request.font.weight),
        .font_style = core.font.styleCode(request.font.style),
        .font_stretch = core.font.stretchCode(request.font.stretch),
        .font_size = request.font_size,
        .width = request.width,
        .wrap = @intFromBool(request.wrap),
        .emoji_spacing = request.emoji_spacing,
        .styles = styles.ptr,
        .style_count = styles.len,
        .objects = request.objects.ptr,
        .object_count = request.objects.len,
    };
    var native = std.mem.zeroes(c.SsTextShape);
    if (c.ss_text_shape_paragraph(source.ptr, &options, &native, positions.ptr) != 0) return error.PangoCreateFailed;
    errdefer c.ss_text_shape_free(&native);
    if (!std.mem.eql(u8, &environment.id, &native.environment.id)) return error.FontEnvironmentChanged;
    try std.Io.checkCancel(io);
    var metrics = std.mem.zeroes(c.SsTextMeasurement);
    if (c.ss_text_measure_layout("M", family.ptr, options.font_weight, options.font_style, options.font_stretch, request.font_size, 0, 0, &metrics) != 0) return error.PangoCreateFailed;
    const default_ascent = metrics.first_baseline - metrics.logical_bounds.y + (request.line_height - metrics.logical_bounds.height) * 0.5;
    try normalizeLines(scratch, &native, positions, request.objects, default_ascent, request.line_height);
    var bytes = @sizeOf(Layout) + source.len + 1 + positions.len * @sizeOf(Position) + native.line_count * @sizeOf(c.SsTextLine) +
        native.run_count * @sizeOf(c.SsTextRun) + native.cluster_count * @sizeOf(c.SsTextCluster) + native.glyph_count * @sizeOf(c.SsTextGlyph);
    for (native.runs[0..native.run_count]) |run| {
        bytes += std.mem.span(run.font_path).len + std.mem.span(run.font_family).len + std.mem.span(run.font_postscript_name).len + std.mem.span(run.language).len + 4;
    }
    const result = try allocator.create(Layout);
    result.* = .{ .allocator = allocator, .source = source, .native = native, .objects = positions, .default_ascent = default_ascent, .byte_size = bytes };
    return result;
}

fn normalizeLines(allocator: Allocator, native: *c.SsTextShape, positions: []Position, objects: []const Object, default_ascent: f64, line_height: f64) !void {
    const ascents = try allocator.alloc(f64, native.line_count);
    const descents = try allocator.alloc(f64, native.line_count);
    @memset(ascents, default_ascent);
    @memset(descents, @max(line_height - default_ascent, 0));
    for (objects, positions) |object, position| {
        ascents[position.line_index] = @max(ascents[position.line_index], object.height - object.baseline_from_bottom);
        descents[position.line_index] = @max(descents[position.line_index], object.baseline_from_bottom);
    }
    var top: f64 = 0;
    var width: f64 = 0;
    var ink: ?c.SsPdfInkExtents = null;
    for (native.lines[0..native.line_count], ascents, descents) |*line, ascent, descent| {
        const dy = top + ascent - line.baseline_y;
        line.baseline_y += dy;
        line.ink_bounds.x -= line.logical_bounds.x;
        line.ink_bounds.y += dy;
        line.logical_bounds.x = 0;
        line.logical_bounds.y = top;
        line.logical_bounds.height = ascent + descent;
        for (native.runs[line.run_start..][0..line.run_count]) |*run| {
            run.baseline_y += dy;
            for (native.clusters[run.cluster_start..][0..run.cluster_count]) |*cluster| {
                cluster.baseline_y += dy;
                cluster.logical_bounds.y += dy;
                cluster.ink_bounds.y += dy;
            }
        }
        top += line.logical_bounds.height;
        width = @max(width, line.logical_bounds.width);
        if (line.ink_bounds.width > 0 and line.ink_bounds.height > 0) ink = if (ink) |previous| unionBounds(previous, line.ink_bounds) else line.ink_bounds;
    }
    for (positions) |*position| position.baseline_y = native.lines[position.line_index].baseline_y;
    native.logical_bounds = .{ .x = 0, .y = 0, .width = width, .height = top };
    native.ink_bounds = ink orelse std.mem.zeroes(c.SsPdfInkExtents);
}

pub fn unionBounds(first: c.SsPdfInkExtents, second: c.SsPdfInkExtents) c.SsPdfInkExtents {
    const x = @min(first.x, second.x);
    const y = @min(first.y, second.y);
    return .{ .x = x, .y = y, .width = @max(first.x + first.width, second.x + second.width) - x, .height = @max(first.y + first.height, second.y + second.height) - y };
}
