const std = @import("std");

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
    latex,
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
    latex,
    icon,
    vector_pdf,
    raster,
};

pub const CommandKind = enum {
    latex,
    other,
};

pub const AnalysisKind = enum {
    embedded_parse,
    embedded_clone,
    module_parse,
    module_graph,
    module_index,
    document_state,
    snapshot_facts,
    static_semantics,
    semantics_types,
    semantics_fields,
    semantics_functions,
    semantics_pages,
    semantics_dependency_queries,
    semantics_call_graph,
    semantics_function_bodies,
    semantics_object_declarations,
    semantics_placement_effects,
    execution_graph,
};

pub const WysiwygKind = enum {
    evaluate_solve,
    evaluate,
    execute_units,
    materialize_display,
    prepare,
    solve,
    render_compile,
    snapshot,
};

pub const RenderCompileKind = enum {
    prepare_fonts,
    font_environment,
    text_cache_begin,
    workers,
    merge_pages,
    finish_document,
    finish_sources,
    finish_semantics,
    finish_catalogs,
    finish_validation,
};

var enabled_state: std.atomic.Value(bool) = .init(false);

var text_advance_hits = CountTime{};
var text_advance_misses = CountTime{};
var text_visual_hits = CountTime{};
var text_visual_misses = CountTime{};
var text_shape_hits = CountTime{};
var text_shape_misses = CountTime{};
var text_cache_restore = CountTime{};
var text_cache_begin_document = CountTime{};
var text_cache_materialize = CountTime{};
var text_cache_share = CountTime{};
var text_cache_clone = CountTime{};
var text_cache_persist = CountTime{};
var render_page_hits = CountTime{};
var render_page_misses = CountTime{};
var render_compile_prepare_fonts = CountTime{};
var render_compile_font_environment = CountTime{};
var render_compile_text_cache_begin = CountTime{};
var render_compile_workers = CountTime{};
var render_compile_merge_pages = CountTime{};
var render_compile_finish_document = CountTime{};
var render_compile_finish_sources = CountTime{};
var render_compile_finish_semantics = CountTime{};
var render_compile_finish_catalogs = CountTime{};
var render_compile_finish_validation = CountTime{};

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
var intrinsic_latex = CountTime{};
var intrinsic_vector_asset = CountTime{};
var intrinsic_raster_asset = CountTime{};
var intrinsic_shape = CountTime{};
var intrinsic_chrome_only = CountTime{};
var intrinsic_other = CountTime{};

var artifact_scan_latex_hits = CountTime{};
var artifact_scan_latex_misses = CountTime{};
var artifact_scan_icon_hits = CountTime{};
var artifact_scan_icon_misses = CountTime{};
var artifact_scan_vector_pdf_hits = CountTime{};
var artifact_scan_vector_pdf_misses = CountTime{};
var artifact_scan_raster_hits = CountTime{};
var artifact_scan_raster_misses = CountTime{};

var artifact_build_latex = CountTime{};
var artifact_build_icon = CountTime{};
var artifact_build_vector_pdf = CountTime{};
var artifact_build_raster = CountTime{};
var artifact_build_wall = CountTime{};

var command_latex = CountTime{};
var command_other = CountTime{};
var command_failures = CountTime{};

var analysis_embedded_parse = CountTime{};
var analysis_embedded_clone = CountTime{};
var analysis_module_parse = CountTime{};
var analysis_module_graph = CountTime{};
var analysis_module_index = CountTime{};
var analysis_document_state = CountTime{};
var analysis_snapshot_facts = CountTime{};
var analysis_static_semantics = CountTime{};
var analysis_semantics_types = CountTime{};
var analysis_semantics_fields = CountTime{};
var analysis_semantics_functions = CountTime{};
var analysis_semantics_pages = CountTime{};
var analysis_semantics_dependency_queries = CountTime{};
var analysis_semantics_call_graph = CountTime{};
var analysis_semantics_function_bodies = CountTime{};
var analysis_semantics_object_declarations = CountTime{};
var analysis_semantics_placement_effects = CountTime{};
var analysis_execution_graph = CountTime{};

var wysiwyg_evaluate_solve = CountTime{};
var wysiwyg_evaluate = CountTime{};
var wysiwyg_execute_units = CountTime{};
var wysiwyg_materialize_display = CountTime{};
var wysiwyg_prepare = CountTime{};
var wysiwyg_solve = CountTime{};
var wysiwyg_render_compile = CountTime{};
var wysiwyg_snapshot = CountTime{};

pub fn isEnabled() bool {
    return enabled_state.load(.monotonic);
}

