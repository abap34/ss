const std = @import("std");
const build_options = @import("build_options");
const core = @import("core");
const render_layout = @import("../render/layout.zig");
const render_compiler = @import("../render/compile.zig");
const render_resources = @import("render_resources");
const render_text = @import("render_text");
const editor_snapshot = @import("../editor/snapshot.zig");
const analysis = @import("../analysis.zig");
const module_loader = @import("../modules/loader.zig");
const project = @import("../project.zig");
const utils = @import("utils");
const lsp_diagnostics = @import("diagnostics.zig");
const protocol = @import("protocol.zig");
const lsp_state = @import("state.zig");
const feature_colors = @import("features/colors.zig");
const feature_completion = @import("features/completion.zig");
const feature_definition = @import("features/definition.zig");
const feature_editor = @import("features/editor.zig");
const feature_edit = @import("features/edit.zig");
const feature_folding = @import("features/folding.zig");
const feature_hover = @import("features/hover.zig");
const feature_layout = @import("features/layout.zig");
const feature_project = @import("features/project.zig");
const feature_shape_edit = @import("features/shape_edit.zig");
const feature_symbols = @import("features/symbols.zig");
const feature_tokens = @import("features/tokens.zig");
const transport = @import("transport.zig");

const JsonValue = protocol.JsonValue;
const AnalysisSnapshot = lsp_state.AnalysisSnapshot;
const DocumentStore = lsp_state.DocumentStore;
const ResponseStore = lsp_state.ResponseStore;
const DiagnosticSet = lsp_diagnostics.DiagnosticSet;
const respond = protocol.respond;
const respondError = protocol.respondError;
const sendNotification = protocol.sendNotification;
const appendJsonValue = protocol.appendJsonValue;
const appendJsonString = protocol.appendJsonString;
const stringField = protocol.stringField;
const intField = protocol.intField;
const objectField = protocol.objectField;
const arrayField = protocol.arrayField;
const uriFromPath = protocol.uriFromPath;

const LayoutBuildMode = enum {
    configured,
    required,
};

