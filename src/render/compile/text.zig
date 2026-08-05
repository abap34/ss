const std = @import("std");
const core = @import("core");
const c = @import("pdf_ffi").c;
const render = @import("render");
const resources_compile = @import("render_resources");
const utils = @import("utils");

const Allocator = std.mem.Allocator;
const FontEnvironmentId = [c.SS_FONT_ENVIRONMENT_ID_SIZE]u8;
pub const FontEnvironment = c.SsFontEnvironment;

const CacheKey = struct {
    source: []const u8,
    family: []const u8,
    weight: u16,
    style: core.font.Style,
    stretch: core.font.Stretch,
    font_size_bits: u64,
    width_bits: u64,
    wrap: bool,
    font_environment: FontEnvironmentId,
};

const CacheKeyContext = struct {
    pub fn hash(_: CacheKeyContext, key: CacheKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.source);
        hasher.update(key.family);
        std.hash.autoHash(&hasher, key.weight);
        std.hash.autoHash(&hasher, key.style);
        std.hash.autoHash(&hasher, key.stretch);
        std.hash.autoHash(&hasher, key.font_size_bits);
        std.hash.autoHash(&hasher, key.width_bits);
        std.hash.autoHash(&hasher, key.wrap);
        hasher.update(&key.font_environment);
        return hasher.final();
    }

    pub fn eql(_: CacheKeyContext, left: CacheKey, right: CacheKey) bool {
        return left.weight == right.weight and
            left.style == right.style and
            left.stretch == right.stretch and
            left.font_size_bits == right.font_size_bits and
            left.width_bits == right.width_bits and
            left.wrap == right.wrap and
            std.mem.eql(u8, &left.font_environment, &right.font_environment) and
            std.mem.eql(u8, left.source, right.source) and
            std.mem.eql(u8, left.family, right.family);
    }
};

const FontDependency = struct {
    path: []u8,
    resource: render.ResourceId,
    instance: render.FontInstanceId,
    face_index: u32,
    family: []u8,
    postscript_name: []u8,
    weight: u16,
    style: core.font.Style,
    stretch: core.font.Stretch,
    ascent_ratio: f64,
    descent_ratio: f64,
    line_gap_ratio: f64,
    underline_position_ratio: f64,
    underline_thickness_ratio: f64,
    strikethrough_position_ratio: f64,
    strikethrough_thickness_ratio: f64,
    math: ?render.MathConstants,
    family_substitution: bool,

    fn deinit(self: *FontDependency, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.family);
        allocator.free(self.postscript_name);
    }
};

const CachedShape = struct {
    layout: render.TextLayout,
    fonts: []FontDependency,
    last_used: std.atomic.Value(u64),
    materialized_epoch: u64,
    byte_size: usize,

    fn deinit(self: *CachedShape, allocator: Allocator) void {
        self.layout.deinit(allocator);
        for (self.fonts) |*font| font.deinit(allocator);
        allocator.free(self.fonts);
    }
};

const ShapeMap = std.HashMap(CacheKey, CachedShape, CacheKeyContext, std.hash_map.default_max_load_percentage);

