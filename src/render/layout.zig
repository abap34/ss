const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const lowering = @import("../lowering.zig");
const compiler = @import("compile.zig");
const render_resources = @import("render_resources");
const execution = @import("../analysis/execution.zig");

pub const FontEnvironmentToken = compiler.FontEnvironmentToken;

pub const Options = struct {
    trace_path: ?[]const u8 = null,
    progress: ?core.layout.graph.LayoutProgress = null,
    jobs: ?usize = null,
    highlight_languages: []const utils.highlight.Language = &.{},
    cancellation: ?utils.Cancellation = null,
    resource_cache: ?*render_resources.SourceCache = null,
    font_environment: ?compiler.FontEnvironmentToken = null,

    fn checkCanceled(self: Options) !void {
        if (self.cancellation) |cancellation| try cancellation.check();
    }
};

pub const EvaluatedPreparedPages = struct {
    pages: core.prepared.PreparedPages,
    font_environment: FontEnvironmentToken,
};

pub fn evaluateAndSolvePreparedPages(
    io: std.Io,
    state: *core.DocumentState,
    graph: *const execution.ExecutionGraph,
    options: Options,
) !EvaluatedPreparedPages {
    try options.checkCanceled();
    const evaluate_start = utils.measure_profile.start();
    try lowering.evaluateDocument(state, graph, .{ .cancellation = options.cancellation });
    utils.measure_profile.recordWysiwyg(.evaluate, evaluate_start);
    try options.checkCanceled();
    const prepare_start = utils.measure_profile.start();
    var pages = try core.prepared.prepare(state.allocator, state);
    utils.measure_profile.recordWysiwyg(.prepare, prepare_start);
    errdefer pages.deinit(state.allocator);
    try options.checkCanceled();
    const font_environment = options.font_environment orelse
        try compiler.acquireFontEnvironment(state.allocator, io, &pages);
    var solve_options = options;
    solve_options.font_environment = font_environment;
    const solve_start = utils.measure_profile.start();
    var results = try solvePreparedPages(io, state, &pages, solve_options);
    utils.measure_profile.recordWysiwyg(.solve, solve_start);
    defer results.deinit(state.allocator);
    try options.checkCanceled();
    return .{
        .pages = pages,
        .font_environment = font_environment,
    };
}

pub fn preloadPreparedPageArtifacts(
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    progress: ?compiler.Progress,
    jobs: ?usize,
    highlight_languages: []const utils.highlight.Language,
) !void {
    try compiler.preload(state.allocator, io, state, pages, .{
        .jobs = jobs,
        .highlight_languages = highlight_languages,
    }, progress);
}

pub fn solvePreparedPages(
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    options: Options,
) !core.layout.Document {
    try options.checkCanceled();
    const font_environment = options.font_environment orelse
        try compiler.acquireFontEnvironment(state.allocator, io, pages);
    var measurement_scope = try compiler.LayoutMeasurementScope.init(
        state.allocator,
        io,
        state,
        pages,
        options.resource_cache,
        options.highlight_languages,
        font_environment,
    );
    defer measurement_scope.deinit();
    var results = try lowering.solveDocument(state, options.trace_path, .{
        .measurement_provider = measurement_scope.provider(),
        .progress = options.progress,
        .jobs = options.jobs,
        .cancellation = options.cancellation,
    });
    errdefer results.deinit(state.allocator);
    try options.checkCanceled();
    try compiler.refreshAndValidateFontEnvironment(font_environment);
    try core.prepared.attachAssetKeys(state.allocator, &results, pages);
    try options.checkCanceled();
    return results;
}