const Server = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    ingress: *transport.Ingress,
    documents: DocumentStore,
    embedded_cache: module_loader.EmbeddedSyntaxCache,
    render_resource_cache: render_resources.SourceCache,
    text_shape_cache: render_text.Cache,
    render_page_cache: render_compiler.PageCache,
    editor_snapshot_cache: editor_snapshot.Cache,
    analysis: ?AnalysisSnapshot = null,
    analysis_revision: u64 = 0,
    layout_responses: ResponseStore = .{},
    editor_responses: ResponseStore = .{},
    editor_diagnostics: ResponseStore = .{},
    published_diagnostic_uris: std.StringHashMap(void),
    pending_rebuild_path: ?[]u8 = null,
    pending_rebuild_due_ms: u64 = 0,
    pending_rebuild_revision: u64 = 0,
    pending_rebuild_translation_patch: bool = false,
    generated_edit_path: ?[]u8 = null,
    generated_edit_source: ?[]u8 = null,
    active_revision: u64 = 0,
    active_request: ?*const transport.RequestState = null,
    exiting: bool = false,
    wysiwyg_paths: std.StringHashMap(void),

    fn init(io: std.Io, allocator: std.mem.Allocator, ingress: *transport.Ingress) Server {
        return .{
            .io = io,
            .allocator = allocator,
            .ingress = ingress,
            .documents = DocumentStore.init(allocator),
            .embedded_cache = module_loader.EmbeddedSyntaxCache.init(allocator),
            .render_resource_cache = render_resources.SourceCache.init(allocator, io),
            .text_shape_cache = render_text.Cache.init(allocator, io),
            .render_page_cache = render_compiler.PageCache.init(allocator, io),
            .editor_snapshot_cache = editor_snapshot.Cache.init(allocator, io),
            .published_diagnostic_uris = std.StringHashMap(void).init(allocator),
            .wysiwyg_paths = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *Server) void {
        self.documents.deinit();
        if (self.analysis) |*snapshot| snapshot.deinit();
        self.embedded_cache.deinit();
        self.render_resource_cache.deinit();
        self.text_shape_cache.deinit();
        self.render_page_cache.deinit();
        self.editor_snapshot_cache.deinit();
        self.layout_responses.deinit(self.allocator);
        self.editor_responses.deinit(self.allocator);
        self.editor_diagnostics.deinit(self.allocator);
        lsp_state.deinitStringSet(self.allocator, &self.published_diagnostic_uris);
        lsp_state.deinitStringSet(self.allocator, &self.wysiwyg_paths);
        self.clearPendingRebuild();
        self.clearGeneratedEdit();
    }

    fn rebuild(
        self: *Server,
        changed_path: []const u8,
        layout_build: LayoutBuildMode,
        prefer_translation_patch: bool,
    ) !void {
        try self.checkCanceled();
        var diagnostics = DiagnosticSet.init(self.allocator);
        defer diagnostics.deinit();
        const rebuild_generation = self.documents.generation;
        var snapshot = try self.buildAnalysis(changed_path, &diagnostics, layout_build, prefer_translation_patch);
        var snapshot_owned = true;
        errdefer if (snapshot_owned) snapshot.deinit();
        try self.checkCanceled();
        if (snapshot.generation != self.documents.generation or rebuild_generation != self.documents.generation) return error.Canceled;
        if (self.analysis) |*old| old.deinit();
        self.analysis = snapshot;
        self.analysis_revision = self.active_revision;
        snapshot_owned = false;
        try self.publishAnalysisDiagnostics(&diagnostics);
    }

    fn publishAnalysisDiagnostics(self: *Server, diagnostics: *DiagnosticSet) !void {
        if (self.analysis.?.project.lsp.enabled and self.analysis.?.project.lsp.diagnostics) {
            try self.publishDiagnostics(diagnostics);
        } else {
            var empty = DiagnosticSet.init(self.allocator);
            defer empty.deinit();
            try self.publishDiagnostics(&empty);
        }
        var editor_diagnostics = std.ArrayList(u8).empty;
        defer editor_diagnostics.deinit(self.allocator);
        try diagnostics.appendEditorErrorsJson(self.allocator, &editor_diagnostics);
        try self.editor_diagnostics.store(
            self.allocator,
            &self.analysis.?,
            editor_diagnostics.items,
        );
    }

    fn rebuildImmediately(self: *Server, changed_path: []const u8) !void {
        self.clearPendingRebuild();
        try self.rebuild(changed_path, .configured, false);
    }

    fn rebuildEditorImmediately(self: *Server, changed_path: []const u8) !void {
        self.clearPendingRebuild();
        if (try self.completeRetainedEditor(changed_path)) return;
        try self.rebuild(changed_path, .required, false);
    }

    fn completeRetainedEditor(self: *Server, changed_path: []const u8) !bool {
        const snapshot = if (self.analysis) |*value| value else return false;
        if (snapshot.generation != self.documents.generation or
            self.analysis_revision != self.active_revision or
            !snapshot.coversPath(changed_path) or
            snapshot.layout_output != null or
            snapshot.retained_layout_inputs == null)
        {
            return false;
        }

        var diagnostics = DiagnosticSet.init(self.allocator);
        defer diagnostics.deinit();
        var layout_context = AnalysisLayoutContext{
            .server = self,
            .diagnostics = &diagnostics,
            .include_editor_snapshot = true,
            .prefer_translation_patch = false,
            .highlight_languages = snapshot.project.highlight.languages,
        };
        const completed = try snapshot.completeRetainedLayout(.{
            .context = &layout_context,
            .run = runAnalysisLayout,
            .on_error = addAnalysisLayoutError,
        }, .{
            .context = self,
            .is_canceled = analysisCanceled,
        });
        if (!completed) return false;
        try self.checkCanceled();
        try diagnostics.addAnalysisBag(&snapshot.diagnostics);
        try self.publishAnalysisDiagnostics(&diagnostics);
        return true;
    }

    fn acceptCurrentRevision(self: *Server) void {
        if (self.pending_rebuild_path != null) {
            self.pending_rebuild_revision = self.active_revision;
            return;
        }
        if (self.analysis) |*snapshot| {
            if (snapshot.generation == self.documents.generation) self.analysis_revision = self.active_revision;
        }
    }

    fn republishCurrentDiagnostics(self: *Server) !void {
        const snapshot = if (self.analysis) |*value| value else return;
        if (snapshot.generation != self.documents.generation or self.analysis_revision != self.active_revision) return;
        var diagnostics = DiagnosticSet.init(self.allocator);
        defer diagnostics.deinit();
        try diagnostics.addAnalysisBag(&snapshot.diagnostics);
        try self.publishAnalysisDiagnostics(&diagnostics);
    }

    fn scheduleRebuild(self: *Server, changed_path: []const u8) !void {
        try self.scheduleRebuildWithDisplayMode(changed_path, false);
    }

    fn scheduleTranslationPatchRebuild(self: *Server, changed_path: []const u8) !void {
        try self.scheduleRebuildWithDisplayMode(changed_path, true);
    }

    fn scheduleRebuildWithDisplayMode(self: *Server, changed_path: []const u8, prefer_translation_patch: bool) !void {
        const delay_ms = self.lspDebounceMs();
        if (delay_ms == 0) {
            self.clearPendingRebuild();
            try self.rebuild(
                changed_path,
                if (prefer_translation_patch) .required else .configured,
                prefer_translation_patch,
            );
            return;
        }
        const owned_path = try self.allocator.dupe(u8, changed_path);
        errdefer self.allocator.free(owned_path);
        self.clearPendingRebuild();
        self.pending_rebuild_path = owned_path;
        self.pending_rebuild_due_ms = saturatedAddMillis(monotonicMillis(), delay_ms);
        self.pending_rebuild_revision = self.active_revision;
        self.pending_rebuild_translation_patch = prefer_translation_patch;
    }

    fn flushPendingRebuild(self: *Server, layout_build: LayoutBuildMode) !void {
        const path = self.pending_rebuild_path orelse return;
        var path_owned = true;
        defer if (path_owned) self.allocator.free(path);
        const revision = self.pending_rebuild_revision;
        const prefer_translation_patch = self.pending_rebuild_translation_patch;
        self.pending_rebuild_path = null;
        self.pending_rebuild_due_ms = 0;
        self.pending_rebuild_revision = 0;
        self.pending_rebuild_translation_patch = false;
        const previous_revision = self.active_revision;
        const previous_request = self.active_request;
        self.active_revision = revision;
        if (previous_revision != revision) self.active_request = null;
        defer {
            self.active_revision = previous_revision;
            self.active_request = previous_request;
        }
        self.rebuild(path, layout_build, prefer_translation_patch) catch |err| {
            if (err == error.Canceled and
                layout_build == .required and
                revision == self.ingress.revision.load(.acquire))
            {
                self.pending_rebuild_path = path;
                self.pending_rebuild_due_ms = saturatedAddMillis(monotonicMillis(), self.lspDebounceMs());
                self.pending_rebuild_revision = revision;
                self.pending_rebuild_translation_patch = prefer_translation_patch;
                path_owned = false;
            }
            return err;
        };
    }

    fn flushPendingRebuildIfDue(self: *Server) !void {
        if (self.pending_rebuild_path == null) return;
        if (monotonicMillis() < self.pending_rebuild_due_ms) return;
        try self.flushPendingRebuild(self.pendingLayoutBuildMode());
    }

    fn pendingLayoutBuildMode(self: *const Server) LayoutBuildMode {
        return if (self.pending_rebuild_translation_patch) .required else .configured;
    }

    fn pendingRebuildPollTimeout(self: *const Server) ?u64 {
        if (self.pending_rebuild_path == null) return null;
        const now = monotonicMillis();
        if (now >= self.pending_rebuild_due_ms) return 0;
        return self.pending_rebuild_due_ms - now;
    }

    fn lspDebounceMs(self: *const Server) u64 {
        return if (self.analysis) |*snapshot| snapshot.project.lsp.debounce_ms else (project.LspConfig{}).debounce_ms;
    }

    fn clearPendingRebuild(self: *Server) void {
        if (self.pending_rebuild_path) |path| self.allocator.free(path);
        self.pending_rebuild_path = null;
        self.pending_rebuild_due_ms = 0;
        self.pending_rebuild_revision = 0;
        self.pending_rebuild_translation_patch = false;
    }

    fn rememberGeneratedEdit(self: *Server, path: []const u8, source: []const u8) !void {
        self.clearGeneratedEdit();
        self.generated_edit_path = try self.allocator.dupe(u8, path);
        errdefer self.clearGeneratedEdit();
        self.generated_edit_source = try self.allocator.dupe(u8, source);
    }

    fn consumeGeneratedEdit(self: *Server, path: []const u8) bool {
        defer self.clearGeneratedEdit();
        const expected_path = self.generated_edit_path orelse return false;
        const expected_source = self.generated_edit_source orelse return false;
        const current_source = self.documents.sourceForPath(path) orelse return false;
        return std.mem.eql(u8, expected_path, path) and std.mem.eql(u8, expected_source, current_source);
    }

    fn clearGeneratedEdit(self: *Server) void {
        if (self.generated_edit_path) |path| self.allocator.free(path);
        if (self.generated_edit_source) |source| self.allocator.free(source);
        self.generated_edit_path = null;
        self.generated_edit_source = null;
    }

    const WorkStatus = enum {
        current,
        canceled,
        content_modified,
    };

    fn workStatus(self: *const Server) WorkStatus {
        if (self.active_request) |request| {
            if (request.canceled.load(.acquire)) return .canceled;
        }
        if (self.active_revision != self.ingress.revision.load(.acquire)) return .content_modified;
        return .current;
    }

    fn checkCanceled(self: *const Server) !void {
        if (self.workStatus() != .current) return error.Canceled;
    }

    fn respondResult(self: *Server, id: ?JsonValue, result_json: []const u8) !void {
        switch (self.workStatus()) {
            .current => try respond(self.allocator, id, result_json),
            .canceled => try respondError(self.allocator, id, -32800, "request cancelled"),
            .content_modified => try respondError(self.allocator, id, -32801, "content modified"),
        }
    }

    fn respondCanceled(self: *Server, id_json: []const u8) !void {
        switch (self.workStatus()) {
            .current, .canceled => try protocol.respondErrorId(self.allocator, id_json, -32800, "request cancelled"),
            .content_modified => try protocol.respondErrorId(self.allocator, id_json, -32801, "content modified"),
        }
    }

    fn buildAnalysis(
        self: *Server,
        changed_path: []const u8,
        diagnostics: *DiagnosticSet,
        layout_build: LayoutBuildMode,
        prefer_translation_patch: bool,
    ) !AnalysisSnapshot {
        return try self.buildAnalysisWithOverride(changed_path, diagnostics, null, layout_build, prefer_translation_patch);
    }

    const SourceOverride = struct {
        path: []const u8,
        source: []const u8,
    };

    fn buildAnalysisWithOverride(
        self: *Server,
        changed_path: []const u8,
        diagnostics: *DiagnosticSet,
        source_override: ?SourceOverride,
        layout_build: LayoutBuildMode,
        prefer_translation_patch: bool,
    ) !AnalysisSnapshot {
        try self.checkCanceled();
        const changed_abs = try project.absolutePath(self.allocator, changed_path);
        defer self.allocator.free(changed_abs);
        const changed_dir = std.fs.path.dirname(changed_abs) orelse ".";

        const project_path = try project.discoverPath(self.allocator, changed_dir);
        defer if (project_path) |path| self.allocator.free(path);
        try self.checkCanceled();

        var config: ?project.Config = null;
        if (project_path) |path| {
            config = project.loadFile(self.allocator, self.io, path) catch |err| blk: {
                try self.addProjectConfigDiagnostic(diagnostics, path, err);
                break :blk null;
            };
        }
        defer if (config) |*cfg| cfg.deinit(self.allocator);
        const include_layout = switch (layout_build) {
            .configured => if (config) |cfg| cfg.wysiwyg.refresh_automatically else true,
            .required => true,
        };
        var default_highlight: ?utils.highlight.Config = null;
        defer if (default_highlight) |*cfg| cfg.deinit(self.allocator);
        const highlight = if (config) |*cfg| cfg.highlight else blk: {
            default_highlight = try utils.highlight.defaultConfig(self.allocator);
            break :blk default_highlight.?;
        };
        try self.checkCanceled();
        const entry_path = if (config) |cfg| try self.allocator.dupe(u8, cfg.entry) else try self.allocator.dupe(u8, changed_abs);
        defer self.allocator.free(entry_path);
        const asset_base_dir = if (config) |cfg| try self.allocator.dupe(u8, cfg.asset_base_dir) else try dirnameAlloc(self.allocator, entry_path);
        defer self.allocator.free(asset_base_dir);

        var sources = analysis.snapshot.SourceSet.init(self.allocator, self.io);
        defer sources.deinit();
        try self.documents.fillOverlay(&sources.overlay);
        if (source_override) |override| try sources.put(override.path, override.source);
        try self.checkCanceled();

        var layout_context = AnalysisLayoutContext{
            .server = self,
            .diagnostics = diagnostics,
            .include_editor_snapshot = include_layout,
            .prefer_translation_patch = prefer_translation_patch,
            .highlight_languages = highlight.languages,
        };
        var analysis_snapshot = try analysis.snapshot.build(self.allocator, &sources, entry_path, asset_base_dir, .{
            .generation = self.documents.generation,
            .project = .{
                .highlight = highlight,
                .lsp = if (config) |cfg| cfg.lsp else .{},
                .wysiwyg = if (config) |cfg| cfg.wysiwyg else .{},
                .page_guide = if (config) |cfg| cfg.page_guide else .{},
            },
            .layout_hook = if (include_layout) .{
                .context = &layout_context,
                .run = runAnalysisLayout,
                .on_error = addAnalysisLayoutError,
            } else null,
            .cancellation = .{
                .context = self,
                .is_canceled = analysisCanceled,
            },
            .embedded_cache = &self.embedded_cache,
            .retain_layout_inputs = !include_layout and self.wysiwyg_paths.count() != 0,
        });
        errdefer analysis_snapshot.deinit();
        try diagnostics.addAnalysisBag(&analysis_snapshot.diagnostics);
        return analysis_snapshot;
    }

    fn buildSingleDocumentAnalysis(self: *Server, changed_path: []const u8, diagnostics: *DiagnosticSet) !AnalysisSnapshot {
        try self.checkCanceled();
        const entry_path = try project.absolutePath(self.allocator, changed_path);
        defer self.allocator.free(entry_path);
        const asset_base_dir = try dirnameAlloc(self.allocator, entry_path);
        defer self.allocator.free(asset_base_dir);

        var sources = analysis.snapshot.SourceSet.init(self.allocator, self.io);
        defer sources.deinit();
        try self.documents.fillOverlay(&sources.overlay);
        var highlight = try utils.highlight.defaultConfig(self.allocator);
        defer highlight.deinit(self.allocator);

        var analysis_snapshot = try analysis.snapshot.build(self.allocator, &sources, entry_path, asset_base_dir, .{
            .generation = self.documents.generation,
            .project = .{ .highlight = highlight },
            .cancellation = .{
                .context = self,
                .is_canceled = analysisCanceled,
            },
            .embedded_cache = &self.embedded_cache,
        });
        errdefer analysis_snapshot.deinit();
        try diagnostics.addAnalysisBag(&analysis_snapshot.diagnostics);
        return analysis_snapshot;
    }

    fn addProjectConfigDiagnostic(self: *Server, diagnostics: *DiagnosticSet, path: []const u8, err: anyerror) !void {
        var owned_source: ?[]u8 = null;
        defer if (owned_source) |text| self.allocator.free(text);
        const text = self.documents.sourceForPath(path) orelse blk: {
            owned_source = utils.fs.readFileAlloc(self.io, self.allocator, path) catch |read_err| switch (read_err) {
                error.OutOfMemory => return read_err,
                else => null,
            };
            break :blk owned_source orelse "";
        };
        const message = try std.fmt.allocPrint(self.allocator, "ProjectConfigFailed: {s}", .{@errorName(err)});
        defer self.allocator.free(message);
        try diagnostics.add(path, text, .@"error", @errorName(err), message, project.configErrorSpan(text, err));
    }

    fn clearChangedDocumentDiagnostics(self: *Server, uri: []const u8) !void {
        try self.sendEmptyDiagnostics(uri, self.documents.versionForUri(uri));
        try putStringSet(self.allocator, &self.published_diagnostic_uris, uri);
    }

    fn sendEmptyDiagnostics(self: *Server, uri: []const u8, version: ?i64) !void {
        try self.checkCanceled();
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, "{\"uri\":");
        try appendJsonString(self.allocator, &body, uri);
        if (version) |value| {
            try body.appendSlice(self.allocator, ",\"version\":");
            try protocol.appendInt(self.allocator, &body, value);
        }
        try body.appendSlice(self.allocator, ",\"diagnostics\":[]}");
        try sendNotification(self.allocator, "textDocument/publishDiagnostics", body.items);
    }

    fn publishDiagnostics(self: *Server, diagnostics: *DiagnosticSet) !void {
        try self.checkCanceled();
        var grouped = std.StringHashMap(std.ArrayList(usize)).init(self.allocator);
        defer {
            var it = grouped.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
            grouped.deinit();
        }

        for (diagnostics.items.items, 0..) |item, index| {
            const gop = try grouped.getOrPut(item.uri);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.allocator, index);
        }

        var current_published = std.StringHashMap(void).init(self.allocator);
        errdefer lsp_state.deinitStringSet(self.allocator, &current_published);

        var it = grouped.iterator();
        while (it.next()) |entry| {
            try self.checkCanceled();
            var body = std.ArrayList(u8).empty;
            defer body.deinit(self.allocator);
            try body.appendSlice(self.allocator, "{\"uri\":");
            try appendJsonString(self.allocator, &body, entry.key_ptr.*);
            if (self.documents.versionForUri(entry.key_ptr.*)) |version| {
                try body.appendSlice(self.allocator, ",\"version\":");
                try protocol.appendInt(self.allocator, &body, version);
            }
            try body.appendSlice(self.allocator, ",\"diagnostics\":[");
            for (entry.value_ptr.items, 0..) |diag_index, i| {
                if (i != 0) try body.append(self.allocator, ',');
                try diagnostics.items.items[diag_index].appendJson(self.allocator, &body);
            }
            try body.appendSlice(self.allocator, "]}");
            try sendNotification(self.allocator, "textDocument/publishDiagnostics", body.items);
            try putStringSet(self.allocator, &current_published, entry.key_ptr.*);
        }

        var doc_iterator = self.documents.iterator();
        while (doc_iterator.next()) |entry| {
            try self.checkCanceled();
            const uri = try uriFromPath(self.allocator, entry.key_ptr.*);
            defer self.allocator.free(uri);
            if (current_published.contains(uri)) continue;
            try self.sendEmptyDiagnostics(uri, self.documents.versionForPath(entry.key_ptr.*));
            try putStringSet(self.allocator, &current_published, uri);
        }

        var previous_iterator = self.published_diagnostic_uris.iterator();
        while (previous_iterator.next()) |entry| {
            try self.checkCanceled();
            if (current_published.contains(entry.key_ptr.*)) continue;
            try self.sendEmptyDiagnostics(entry.key_ptr.*, null);
        }

        lsp_state.deinitStringSet(self.allocator, &self.published_diagnostic_uris);
        self.published_diagnostic_uris = current_published;
    }
};

