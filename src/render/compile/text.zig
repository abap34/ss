const std = @import("std");
const core = @import("core");
const c = @import("pdf_ffi").c;
const render = @import("render");
const resources_compile = @import("render_resources");
const utils = @import("utils");

const Allocator = std.mem.Allocator;
const TextRange = @TypeOf(@as(render.TextLine, undefined).source);
const FontEnvironmentId = [c.SS_FONT_ENVIRONMENT_ID_SIZE]u8;
pub const FontEnvironment = c.SsFontEnvironment;
const persistent_cache_version = "ss-text-shapes-v2\n";
const persistent_cache_directory = "text-shapes-v2";
const persistent_cache_filename = "shapes.bin";
const persistent_cache_file_limit = 128 * 1024 * 1024;
const persistent_cache_checksum_size = std.crypto.hash.sha2.Sha256.digest_length;

pub const ContentRange = struct {
    start: usize,
    end: usize,
};

pub const ResolvedFontFace = struct {
    path: []const u8,
    family: []const u8,
    postscript_name: []const u8,
    synthetic_bold: bool,
    synthetic_italic: bool,
    source: TextRange,
};

pub const SyntheticFontFailure = struct {
    requested: core.font.Face,
    selected_family: []u8,
    selected_postscript_name: []u8,
    synthetic_bold: bool,
    synthetic_italic: bool,
    source: TextRange,

    pub fn contentRange(self: *const SyntheticFontFailure, run: ContentRange, token_offset: usize) ContentRange {
        const run_end = @max(run.start, run.end);
        const run_length = run_end - run.start;
        const token_start = @min(token_offset, run_length);
        const token_capacity = run_length - token_start;
        const source_start = @min(@as(usize, @intCast(self.source.start)), token_capacity);
        const source_end = @min(@as(usize, @intCast(self.source.end)), token_capacity);
        return .{
            .start = run.start + token_start + source_start,
            .end = run.start + token_start + @max(source_start, source_end),
        };
    }

    fn deinit(self: *SyntheticFontFailure, allocator: Allocator) void {
        allocator.free(self.requested.family);
        allocator.free(self.selected_family);
        allocator.free(self.selected_postscript_name);
    }
};

pub const ShapeFailure = struct {
    synthetic_font: ?SyntheticFontFailure = null,

    pub fn deinit(self: *ShapeFailure, allocator: Allocator) void {
        if (self.synthetic_font) |*failure| failure.deinit(allocator);
        self.* = .{};
    }

    fn recordSyntheticFont(
        self: *ShapeFailure,
        allocator: Allocator,
        requested: core.font.Face,
        selected: ResolvedFontFace,
    ) !void {
        if (self.synthetic_font != null) return;
        const requested_family = try allocator.dupe(u8, requested.family);
        errdefer allocator.free(requested_family);
        const selected_family = try allocator.dupe(u8, selected.family);
        errdefer allocator.free(selected_family);
        const selected_postscript_name = try allocator.dupe(u8, selected.postscript_name);
        errdefer allocator.free(selected_postscript_name);
        self.synthetic_font = .{
            .requested = .{
                .family = requested_family,
                .weight = requested.weight,
                .style = requested.style,
                .stretch = requested.stretch,
            },
            .selected_family = selected_family,
            .selected_postscript_name = selected_postscript_name,
            .synthetic_bold = selected.synthetic_bold,
            .synthetic_italic = selected.synthetic_italic,
            .source = selected.source,
        };
    }
};

pub fn validateResolvedFontFace(
    allocator: Allocator,
    requested: core.font.Face,
    selected: ResolvedFontFace,
    failure: ?*ShapeFailure,
) !void {
    if (selected.path.len == 0) return error.MissingFontResource;
    if (!selected.synthetic_bold and !selected.synthetic_italic) return;
    if (failure) |target| try target.recordSyntheticFont(allocator, requested, selected);
    return error.UnsupportedSyntheticFont;
}