pub fn setEnabled(enabled: bool) void {
    enabled_state.store(enabled, .monotonic);
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

pub fn recordTextShape(hit: bool, start_ns: i128) void {
    if (start_ns == 0) return;
    if (hit)
        text_shape_hits.add(elapsed(start_ns))
    else
        text_shape_misses.add(elapsed(start_ns));
}

pub fn recordTextCacheRestore(start_ns: i128) void {
    if (start_ns != 0) text_cache_restore.add(elapsed(start_ns));
}

pub fn recordTextCacheBeginDocument(start_ns: i128) void {
    if (start_ns != 0) text_cache_begin_document.add(elapsed(start_ns));
}

pub fn recordTextCacheMaterialize(start_ns: i128) void {
    if (start_ns != 0) text_cache_materialize.add(elapsed(start_ns));
}

pub fn recordTextCacheShare(start_ns: i128) void {
    if (start_ns != 0) text_cache_share.add(elapsed(start_ns));
}

pub fn recordTextCacheClone(start_ns: i128) void {
    if (start_ns != 0) text_cache_clone.add(elapsed(start_ns));
}

pub fn recordTextCachePersist(start_ns: i128) void {
    if (start_ns != 0) text_cache_persist.add(elapsed(start_ns));
}

pub fn recordRenderPage(hit: bool, start_ns: i128) void {
    if (start_ns == 0) return;
    if (hit)
        render_page_hits.add(elapsed(start_ns))
    else
        render_page_misses.add(elapsed(start_ns));
}

pub fn recordRenderCompile(kind: RenderCompileKind, start_ns: i128) void {
    if (start_ns == 0) return;
    const counter = switch (kind) {
        .prepare_fonts => &render_compile_prepare_fonts,
        .font_environment => &render_compile_font_environment,
        .text_cache_begin => &render_compile_text_cache_begin,
        .workers => &render_compile_workers,
        .merge_pages => &render_compile_merge_pages,
        .finish_document => &render_compile_finish_document,
        .finish_sources => &render_compile_finish_sources,
        .finish_semantics => &render_compile_finish_semantics,
        .finish_catalogs => &render_compile_finish_catalogs,
        .finish_validation => &render_compile_finish_validation,
    };
    counter.add(elapsed(start_ns));
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

pub fn recordAnalysis(kind: AnalysisKind, start_ns: i128) void {
    if (start_ns == 0) return;
    analysisCounter(kind).add(elapsed(start_ns));
}

pub fn recordWysiwyg(kind: WysiwygKind, start_ns: i128) void {
    if (start_ns == 0) return;
    const counter = switch (kind) {
        .evaluate_solve => &wysiwyg_evaluate_solve,
        .evaluate => &wysiwyg_evaluate,
        .execute_units => &wysiwyg_execute_units,
        .materialize_display => &wysiwyg_materialize_display,
        .prepare => &wysiwyg_prepare,
        .solve => &wysiwyg_solve,
        .render_compile => &wysiwyg_render_compile,
        .snapshot => &wysiwyg_snapshot,
    };
    counter.add(elapsed(start_ns));
}

pub fn printIfEnabled() void {
    if (!isEnabled()) return;

    std.debug.print("\n[measure-profile]\n", .{});
    printCachePair("text advance", &text_advance_hits, &text_advance_misses);
    printCachePair("text visual", &text_visual_hits, &text_visual_misses);
    printCachePair("text shape", &text_shape_hits, &text_shape_misses);
    printCounter("text cache restore", &text_cache_restore);
    printCounter("text cache begin document", &text_cache_begin_document);
    printCounter("text cache materialize", &text_cache_materialize);
    printCounter("text cache share", &text_cache_share);
    printCounter("text cache clone", &text_cache_clone);
    printCounter("text cache persist", &text_cache_persist);
    printCachePair("render page", &render_page_hits, &render_page_misses);
    printCounter("render compile prepare fonts", &render_compile_prepare_fonts);
    printCounter("render compile font environment", &render_compile_font_environment);
    printCounter("render compile text cache begin", &render_compile_text_cache_begin);
    printCounter("render compile workers", &render_compile_workers);
    printCounter("render compile merge pages", &render_compile_merge_pages);
    printCounter("render compile finish document", &render_compile_finish_document);
    printCounter("render compile finish sources", &render_compile_finish_sources);
    printCounter("render compile finish semantics", &render_compile_finish_semantics);
    printCounter("render compile finish catalogs", &render_compile_finish_catalogs);
    printCounter("render compile finish validation", &render_compile_finish_validation);

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
    printCounter("intrinsic latex", &intrinsic_latex);
    printCounter("intrinsic vector asset", &intrinsic_vector_asset);
    printCounter("intrinsic raster asset", &intrinsic_raster_asset);
    printCounter("intrinsic shape", &intrinsic_shape);
    printCounter("intrinsic chrome only", &intrinsic_chrome_only);
    printCounter("intrinsic other", &intrinsic_other);

    printCachePair("artifact scan latex", &artifact_scan_latex_hits, &artifact_scan_latex_misses);
    printCachePair("artifact scan icon", &artifact_scan_icon_hits, &artifact_scan_icon_misses);
    printCachePair("artifact scan vector pdf", &artifact_scan_vector_pdf_hits, &artifact_scan_vector_pdf_misses);
    printCachePair("artifact scan raster", &artifact_scan_raster_hits, &artifact_scan_raster_misses);
    printCounter("artifact build latex", &artifact_build_latex);
    printCounter("artifact build icon", &artifact_build_icon);
    printCounter("artifact build vector pdf", &artifact_build_vector_pdf);
    printCounter("artifact build raster", &artifact_build_raster);
    printCounter("artifact build wall", &artifact_build_wall);

    printCounter("command latex", &command_latex);
    printCounter("command other", &command_other);
    printCounter("command failures", &command_failures);

    printCounter("analysis embedded parse", &analysis_embedded_parse);
    printCounter("analysis embedded clone", &analysis_embedded_clone);
    printCounter("analysis module parse", &analysis_module_parse);
    printCounter("analysis module graph", &analysis_module_graph);
    printCounter("analysis module index", &analysis_module_index);
    printCounter("analysis document state", &analysis_document_state);
    printCounter("analysis snapshot facts", &analysis_snapshot_facts);
    printCounter("analysis static semantics", &analysis_static_semantics);
    printCounter("analysis semantics types", &analysis_semantics_types);
    printCounter("analysis semantics fields", &analysis_semantics_fields);
    printCounter("analysis semantics functions", &analysis_semantics_functions);
    printCounter("analysis semantics pages", &analysis_semantics_pages);
    printCounter("analysis semantics dependency queries", &analysis_semantics_dependency_queries);
    printCounter("analysis semantics call graph", &analysis_semantics_call_graph);
    printCounter("analysis semantics function bodies", &analysis_semantics_function_bodies);
    printCounter("analysis semantics object declarations", &analysis_semantics_object_declarations);
    printCounter("analysis semantics placement effects", &analysis_semantics_placement_effects);
    printCounter("analysis execution graph", &analysis_execution_graph);

    printCounter("WYSIWYG evaluate and solve", &wysiwyg_evaluate_solve);
    printCounter("WYSIWYG evaluate", &wysiwyg_evaluate);
    printCounter("WYSIWYG execute units", &wysiwyg_execute_units);
    printCounter("WYSIWYG materialize display", &wysiwyg_materialize_display);
    printCounter("WYSIWYG prepare", &wysiwyg_prepare);
    printCounter("WYSIWYG solve", &wysiwyg_solve);
    printCounter("WYSIWYG render compile", &wysiwyg_render_compile);
    printCounter("WYSIWYG snapshot", &wysiwyg_snapshot);
}

fn analysisCounter(kind: AnalysisKind) *CountTime {
    return switch (kind) {
        .embedded_parse => &analysis_embedded_parse,
        .embedded_clone => &analysis_embedded_clone,
        .module_parse => &analysis_module_parse,
        .module_graph => &analysis_module_graph,
        .module_index => &analysis_module_index,
        .document_state => &analysis_document_state,
        .snapshot_facts => &analysis_snapshot_facts,
        .static_semantics => &analysis_static_semantics,
        .semantics_types => &analysis_semantics_types,
        .semantics_fields => &analysis_semantics_fields,
        .semantics_functions => &analysis_semantics_functions,
        .semantics_pages => &analysis_semantics_pages,
        .semantics_dependency_queries => &analysis_semantics_dependency_queries,
        .semantics_call_graph => &analysis_semantics_call_graph,
        .semantics_function_bodies => &analysis_semantics_function_bodies,
        .semantics_object_declarations => &analysis_semantics_object_declarations,
        .semantics_placement_effects => &analysis_semantics_placement_effects,
        .execution_graph => &analysis_execution_graph,
    };
}

fn monotonicNowNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn commandKind(argv0: []const u8) CommandKind {
    const name = std.fs.path.basename(argv0);
    if (std.ascii.eqlIgnoreCase(name, "pdflatex") or std.ascii.eqlIgnoreCase(name, "lualatex")) return .latex;
    return .other;
}

fn renderIntrinsicCounter(kind: RenderMeasureKind) *CountTime {
    return switch (kind) {
        .text => &intrinsic_text,
        .code => &intrinsic_code,
        .latex => &intrinsic_latex,
        .vector_asset => &intrinsic_vector_asset,
        .raster_asset => &intrinsic_raster_asset,
        .shape => &intrinsic_shape,
        .chrome_only => &intrinsic_chrome_only,
        .other => &intrinsic_other,
    };
}

fn artifactScanCounter(kind: ArtifactKind, hit: bool) *CountTime {
    return switch (kind) {
        .latex => if (hit) &artifact_scan_latex_hits else &artifact_scan_latex_misses,
        .icon => if (hit) &artifact_scan_icon_hits else &artifact_scan_icon_misses,
        .vector_pdf => if (hit) &artifact_scan_vector_pdf_hits else &artifact_scan_vector_pdf_misses,
        .raster => if (hit) &artifact_scan_raster_hits else &artifact_scan_raster_misses,
    };
}

fn artifactBuildCounter(kind: ArtifactKind) *CountTime {
    return switch (kind) {
        .latex => &artifact_build_latex,
        .icon => &artifact_build_icon,
        .vector_pdf => &artifact_build_vector_pdf,
        .raster => &artifact_build_raster,
    };
}

fn commandCounter(kind: CommandKind) *CountTime {
    return switch (kind) {
        .latex => &command_latex,
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