fn analysisProvider(server: *Server) lsp_state.AnalysisProvider {
    return .{
        .context = server,
        .current = if (server.analysis) |*snapshot| snapshot else null,
        .generation = server.documents.generation,
        .cancellation = .{
            .context = server,
            .is_canceled = analysisCanceled,
        },
        .build = buildAnalysisForFeature,
    };
}

fn analysisCanceled(context: *const anyopaque) bool {
    const server: *const Server = @ptrCast(@alignCast(context));
    return server.workStatus() != .current;
}

fn buildAnalysisForFeature(context: *anyopaque, path: []const u8) !AnalysisSnapshot {
    const server: *Server = @ptrCast(@alignCast(context));
    var diagnostics = DiagnosticSet.init(server.allocator);
    defer diagnostics.deinit();
    var snapshot = try server.buildAnalysis(path, &diagnostics, .configured, false);
    if (snapshot.coversPath(path)) return snapshot;
    snapshot.deinit();
    return try server.buildSingleDocumentAnalysis(path, &diagnostics);
}

const AnalysisLayoutContext = struct {
    server: *Server,
    diagnostics: *DiagnosticSet,
    include_editor_snapshot: bool,
    prefer_translation_patch: bool,
    highlight_languages: []const utils.highlight.Language,
};

fn rememberGeneratedEdit(context: *anyopaque, path: []const u8, source: []const u8) !void {
    const server: *Server = @ptrCast(@alignCast(context));
    try server.rememberGeneratedEdit(path, source);
}