pub fn formatSyntheticFontDiagnostic(buffer: []u8, failure: *const SyntheticFontFailure) []const u8 {
    const synthesis = if (failure.synthetic_bold and failure.synthetic_italic)
        "bold and italic"
    else if (failure.synthetic_bold)
        "bold"
    else
        "italic";
    const remedy = if (failure.synthetic_bold and failure.synthetic_italic)
        "install or select a font with an actual bold italic face, or use an available weight and style"
    else if (failure.synthetic_bold)
        "install or select a font with an actual bold face, or use an available weight such as 400"
    else
        "install or select a font with an actual italic face, or use an available style such as normal";
    const requested_family = std.mem.trim(u8, failure.requested.family, " \t");
    const selected_family = std.mem.trim(u8, failure.selected_family, " \t");
    const selected_name = if (failure.selected_postscript_name.len != 0)
        failure.selected_postscript_name
    else
        selected_family;
    const uses_fallback = requested_family.len != 0 and selected_family.len != 0 and
        !std.ascii.eqlIgnoreCase(requested_family, selected_family);
    if (uses_fallback and selected_name.len != 0) {
        return std.fmt.bufPrint(
            buffer,
            "FontFaceUnavailable: font '{s}' at weight {d} and style {s} resolved to synthesized {s} using fallback font '{s}', which ss cannot reproduce consistently in PDF and HTML; {s}",
            .{ requested_family, failure.requested.weight, @tagName(failure.requested.style), synthesis, selected_name, remedy },
        ) catch genericSyntheticFontDiagnostic();
    }
    return std.fmt.bufPrint(
        buffer,
        "FontFaceUnavailable: font '{s}' at weight {d} and style {s} resolved to synthesized {s}, which ss cannot reproduce consistently in PDF and HTML; {s}",
        .{ requested_family, failure.requested.weight, @tagName(failure.requested.style), synthesis, remedy },
    ) catch genericSyntheticFontDiagnostic();
}