pub const Cache = struct {
    allocator: Allocator,
    io: std.Io,
    lock: std.Io.RwLock = .init,
    document_lock: std.Io.Mutex = .init,
    shapes: ShapeMap,
    access_clock: std.atomic.Value(u64) = .init(0),
    shape_bytes: usize = 0,
    dirty: bool = false,
    document_epoch: u64 = 1,
    font_environment: ?FontEnvironment = null,

    const max_entries = 8192;
    const max_cached_bytes = 128 * 1024 * 1024;

    pub fn init(allocator: Allocator, io: std.Io) Cache {
        return .{
            .allocator = allocator,
            .io = io,
            .shapes = ShapeMap.init(allocator),
        };
    }

    pub fn deinit(self: *Cache) void {
        self.clear();
        self.shapes.deinit();
        self.* = undefined;
    }

    pub fn entryCount(self: *const Cache) usize {
        return self.shapes.count();
    }

    pub fn beginDocument(self: *Cache) !void {
        const profile_start = utils.measure_profile.start();
        defer utils.measure_profile.recordTextCacheBeginDocument(profile_start);
        self.document_lock.lockUncancelable(self.io);
        errdefer self.document_lock.unlock(self.io);
        const environment = try fontEnvironmentSnapshot();
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.font_environment = environment;
        self.document_epoch +%= 1;
        if (self.document_epoch != 0) return;
        self.document_epoch = 1;
        var iterator = self.shapes.valueIterator();
        while (iterator.next()) |cached_shape| cached_shape.materialized_epoch = 0;
    }

    pub fn endDocument(self: *Cache) void {
        self.lock.lockUncancelable(self.io);
        self.font_environment = null;
        self.lock.unlock(self.io);
        self.document_lock.unlock(self.io);
    }

    fn currentEnvironment(self: *Cache) ?FontEnvironment {
        self.lock.lockSharedUncancelable(self.io);
        defer self.lock.unlockShared(self.io);
        return self.font_environment;
    }

    fn clear(self: *Cache) void {
        var iterator = self.shapes.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.source);
            self.allocator.free(entry.key_ptr.family);
            entry.value_ptr.deinit(self.allocator);
        }
        self.shapes.clearRetainingCapacity();
        self.shape_bytes = 0;
    }

    fn get(
        self: *Cache,
        allocator: Allocator,
        io: std.Io,
        resources: *resources_compile.Builder,
        fonts: *render.FontBuilder,
        key: CacheKey,
    ) !?render.TextLayout {
        self.lock.lockSharedUncancelable(self.io);
        if (self.shapes.getPtr(key)) |cached| {
            self.touch(cached);
            if (self.font_environment != null and cached.materialized_epoch == self.document_epoch) {
                const profile_clone = utils.measure_profile.start();
                const layout = cached.layout.clone(allocator) catch |err| {
                    self.lock.unlockShared(self.io);
                    return err;
                };
                utils.measure_profile.recordTextCacheClone(profile_clone);
                self.lock.unlockShared(self.io);
                return layout;
            }
        }
        self.lock.unlockShared(self.io);

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const cached = self.shapes.getPtr(key) orelse return null;
        self.touch(cached);
        if (self.font_environment == null or cached.materialized_epoch != self.document_epoch) {
            const profile_materialize = utils.measure_profile.start();
            defer utils.measure_profile.recordTextCacheMaterialize(profile_materialize);
            for (cached.fonts) |font| {
                const resource = resources.addPath(allocator, io, .font, font.path) catch |err| switch (err) {
                    error.OutOfMemory, error.Canceled => return err,
                    else => {
                        self.removeEntry(key);
                        return null;
                    },
                };
                if (!std.mem.eql(u8, &resource, &font.resource)) {
                    self.removeEntry(key);
                    return null;
                }
                const instance = try fonts.add(allocator, io, fontSpec(font, resource));
                if (!std.mem.eql(u8, &instance, &font.instance)) {
                    self.removeEntry(key);
                    return null;
                }
            }
            cached.materialized_epoch = if (self.font_environment != null) self.document_epoch else 0;
        }
        const profile_share = utils.measure_profile.start();
        try cached.layout.share(self.allocator);
        utils.measure_profile.recordTextCacheShare(profile_share);
        const profile_clone = utils.measure_profile.start();
        defer utils.measure_profile.recordTextCacheClone(profile_clone);
        return try cached.layout.clone(allocator);
    }

    fn put(
        self: *Cache,
        source: []const u8,
        requested_font: core.font.Face,
        font_size: f64,
        width: f64,
        wrap: bool,
        font_environment: FontEnvironmentId,
        layout: *const render.TextLayout,
        native: c.SsTextShape,
        resources: *resources_compile.Builder,
        fonts: *render.FontBuilder,
    ) !void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);

        const owned_source = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(owned_source);
        const owned_family = try self.allocator.dupe(u8, requested_font.family);
        errdefer self.allocator.free(owned_family);
        const key = cacheKey(owned_source, .{
            .family = owned_family,
            .weight = requested_font.weight,
            .style = requested_font.style,
            .stretch = requested_font.stretch,
        }, font_size, width, wrap, font_environment);
        var cached_layout = try layout.clone(self.allocator);
        errdefer cached_layout.deinit(self.allocator);
        const dependencies = try cacheFontDependencies(
            self.allocator,
            self.io,
            resources,
            fonts,
            requested_font,
            font_size,
            native,
            layout,
        );
        errdefer {
            for (dependencies) |*dependency| dependency.deinit(self.allocator);
            self.allocator.free(dependencies);
        }
        const byte_size = owned_source.len +| owned_family.len +|
            cached_layout.ownedByteSize() +| fontDependenciesByteSize(dependencies);
        if (byte_size > max_cached_bytes) {
            self.allocator.free(owned_source);
            self.allocator.free(owned_family);
            cached_layout.deinit(self.allocator);
            for (dependencies) |*dependency| dependency.deinit(self.allocator);
            self.allocator.free(dependencies);
            return;
        }
        try self.shapes.ensureUnusedCapacity(1);
        if (self.shapes.fetchRemove(key)) |previous| {
            self.allocator.free(previous.key.source);
            self.allocator.free(previous.key.family);
            var value = previous.value;
            self.shape_bytes -= value.byte_size;
            value.deinit(self.allocator);
        }
        while (self.shapes.count() >= max_entries or self.shape_bytes > max_cached_bytes - byte_size) {
            self.evictLeastRecentlyUsed();
        }
        self.shapes.putAssumeCapacityNoClobber(key, .{
            .layout = cached_layout,
            .fonts = dependencies,
            .last_used = .init(self.nextAccess()),
            .materialized_epoch = if (self.font_environment != null) self.document_epoch else 0,
            .byte_size = byte_size,
        });
        self.shape_bytes += byte_size;
        self.dirty = true;
    }

    fn nextAccess(self: *Cache) u64 {
        const next = self.access_clock.fetchAdd(1, .monotonic) +% 1;
        if (next != 0) return next;
        return self.access_clock.fetchAdd(1, .monotonic) +% 1;
    }

    fn touch(self: *Cache, cached: *CachedShape) void {
        const access = self.nextAccess();
        var previous = cached.last_used.load(.monotonic);
        while (previous < access) {
            previous = cached.last_used.cmpxchgWeak(
                previous,
                access,
                .monotonic,
                .monotonic,
            ) orelse return;
        }
    }

    fn evictLeastRecentlyUsed(self: *Cache) void {
        var oldest_key: ?CacheKey = null;
        var oldest_access: u64 = std.math.maxInt(u64);
        var iterator = self.shapes.iterator();
        while (iterator.next()) |entry| {
            const last_used = entry.value_ptr.last_used.load(.monotonic);
            if (last_used >= oldest_access) continue;
            oldest_key = entry.key_ptr.*;
            oldest_access = last_used;
        }
        self.removeEntry(oldest_key orelse return);
    }

    fn removeEntry(self: *Cache, key: CacheKey) void {
        const removed = self.shapes.fetchRemove(key) orelse return;
        self.allocator.free(removed.key.source);
        self.allocator.free(removed.key.family);
        var value = removed.value;
        self.shape_bytes -= value.byte_size;
        value.deinit(self.allocator);
    }
};