const AnalysisLayoutTaskResult = union(enum) {
    layout: anyerror!analysis.snapshot.LayoutHookOutput,
    canceled: void,
};

fn runAnalysisLayout(context: *anyopaque, state: *core.DocumentState, graph: *const analysis.execution.ExecutionGraph) !analysis.snapshot.LayoutHookOutput {
    const hook: *AnalysisLayoutContext = @ptrCast(@alignCast(context));
    try hook.server.checkCanceled();

    var result_buffer: [2]AnalysisLayoutTaskResult = undefined;
    var tasks = std.Io.Select(AnalysisLayoutTaskResult).init(hook.server.io, &result_buffer);
    try tasks.concurrent(.layout, runAnalysisLayoutWork, .{ context, state, graph });
    defer cancelAnalysisLayoutTasks(&tasks, state.allocator);
    try tasks.concurrent(.canceled, waitForAnalysisCancellation, .{hook.server});

    return switch (try tasks.await()) {
        .layout => |result| try result,
        .canceled => error.Canceled,
    };
}

fn runAnalysisLayoutWork(context: *anyopaque, state: *core.DocumentState, graph: *const analysis.execution.ExecutionGraph) !analysis.snapshot.LayoutHookOutput {
    const hook: *AnalysisLayoutContext = @ptrCast(@alignCast(context));
    try hook.server.checkCanceled();
    const layout_start = utils.measure_profile.start();
    var pages = try render_layout.evaluateAndSolvePreparedPages(hook.server.io, state, graph, .{
        .jobs = 1,
        .resource_cache = &hook.server.render_resource_cache,
        .cancellation = .{
            .context = hook.server,
            .is_canceled = analysisCanceled,
        },
    });
    utils.measure_profile.recordWysiwyg(.evaluate_solve, layout_start);
    defer pages.deinit(state.allocator);
    try hook.server.checkCanceled();
    const conflicts_json = try core.layout.conflicts.toJson(state.allocator, state);
    errdefer state.allocator.free(conflicts_json);
    if (!hook.include_editor_snapshot or hook.server.wysiwyg_paths.count() == 0) {
        return .{ .conflicts_json = conflicts_json };
    }

    if (hook.prefer_translation_patch) {
        if (hook.server.analysis) |*previous| {
            if (previous.layout_output) |*previous_layout| {
                if (previous_layout.editor) |*previous_editor| {
                    if (try collectTranslations(state.allocator, state, &previous_layout.report)) |translations| {
                        defer state.allocator.free(translations);
                        return .{ .editor = try editor_snapshot.buildTranslationPatch(
                            state.allocator,
                            state,
                            hook.server.documents.generation,
                            previous_editor.model.snapshot_id,
                            translations,
                            conflicts_json,
                        ), .conflicts_json = conflicts_json };
                    }
                }
            }
        }
    }

    const render_start = utils.measure_profile.start();
    var render_ir = try render_compiler.compile(state.allocator, hook.server.io, state, &pages, .{
        .jobs = 1,
        .highlight_languages = hook.highlight_languages,
        .resource_cache = &hook.server.render_resource_cache,
        .text_cache = &hook.server.text_shape_cache,
        .page_cache = &hook.server.render_page_cache,
    });
    utils.measure_profile.recordWysiwyg(.render_compile, render_start);
    defer render_ir.deinit(state.allocator);
    try hook.server.checkCanceled();
    const snapshot_start = utils.measure_profile.start();
    defer utils.measure_profile.recordWysiwyg(.snapshot, snapshot_start);
    return .{ .editor = try editor_snapshot.build(
        state.allocator,
        hook.server.io,
        state,
        &render_ir,
        hook.server.documents.generation,
        conflicts_json,
        &hook.server.editor_snapshot_cache,
    ), .conflicts_json = conflicts_json };
}