pub fn genericSyntheticFontDiagnostic() []const u8 {
    return "FontFaceUnavailable: the local font system synthesized a font face that ss cannot reproduce consistently in PDF and HTML; install or select a font with an actual matching face, or use an available weight or style";
}

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

    pub fn restore(self: *Cache, cache_dir: []const u8) void {
        const profile_start = utils.measure_profile.start();
        defer utils.measure_profile.recordTextCacheRestore(profile_start);
        self.document_lock.lockUncancelable(self.io);
        defer self.document_lock.unlock(self.io);
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.clear();
        self.restoreLocked(cache_dir) catch self.clear();
    }

    pub fn persist(self: *Cache, cache_dir: []const u8) void {
        const profile_start = utils.measure_profile.start();
        defer utils.measure_profile.recordTextCachePersist(profile_start);
        self.document_lock.lockUncancelable(self.io);
        defer self.document_lock.unlock(self.io);
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.persistLocked(cache_dir) catch {};
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
        self.dirty = false;
    }

    fn restoreLocked(self: *Cache, cache_dir: []const u8) !void {
        const path = try persistentCachePath(self.allocator, cache_dir);
        defer self.allocator.free(path);
        const source = utils.fs.readFileAllocLimited(
            self.io,
            self.allocator,
            path,
            .limited(persistent_cache_file_limit),
        ) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(source);
        if (source.len < persistent_cache_checksum_size) return error.InvalidPersistentTextCache;
        const payload = source[0 .. source.len - persistent_cache_checksum_size];
        const expected_checksum = source[source.len - persistent_cache_checksum_size ..];
        var actual_checksum: [persistent_cache_checksum_size]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &actual_checksum, .{});
        if (!std.mem.eql(u8, &actual_checksum, expected_checksum)) {
            return error.InvalidPersistentTextCache;
        }
        var reader = CacheReader{ .source = payload };
        try reader.expectBytes(persistent_cache_version);
        try reader.expectString(nativeVersion(c.ss_pdf_pango_version_string()));
        try reader.expectString(nativeVersion(c.ss_pdf_harfbuzz_version_string()));
        if (try reader.integer(u32) != @as(u32, @intCast(c.ss_pdf_fontconfig_version()))) {
            return error.InvalidPersistentTextCache;
        }
        const entry_count = try reader.integer(u32);
        if (entry_count > max_entries) return error.InvalidPersistentTextCache;
        try self.shapes.ensureUnusedCapacity(entry_count);
        for (0..entry_count) |_| {
            var entry = try readPersistentEntry(self.allocator, &reader);
            var entry_live = true;
            errdefer if (entry_live) entry.deinit(self.allocator);
            if (self.shapes.contains(entry.key)) return error.InvalidPersistentTextCache;
            if (entry.value.byte_size > max_cached_bytes or self.shape_bytes > max_cached_bytes - entry.value.byte_size) {
                return error.InvalidPersistentTextCache;
            }
            entry.value.last_used.store(self.nextAccess(), .monotonic);
            self.shape_bytes += entry.value.byte_size;
            self.shapes.putAssumeCapacityNoClobber(entry.key, entry.value);
            entry_live = false;
        }
        if (!reader.atEnd()) return error.InvalidPersistentTextCache;
    }

    fn persistLocked(self: *Cache, cache_dir: []const u8) !void {
        if (!self.dirty) return;
        const directory = try std.fs.path.join(self.allocator, &.{ cache_dir, persistent_cache_directory });
        defer self.allocator.free(directory);
        try std.Io.Dir.cwd().createDirPath(self.io, directory);
        const path = try std.fs.path.join(self.allocator, &.{ directory, persistent_cache_filename });
        defer self.allocator.free(path);
        const temporary = try std.fmt.allocPrint(
            self.allocator,
            "{s}.tmp-{d}",
            .{ path, std.c.getpid() },
        );
        defer self.allocator.free(temporary);
        errdefer std.Io.Dir.cwd().deleteFile(self.io, temporary) catch {};

        var writer = CacheWriter{ .allocator = self.allocator };
        defer writer.bytes.deinit(self.allocator);
        try writer.append(persistent_cache_version);
        try writer.string(nativeVersion(c.ss_pdf_pango_version_string()));
        try writer.string(nativeVersion(c.ss_pdf_harfbuzz_version_string()));
        try writer.integer(u32, @intCast(c.ss_pdf_fontconfig_version()));
        try writer.integer(u32, @intCast(self.shapes.count()));
        var iterator = self.shapes.iterator();
        while (iterator.next()) |entry| try writePersistentEntry(&writer, entry.key_ptr.*, entry.value_ptr);
        var checksum: [persistent_cache_checksum_size]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(writer.bytes.items, &checksum, .{});
        try writer.append(&checksum);
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = temporary,
            .data = writer.bytes.items,
            .flags = .{ .truncate = true },
        });
        try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, self.io);
        self.dirty = false;
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
        self.dirty = true;
    }
};

const PersistentEntry = struct {
    key: CacheKey,
    value: CachedShape,

    fn deinit(self: *PersistentEntry, allocator: Allocator) void {
        allocator.free(self.key.source);
        allocator.free(self.key.family);
        self.value.deinit(allocator);
    }
};

const CacheWriter = struct {
    allocator: Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn append(self: *CacheWriter, value: []const u8) !void {
        if (value.len > persistent_cache_file_limit or
            self.bytes.items.len > persistent_cache_file_limit - value.len)
        {
            return error.PersistentTextCacheTooLarge;
        }
        try self.bytes.appendSlice(self.allocator, value);
    }

    fn integer(self: *CacheWriter, comptime T: type, value: T) !void {
        var encoded: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &encoded, value, .little);
        try self.append(&encoded);
    }

    fn boolean(self: *CacheWriter, value: bool) !void {
        try self.integer(u8, @intFromBool(value));
    }

    fn float(self: *CacheWriter, value: f64) !void {
        try self.integer(u64, @bitCast(value));
    }

    fn string(self: *CacheWriter, value: []const u8) !void {
        if (value.len > std.math.maxInt(u32)) return error.PersistentTextCacheTooLarge;
        try self.integer(u32, @intCast(value.len));
        try self.append(value);
    }
};