fn fontDependenciesByteSize(dependencies: []const FontDependency) usize {
    var total = dependencies.len *| @sizeOf(FontDependency);
    for (dependencies) |dependency| {
        total +|= dependency.path.len;
        total +|= dependency.family.len;
        total +|= dependency.postscript_name.len;
    }
    return total;
}

fn cacheKey(
    source: []const u8,
    font: core.font.Face,
    font_size: f64,
    width: f64,
    wrap: bool,
    font_environment: FontEnvironmentId,
) CacheKey {
    return .{
        .source = source,
        .family = font.family,
        .weight = font.weight,
        .style = font.style,
        .stretch = font.stretch,
        .font_size_bits = @bitCast(font_size),
        .width_bits = @bitCast(if (wrap) width else @as(f64, 0)),
        .wrap = wrap,
        .font_environment = font_environment,
    };
}

pub fn fontEnvironmentSnapshot() !FontEnvironment {
    var environment = std.mem.zeroes(FontEnvironment);
    if (c.ss_font_environment_snapshot(&environment) != 0) return error.PangoCreateFailed;
    return environment;
}

pub fn fontEnvironmentRefresh() !FontEnvironment {
    var environment = std.mem.zeroes(FontEnvironment);
    if (c.ss_font_environment_refresh(&environment) != 0) return error.FontEnvironmentRefreshFailed;
    return environment;
}

fn sameFontEnvironment(left: FontEnvironment, right: FontEnvironment) bool {
    return left.generation == right.generation and std.mem.eql(u8, &left.id, &right.id);
}

pub fn validateFontEnvironment(expected: FontEnvironment) !void {
    const current = try fontEnvironmentSnapshot();
    if (!sameFontEnvironment(expected, current)) return error.FontEnvironmentChanged;
}