fn waitForAnalysisCancellation(server: *Server) void {
    while (server.workStatus() == .current) {
        std.Io.sleep(server.io, std.Io.Duration.fromMilliseconds(10), .awake) catch return;
    }
}

fn cancelAnalysisLayoutTasks(tasks: *std.Io.Select(AnalysisLayoutTaskResult), allocator: std.mem.Allocator) void {
    while (tasks.cancel()) |result| switch (result) {
        .layout => |layout_result| {
            var output = layout_result catch continue;
            output.deinit(allocator);
        },
        .canceled => {},
    };
}

fn collectTranslations(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    previous: *const core.layout.conflicts.Report,
) !?[]editor_snapshot.Translation {
    var current = try core.layout.conflicts.Report.init(allocator, state);
    defer current.deinit();
    if (current.failure_count != 0 or
        current.pages.len != previous.pages.len or
        current.objects.len != previous.objects.len)
    {
        return null;
    }

    const tolerance: f32 = core.layout.graph.ConstraintTolerance;
    for (current.pages) |page| {
        const old = previous.pageById(page.id) orelse return null;
        if (@abs(page.width - old.width) > tolerance or
            @abs(page.height - old.height) > tolerance)
        {
            return null;
        }
    }

    var translations = std.ArrayList(editor_snapshot.Translation).empty;
    errdefer translations.deinit(allocator);
    for (current.objects) |object| {
        const old = previous.objectById(object.id) orelse return null;
        if (object.page_id != old.page_id or
            @abs(object.width - old.width) > tolerance or
            @abs(object.height - old.height) > tolerance)
        {
            return null;
        }
        const x = object.x - old.x;
        const y = old.y - object.y;
        if (@abs(x) <= tolerance and @abs(y) <= tolerance) continue;
        try translations.append(allocator, .{
            .node_id = object.id,
            .x = x,
            .y = y,
        });
    }
    return try translations.toOwnedSlice(allocator);
}