const CacheReader = struct {
    source: []const u8,
    offset: usize = 0,
    allocated_bytes: usize = 0,

    fn take(self: *CacheReader, length: usize) ![]const u8 {
        if (length > self.source.len - self.offset) return error.InvalidPersistentTextCache;
        const result = self.source[self.offset..][0..length];
        self.offset += length;
        return result;
    }

    fn expectBytes(self: *CacheReader, expected: []const u8) !void {
        if (!std.mem.eql(u8, try self.take(expected.len), expected)) {
            return error.InvalidPersistentTextCache;
        }
    }

    fn expectString(self: *CacheReader, expected: []const u8) !void {
        const length: usize = try self.integer(u32);
        if (!std.mem.eql(u8, try self.take(length), expected)) {
            return error.InvalidPersistentTextCache;
        }
    }

    fn integer(self: *CacheReader, comptime T: type) !T {
        const bytes = try self.take(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }

    fn boolean(self: *CacheReader) !bool {
        return switch (try self.integer(u8)) {
            0 => false,
            1 => true,
            else => error.InvalidPersistentTextCache,
        };
    }

    fn float(self: *CacheReader) !f64 {
        const value: f64 = @bitCast(try self.integer(u64));
        if (!std.math.isFinite(value)) return error.InvalidPersistentTextCache;
        return value;
    }

    fn reserve(self: *CacheReader, length: usize) !void {
        if (length > Cache.max_cached_bytes or self.allocated_bytes > Cache.max_cached_bytes - length) {
            return error.InvalidPersistentTextCache;
        }
        self.allocated_bytes += length;
    }

    fn arrayLength(self: *CacheReader, comptime T: type) !usize {
        const count: usize = try self.integer(u32);
        const byte_size = std.math.mul(usize, count, @sizeOf(T)) catch
            return error.InvalidPersistentTextCache;
        try self.reserve(byte_size);
        return count;
    }

    fn ownedString(self: *CacheReader, allocator: Allocator) ![]u8 {
        const length: usize = try self.integer(u32);
        try self.reserve(length);
        return try allocator.dupe(u8, try self.take(length));
    }

    fn ownedStringZ(self: *CacheReader, allocator: Allocator) ![:0]u8 {
        const length: usize = try self.integer(u32);
        if (length == std.math.maxInt(usize)) return error.InvalidPersistentTextCache;
        try self.reserve(length + 1);
        return try allocator.dupeZ(u8, try self.take(length));
    }

    fn atEnd(self: *const CacheReader) bool {
        return self.offset == self.source.len;
    }
};

fn persistentCachePath(allocator: Allocator, cache_dir: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{
        cache_dir,
        persistent_cache_directory,
        persistent_cache_filename,
    });
}

fn nativeVersion(pointer: [*c]const u8) []const u8 {
    if (pointer == null) return "";
    const sentinel: [*:0]const u8 = @ptrCast(pointer);
    return std.mem.span(sentinel);
}

fn writePersistentEntry(writer: *CacheWriter, key: CacheKey, value: *const CachedShape) !void {
    try writer.string(key.source);
    try writer.string(key.family);
    try writer.integer(u16, key.weight);
    try writer.integer(u8, @intFromEnum(key.style));
    try writer.integer(u8, @intFromEnum(key.stretch));
    try writer.integer(u64, key.font_size_bits);
    try writer.integer(u64, key.width_bits);
    try writer.boolean(key.wrap);
    try writer.append(&key.font_environment);
    try writeLayout(writer, &value.layout);
    if (value.fonts.len > std.math.maxInt(u32)) return error.PersistentTextCacheTooLarge;
    try writer.integer(u32, @intCast(value.fonts.len));
    for (value.fonts) |font| try writeFontDependency(writer, font);
}