pub fn refreshAndValidateFontEnvironment(expected: FontEnvironment) !void {
    const current = try fontEnvironmentRefresh();
    if (!sameFontEnvironment(expected, current)) return error.FontEnvironmentChanged;
}

pub fn shape(
    allocator: Allocator,
    io: std.Io,
    resources: *resources_compile.Builder,
    fonts: *render.FontBuilder,
    source: []const u8,
    requested_font: core.font.Face,
    font_size: f64,
    width: f64,
    wrap: bool,
    cache: ?*Cache,
) !render.TextLayout {
    const profile_start = utils.measure_profile.start();
    var profile_hit = false;
    defer utils.measure_profile.recordTextShape(profile_hit, profile_start);
    const environment = if (cache) |shape_cache|
        shape_cache.currentEnvironment() orelse try fontEnvironmentSnapshot()
    else
        try fontEnvironmentSnapshot();
    if (cache) |shape_cache| {
        if (try shape_cache.get(
            allocator,
            io,
            resources,
            fonts,
            cacheKey(source, requested_font, font_size, width, wrap, environment.id),
        )) |cached_layout| {
            profile_hit = true;
            return cached_layout;
        }
    }

    const family_z = try allocator.dupeZ(u8, requested_font.family);
    defer allocator.free(family_z);
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);
    var native = std.mem.zeroes(c.SsTextShape);
    if (c.ss_text_shape(
        source_z.ptr,
        family_z.ptr,
        @intCast(requested_font.weight),
        core.font.styleCode(requested_font.style),
        core.font.stretchCode(requested_font.stretch),
        font_size,
        width,
        @intFromBool(wrap),
        &native,
    ) != 0) return error.PangoCreateFailed;
    defer c.ss_text_shape_free(&native);
    if (!sameFontEnvironment(environment, native.environment)) return error.FontEnvironmentChanged;
    const layout = try copy(allocator, io, resources, fonts, source, requested_font, font_size, native);
    if (cache) |shape_cache| shape_cache.put(
        source,
        requested_font,
        font_size,
        width,
        wrap,
        native.environment.id,
        &layout,
        native,
        resources,
        fonts,
    ) catch {};
    return layout;
}

fn copy(
    allocator: Allocator,
    io: std.Io,
    resources: *resources_compile.Builder,
    fonts: *render.FontBuilder,
    source: []const u8,
    requested_font: core.font.Face,
    font_size: f64,
    native: c.SsTextShape,
) !render.TextLayout {
    const owned_source = try allocator.dupeZ(u8, source);
    errdefer allocator.free(owned_source);
    const lines = try allocator.alloc(render.TextLine, native.line_count);
    errdefer allocator.free(lines);
    const runs = try allocator.alloc(render.TextRun, native.run_count);
    var initialized_runs: usize = 0;
    errdefer {
        for (runs[0..initialized_runs]) |*run| allocator.free(run.language);
        allocator.free(runs);
    }
    const glyphs = try allocator.alloc(render.Glyph, native.glyph_count);
    errdefer allocator.free(glyphs);
    const clusters = try allocator.alloc(render.TextCluster, native.cluster_count);
    errdefer allocator.free(clusters);

    for (native.lines[0..native.line_count], 0..) |line, index| lines[index] = .{
        .source = .{ .start = @intCast(line.source_start), .end = @intCast(line.source_end) },
        .run_range = .{ .start = @intCast(line.run_start), .end = @intCast(line.run_start + line.run_count) },
        .baseline_y = line.baseline_y,
        .logical_bounds = nativeRect(line.logical_bounds),
        .ink_bounds = nativeRect(line.ink_bounds),
    };
    for (native.runs[0..native.run_count], 0..) |run, index| {
        const font_path = std.mem.span(run.font_path);
        if (font_path.len == 0) return error.MissingFontResource;
        if (run.synthetic_bold != 0 or run.synthetic_italic != 0) return error.UnsupportedSyntheticFont;
        const font_resource = try resources.addPath(allocator, io, .font, font_path);
        const font_instance = try fonts.add(allocator, io, fontSpecFromNative(run, requested_font, font_size, font_resource));
        const language = try allocator.dupeZ(u8, std.mem.span(run.language));
        errdefer allocator.free(language);
        runs[index] = .{
            .source = .{ .start = @intCast(run.source_start), .end = @intCast(run.source_end) },
            .glyph_range = .{ .start = @intCast(run.glyph_start), .end = @intCast(run.glyph_start + run.glyph_count) },
            .cluster_range = .{ .start = @intCast(run.cluster_start), .end = @intCast(run.cluster_start + run.cluster_count) },
            .x = run.x,
            .baseline_y = run.baseline_y,
            .advance = run.advance,
            .font_instance = font_instance,
            .language = language,
            .direction = if (run.bidi_level & 1 == 0) .left_to_right else .right_to_left,
            .bidi_level = run.bidi_level,
        };
        initialized_runs += 1;
    }
    for (native.glyphs[0..native.glyph_count], 0..) |glyph, index| glyphs[index] = .{
        .id = glyph.id,
        .offset_x = glyph.offset_x,
        .offset_y = glyph.offset_y,
        .advance_x = glyph.advance_x,
        .advance_y = glyph.advance_y,
    };
    for (native.clusters[0..native.cluster_count], 0..) |cluster, index| clusters[index] = .{
        .source = .{ .start = @intCast(cluster.source_start), .end = @intCast(cluster.source_end) },
        .glyph_range = .{ .start = @intCast(cluster.glyph_start), .end = @intCast(cluster.glyph_start + cluster.glyph_count) },
        .x = cluster.x,
        .baseline_y = cluster.baseline_y,
        .advance_x = cluster.advance_x,
        .advance_y = cluster.advance_y,
        .logical_bounds = nativeRect(cluster.logical_bounds),
        .ink_bounds = nativeRect(cluster.ink_bounds),
    };
    return .{
        .source_text = owned_source,
        .lines = lines,
        .runs = runs,
        .clusters = clusters,
        .glyphs = glyphs,
        .logical_bounds = nativeRect(native.logical_bounds),
        .ink_bounds = nativeRect(native.ink_bounds),
    };
}