fn addAnalysisLayoutError(context: *anyopaque, state: *core.DocumentState, err: anyerror) !void {
    const hook: *AnalysisLayoutContext = @ptrCast(@alignCast(context));
    try hook.diagnostics.addConstraintFailure(state, err);
}

fn putStringSet(allocator: std.mem.Allocator, set: *std.StringHashMap(void), value: []const u8) !void {
    if (set.contains(value)) return;
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try set.put(owned, {});
}

const Worker = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    ingress: *transport.Ingress,
    failure: ?anyerror = null,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var ingress: transport.Ingress = undefined;
    ingress.init(allocator, io);
    defer ingress.deinit();

    var worker = Worker{
        .io = io,
        .allocator = allocator,
        .ingress = &ingress,
    };
    const thread = try std.Thread.spawn(.{}, workerMain, .{&worker});
    ingress.read();
    thread.join();

    if (worker.failure) |err| return err;
    if (ingress.readFailed()) return error.ReadFailed;
}

fn workerMain(worker: *Worker) void {
    runWorker(worker.io, worker.allocator, worker.ingress) catch |err| {
        worker.failure = err;
    };
}

fn runWorker(io: std.Io, allocator: std.mem.Allocator, ingress: *transport.Ingress) !void {
    var server = Server.init(io, allocator, ingress);
    defer server.deinit();

    while (!server.exiting) {
        server.flushPendingRebuildIfDue() catch |err| switch (err) {
            error.Canceled => {},
            else => return err,
        };

        const envelope = try ingress.next(server.pendingRebuildPollTimeout());
        if (envelope) |value| {
            try processEnvelope(&server, value);
            continue;
        }
        if (ingress.isFinished()) break;
    }
}

fn processEnvelope(server: *Server, value: transport.Envelope) !void {
    var envelope = value;
    defer envelope.deinit(server.ingress);

    server.active_revision = envelope.revision;
    server.active_request = if (envelope.request) |request| request.state else null;
    defer {
        server.active_revision = server.ingress.revision.load(.acquire);
        server.active_request = null;
    }

    handleMessage(server, &envelope.message.value) catch |err| switch (err) {
        error.Canceled => {
            if (envelope.request) |request| try server.respondCanceled(request.key);
        },
        else => return err,
    };
}