fn readPersistentEntry(allocator: Allocator, reader: *CacheReader) !PersistentEntry {
    const source = try reader.ownedString(allocator);
    errdefer allocator.free(source);
    const family = try reader.ownedString(allocator);
    errdefer allocator.free(family);
    if (!std.unicode.utf8ValidateSlice(source) or !std.unicode.utf8ValidateSlice(family)) {
        return error.InvalidPersistentTextCache;
    }
    const weight = try reader.integer(u16);
    const style = std.enums.fromInt(core.font.Style, try reader.integer(u8)) orelse
        return error.InvalidPersistentTextCache;
    const stretch = std.enums.fromInt(core.font.Stretch, try reader.integer(u8)) orelse
        return error.InvalidPersistentTextCache;
    const font_size_bits = try reader.integer(u64);
    const width_bits = try reader.integer(u64);
    const wrap = try reader.boolean();
    var font_environment: FontEnvironmentId = undefined;
    @memcpy(&font_environment, try reader.take(font_environment.len));
    const key = CacheKey{
        .source = source,
        .family = family,
        .weight = weight,
        .style = style,
        .stretch = stretch,
        .font_size_bits = font_size_bits,
        .width_bits = width_bits,
        .wrap = wrap,
        .font_environment = font_environment,
    };
    const font_size: f64 = @bitCast(key.font_size_bits);
    const width: f64 = @bitCast(key.width_bits);
    if (!std.math.isFinite(font_size) or font_size <= 0 or !std.math.isFinite(width)) {
        return error.InvalidPersistentTextCache;
    }
    var layout = try readLayout(allocator, reader);
    errdefer layout.deinit(allocator);
    if (!std.mem.eql(u8, layout.source_text, source)) return error.InvalidPersistentTextCache;
    const font_count = try reader.arrayLength(FontDependency);
    const fonts = try allocator.alloc(FontDependency, font_count);
    var initialized_fonts: usize = 0;
    errdefer {
        for (fonts[0..initialized_fonts]) |*font| font.deinit(allocator);
        allocator.free(fonts);
    }
    for (fonts) |*font| {
        font.* = try readFontDependency(allocator, reader);
        initialized_fonts += 1;
    }
    if (!layoutFontsPresent(&layout, fonts)) return error.InvalidPersistentTextCache;
    return .{
        .key = key,
        .value = .{
            .layout = layout,
            .fonts = fonts,
            .last_used = .init(0),
            .materialized_epoch = 0,
            .byte_size = source.len +| family.len +|
                layout.ownedByteSize() +| fontDependenciesByteSize(fonts),
        },
    };
}

fn writeLayout(writer: *CacheWriter, layout: *const render.TextLayout) !void {
    try writer.string(layout.source_text);
    inline for (.{ layout.lines.len, layout.runs.len, layout.clusters.len, layout.glyphs.len }) |count| {
        if (count > std.math.maxInt(u32)) return error.PersistentTextCacheTooLarge;
        try writer.integer(u32, @intCast(count));
    }
    try writeRect(writer, layout.logical_bounds);
    try writeRect(writer, layout.ink_bounds);
    for (layout.lines) |line| {
        try writeRange(writer, line.source);
        try writeRange(writer, line.run_range);
        try writer.float(line.baseline_y);
        try writeRect(writer, line.logical_bounds);
        try writeRect(writer, line.ink_bounds);
    }
    for (layout.runs) |run| {
        try writeRange(writer, run.source);
        try writeRange(writer, run.glyph_range);
        try writeRange(writer, run.cluster_range);
        try writer.float(run.x);
        try writer.float(run.baseline_y);
        try writer.float(run.advance);
        try writer.append(&run.font_instance);
        try writer.string(run.language);
        try writer.integer(u8, @intFromEnum(run.direction));
        try writer.integer(u8, run.bidi_level);
    }
    for (layout.clusters) |cluster| {
        try writeRange(writer, cluster.source);
        try writeRange(writer, cluster.glyph_range);
        try writer.float(cluster.x);
        try writer.float(cluster.baseline_y);
        try writer.float(cluster.advance_x);
        try writer.float(cluster.advance_y);
        try writeRect(writer, cluster.logical_bounds);
        try writeRect(writer, cluster.ink_bounds);
    }
    for (layout.glyphs) |glyph| {
        try writer.integer(u32, glyph.id);
        try writer.float(glyph.offset_x);
        try writer.float(glyph.offset_y);
        try writer.float(glyph.advance_x);
        try writer.float(glyph.advance_y);
    }
}