fn cacheFontDependencies(
    allocator: Allocator,
    io: std.Io,
    resources: *resources_compile.Builder,
    fonts: *render.FontBuilder,
    requested_font: core.font.Face,
    font_size: f64,
    native: c.SsTextShape,
    layout: *const render.TextLayout,
) ![]FontDependency {
    var dependencies = std.ArrayList(FontDependency).empty;
    errdefer {
        for (dependencies.items) |*dependency| dependency.deinit(allocator);
        dependencies.deinit(allocator);
    }
    for (native.runs[0..native.run_count], layout.runs) |run, layout_run| {
        var found = false;
        for (dependencies.items) |dependency| {
            if (std.mem.eql(u8, &dependency.instance, &layout_run.font_instance)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        const path = std.mem.span(run.font_path);
        if (path.len == 0) return error.MissingFontResource;
        const resource = try resources.addPath(allocator, io, .font, path);
        const spec = fontSpecFromNative(run, requested_font, font_size, resource);
        const instance = try fonts.add(allocator, io, spec);
        if (!std.mem.eql(u8, &instance, &layout_run.font_instance)) return error.InvalidFontCacheEntry;
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const family = try allocator.dupe(u8, spec.family);
        errdefer allocator.free(family);
        const postscript_name = try allocator.dupe(u8, spec.postscript_name);
        errdefer allocator.free(postscript_name);
        try dependencies.append(allocator, .{
            .path = owned_path,
            .resource = resource,
            .instance = instance,
            .face_index = spec.face_index,
            .family = family,
            .postscript_name = postscript_name,
            .weight = spec.weight,
            .style = spec.style,
            .stretch = spec.stretch,
            .ascent_ratio = spec.ascent_ratio,
            .descent_ratio = spec.descent_ratio,
            .line_gap_ratio = spec.line_gap_ratio,
            .underline_position_ratio = spec.underline_position_ratio,
            .underline_thickness_ratio = spec.underline_thickness_ratio,
            .strikethrough_position_ratio = spec.strikethrough_position_ratio,
            .strikethrough_thickness_ratio = spec.strikethrough_thickness_ratio,
            .math = spec.math,
            .family_substitution = spec.family_substitution,
        });
    }
    return try dependencies.toOwnedSlice(allocator);
}

fn fontSpecFromNative(run: c.SsTextRun, requested_font: core.font.Face, font_size: f64, resource: render.ResourceId) render.FontSpec {
    const family = std.mem.span(run.font_family);
    return .{
        .resource = resource,
        .face_index = @intCast(run.font_index),
        .family = family,
        .postscript_name = std.mem.span(run.font_postscript_name),
        .weight = @intCast(std.math.clamp(run.font_weight, 1, 1000)),
        .style = fontStyle(run.font_style),
        .stretch = fontStretch(run.font_stretch),
        .ascent_ratio = run.ascent / font_size,
        .descent_ratio = run.descent / font_size,
        .line_gap_ratio = run.line_gap / font_size,
        .underline_position_ratio = run.underline_position / font_size,
        .underline_thickness_ratio = run.underline_thickness / font_size,
        .strikethrough_position_ratio = run.strikethrough_position / font_size,
        .strikethrough_thickness_ratio = run.strikethrough_thickness / font_size,
        .math = mathConstants(run.math),
        .synthetic_bold = false,
        .synthetic_italic = false,
        .family_substitution = !std.ascii.eqlIgnoreCase(std.mem.trim(u8, requested_font.family, " \t"), family),
    };
}

fn fontSpec(font: FontDependency, resource: render.ResourceId) render.FontSpec {
    return .{
        .resource = resource,
        .face_index = font.face_index,
        .family = font.family,
        .postscript_name = font.postscript_name,
        .weight = font.weight,
        .style = font.style,
        .stretch = font.stretch,
        .ascent_ratio = font.ascent_ratio,
        .descent_ratio = font.descent_ratio,
        .line_gap_ratio = font.line_gap_ratio,
        .underline_position_ratio = font.underline_position_ratio,
        .underline_thickness_ratio = font.underline_thickness_ratio,
        .strikethrough_position_ratio = font.strikethrough_position_ratio,
        .strikethrough_thickness_ratio = font.strikethrough_thickness_ratio,
        .math = font.math,
        .family_substitution = font.family_substitution,
    };
}

fn mathConstants(value: c.SsMathConstants) ?render.MathConstants {
    if (value.has_data == 0) return null;
    return .{
        .script_scale = value.script_scale,
        .script_script_scale = value.script_script_scale,
        .axis_height = value.axis_height,
        .subscript_shift_down = value.subscript_shift_down,
        .subscript_top_max = value.subscript_top_max,
        .subscript_baseline_drop_min = value.subscript_baseline_drop_min,
        .superscript_shift_up = value.superscript_shift_up,
        .superscript_bottom_min = value.superscript_bottom_min,
        .superscript_baseline_drop_max = value.superscript_baseline_drop_max,
        .sub_superscript_gap_min = value.sub_superscript_gap_min,
        .superscript_bottom_max_with_subscript = value.superscript_bottom_max_with_subscript,
        .space_after_script = value.space_after_script,
        .fraction_numerator_shift_up = value.fraction_numerator_shift_up,
        .fraction_numerator_display_shift_up = value.fraction_numerator_display_shift_up,
        .fraction_denominator_shift_down = value.fraction_denominator_shift_down,
        .fraction_denominator_display_shift_down = value.fraction_denominator_display_shift_down,
        .fraction_numerator_gap_min = value.fraction_numerator_gap_min,
        .fraction_numerator_display_gap_min = value.fraction_numerator_display_gap_min,
        .fraction_rule_thickness = value.fraction_rule_thickness,
        .fraction_denominator_gap_min = value.fraction_denominator_gap_min,
        .fraction_denominator_display_gap_min = value.fraction_denominator_display_gap_min,
        .radical_vertical_gap = value.radical_vertical_gap,
        .radical_display_vertical_gap = value.radical_display_vertical_gap,
        .radical_rule_thickness = value.radical_rule_thickness,
        .radical_extra_ascender = value.radical_extra_ascender,
    };
}

fn fontStyle(value: c_int) core.font.Style {
    return switch (value) {
        1 => .oblique,
        2 => .italic,
        else => .normal,
    };
}

fn fontStretch(value: c_int) core.font.Stretch {
    return switch (value) {
        0 => .ultra_condensed,
        1 => .extra_condensed,
        2 => .condensed,
        3 => .semi_condensed,
        5 => .semi_expanded,
        6 => .expanded,
        7 => .extra_expanded,
        8 => .ultra_expanded,
        else => .normal,
    };
}

fn nativeRect(value: c.SsPdfInkExtents) render.Rect {
    return .{ .x = value.x, .y = value.y, .width = value.width, .height = value.height };
}
