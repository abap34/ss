const std = @import("std");
const build_options = @import("build_options");
const core = @import("core");
const pdf = @import("../render/pdf.zig");
const lowering = @import("../lowering.zig");
const analysis = @import("../analysis.zig");
const project = @import("../project.zig");
const utils = @import("utils");
const lsp_diagnostics = @import("diagnostics.zig");
const protocol = @import("protocol.zig");
const lsp_state = @import("state.zig");
const feature_colors = @import("features/colors.zig");
const feature_completion = @import("features/completion.zig");
const feature_definition = @import("features/definition.zig");
const feature_folding = @import("features/folding.zig");
const feature_hover = @import("features/hover.zig");
const feature_inlay = @import("features/inlay.zig");
const feature_layout = @import("features/layout.zig");
const feature_project = @import("features/project.zig");
const feature_symbols = @import("features/symbols.zig");
const feature_tokens = @import("features/tokens.zig");

const JsonValue = protocol.JsonValue;
const Snapshot = lsp_state.Snapshot;
const DocumentStore = lsp_state.DocumentStore;
const LayoutStore = lsp_state.LayoutStore;
const DiagnosticSet = lsp_diagnostics.DiagnosticSet;
const max_poll_timeout_ms = std.math.maxInt(i32);

const readMessage = protocol.readMessage;
const respond = protocol.respond;
const respondError = protocol.respondError;
const sendNotification = protocol.sendNotification;
const appendJsonValue = protocol.appendJsonValue;
const appendJsonString = protocol.appendJsonString;
const stringField = protocol.stringField;
const objectField = protocol.objectField;
const arrayField = protocol.arrayField;
const uriFromPath = protocol.uriFromPath;