fn readLayout(allocator: Allocator, reader: *CacheReader) !render.TextLayout {
    const source_text = try reader.ownedStringZ(allocator);
    errdefer allocator.free(source_text);
    if (!std.unicode.utf8ValidateSlice(source_text)) return error.InvalidPersistentTextCache;
    const line_count = try reader.arrayLength(render.TextLine);
    const run_count = try reader.arrayLength(render.TextRun);
    const cluster_count = try reader.arrayLength(render.TextCluster);
    const glyph_count = try reader.arrayLength(render.Glyph);
    const logical_bounds = try readRect(reader);
    const ink_bounds = try readRect(reader);
    const lines = try allocator.alloc(render.TextLine, line_count);
    errdefer allocator.free(lines);
    for (lines) |*line| line.* = .{
        .source = try readRange(reader),
        .run_range = try readRange(reader),
        .baseline_y = try reader.float(),
        .logical_bounds = try readRect(reader),
        .ink_bounds = try readRect(reader),
    };
    const runs = try allocator.alloc(render.TextRun, run_count);
    var initialized_runs: usize = 0;
    errdefer {
        for (runs[0..initialized_runs]) |*run| allocator.free(run.language);
        allocator.free(runs);
    }
    for (runs) |*run| {
        run.* = try readTextRun(allocator, reader);
        initialized_runs += 1;
    }
    const clusters = try allocator.alloc(render.TextCluster, cluster_count);
    errdefer allocator.free(clusters);
    for (clusters) |*cluster| cluster.* = .{
        .source = try readRange(reader),
        .glyph_range = try readRange(reader),
        .x = try reader.float(),
        .baseline_y = try reader.float(),
        .advance_x = try reader.float(),
        .advance_y = try reader.float(),
        .logical_bounds = try readRect(reader),
        .ink_bounds = try readRect(reader),
    };
    const glyphs = try allocator.alloc(render.Glyph, glyph_count);
    errdefer allocator.free(glyphs);
    for (glyphs) |*glyph| glyph.* = .{
        .id = try reader.integer(u32),
        .offset_x = try reader.float(),
        .offset_y = try reader.float(),
        .advance_x = try reader.float(),
        .advance_y = try reader.float(),
    };
    const result = render.TextLayout{
        .source_text = source_text,
        .lines = lines,
        .runs = runs,
        .clusters = clusters,
        .glyphs = glyphs,
        .logical_bounds = logical_bounds,
        .ink_bounds = ink_bounds,
    };
    if (!validLayout(&result)) return error.InvalidPersistentTextCache;
    return result;
}

fn readTextRun(allocator: Allocator, reader: *CacheReader) !render.TextRun {
    const source = try readRange(reader);
    const glyph_range = try readRange(reader);
    const cluster_range = try readRange(reader);
    const x = try reader.float();
    const baseline_y = try reader.float();
    const advance = try reader.float();
    var font_instance: render.FontInstanceId = undefined;
    @memcpy(font_instance[0..], try reader.take(font_instance.len));
    const language = try reader.ownedStringZ(allocator);
    errdefer allocator.free(language);
    if (!std.unicode.utf8ValidateSlice(language)) return error.InvalidPersistentTextCache;
    const direction = std.enums.fromInt(render.TextDirection, try reader.integer(u8)) orelse
        return error.InvalidPersistentTextCache;
    return .{
        .source = source,
        .glyph_range = glyph_range,
        .cluster_range = cluster_range,
        .x = x,
        .baseline_y = baseline_y,
        .advance = advance,
        .font_instance = font_instance,
        .language = language,
        .direction = direction,
        .bidi_level = try reader.integer(u8),
    };
}