fn handleMessage(server: *Server, message: *const JsonValue) !void {
    if (message.* != .object) return;
    const root = message.object;
    const method = stringField(&root, "method") orelse return;
    const id = if (utils.json.fieldValue(&root, "id")) |value| value.* else null;
    const params = if (utils.json.fieldValue(&root, "params")) |value| value.* else null;

    if (std.mem.eql(u8, method, "initialize")) {
        const result = try initializeResult(server.allocator);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "shutdown")) {
        try respond(server.allocator, id, "null");
        return;
    }
    if (std.mem.eql(u8, method, "exit")) {
        server.exiting = true;
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        if (params) |p| if (objectField(p, "textDocument")) |doc| {
            if (stringField(doc, "uri")) |uri| {
                const text = stringField(doc, "text") orelse "";
                const path = try server.documents.replaceUri(uri, text, intField(doc, "version"));
                defer server.allocator.free(path);
                try server.scheduleRebuild(path);
            }
        };
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/didChange")) {
        if (params) |p| if (objectField(p, "textDocument")) |doc| {
            if (stringField(doc, "uri")) |uri| {
                if (arrayField(p, "contentChanges")) |changes| if (changes.items.len != 0) {
                    const path = try server.documents.absolutePathFromUri(uri);
                    defer server.allocator.free(path);
                    const previous_generation = server.documents.generation;
                    for (changes.items) |*change| {
                        if (change.* == .object) try server.documents.applyChangeAtPath(path, &change.object);
                    }
                    if (intField(doc, "version")) |version| try server.documents.setVersionAtPath(path, version);
                    if (server.documents.generation == previous_generation) {
                        server.acceptCurrentRevision();
                        try server.republishCurrentDiagnostics();
                        return;
                    }
                    try server.clearChangedDocumentDiagnostics(uri);
                    if (server.consumeGeneratedEdit(path))
                        try server.scheduleTranslationPatchRebuild(path)
                    else
                        try server.scheduleRebuild(path);
                };
            }
        };
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/didSave")) {
        if (params) |p| if (objectField(p, "textDocument")) |doc| {
            if (stringField(doc, "uri")) |uri| {
                const path = try server.documents.absolutePathFromUri(uri);
                defer server.allocator.free(path);
                if (server.pending_rebuild_path != null) {
                    server.pending_rebuild_revision = server.active_revision;
                    try server.flushPendingRebuild(server.pendingLayoutBuildMode());
                } else if (server.analysis != null and
                    server.analysis.?.generation == server.documents.generation and
                    server.analysis.?.coversPath(path))
                {
                    server.acceptCurrentRevision();
                } else {
                    try server.rebuildImmediately(path);
                }
            }
        };
        return;
    }
    if (std.mem.eql(u8, method, "workspace/didChangeWatchedFiles")) {
        var relevant = params == null;
        if (params) |p| if (arrayField(p, "changes")) |changes| {
            for (changes.items) |*change| {
                if (change.* != .object) continue;
                const uri = stringField(&change.object, "uri") orelse continue;
                const path = try server.documents.absolutePathFromUri(uri);
                defer server.allocator.free(path);
                if (server.documents.sourceForPath(path) != null) continue;
                if (std.mem.eql(u8, std.fs.path.basename(path), "ss.toml") or
                    std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".ss"))
                {
                    relevant = true;
                    break;
                }
            }
        };
        if (relevant) {
            if (server.analysis) |*snapshot| {
                const entry_path = try server.allocator.dupe(u8, snapshot.project.entry_path);
                defer server.allocator.free(entry_path);
                try server.scheduleRebuild(entry_path);
            } else {
                server.acceptCurrentRevision();
            }
        } else {
            server.acceptCurrentRevision();
        }
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/didClose")) {
        if (params) |p| if (objectField(p, "textDocument")) |doc| {
            if (stringField(doc, "uri")) |uri| {
                if (server.documents.removeUri(uri)) |path| server.allocator.free(path);
            }
        };
        return;
    }

    if (id != null) try server.checkCanceled();

    if (std.mem.eql(u8, method, "textDocument/completion")) {
        var provider = analysisProvider(server);
        var ctx = feature_completion.Context{
            .allocator = server.allocator,
            .provider = &provider,
            .documents = &server.documents,
        };
        const result = try feature_completion.result(&ctx, params);
        defer server.allocator.free(result);
        try server.respondResult(id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/hover")) {
        var provider = analysisProvider(server);
        var ctx = feature_hover.Context{
            .allocator = server.allocator,
            .provider = &provider,
            .documents = &server.documents,
        };
        const result = try feature_hover.result(&ctx, params);
        defer server.allocator.free(result);
        try server.respondResult(id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/definition")) {
        var provider = analysisProvider(server);
        var ctx = feature_definition.Context{
            .allocator = server.allocator,
            .provider = &provider,
            .documents = &server.documents,
        };
        const result = try feature_definition.result(&ctx, params);
        defer server.allocator.free(result);
        try server.respondResult(id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
        var provider = analysisProvider(server);
        var ctx = feature_symbols.Context{
            .allocator = server.allocator,
            .provider = &provider,
        };
        const result = try feature_symbols.result(&ctx, params);
        defer server.allocator.free(result);
        try server.respondResult(id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/foldingRange")) {
        var provider = analysisProvider(server);
        var ctx = feature_folding.Context{
            .allocator = server.allocator,
            .provider = &provider,
        };
        const result = try feature_folding.result(&ctx, params);
        defer server.allocator.free(result);
        try server.respondResult(id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
        var ctx = feature_tokens.Context{
            .allocator = server.allocator,
            .io = server.io,
            .documents = &server.documents,
            .current_snapshot = if (server.analysis) |*snapshot| snapshot else null,
        };
        const result = try feature_tokens.result(&ctx, params);
        defer server.allocator.free(result);
        try server.respondResult(id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/documentColor")) {
        var ctx = feature_colors.Context{
            .allocator = server.allocator,
            .io = server.io,
            .documents = &server.documents,
            .current_snapshot = if (server.analysis) |*snapshot| snapshot else null,
        };
        const result = try feature_colors.documentColorsResult(&ctx, params);
        defer server.allocator.free(result);
        try server.respondResult(id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/colorPresentation")) {
        var ctx = feature_colors.Context{
            .allocator = server.allocator,
            .io = server.io,
            .documents = &server.documents,
            .current_snapshot = if (server.analysis) |*snapshot| snapshot else null,
        };
        const result = try feature_colors.colorPresentationResult(&ctx, params);
        defer server.allocator.free(result);
        try server.respondResult(id, result);
        return;
    }
    if (std.mem.eql(u8, method, "ss/projectInfo")) {
        var provider = analysisProvider(server);
        var ctx = feature_project.Context{
            .allocator = server.allocator,
            .provider = &provider,
        };
        const result = try feature_project.result(&ctx, params);
        defer server.allocator.free(result);
        try server.respondResult(id, result);
        return;
    }
    if (std.mem.eql(u8, method, "ss/layoutConflicts")) {
        var provider = analysisProvider(server);
        var ctx = feature_layout.Context{
            .io = server.io,
            .allocator = server.allocator,
            .documents = &server.documents,
            .provider = &provider,
            .responses = &server.layout_responses,
        };
        const result = try feature_layout.result(&ctx, params);
        defer server.allocator.free(result);
        try server.respondResult(id, result);
        return;
    }
    if (std.mem.eql(u8, method, "ss/editorSnapshot")) {
        const base_snapshot_id = if (params) |p| switch (p) {
            .object => |*object| stringField(object, "baseSnapshotId") orelse "",
            else => "",
        } else "";
        const doc_path = try protocol.docPathFromParams(server.allocator, params);
        defer if (doc_path) |path| server.allocator.free(path);
        if (doc_path) |path| {
            const first_for_path = !server.wysiwyg_paths.contains(path);
            if (first_for_path) try putStringSet(server.allocator, &server.wysiwyg_paths, path);
            const flushed_pending = server.pending_rebuild_path != null;
            if (flushed_pending) try server.flushPendingRebuild(.required);
            if (server.analysis == null or
                !server.analysis.?.coversPath(path) or
                server.analysis_revision != server.active_revision or
                (!flushed_pending and (server.analysis.?.layout_output == null or
                    server.analysis.?.layout_output.?.editor == null)) or
                (server.analysis.?.layout_output != null and
                    server.analysis.?.layout_output.?.editor != null and
                    !editorDisplayMatches(server.analysis.?.layout_output.?.editor.?.model, base_snapshot_id)))
            {
                try server.rebuildEditorImmediately(path);
            }
        } else if (server.pending_rebuild_path != null) {
            try server.flushPendingRebuild(server.pendingLayoutBuildMode());
        }
        var provider = analysisProvider(server);
        var ctx = feature_editor.Context{
            .allocator = server.allocator,
            .documents = &server.documents,
            .provider = &provider,
            .responses = &server.editor_responses,
            .diagnostics = &server.editor_diagnostics,
            .snapshot_cache = &server.editor_snapshot_cache,
        };
        const result = try feature_editor.snapshotResult(&ctx, params);
        defer server.allocator.free(result);
        try server.respondResult(id, result);
        return;
    }
    if (std.mem.eql(u8, method, "ss/editorClose")) {
        const doc_path = try protocol.docPathFromParams(server.allocator, params);
        defer if (doc_path) |path| server.allocator.free(path);
        if (doc_path) |path| {
            if (server.wysiwyg_paths.fetchRemove(path)) |entry| server.allocator.free(entry.key);
        }
        return;
    }
    if (std.mem.eql(u8, method, "ss/layoutEdit")) {
        var provider = analysisProvider(server);
        var ctx = feature_edit.Context{
            .io = server.io,
            .allocator = server.allocator,
            .documents = &server.documents,
            .active_editor_paths = &server.wysiwyg_paths,
            .provider = &provider,
            .generated_context = server,
            .on_generated = rememberGeneratedEdit,
        };
        const result = try feature_edit.result(&ctx, params);
        defer server.allocator.free(result);
        try server.respondResult(id, result);
        return;
    }
    if (std.mem.eql(u8, method, "ss/insertShape")) {
        var provider = analysisProvider(server);
        var ctx = feature_shape_edit.Context{
            .io = server.io,
            .allocator = server.allocator,
            .documents = &server.documents,
            .active_editor_paths = &server.wysiwyg_paths,
            .provider = &provider,
        };
        const result = try feature_shape_edit.insertResult(&ctx, params);
        defer server.allocator.free(result);
        try server.respondResult(id, result);
        return;
    }
    if (std.mem.eql(u8, method, "ss/editLineGeometry")) {
        var provider = analysisProvider(server);
        var ctx = feature_shape_edit.Context{
            .io = server.io,
            .allocator = server.allocator,
            .documents = &server.documents,
            .active_editor_paths = &server.wysiwyg_paths,
            .provider = &provider,
        };
        const result = try feature_shape_edit.lineGeometryResult(&ctx, params);
        defer server.allocator.free(result);
        try server.respondResult(id, result);
        return;
    }
    if (std.mem.eql(u8, method, "ss/shapeStyleEdit")) {
        var provider = analysisProvider(server);
        var ctx = feature_shape_edit.Context{
            .io = server.io,
            .allocator = server.allocator,
            .documents = &server.documents,
            .active_editor_paths = &server.wysiwyg_paths,
            .provider = &provider,
        };
        const result = try feature_shape_edit.styleResult(&ctx, params);
        defer server.allocator.free(result);
        try server.respondResult(id, result);
        return;
    }
    if (id != null) switch (server.workStatus()) {
        .current => try respondError(server.allocator, id, -32601, "method not found"),
        .canceled => try respondError(server.allocator, id, -32800, "request cancelled"),
        .content_modified => try respondError(server.allocator, id, -32801, "content modified"),
    };
}

fn editorDisplayMatches(model: editor_snapshot.Model, base_snapshot_id: []const u8) bool {
    const required = model.display_base_snapshot_id orelse return true;
    return std.mem.eql(u8, required, base_snapshot_id);
}

const initializeResultPrefix =
    \\{"capabilities":{"textDocumentSync":2,"completionProvider":{"triggerCharacters":[".","\"","@",":"]},"hoverProvider":true,"definitionProvider":true,"documentSymbolProvider":true,"foldingRangeProvider":true,"semanticTokensProvider":{"legend":{"tokenTypes":["keyword","function","variable","string","number","type","property","operator"],"tokenModifiers":[]},"full":true},"colorProvider":true},"serverInfo":{"name":"ss-lsp","version":
;

fn initializeResult(allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, initializeResultPrefix);
    try appendJsonString(allocator, &out, build_options.version);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

fn monotonicMillis() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * std.time.ms_per_s + nsec / std.time.ns_per_ms;
}

fn saturatedAddMillis(base: u64, delta: u64) u64 {
    return std.math.add(u64, base, delta) catch std.math.maxInt(u64);
}

fn dirnameAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(path) orelse ".";
    return project.absolutePath(allocator, dir);
}