const Server = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    documents: DocumentStore,
    snapshot: ?Snapshot = null,
    layout_snapshots: LayoutStore = .{},
    published_diagnostic_uris: std.StringHashMap(void),
    pending_rebuild_path: ?[]u8 = null,
    pending_rebuild_due_ms: u64 = 0,
    shutdown: bool = false,

    fn init(io: std.Io, allocator: std.mem.Allocator) Server {
        return .{
            .io = io,
            .allocator = allocator,
            .documents = DocumentStore.init(allocator),
            .published_diagnostic_uris = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *Server) void {
        self.documents.deinit();
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.layout_snapshots.deinit(self.allocator);
        lsp_state.deinitStringSet(self.allocator, &self.published_diagnostic_uris);
        self.clearPendingRebuild();
    }

    fn rebuild(self: *Server, changed_path: []const u8) !void {
        if (self.snapshot) |*old| old.deinit();
        self.snapshot = null;

        var diagnostics = DiagnosticSet.init(self.allocator);
        defer diagnostics.deinit();
        const rebuild_generation = self.documents.generation;
        var snapshot = try self.buildSnapshot(changed_path, &diagnostics);
        errdefer snapshot.deinit();
        if (snapshot.generation != self.documents.generation or rebuild_generation != self.documents.generation) {
            snapshot.deinit();
            return;
        }
        self.snapshot = snapshot;
        if (self.snapshot.?.project.lsp.enabled and self.snapshot.?.project.lsp.diagnostics) {
            try self.publishDiagnostics(&diagnostics);
        } else {
            var empty = DiagnosticSet.init(self.allocator);
            defer empty.deinit();
            try self.publishDiagnostics(&empty);
        }
    }

    fn rebuildImmediately(self: *Server, changed_path: []const u8) !void {
        self.clearPendingRebuild();
        try self.rebuild(changed_path);
    }

    fn scheduleRebuild(self: *Server, changed_path: []const u8) !void {
        const delay_ms = self.lspDebounceMs();
        if (delay_ms == 0) {
            try self.rebuildImmediately(changed_path);
            return;
        }
        const owned_path = try self.allocator.dupe(u8, changed_path);
        errdefer self.allocator.free(owned_path);
        self.clearPendingRebuild();
        self.pending_rebuild_path = owned_path;
        self.pending_rebuild_due_ms = saturatedAddMillis(monotonicMillis(), delay_ms);
    }

    fn flushPendingRebuild(self: *Server) !void {
        const path = self.pending_rebuild_path orelse return;
        self.pending_rebuild_path = null;
        self.pending_rebuild_due_ms = 0;
        defer self.allocator.free(path);
        try self.rebuild(path);
    }

    fn flushPendingRebuildIfDue(self: *Server) !void {
        if (self.pending_rebuild_path == null) return;
        if (monotonicMillis() < self.pending_rebuild_due_ms) return;
        try self.flushPendingRebuild();
    }

    fn pendingRebuildPollTimeout(self: *const Server) ?i32 {
        if (self.pending_rebuild_path == null) return null;
        const now = monotonicMillis();
        if (now >= self.pending_rebuild_due_ms) return 0;
        const delta = self.pending_rebuild_due_ms - now;
        return @intCast(@min(delta, @as(u64, @intCast(max_poll_timeout_ms))));
    }

    fn lspDebounceMs(self: *const Server) u64 {
        return if (self.snapshot) |*snapshot| snapshot.project.lsp.debounce_ms else (project.LspConfig{}).debounce_ms;
    }

    fn clearPendingRebuild(self: *Server) void {
        if (self.pending_rebuild_path) |path| self.allocator.free(path);
        self.pending_rebuild_path = null;
        self.pending_rebuild_due_ms = 0;
    }

    fn buildSnapshot(self: *Server, changed_path: []const u8, diagnostics: *DiagnosticSet) !Snapshot {
        const changed_abs = try project.absolutePath(self.allocator, changed_path);
        defer self.allocator.free(changed_abs);
        const changed_dir = std.fs.path.dirname(changed_abs) orelse ".";

        const project_path = try project.discoverPath(self.allocator, changed_dir);
        defer if (project_path) |path| self.allocator.free(path);

        var config: ?project.Config = null;
        if (project_path) |path| {
            config = project.loadFile(self.allocator, self.io, path) catch |err| blk: {
                try self.addProjectConfigDiagnostic(diagnostics, path, err);
                break :blk null;
            };
        }
        defer if (config) |*cfg| cfg.deinit(self.allocator);
        const entry_path = if (config) |cfg| try self.allocator.dupe(u8, cfg.entry) else try self.allocator.dupe(u8, changed_abs);
        defer self.allocator.free(entry_path);
        const asset_base_dir = if (config) |cfg| try self.allocator.dupe(u8, cfg.asset_base_dir) else try dirnameAlloc(self.allocator, entry_path);
        defer self.allocator.free(asset_base_dir);

        var sources = analysis.snapshot.SourceSet.init(self.allocator, self.io);
        defer sources.deinit();
        try self.documents.fillOverlay(&sources.overlay);

        var layout_context = LayoutHookContext{ .server = self, .diagnostics = diagnostics };
        var analysis_snapshot = try analysis.snapshot.buildSnapshot(self.allocator, &sources, entry_path, asset_base_dir, .{
            .generation = self.documents.generation,
            .project = .{
                .lsp = if (config) |cfg| cfg.lsp else .{},
                .preview = if (config) |cfg| cfg.preview else .{},
                .page_guide = if (config) |cfg| cfg.page_guide else .{},
            },
            .layout = .{
                .context = &layout_context,
                .run = runSnapshotLayout,
                .on_error = addSnapshotLayoutError,
            },
        });
        errdefer analysis_snapshot.deinit();
        try diagnostics.addAnalysisBag(&analysis_snapshot.diagnostics);
        return analysis_snapshot;
    }

    fn buildSingleDocumentSnapshot(self: *Server, changed_path: []const u8, diagnostics: *DiagnosticSet) !Snapshot {
        const entry_path = try project.absolutePath(self.allocator, changed_path);
        defer self.allocator.free(entry_path);
        const asset_base_dir = try dirnameAlloc(self.allocator, entry_path);
        defer self.allocator.free(asset_base_dir);

        var sources = analysis.snapshot.SourceSet.init(self.allocator, self.io);
        defer sources.deinit();
        try self.documents.fillOverlay(&sources.overlay);

        var analysis_snapshot = try analysis.snapshot.buildSnapshot(self.allocator, &sources, entry_path, asset_base_dir, .{
            .generation = self.documents.generation,
        });
        errdefer analysis_snapshot.deinit();
        try diagnostics.addAnalysisBag(&analysis_snapshot.diagnostics);
        return analysis_snapshot;
    }

    fn lowerToIrWithRenderMeasurements(self: *Server, ir: *core.Ir) !void {
        try lowering.evaluateDocument(ir);
        var measurement_scope = try pdf.LayoutMeasurementScope.init(ir.allocator, self.io, ir);
        defer measurement_scope.deinit();
        try lowering.solveLayoutWithOptions(ir, .{ .measurement_provider = measurement_scope.provider() });
    }

    fn addProjectConfigDiagnostic(self: *Server, diagnostics: *DiagnosticSet, path: []const u8, err: anyerror) !void {
        var owned_source: ?[]u8 = null;
        defer if (owned_source) |text| self.allocator.free(text);
        const text = self.documents.sourceForPath(path) orelse blk: {
            owned_source = utils.fs.readFileAlloc(self.io, self.allocator, path) catch null;
            break :blk owned_source orelse "";
        };
        const message = try std.fmt.allocPrint(self.allocator, "ProjectConfigFailed: {s}", .{@errorName(err)});
        defer self.allocator.free(message);
        try diagnostics.add(path, text, .@"error", @errorName(err), message, project.configErrorSpan(text, err));
    }

    fn publishDiagnostics(self: *Server, diagnostics: *DiagnosticSet) !void {
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
            var body = std.ArrayList(u8).empty;
            defer body.deinit(self.allocator);
            try body.appendSlice(self.allocator, "{\"uri\":");
            try appendJsonString(self.allocator, &body, entry.key_ptr.*);
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
            const uri = try uriFromPath(self.allocator, entry.key_ptr.*);
            defer self.allocator.free(uri);
            if (current_published.contains(uri)) continue;
            var body = std.ArrayList(u8).empty;
            defer body.deinit(self.allocator);
            try body.appendSlice(self.allocator, "{\"uri\":");
            try appendJsonString(self.allocator, &body, uri);
            try body.appendSlice(self.allocator, ",\"diagnostics\":[]}");
            try sendNotification(self.allocator, "textDocument/publishDiagnostics", body.items);
            try putStringSet(self.allocator, &current_published, uri);
        }

        var previous_iterator = self.published_diagnostic_uris.iterator();
        while (previous_iterator.next()) |entry| {
            if (current_published.contains(entry.key_ptr.*)) continue;
            var body = std.ArrayList(u8).empty;
            defer body.deinit(self.allocator);
            try body.appendSlice(self.allocator, "{\"uri\":");
            try appendJsonString(self.allocator, &body, entry.key_ptr.*);
            try body.appendSlice(self.allocator, ",\"diagnostics\":[]}");
            try sendNotification(self.allocator, "textDocument/publishDiagnostics", body.items);
        }

        lsp_state.deinitStringSet(self.allocator, &self.published_diagnostic_uris);
        self.published_diagnostic_uris = current_published;
    }
};