fn writeFontDependency(writer: *CacheWriter, font: FontDependency) !void {
    try writer.string(font.path);
    try writer.append(&font.resource);
    try writer.append(&font.instance);
    try writer.integer(u32, font.face_index);
    try writer.string(font.family);
    try writer.string(font.postscript_name);
    try writer.integer(u16, font.weight);
    try writer.integer(u8, @intFromEnum(font.style));
    try writer.integer(u8, @intFromEnum(font.stretch));
    inline for (.{
        font.ascent_ratio,
        font.descent_ratio,
        font.line_gap_ratio,
        font.underline_position_ratio,
        font.underline_thickness_ratio,
        font.strikethrough_position_ratio,
        font.strikethrough_thickness_ratio,
    }) |value| try writer.float(value);
    try writer.boolean(font.math != null);
    if (font.math) |math| {
        inline for (std.meta.fields(render.MathConstants)) |field| {
            try writer.float(@field(math, field.name));
        }
    }
    try writer.boolean(font.family_substitution);
}

fn readFontDependency(allocator: Allocator, reader: *CacheReader) !FontDependency {
    const path = try reader.ownedString(allocator);
    errdefer allocator.free(path);
    var resource: render.ResourceId = undefined;
    @memcpy(resource[0..], try reader.take(resource.len));
    var instance: render.FontInstanceId = undefined;
    @memcpy(instance[0..], try reader.take(instance.len));
    const face_index = try reader.integer(u32);
    const family = try reader.ownedString(allocator);
    errdefer allocator.free(family);
    const postscript_name = try reader.ownedString(allocator);
    errdefer allocator.free(postscript_name);
    if (path.len == 0 or family.len == 0 or
        !std.unicode.utf8ValidateSlice(family) or !std.unicode.utf8ValidateSlice(postscript_name))
    {
        return error.InvalidPersistentTextCache;
    }
    const weight = try reader.integer(u16);
    if (weight == 0 or weight > 1000) return error.InvalidPersistentTextCache;
    const style = std.enums.fromInt(core.font.Style, try reader.integer(u8)) orelse
        return error.InvalidPersistentTextCache;
    const stretch = std.enums.fromInt(core.font.Stretch, try reader.integer(u8)) orelse
        return error.InvalidPersistentTextCache;
    const ascent_ratio = try reader.float();
    const descent_ratio = try reader.float();
    const line_gap_ratio = try reader.float();
    const underline_position_ratio = try reader.float();
    const underline_thickness_ratio = try reader.float();
    const strikethrough_position_ratio = try reader.float();
    const strikethrough_thickness_ratio = try reader.float();
    const maybe_math = if (try reader.boolean()) blk: {
        var math: render.MathConstants = undefined;
        inline for (std.meta.fields(render.MathConstants)) |field| {
            @field(math, field.name) = try reader.float();
        }
        break :blk math;
    } else null;
    return .{
        .path = path,
        .resource = resource,
        .instance = instance,
        .face_index = face_index,
        .family = family,
        .postscript_name = postscript_name,
        .weight = weight,
        .style = style,
        .stretch = stretch,
        .ascent_ratio = ascent_ratio,
        .descent_ratio = descent_ratio,
        .line_gap_ratio = line_gap_ratio,
        .underline_position_ratio = underline_position_ratio,
        .underline_thickness_ratio = underline_thickness_ratio,
        .strikethrough_position_ratio = strikethrough_position_ratio,
        .strikethrough_thickness_ratio = strikethrough_thickness_ratio,
        .math = maybe_math,
        .family_substitution = try reader.boolean(),
    };
}

