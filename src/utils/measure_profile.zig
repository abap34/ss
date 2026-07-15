const std = @import("std");

const env_name = "SS_MEASURE_PROFILE";

const CountTime = struct {
    count: std.atomic.Value(u64) = .init(0),
    ns: std.atomic.Value(u64) = .init(0),

    fn add(self: *CountTime, duration_ns: u64) void {
        _ = self.count.fetchAdd(1, .monotonic);
        _ = self.ns.fetchAdd(duration_ns, .monotonic);
    }

    fn addCount(self: *CountTime, amount: u64, duration_ns: u64) void {
        _ = self.count.fetchAdd(amount, .monotonic);
        _ = self.ns.fetchAdd(duration_ns, .monotonic);
    }

    fn snapshot(self: *const CountTime) Snapshot {
        return .{
            .count = self.count.load(.monotonic),
            .ns = self.ns.load(.monotonic),
        };
    }
};

const Snapshot = struct {
    count: u64,
    ns: u64,
};

pub const TextKind = enum {
    advance,
    visual,
};

pub const RenderMeasureKind = enum {
    text,
    code,
    vector_math,
    vector_asset,
    raster_asset,
    shape,
    chrome_only,
    other,
};

pub const LayoutMeasurementCacheKind = enum {
    memory_hit,
    file_hit,
    file_miss,
    write,
};

pub const ArtifactKind = enum {
    math,
    icon,
    vector_pdf,
    raster,
};

pub const CommandKind = enum {
    pdflatex,
    other,
};

var enabled_state: std.atomic.Value(u8) = .init(0);

var text_advance_hits = CountTime{};
var text_advance_misses = CountTime{};
var text_visual_hits = CountTime{};
var text_visual_misses = CountTime{};

var layout_measure_total = CountTime{};
var layout_measure_lock_wait = CountTime{};
var layout_measure_object_command = CountTime{};
var layout_measure_cache_key = CountTime{};
var layout_measure_memory_hits = CountTime{};
var layout_measure_file_hits = CountTime{};
var layout_measure_file_misses = CountTime{};
var layout_measure_writes = CountTime{};

var intrinsic_text = CountTime{};
var intrinsic_code = CountTime{};
var intrinsic_vector_math = CountTime{};
var intrinsic_vector_asset = CountTime{};
var intrinsic_raster_asset = CountTime{};
var intrinsic_shape = CountTime{};
var intrinsic_chrome_only = CountTime{};
var intrinsic_other = CountTime{};

var artifact_scan_math_hits = CountTime{};
var artifact_scan_math_misses = CountTime{};
var artifact_scan_icon_hits = CountTime{};
var artifact_scan_icon_misses = CountTime{};
var artifact_scan_vector_pdf_hits = CountTime{};
var artifact_scan_vector_pdf_misses = CountTime{};
var artifact_scan_raster_hits = CountTime{};
var artifact_scan_raster_misses = CountTime{};

var artifact_build_math = CountTime{};
var artifact_build_icon = CountTime{};
var artifact_build_vector_pdf = CountTime{};
var artifact_build_raster = CountTime{};
var artifact_build_wall = CountTime{};

var command_pdflatex = CountTime{};
var command_other = CountTime{};
var command_failures = CountTime{};

pub fn isEnabled() bool {
    const state = enabled_state.load(.monotonic);
    if (state == 1) return false;
    if (state == 2) return true;
    const enabled = detectEnabled();
    enabled_state.store(if (enabled) 2 else 1, .monotonic);
    return enabled;
}

pub fn start() i128 {
    if (!isEnabled()) return 0;
    return monotonicNowNs();
}

pub fn elapsed(start_ns: i128) u64 {
    if (start_ns == 0) return 0;
    const delta = monotonicNowNs() - start_ns;
    if (delta <= 0) return 0;
    return @intCast(delta);
}

