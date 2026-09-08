const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const analysis = @import("../analysis.zig");
const render_layout = @import("../render/layout.zig");
const render_resources = @import("render_resources");
const render_text = @import("render_text");
const editor_snapshot = @import("snapshot.zig");
const generated_edit = @import("edit/generated.zig");
const source = @import("reuse/source.zig");
const translations = @import("reuse/translations.zig");

pub const collectTranslations = translations.collectTranslations;
pub const translationPatchPreservesRenderedOutput = translations.translationPatchPreservesRenderedOutput;
const hasExternalRenderDependency = translations.hasExternalRenderDependency;

fn matchesFontEnvironment(snapshot: *const analysis.snapshot.AnalysisSnapshot, current: render_layout.FontEnvironmentToken) bool {
    const retained = if (snapshot.retained_layout_state) |*value| value else return false;
    const inputs = if (retained.reuse_inputs) |*value| value else return false;
    return render_text.sameFontEnvironment(inputs.font_environment, current);
}

pub fn translateRebuilt(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    prepared: *const render_layout.EvaluatedPreparedPages,
    previous: *analysis.snapshot.AnalysisSnapshot,
    generation: u64,
    highlight_languages: []const utils.highlight.Language,
    conflicts_json: []u8,
) !?analysis.snapshot.LayoutHookOutput {
    if (!matchesFontEnvironment(previous, prepared.font_environment)) return null;
    const previous_layout = if (previous.layout_output) |*value| value else return null;
    const previous_editor = if (previous_layout.editor) |*value| value else return null;
    var collected = try collectTranslations(allocator, state, &previous_layout.report) orelse return null;
    defer collected.deinit(allocator);
    if (!translationPatchPreservesRenderedOutput(state, &prepared.pages, collected.translations, highlight_languages)) return null;
    const editor = try editor_snapshot.buildTranslationPatch(
        allocator,
        state,
        generation,
        previous_editor,
        collected.translations,
        conflicts_json,
    );
    return .{ .editor = editor, .conflicts_json = conflicts_json, .report = collected.takeReport() };
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    resource_cache: ?*render_resources.SourceCache = null,
    highlight_cache: ?*render_layout.HighlightCache = null,
    cancellation: ?utils.Cancellation = null,
};

/// Applies only validated numeric position rewrites to an evaluated generation.
/// A failed solve discards the retained state so the caller can rebuild from source.
pub fn apply(ctx: Context, snapshot: *analysis.snapshot.AnalysisSnapshot, path: []const u8, generated: *const generated_edit.Edit, generation: u64) !bool {
    if (ctx.cancellation) |cancellation| try cancellation.check();
    const validation_start = utils.measure_profile.start();
    if (!source.canApply(snapshot, path, generated, generation)) return false;
    const retained = &snapshot.retained_layout_state.?;
    const state = &retained.state;

    utils.measure_profile.recordGeneratedEdit(.validation, validation_start);
    const prepare_start = utils.measure_profile.start();
    var discard_retained_state = false;
    defer if (discard_retained_state) {
        if (snapshot.retained_layout_state) |*value| value.deinit();
        snapshot.retained_layout_state = null;
    };

    if (state.has_external_evaluation_inputs) return false;
    var render_cache_lease = utils.render_cache.Lease.acquire(ctx.io) catch return false;
    defer render_cache_lease.deinit();
    const reuse_inputs = if (retained.reuse_inputs) |*value| value else return false;
    const pages = &reuse_inputs.pages;
    if (hasExternalRenderDependency(pages, snapshot.project.highlight.languages)) return false;
    utils.measure_profile.recordGeneratedEdit(.prepare, prepare_start);

    for (generated.replacements) |replacement| {
        state.constraints.items[replacement.index].offset = replacement.new_offset;
        source.syncConstraintUpdate(state, replacement);
    }
    discard_retained_state = true;
    const solve_start = utils.measure_profile.start();
    var results = render_layout.solvePreparedPages(ctx.io, state, pages, .{
        .page_id = generated.page_id,
        .font_environment = reuse_inputs.font_environment,
        .retained_measurements = &reuse_inputs.measurements,
        .resource_cache = ctx.resource_cache,
        .highlight_cache = ctx.highlight_cache,
        .highlight_languages = snapshot.project.highlight.languages,
        .cancellation = ctx.cancellation,
    }) catch |err| switch (err) {
        error.Canceled => return err,
        else => return false,
    };
    defer results.deinit(state.allocator);
    utils.measure_profile.recordGeneratedEdit(.solve, solve_start);
    if (source.hasLayoutDiagnostics(state)) return false;

    const translations_start = utils.measure_profile.start();
    const previous_layout = &snapshot.layout_output.?;
    const previous_editor = &previous_layout.editor.?;
    var collected = try collectTranslations(ctx.allocator, state, &previous_layout.report) orelse
        return false;
    defer collected.deinit(ctx.allocator);
    if (!translationPatchPreservesRenderedOutput(
        state,
        pages,
        collected.translations,
        snapshot.project.highlight.languages,
    )) return false;
    utils.measure_profile.recordGeneratedEdit(.translations, translations_start);

    const snapshot_start = utils.measure_profile.start();
    const state_module = source.stateModuleForPathMutable(state, path) orelse return false;
    @memcpy(state_module.source, generated.source);
    const conflicts_json = try core.layout.conflicts.toJson(ctx.allocator, state);
    const editor = editor_snapshot.buildTranslationPatch(
        ctx.allocator,
        state,
        generation,
        previous_editor,
        collected.translations,
        conflicts_json,
    ) catch |err| {
        ctx.allocator.free(conflicts_json);
        return err;
    };
    var next_layout = try analysis.snapshot.LayoutOutput.fromDocumentStateWithOwnedReport(
        ctx.allocator,
        state,
        collected.takeReport(),
        editor,
        conflicts_json,
    );

    var next_layout_owned = true;
    errdefer if (next_layout_owned) next_layout.deinit(ctx.allocator);
    utils.measure_profile.recordGeneratedEdit(.snapshot, snapshot_start);
    const syntax_start = utils.measure_profile.start();
    try snapshot.updateSyntax(path, generated.source, ctx.cancellation);
    utils.measure_profile.recordGeneratedEdit(.syntax, syntax_start);
    previous_layout.deinit(ctx.allocator);
    snapshot.layout_output = next_layout;
    next_layout_owned = false;
    source.rebaseSnapshotSource(snapshot, path, generated.source);
    snapshot.generation = generation;
    discard_retained_state = false;

    return true;
}