fn writeRange(writer: *CacheWriter, value: TextRange) !void {
    try writer.integer(u32, value.start);
    try writer.integer(u32, value.end);
}

fn readRange(reader: *CacheReader) !TextRange {
    const result = TextRange{
        .start = try reader.integer(u32),
        .end = try reader.integer(u32),
    };
    if (result.start > result.end) return error.InvalidPersistentTextCache;
    return result;
}

fn writeRect(writer: *CacheWriter, rect: render.Rect) !void {
    try writer.float(rect.x);
    try writer.float(rect.y);
    try writer.float(rect.width);
    try writer.float(rect.height);
}

fn readRect(reader: *CacheReader) !render.Rect {
    const result = render.Rect{
        .x = try reader.float(),
        .y = try reader.float(),
        .width = try reader.float(),
        .height = try reader.float(),
    };
    if (!result.isValid()) return error.InvalidPersistentTextCache;
    return result;
}

fn validLayout(layout: *const render.TextLayout) bool {
    for (layout.lines) |line| {
        if (line.source.end > layout.source_text.len or line.run_range.end > layout.runs.len) return false;
    }
    for (layout.runs) |run| {
        if (run.source.end > layout.source_text.len or
            run.glyph_range.end > layout.glyphs.len or
            run.cluster_range.end > layout.clusters.len)
        {
            return false;
        }
    }
    for (layout.clusters) |cluster| {
        if (cluster.source.end > layout.source_text.len or cluster.glyph_range.end > layout.glyphs.len) return false;
    }
    return true;
}

fn layoutFontsPresent(layout: *const render.TextLayout, fonts: []const FontDependency) bool {
    for (layout.runs) |run| {
        var found = false;
        for (fonts) |font| {
            if (!std.mem.eql(u8, &run.font_instance, &font.instance)) continue;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return true;
}

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

pub fn diagnosticMessageForError(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.FontEnvironmentRefreshFailed => "FontSetupFailed: ss could not initialize or refresh Pango's Fontconfig backend. Run 'fc-list'. If it fails, repair Fontconfig or unset invalid FONTCONFIG_FILE and FONTCONFIG_PATH values. If it succeeds, verify that Pango includes its Fontconfig/FreeType backend and that ss, Pango, and Fontconfig come from the same package source. On Homebrew systems, run 'brew reinstall pango fontconfig', then rebuild or reinstall ss against those libraries",
        error.PangoCreateFailed => "TextLayoutUnavailable: Pango could not initialize or produce usable text layout data; verify that Pango and Fontconfig are installed, confirm that 'fc-list' succeeds, and check FONTCONFIG_FILE and FONTCONFIG_PATH",
        error.FontEnvironmentChanged => "FontEnvironmentChanged: the system font catalog changed while the document was being processed; retry after font installation or font-cache updates finish",
        else => null,
    };
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
    return shapeImpl(allocator, io, resources, fonts, source, requested_font, font_size, width, wrap, cache, null);
}

pub fn shapeWithFailure(
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
    failure: *ShapeFailure,
) !render.TextLayout {
    return shapeImpl(allocator, io, resources, fonts, source, requested_font, font_size, width, wrap, cache, failure);
}

fn shapeImpl(
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
    failure: ?*ShapeFailure,
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
    const layout = try copy(allocator, io, resources, fonts, source, requested_font, font_size, native, failure);
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
    failure: ?*ShapeFailure,
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
        try validateResolvedFontFace(allocator, requested_font, .{
            .path = font_path,
            .family = std.mem.span(run.font_family),
            .postscript_name = std.mem.span(run.font_postscript_name),
            .synthetic_bold = run.synthetic_bold != 0,
            .synthetic_italic = run.synthetic_italic != 0,
            .source = .{
                .start = @intCast(run.source_start),
                .end = @intCast(run.source_end),
            },
        }, failure);
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