pub fn recordText(kind: TextKind, hit: bool, start_ns: i128) void {
    if (start_ns == 0) return;
    const duration = elapsed(start_ns);
    switch (kind) {
        .advance => if (hit) text_advance_hits.add(duration) else text_advance_misses.add(duration),
        .visual => if (hit) text_visual_hits.add(duration) else text_visual_misses.add(duration),
    }
}

pub fn recordLayoutMeasurementTotal(start_ns: i128) void {
    if (start_ns != 0) layout_measure_total.add(elapsed(start_ns));
}

pub fn recordLayoutMeasurementLockWait(start_ns: i128) void {
    if (start_ns != 0) layout_measure_lock_wait.add(elapsed(start_ns));
}

pub fn recordLayoutMeasurementObjectCommand(start_ns: i128) void {
    if (start_ns != 0) layout_measure_object_command.add(elapsed(start_ns));
}

pub fn recordLayoutMeasurementCacheKey(start_ns: i128) void {
    if (start_ns != 0) layout_measure_cache_key.add(elapsed(start_ns));
}

pub fn recordLayoutMeasurementCache(kind: LayoutMeasurementCacheKind, start_ns: i128) void {
    if (start_ns == 0) return;
    const duration = elapsed(start_ns);
    switch (kind) {
        .memory_hit => layout_measure_memory_hits.add(duration),
        .file_hit => layout_measure_file_hits.add(duration),
        .file_miss => layout_measure_file_misses.add(duration),
        .write => layout_measure_writes.add(duration),
    }
}

pub fn recordRenderIntrinsic(kind: RenderMeasureKind, start_ns: i128) void {
    if (start_ns == 0) return;
    renderIntrinsicCounter(kind).add(elapsed(start_ns));
}

pub fn recordArtifactScan(kind: ArtifactKind, hit: bool, start_ns: i128) void {
    if (start_ns == 0) return;
    artifactScanCounter(kind, hit).add(elapsed(start_ns));
}

pub fn recordArtifactBuild(kind: ArtifactKind, start_ns: i128) void {
    if (start_ns == 0) return;
    artifactBuildCounter(kind).add(elapsed(start_ns));
}

pub fn recordArtifactBuildMany(kind: ArtifactKind, count: usize, start_ns: i128) void {
    if (start_ns == 0 or count == 0) return;
    artifactBuildCounter(kind).addCount(@intCast(count), elapsed(start_ns));
}

pub fn recordArtifactBuildWall(miss_count: usize, start_ns: i128) void {
    if (start_ns == 0) return;
    artifact_build_wall.addCount(@intCast(miss_count), elapsed(start_ns));
}

pub fn recordCommand(argv0: []const u8, failed: bool, start_ns: i128) void {
    if (start_ns == 0) return;
    const duration = elapsed(start_ns);
    commandCounter(commandKind(argv0)).add(duration);
    if (failed) command_failures.add(duration);
}

pub fn printIfEnabled() void {
    if (!isEnabled()) return;

    std.debug.print("\n[measure-profile]\n", .{});
    printCachePair("text advance", &text_advance_hits, &text_advance_misses);
    printCachePair("text visual", &text_visual_hits, &text_visual_misses);

    printCounter("layout provider total", &layout_measure_total);
    printCounter("layout provider lock wait", &layout_measure_lock_wait);
    printCounter("layout object command build", &layout_measure_object_command);
    printCounter("layout cache key", &layout_measure_cache_key);
    printCounter("layout memory cache hit", &layout_measure_memory_hits);
    printCounter("layout file cache hit", &layout_measure_file_hits);
    printCounter("layout file cache miss", &layout_measure_file_misses);
    printCounter("layout cache write", &layout_measure_writes);

    printCounter("intrinsic text", &intrinsic_text);
    printCounter("intrinsic code", &intrinsic_code);
    printCounter("intrinsic vector math", &intrinsic_vector_math);
    printCounter("intrinsic vector asset", &intrinsic_vector_asset);
    printCounter("intrinsic raster asset", &intrinsic_raster_asset);
    printCounter("intrinsic shape", &intrinsic_shape);
    printCounter("intrinsic chrome only", &intrinsic_chrome_only);
    printCounter("intrinsic other", &intrinsic_other);

    printCachePair("artifact scan math", &artifact_scan_math_hits, &artifact_scan_math_misses);
    printCachePair("artifact scan icon", &artifact_scan_icon_hits, &artifact_scan_icon_misses);
    printCachePair("artifact scan vector pdf", &artifact_scan_vector_pdf_hits, &artifact_scan_vector_pdf_misses);
    printCachePair("artifact scan raster", &artifact_scan_raster_hits, &artifact_scan_raster_misses);
    printCounter("artifact build math", &artifact_build_math);
    printCounter("artifact build icon", &artifact_build_icon);
    printCounter("artifact build vector pdf", &artifact_build_vector_pdf);
    printCounter("artifact build raster", &artifact_build_raster);
    printCounter("artifact build wall", &artifact_build_wall);

    printCounter("command pdflatex", &command_pdflatex);
    printCounter("command other", &command_other);
    printCounter("command failures", &command_failures);
}