fn snapshotProvider(server: *Server) lsp_state.SnapshotProvider {
    return .{
        .context = server,
        .current = if (server.snapshot) |*snapshot| snapshot else null,
        .generation = server.documents.generation,
        .build = buildSnapshotForFeature,
    };
}

fn buildSnapshotForFeature(context: *anyopaque, path: []const u8) !Snapshot {
    const server: *Server = @ptrCast(@alignCast(context));
    var diagnostics = DiagnosticSet.init(server.allocator);
    defer diagnostics.deinit();
    var snapshot = try server.buildSnapshot(path, &diagnostics);
    if (snapshot.coversPath(path)) return snapshot;
    snapshot.deinit();
    return try server.buildSingleDocumentSnapshot(path, &diagnostics);
}

const LayoutHookContext = struct {
    server: *Server,
    diagnostics: *DiagnosticSet,
};

fn runSnapshotLayout(context: *anyopaque, ir: *core.Ir) !void {
    const hook: *LayoutHookContext = @ptrCast(@alignCast(context));
    try hook.server.lowerToIrWithRenderMeasurements(ir);
}

fn addSnapshotLayoutError(context: *anyopaque, ir: *core.Ir, err: anyerror) !void {
    const hook: *LayoutHookContext = @ptrCast(@alignCast(context));
    try hook.diagnostics.addConstraintFailure(ir, err);
}

fn putStringSet(allocator: std.mem.Allocator, set: *std.StringHashMap(void), value: []const u8) !void {
    if (set.contains(value)) return;
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try set.put(owned, {});
}

pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server = Server.init(io, allocator);
    defer server.deinit();

    while (!server.shutdown) {
        try server.flushPendingRebuildIfDue();
        const stdin_ready = try waitForStdin(server.pendingRebuildPollTimeout());
        if (!stdin_ready) {
            try server.flushPendingRebuild();
            continue;
        }
        const message = try readMessage(allocator);
        const body = message orelse break;
        defer allocator.free(body);
        try handleMessage(&server, body);
    }
}

fn handleMessage(server: *Server, body: []const u8) !void {
    var parsed = utils.json.parseValue(server.allocator, body, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const root = parsed.value.object;
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
        server.shutdown = true;
        try respond(server.allocator, id, "null");
        return;
    }
    if (std.mem.eql(u8, method, "exit")) {
        server.shutdown = true;
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        if (params) |p| if (objectField(p, "textDocument")) |doc| {
            if (stringField(doc, "uri")) |uri| {
                const text = stringField(doc, "text") orelse "";
                const path = try server.documents.replaceUri(uri, text);
                defer server.allocator.free(path);
                try server.rebuildImmediately(path);
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
                    for (changes.items) |*change| {
                        if (change.* == .object) try server.documents.applyChangeAtPath(path, &change.object);
                    }
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
                try server.rebuildImmediately(path);
            }
        };
        return;
    }
    if (std.mem.eql(u8, method, "workspace/didChangeWatchedFiles")) {
        if (server.snapshot) |*snapshot| {
            const entry_path = try server.allocator.dupe(u8, snapshot.project.entry_path);
            defer server.allocator.free(entry_path);
            try server.scheduleRebuild(entry_path);
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

    if (std.mem.eql(u8, method, "textDocument/completion")) {
        var provider = snapshotProvider(server);
        var ctx = feature_completion.Context{
            .allocator = server.allocator,
            .provider = &provider,
            .documents = &server.documents,
        };
        const result = try feature_completion.result(&ctx, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/hover")) {
        var provider = snapshotProvider(server);
        var ctx = feature_hover.Context{
            .allocator = server.allocator,
            .provider = &provider,
            .documents = &server.documents,
        };
        const result = try feature_hover.result(&ctx, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/definition")) {
        var provider = snapshotProvider(server);
        var ctx = feature_definition.Context{
            .allocator = server.allocator,
            .provider = &provider,
            .documents = &server.documents,
        };
        const result = try feature_definition.result(&ctx, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
        var provider = snapshotProvider(server);
        var ctx = feature_inlay.Context{
            .allocator = server.allocator,
            .provider = &provider,
        };
        const result = try feature_inlay.result(&ctx, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
        var provider = snapshotProvider(server);
        var ctx = feature_symbols.Context{
            .allocator = server.allocator,
            .provider = &provider,
        };
        const result = try feature_symbols.result(&ctx, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/foldingRange")) {
        var provider = snapshotProvider(server);
        var ctx = feature_folding.Context{
            .allocator = server.allocator,
            .provider = &provider,
        };
        const result = try feature_folding.result(&ctx, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
        var ctx = feature_tokens.Context{
            .allocator = server.allocator,
            .io = server.io,
            .documents = &server.documents,
            .current_snapshot = if (server.snapshot) |*snapshot| snapshot else null,
        };
        const result = try feature_tokens.result(&ctx, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/documentColor")) {
        var ctx = feature_colors.Context{
            .allocator = server.allocator,
            .io = server.io,
            .documents = &server.documents,
            .current_snapshot = if (server.snapshot) |*snapshot| snapshot else null,
        };
        const result = try feature_colors.documentColorsResult(&ctx, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/colorPresentation")) {
        var ctx = feature_colors.Context{
            .allocator = server.allocator,
            .io = server.io,
            .documents = &server.documents,
            .current_snapshot = if (server.snapshot) |*snapshot| snapshot else null,
        };
        const result = try feature_colors.colorPresentationResult(&ctx, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "ss/projectInfo")) {
        var provider = snapshotProvider(server);
        var ctx = feature_project.Context{
            .allocator = server.allocator,
            .provider = &provider,
        };
        const result = try feature_project.result(&ctx, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "ss/layoutConflicts")) {
        var provider = snapshotProvider(server);
        var ctx = feature_layout.Context{
            .io = server.io,
            .allocator = server.allocator,
            .documents = &server.documents,
            .provider = &provider,
            .layout_snapshots = &server.layout_snapshots,
        };
        const result = try feature_layout.result(&ctx, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (id != null) try respondError(server.allocator, id, -32601, "method not found");
}

const initializeResultPrefix =
    \\{"capabilities":{"textDocumentSync":2,"completionProvider":{"triggerCharacters":[".","\"","@",":"]},"hoverProvider":true,"definitionProvider":true,"inlayHintProvider":true,"documentSymbolProvider":true,"foldingRangeProvider":true,"semanticTokensProvider":{"legend":{"tokenTypes":["keyword","function","variable","string","number","type","property","operator"],"tokenModifiers":[]},"full":true},"colorProvider":true},"serverInfo":{"name":"ss-lsp","version":
;

fn initializeResult(allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, initializeResultPrefix);
    try appendJsonString(allocator, &out, build_options.version);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

fn waitForStdin(timeout_ms: ?i32) !bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = 0,
        .events = @as(i16, std.posix.POLL.IN),
        .revents = 0,
    }};
    const ready = try std.posix.poll(fds[0..], timeout_ms orelse -1);
    if (ready == 0) return false;
    const terminal_events = @as(i16, std.posix.POLL.HUP) | @as(i16, std.posix.POLL.ERR) | @as(i16, std.posix.POLL.NVAL);
    return (fds[0].revents & (@as(i16, std.posix.POLL.IN) | terminal_events)) != 0;
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