fn detectEnabled() bool {
    const raw = std.c.getenv(env_name) orelse return false;
    const value = std.mem.span(raw);
    if (value.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    if (std.ascii.eqlIgnoreCase(value, "off")) return false;
    if (std.ascii.eqlIgnoreCase(value, "no")) return false;
    return true;
}

fn monotonicNowNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn commandKind(argv0: []const u8) CommandKind {
    const name = std.fs.path.basename(argv0);
    if (std.ascii.eqlIgnoreCase(name, "pdflatex")) return .pdflatex;
    return .other;
}

fn renderIntrinsicCounter(kind: RenderMeasureKind) *CountTime {
    return switch (kind) {
        .text => &intrinsic_text,
        .code => &intrinsic_code,
        .vector_math => &intrinsic_vector_math,
        .vector_asset => &intrinsic_vector_asset,
        .raster_asset => &intrinsic_raster_asset,
        .shape => &intrinsic_shape,
        .chrome_only => &intrinsic_chrome_only,
        .other => &intrinsic_other,
    };
}

fn artifactScanCounter(kind: ArtifactKind, hit: bool) *CountTime {
    return switch (kind) {
        .math => if (hit) &artifact_scan_math_hits else &artifact_scan_math_misses,
        .icon => if (hit) &artifact_scan_icon_hits else &artifact_scan_icon_misses,
        .vector_pdf => if (hit) &artifact_scan_vector_pdf_hits else &artifact_scan_vector_pdf_misses,
        .raster => if (hit) &artifact_scan_raster_hits else &artifact_scan_raster_misses,
    };
}

fn artifactBuildCounter(kind: ArtifactKind) *CountTime {
    return switch (kind) {
        .math => &artifact_build_math,
        .icon => &artifact_build_icon,
        .vector_pdf => &artifact_build_vector_pdf,
        .raster => &artifact_build_raster,
    };
}

fn commandCounter(kind: CommandKind) *CountTime {
    return switch (kind) {
        .pdflatex => &command_pdflatex,
        .other => &command_other,
    };
}

fn printCounter(label: []const u8, counter: *const CountTime) void {
    const snap = counter.snapshot();
    if (snap.count == 0) return;
    std.debug.print("  {s}: {d} calls, {d:.3}s aggregate\n", .{
        label,
        snap.count,
        seconds(snap.ns),
    });
}

fn printCachePair(label: []const u8, hits: *const CountTime, misses: *const CountTime) void {
    const hit = hits.snapshot();
    const miss = misses.snapshot();
    if (hit.count == 0 and miss.count == 0) return;
    std.debug.print("  {s}: hit {d} ({d:.3}s), miss {d} ({d:.3}s)\n", .{
        label,
        hit.count,
        seconds(hit.ns),
        miss.count,
        seconds(miss.ns),
    });
}

fn seconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
}
