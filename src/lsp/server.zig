const std = @import("std");
const ast = @import("ast");
const build_options = @import("build_options");
const core = @import("core");
const app = @import("../app.zig");
const pdf = @import("../render/pdf.zig");
const syntax = @import("../syntax.zig");
const lowering = @import("../lowering.zig");
const analysis = @import("../analysis.zig");
const module_loader = @import("../modules/loader.zig");
const project = @import("../project.zig");
const dump = @import("../dump.zig");
const utils = @import("utils");
const analysis_completion = @import("../analysis/completion.zig");
const analysis_editor = @import("../analysis/editor.zig");
const lsp_diagnostics = @import("diagnostics.zig");
const document_features = @import("document_features.zig");
const protocol = @import("protocol.zig");
const lsp_state = @import("state.zig");
const source = utils.source;

const JsonValue = protocol.JsonValue;
const JsonObject = protocol.JsonObject;
const Snapshot = lsp_state.Snapshot;
const CompletionCache = lsp_state.CompletionCache;
const DocumentCompletionCache = lsp_state.DocumentCompletionCache;
const DiagnosticSet = lsp_diagnostics.DiagnosticSet;
const max_poll_timeout_ms = std.math.maxInt(i32);

const readMessage = protocol.readMessage;
const respond = protocol.respond;
const respondError = protocol.respondError;
const sendNotification = protocol.sendNotification;
const appendJsonValue = protocol.appendJsonValue;
const appendJsonString = protocol.appendJsonString;
const appendInt = protocol.appendInt;
const appendBool = protocol.appendBool;
const appendFloat = protocol.appendFloat;
const stringField = protocol.stringField;
const intField = protocol.intField;
const usizeField = protocol.usizeField;
const lspLine = protocol.lspLine;
const lspCharacter = protocol.lspCharacter;
const numberField = protocol.numberField;
const objectField = protocol.objectField;
const objectFieldObject = protocol.objectFieldObject;
const arrayField = protocol.arrayField;
const arrayFieldObject = protocol.arrayFieldObject;
const docPathFromParams = protocol.docPathFromParams;
const pathFromUri = protocol.pathFromUri;
const uriFromPath = protocol.uriFromPath;
const rangeFromSpan = protocol.rangeFromSpan;
const appendRange = protocol.appendRange;
const locationJson = protocol.locationJson;
const appendLocationObject = protocol.appendLocationObject;
const samePath = protocol.samePath;

const RequestPosition = struct {
    doc_path: []u8,
    source: []const u8,
    offset: usize,
    line: usize,
    character: usize,

    pub fn deinit(self: *RequestPosition, allocator: std.mem.Allocator) void {
        allocator.free(self.doc_path);
    }
};

const DocumentText = struct {
    path: []u8,
    source: []const u8,
    owned_source: ?[]u8 = null,

    fn deinit(self: *DocumentText, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.owned_source) |text| allocator.free(text);
    }
};

const RequestContext = struct {
    target: []u8,
    doc_path: []u8,
    source: []const u8,
    offset: usize,
    program: ?ast.Program = null,

    pub fn deinit(self: *RequestContext, allocator: std.mem.Allocator) void {
        if (self.program) |*program| program.deinit(allocator);
        allocator.free(self.target);
        allocator.free(self.doc_path);
    }
};

const Server = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    documents: std.StringHashMap([]u8),
    snapshot: ?Snapshot = null,
    last_good_completion: ?CompletionCache = null,
    document_completion_cache: std.StringHashMap(DocumentCompletionCache),
    published_diagnostic_uris: std.StringHashMap(void),
    pending_rebuild_path: ?[]u8 = null,
    pending_rebuild_due_ms: u64 = 0,
    shutdown: bool = false,

    fn init(io: std.Io, allocator: std.mem.Allocator) Server {
        return .{
            .io = io,
            .allocator = allocator,
            .documents = std.StringHashMap([]u8).init(allocator),
            .document_completion_cache = std.StringHashMap(DocumentCompletionCache).init(allocator),
            .published_diagnostic_uris = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *Server) void {
        var iterator = self.documents.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.documents.deinit();
        if (self.snapshot) |*snapshot| snapshot.deinit(self.allocator);
        if (self.last_good_completion) |*cache| cache.deinit(self.allocator);
        lsp_state.deinitCompletionIndexMap(self.allocator, &self.document_completion_cache);
        lsp_state.deinitStringSet(self.allocator, &self.published_diagnostic_uris);
        self.clearPendingRebuild();
    }

    fn replaceDocument(self: *Server, uri: []const u8, text: []const u8) !void {
        const path = try pathFromUri(self.allocator, uri);
        errdefer self.allocator.free(path);
        const document_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(document_text);
        if (self.documents.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        try self.documents.put(path, document_text);
    }

    fn applyDocumentChange(self: *Server, uri: []const u8, change: *const JsonObject) !void {
        const text = stringField(change, "text") orelse "";
        const range = objectFieldObject(change, "range") orelse {
            try self.replaceDocument(uri, text);
            return;
        };
        const start = objectFieldObject(range, "start") orelse {
            try self.replaceDocument(uri, text);
            return;
        };
        const end = objectFieldObject(range, "end") orelse {
            try self.replaceDocument(uri, text);
            return;
        };

        const path = try pathFromUri(self.allocator, uri);
        errdefer self.allocator.free(path);
        const old_source = self.documents.get(path) orelse "";
        const start_offset = source.offsetForUtf16Position(old_source, lspLine(start), lspCharacter(start));
        const end_offset = source.offsetForUtf16Position(old_source, lspLine(end), lspCharacter(end));
        if (end_offset < start_offset) return error.InvalidLspRange;

        var next = std.ArrayList(u8).empty;
        errdefer next.deinit(self.allocator);
        try next.appendSlice(self.allocator, old_source[0..start_offset]);
        try next.appendSlice(self.allocator, text);
        try next.appendSlice(self.allocator, old_source[end_offset..]);
        const document_text = try next.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(document_text);

        if (self.documents.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        try self.documents.put(path, document_text);
    }

    fn removeDocument(self: *Server, uri: []const u8) void {
        const path = pathFromUri(self.allocator, uri) catch return;
        defer self.allocator.free(path);
        if (self.documents.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.removeDocumentCompletionCache(path);
    }

    fn sourceForPath(self: *Server, path: []const u8) ?[]const u8 {
        const absolute = project.absolutePath(self.allocator, path) catch return null;
        defer self.allocator.free(absolute);
        return self.documents.get(absolute);
    }

    fn rebuild(self: *Server, changed_path: []const u8) !void {
        if (self.snapshot) |*old| old.deinit(self.allocator);
        self.snapshot = null;

        var diagnostics = DiagnosticSet.init(self.allocator);
        defer diagnostics.deinit();
        var snapshot = try self.buildSnapshot(changed_path, &diagnostics);
        errdefer snapshot.deinit(self.allocator);
        if (snapshot.dump_json != null) try self.rememberCompletionSnapshot(&snapshot);
        self.snapshot = snapshot;
        try self.refreshDocumentCompletionCache(changed_path);
        if (self.snapshot.?.lsp.enabled and self.snapshot.?.lsp.diagnostics) {
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
        return if (self.snapshot) |snapshot| snapshot.lsp.debounce_ms else (project.LspConfig{}).debounce_ms;
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
        errdefer self.allocator.free(entry_path);
        const asset_base_dir = if (config) |cfg| try self.allocator.dupe(u8, cfg.asset_base_dir) else try dirnameAlloc(self.allocator, entry_path);
        errdefer self.allocator.free(asset_base_dir);

        var snapshot = Snapshot{
            .entry_path = entry_path,
            .asset_base_dir = asset_base_dir,
            .lsp = if (config) |cfg| cfg.lsp else .{},
            .preview = if (config) |cfg| cfg.preview else .{},
            .page_guide = if (config) |cfg| cfg.page_guide else .{},
            .module_paths = .empty,
        };
        errdefer snapshot.deinit(self.allocator);

        var overlay = module_loader.SourceOverlay.init(self.allocator);
        defer overlay.deinit();
        var doc_iterator = self.documents.iterator();
        while (doc_iterator.next()) |entry| {
            try overlay.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var entry_source = if (self.sourceForPath(entry_path)) |text|
            try self.allocator.dupe(u8, text)
        else
            utils.fs.readFileAlloc(self.io, self.allocator, entry_path) catch |err| {
                try self.addProjectEntryReadDiagnostic(diagnostics, project_path, entry_path, err);
                return snapshot;
            };

        var program = syntax.parseWithSourceName(self.allocator, entry_source, entry_path) catch |err| {
            const diagnostic = syntax.lastParseDiagnostic();
            var message_buf: [256]u8 = undefined;
            const message = if (diagnostic) |diag|
                utils.err.formatParseDiagnostic(&message_buf, diag)
            else
                utils.err.formatParseFailureWithoutDiagnostic(&message_buf, err);
            try diagnostics.add(entry_path, entry_source, .@"error", @errorName(err), message, if (diagnostic) |diag| .{ .start = diag.span.start, .end = diag.span.end } else null);
            self.allocator.free(entry_source);
            return snapshot;
        };

        var load_diagnostics = module_loader.LoadDiagnostics.init(self.allocator);
        defer load_diagnostics.deinit();
        var index = analysis.loadProgramIndexWithOptions(self.allocator, self.io, asset_base_dir, program, .{
            .overlay = &overlay,
            .diagnostics = &load_diagnostics,
            .print_diagnostics = false,
        }) catch |err| {
            try diagnostics.addLoadDiagnostics(&load_diagnostics);
            if (load_diagnostics.items.items.len != 0) {
                const span = module_loader.importFailureSpan(self.allocator, self.io, asset_base_dir, &program, &overlay, &load_diagnostics);
                try diagnostics.add(entry_path, entry_source, .@"error", "ImportFailed", "ImportFailed: imported module failed to load", span);
            } else if (err == error.UnknownImport) {
                if (try module_loader.findUnknownImportReport(self.allocator, self.io, asset_base_dir, program, &overlay)) |found| {
                    var report = found;
                    defer report.deinit(self.allocator);
                    try diagnostics.add(entry_path, entry_source, .@"error", "UnknownImport", report.message, .{ .start = report.span.start, .end = report.span.end });
                }
            } else {
                const message = try std.fmt.allocPrint(self.allocator, "ProjectLoadFailed: {s}", .{@errorName(err)});
                defer self.allocator.free(message);
                try diagnostics.add(entry_path, entry_source, .@"error", @errorName(err), message, null);
            }
            program.deinit(self.allocator);
            self.allocator.free(entry_source);
            return snapshot;
        };
        defer index.deinit();

        var ir = analysis.buildIrWithOptions(self.allocator, entry_path, asset_base_dir, &entry_source, &program, &index, .{ .allow_diagnostics = true }) catch |err| {
            const message = try std.fmt.allocPrint(self.allocator, "BuildFailed: {s}", .{@errorName(err)});
            defer self.allocator.free(message);
            try diagnostics.add(entry_path, entry_source, .@"error", @errorName(err), message, null);
            program.deinit(self.allocator);
            if (entry_source.len != 0) self.allocator.free(entry_source);
            return snapshot;
        };
        defer ir.deinit();

        analysis.analyzeProgram(self.allocator, &ir) catch {};
        try diagnostics.addIr(&ir);
        if (!diagnostics.hasErrors()) {
            if (self.lowerToIrWithRenderMeasurements(&ir)) {
                try diagnostics.addIr(&ir);
            } else |err| switch (err) {
                error.ConstraintConflict,
                error.NegativeFrameSize,
                => try diagnostics.addConstraintFailure(&ir, err),
                else => {
                    try diagnostics.addIr(&ir);
                    if (!diagnostics.hasErrors()) {
                        const message = try std.fmt.allocPrint(self.allocator, "BuildFailed: {s}", .{@errorName(err)});
                        defer self.allocator.free(message);
                        try diagnostics.add(entry_path, entry_source, .@"error", @errorName(err), message, null);
                    }
                },
            }
        }

        var seen_modules = std.StringHashMap(void).init(self.allocator);
        defer seen_modules.deinit();
        for (ir.modules.items) |module| {
            if (module.path) |module_path| {
                if (seen_modules.contains(module_path)) continue;
                try seen_modules.put(module_path, {});
                try snapshot.module_paths.append(self.allocator, try self.allocator.dupe(u8, module_path));
            }
        }

        snapshot.dump_json = dump.toOwnedString(self.allocator, &ir) catch null;
        snapshot.completion_index = analysis_completion.Index.fromIr(self.allocator, &ir) catch null;
        return snapshot;
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
        const text = self.sourceForPath(path) orelse blk: {
            owned_source = utils.fs.readFileAlloc(self.io, self.allocator, path) catch null;
            break :blk owned_source orelse "";
        };
        const message = try std.fmt.allocPrint(self.allocator, "ProjectConfigFailed: {s}", .{@errorName(err)});
        defer self.allocator.free(message);
        try diagnostics.add(path, text, .@"error", @errorName(err), message, project.configErrorSpan(text, err));
    }

    fn addProjectEntryReadDiagnostic(
        self: *Server,
        diagnostics: *DiagnosticSet,
        project_path: ?[]const u8,
        entry_path: []const u8,
        err: anyerror,
    ) !void {
        const message = try std.fmt.allocPrint(self.allocator, "ProjectReadFailed: could not read {s}: {s}", .{ entry_path, @errorName(err) });
        defer self.allocator.free(message);
        if (project_path) |path| {
            var owned_source: ?[]u8 = null;
            defer if (owned_source) |text| self.allocator.free(text);
            const text = self.sourceForPath(path) orelse blk: {
                owned_source = utils.fs.readFileAlloc(self.io, self.allocator, path) catch null;
                break :blk owned_source orelse "";
            };
            try diagnostics.add(path, text, .@"error", "ProjectReadFailed", message, project.tomlKeySpan(text, "project", "entry") orelse project.tomlSectionSpan(text, "project"));
            return;
        }
        try diagnostics.add(entry_path, "", .@"error", "ProjectReadFailed", message, null);
    }

    fn rememberCompletionSnapshot(self: *Server, snapshot: *const Snapshot) !void {
        const index = if (snapshot.completion_index) |*value| value else return;
        const entry_path = try self.allocator.dupe(u8, snapshot.entry_path);
        errdefer self.allocator.free(entry_path);
        var cached_index = try index.clone(self.allocator);
        errdefer cached_index.deinit();
        const next = CompletionCache{
            .entry_path = entry_path,
            .index = cached_index,
        };
        if (self.last_good_completion) |*cache| cache.deinit(self.allocator);
        self.last_good_completion = next;
    }

    fn rememberDocumentCompletion(self: *Server, path: []const u8, source_hash: u64, index: analysis_completion.Index) !void {
        const key = try project.absolutePath(self.allocator, path);
        errdefer self.allocator.free(key);
        var value = DocumentCompletionCache{ .source_hash = source_hash, .index = index };
        errdefer value.deinit();
        if (self.document_completion_cache.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            var old = entry.value;
            old.deinit();
        }
        try self.document_completion_cache.put(key, value);
    }

    fn documentCompletionCache(self: *const Server, path: []const u8, source_hash: u64) ?*const analysis_completion.Index {
        const key = project.absolutePath(self.allocator, path) catch return null;
        defer self.allocator.free(key);
        const cache = self.document_completion_cache.getPtr(key) orelse return null;
        if (cache.source_hash != source_hash) return null;
        return &cache.index;
    }

    fn removeDocumentCompletionCache(self: *Server, path: []const u8) void {
        const key = project.absolutePath(self.allocator, path) catch return;
        defer self.allocator.free(key);
        if (self.document_completion_cache.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            var cache = entry.value;
            cache.deinit();
        }
    }

    fn refreshDocumentCompletionCache(self: *Server, path: []const u8) !void {
        const text = self.sourceForPath(path) orelse return;
        const source_hash = completionSourceHash(text);
        if (self.snapshot) |*snapshot| {
            if (snapshot.completion_index) |*index| {
                if (index.containsDocument(self.allocator, path)) {
                    const cloned = try index.clone(self.allocator);
                    try self.rememberDocumentCompletion(path, source_hash, cloned);
                    return;
                }
            }
        }
        const index = try buildDocumentCompletionIndex(self, path, text) orelse return;
        try self.rememberDocumentCompletion(path, source_hash, index);
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
                try server.replaceDocument(uri, text);
                const path = try pathFromUri(server.allocator, uri);
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
                    for (changes.items) |*change| {
                        if (change.* == .object) try server.applyDocumentChange(uri, &change.object);
                    }
                    const path = try pathFromUri(server.allocator, uri);
                    defer server.allocator.free(path);
                    try server.scheduleRebuild(path);
                };
            }
        };
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/didSave")) {
        if (params) |p| if (objectField(p, "textDocument")) |doc| {
            if (stringField(doc, "uri")) |uri| {
                const path = try pathFromUri(server.allocator, uri);
                defer server.allocator.free(path);
                try server.rebuildImmediately(path);
            }
        };
        return;
    }
    if (std.mem.eql(u8, method, "workspace/didChangeWatchedFiles")) {
        if (server.snapshot) |snapshot| {
            const entry_path = try server.allocator.dupe(u8, snapshot.entry_path);
            defer server.allocator.free(entry_path);
            try server.scheduleRebuild(entry_path);
        }
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/didClose")) {
        if (params) |p| if (objectField(p, "textDocument")) |doc| {
            if (stringField(doc, "uri")) |uri| server.removeDocument(uri);
        };
        return;
    }

    if (std.mem.eql(u8, method, "textDocument/completion")) {
        const result = try completionResult(server, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/hover")) {
        const result = try hoverResult(server, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/definition")) {
        const result = try definitionResult(server, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
        const result = try inlayHintResult(server, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
        const result = try documentSymbolResult(server, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/foldingRange")) {
        const result = try foldingRangeResult(server, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
        const result = try semanticTokensResult(server, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/documentColor")) {
        const result = try documentColorResult(server, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/colorPresentation")) {
        const result = try colorPresentationResult(server, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "ss/projectInfo")) {
        const result = try projectInfoResult(server, params);
        defer server.allocator.free(result);
        try respond(server.allocator, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "ss/layoutConflicts")) {
        const result = try layoutConflictsResult(server, params);
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

const CompletionBuilder = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    seen: std.StringHashMap(void),
    first: bool = true,

    fn init(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) CompletionBuilder {
        return .{
            .allocator = allocator,
            .out = out,
            .seen = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *CompletionBuilder) void {
        self.seen.deinit();
    }

    fn add(self: *CompletionBuilder, label: []const u8, kind: usize, detail: ?[]const u8, documentation: ?[]const u8) !void {
        if (label.len == 0 or self.seen.contains(label)) return;
        try self.seen.put(label, {});
        if (!self.first) try self.out.append(self.allocator, ',');
        self.first = false;
        try self.out.appendSlice(self.allocator, "{\"label\":");
        try appendJsonString(self.allocator, self.out, label);
        try self.out.appendSlice(self.allocator, ",\"kind\":");
        try appendInt(self.allocator, self.out, kind);
        if (detail) |text| {
            try self.out.appendSlice(self.allocator, ",\"detail\":");
            try appendJsonString(self.allocator, self.out, text);
        }
        if (documentation) |text| if (text.len != 0) {
            try self.out.appendSlice(self.allocator, ",\"documentation\":");
            try appendJsonString(self.allocator, self.out, text);
        };
        try self.out.append(self.allocator, '}');
    }

    fn addCandidate(self: *CompletionBuilder, candidate: analysis_completion.Candidate) !void {
        try self.add(candidate.label, completionKind(candidate.kind), candidate.detail, candidate.documentation);
    }
};

fn completionKind(kind: analysis_completion.CompletionKind) usize {
    return switch (kind) {
        .keyword => 14,
        .function => 3,
        .variable => 6,
        .property => 10,
        .enum_case => 20,
        .type_decl => 25,
        .class => 7,
        .role => 20,
    };
}

const LspFeature = enum {
    completion,
    hover,
    definition,
    inlay_hints,
    document_symbols,
    folding_ranges,
    semantic_tokens,
    colors,
};

fn lspFeatureEnabled(server: *const Server, feature: LspFeature) bool {
    const cfg = if (server.snapshot) |snapshot| snapshot.lsp else project.LspConfig{};
    return lspFeatureEnabledInConfig(cfg, feature);
}

fn lspFeatureEnabledForSnapshot(snapshot: *const Snapshot, feature: LspFeature) bool {
    return lspFeatureEnabledInConfig(snapshot.lsp, feature);
}

fn lspFeatureEnabledInConfig(cfg: project.LspConfig, feature: LspFeature) bool {
    if (!cfg.enabled) return false;
    return switch (feature) {
        .completion => cfg.completion,
        .hover => cfg.hover,
        .definition => cfg.definition,
        .inlay_hints => cfg.inlay_hints,
        .document_symbols => cfg.document_symbols,
        .folding_ranges => cfg.folding_ranges,
        .semantic_tokens => cfg.semantic_tokens,
        .colors => cfg.colors,
    };
}

fn snapshotForDocument(server: *Server, doc_path: []const u8, owned_snapshot: *?Snapshot) !?*Snapshot {
    if (server.snapshot) |*snapshot| {
        if (snapshotCoversPath(snapshot, doc_path)) return snapshot;
    }
    var diagnostics = DiagnosticSet.init(server.allocator);
    defer diagnostics.deinit();
    owned_snapshot.* = try server.buildSnapshot(doc_path, &diagnostics);
    if (owned_snapshot.*) |*snapshot| return snapshot;
    return null;
}

fn completionResult(server: *Server, params: ?JsonValue) ![]const u8 {
    if (!lspFeatureEnabled(server, .completion)) return try server.allocator.dupe(u8, "{\"isIncomplete\":false,\"items\":[]}");
    var out = std.ArrayList(u8).empty;
    const allocator = server.allocator;
    var position = try requestPosition(server, params);
    defer if (position) |*pos| pos.deinit(allocator);
    try out.appendSlice(allocator, "{\"isIncomplete\":false,\"items\":[");
    var builder = CompletionBuilder.init(allocator, &out);
    defer builder.deinit();
    if (position) |*pos| {
        if (try completionIndexForRequest(server, pos)) |index| {
            var result = try analysis_completion.complete(allocator, index, .{
                .doc_path = pos.doc_path,
                .source = pos.source,
                .offset = pos.offset,
            });
            defer result.deinit(allocator);
            for (result.items) |item| {
                try builder.addCandidate(item);
            }
        }
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn completionIndex(server: *const Server) ?*const analysis_completion.Index {
    const snapshot = if (server.snapshot) |*value| value else return null;
    if (snapshot.completion_index) |*index| return index;
    const cache = if (server.last_good_completion) |*value| value else return null;
    if (!std.mem.eql(u8, cache.entry_path, snapshot.entry_path)) return null;
    return &cache.index;
}

fn completionIndexForRequest(server: *Server, position: *const RequestPosition) !?*const analysis_completion.Index {
    const current_project = currentSnapshotCompletionIndex(server);
    const primary = completionIndex(server);
    const source_hash = completionSourceHash(position.source);
    if (server.documentCompletionCache(position.doc_path, source_hash)) |index| return index;
    if (try buildDocumentCompletionIndex(server, position.doc_path, position.source)) |index| {
        try server.rememberDocumentCompletion(position.doc_path, source_hash, index);
        return server.documentCompletionCache(position.doc_path, source_hash) orelse primary;
    }
    const access_context = analysis_completion.accessBeforeOffset(position.source, position.offset);
    if (access_context) |access| {
        if (try buildAccessRecoveryCompletionIndex(server, position.doc_path, position.source, access)) |index| {
            try server.rememberDocumentCompletion(position.doc_path, source_hash, index);
            return server.documentCompletionCache(position.doc_path, source_hash) orelse primary;
        }
        if (try buildImportEnvironmentCompletionIndex(server, position.doc_path, position.source)) |index| {
            try server.rememberDocumentCompletion(position.doc_path, source_hash, index);
            return server.documentCompletionCache(position.doc_path, source_hash) orelse primary;
        }
    }
    if (access_context == null) {
        if (try buildImportEnvironmentCompletionIndex(server, position.doc_path, position.source)) |index| {
            try server.rememberDocumentCompletion(position.doc_path, source_hash, index);
            return server.documentCompletionCache(position.doc_path, source_hash) orelse primary;
        }
    }
    if (current_project) |index| {
        if (index.containsDocument(server.allocator, position.doc_path)) return index;
    }
    return primary;
}

fn buildAccessRecoveryCompletionIndex(
    server: *Server,
    doc_path: []const u8,
    doc_source: []const u8,
    access: analysis_completion.AccessContext,
) !?analysis_completion.Index {
    if (access.separator != .dot) return null;
    if (access.separator_offset >= doc_source.len) return null;

    var recovered_text = try server.allocator.dupe(u8, doc_source);
    defer server.allocator.free(recovered_text);

    const line_span = source.lineAt(recovered_text, access.separator_offset).span;
    var cursor = line_span.start;
    while (cursor < line_span.end) : (cursor += 1) {
        recovered_text[cursor] = ' ';
    }

    return buildDocumentCompletionIndex(server, doc_path, recovered_text);
}

fn completionSourceHash(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0, text);
}

fn currentSnapshotCompletionIndex(server: *const Server) ?*const analysis_completion.Index {
    const snapshot = if (server.snapshot) |*value| value else return null;
    if (snapshot.completion_index) |*index| return index;
    return null;
}

fn buildDocumentCompletionIndex(server: *Server, doc_path: []const u8, doc_source: []const u8) !?analysis_completion.Index {
    const asset_base_dir = if (server.snapshot) |snapshot|
        try server.allocator.dupe(u8, snapshot.asset_base_dir)
    else
        try dirnameAlloc(server.allocator, doc_path);
    defer server.allocator.free(asset_base_dir);

    var overlay = module_loader.SourceOverlay.init(server.allocator);
    defer overlay.deinit();
    var doc_iterator = server.documents.iterator();
    while (doc_iterator.next()) |entry| {
        try overlay.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    try overlay.put(doc_path, doc_source);

    var parsed_text = try server.allocator.dupe(u8, doc_source);
    var program = syntax.parseWithSourceName(server.allocator, parsed_text, doc_path) catch {
        server.allocator.free(parsed_text);
        return null;
    };

    var load_diagnostics = module_loader.LoadDiagnostics.init(server.allocator);
    defer load_diagnostics.deinit();
    var index = analysis.loadProgramIndexWithOptions(server.allocator, server.io, asset_base_dir, program, .{
        .overlay = &overlay,
        .diagnostics = &load_diagnostics,
        .print_diagnostics = false,
    }) catch {
        program.deinit(server.allocator);
        server.allocator.free(parsed_text);
        return null;
    };
    defer index.deinit();

    var ir = analysis.buildIrWithOptions(server.allocator, doc_path, asset_base_dir, &parsed_text, &program, &index, .{ .allow_diagnostics = true }) catch {
        program.deinit(server.allocator);
        if (parsed_text.len != 0) server.allocator.free(parsed_text);
        return null;
    };
    defer ir.deinit();

    analysis.analyzeProgram(server.allocator, &ir) catch {};
    return analysis_completion.Index.fromIr(server.allocator, &ir) catch null;
}

fn buildImportEnvironmentCompletionIndex(server: *Server, doc_path: []const u8, doc_source: []const u8) !?analysis_completion.Index {
    var generated_text = std.ArrayList(u8).empty;
    defer generated_text.deinit(server.allocator);

    var lines = source.lineIterator(doc_source);
    while (lines.next()) |line_view| {
        const line = line_view.text(doc_source);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "import ") and trimmed.len > "import ".len) {
            try generated_text.appendSlice(server.allocator, line);
            try generated_text.append(server.allocator, '\n');
        }
    }
    try generated_text.appendSlice(server.allocator, "\npage __completion_probe\nend\n");
    return buildDocumentCompletionIndex(server, doc_path, generated_text.items);
}

fn resolveAliasModuleId(allocator: std.mem.Allocator, root: *const JsonObject, doc_path: []const u8, alias: []const u8) ?i64 {
    const module = moduleForPath(allocator, root, doc_path) orelse return null;
    if (arrayFieldObject(module, "imports")) |imports| {
        var index = imports.items.len;
        while (index > 0) {
            index -= 1;
            const item = imports.items[index];
            if (item != .object) continue;
            if (!std.mem.eql(u8, stringField(&item.object, "alias") orelse "", alias)) continue;
            return intField(&item.object, "module_id");
        }
    }
    return null;
}

fn moduleForPath(allocator: std.mem.Allocator, root: *const JsonObject, doc_path: []const u8) ?*const JsonObject {
    if (arrayFieldObject(root, "modules")) |modules| for (modules.items) |*module| if (module.* == .object) {
        const path = stringField(&module.object, "path") orelse continue;
        if (samePath(allocator, path, doc_path)) return &module.object;
    };
    return null;
}

fn moduleObjectById(root: *const JsonObject, module_id: i64) ?*const JsonObject {
    if (arrayFieldObject(root, "modules")) |modules| for (modules.items) |*module| if (module.* == .object) {
        if ((intField(&module.object, "id") orelse -1) == module_id) return &module.object;
    };
    return null;
}

fn functionObject(root: *const JsonObject, target: []const u8, module_id: ?i64) ?*const JsonObject {
    if (arrayFieldObject(root, "functions")) |functions| for (functions.items) |*item| if (item.* == .object) {
        if (!std.mem.eql(u8, stringField(&item.object, "name") orelse "", target)) continue;
        if (module_id) |id| {
            if ((intField(&item.object, "moduleId") orelse -1) != id) continue;
        }
        return &item.object;
    };
    return null;
}

fn definitionObject(root: *const JsonObject, target: []const u8, module_id: i64, kind: core.DefinitionKind) ?*const JsonObject {
    if (arrayFieldObject(root, "definitions")) |defs| for (defs.items) |*item| if (item.* == .object) {
        if (!std.mem.eql(u8, stringField(&item.object, "name") orelse "", target)) continue;
        if (!std.mem.eql(u8, stringField(&item.object, "kind") orelse "", @tagName(kind))) continue;
        if ((intField(&item.object, "moduleId") orelse -1) != module_id) continue;
        return &item.object;
    };
    return null;
}

fn qualifiedModuleIdForContext(allocator: std.mem.Allocator, root: *const JsonObject, context: *const RequestContext) ?i64 {
    const alias = qualifiedCallableAliasForContext(context) orelse return null;
    return resolveAliasModuleId(allocator, root, context.doc_path, alias);
}

fn aliasModuleIdForContext(allocator: std.mem.Allocator, root: *const JsonObject, context: *const RequestContext) ?i64 {
    if (!isQualifiedCallableAliasTarget(context) and !isImportAliasTarget(context)) return null;
    return resolveAliasModuleId(allocator, root, context.doc_path, context.target);
}

fn qualifiedCallableAliasForContext(context: *const RequestContext) ?[]const u8 {
    const program = if (context.program) |*program| program else return null;
    return analysis_editor.qualifiedCallableQualifierForName(program, context.offset);
}

fn isQualifiedCallableAliasTarget(context: *const RequestContext) bool {
    const program = if (context.program) |*program| program else return false;
    return analysis_editor.isQualifiedCallableQualifierAt(program, context.offset);
}

fn definitionKindForContext(context: *const RequestContext) core.DefinitionKind {
    if (context.program) |*program| {
        if (analysis_editor.callableAt(program, context.offset)) |target| {
            if (target.role == .name) return .function;
        }
    }
    if (std.mem.endsWith(u8, context.target, "!")) return .function;
    return .constant;
}

fn isImportAliasTarget(context: *const RequestContext) bool {
    const program = if (context.program) |*program| program else return false;
    return analysis_editor.isImportAliasAt(program, context.offset);
}

fn importSpecModuleIdForContext(allocator: std.mem.Allocator, root: *const JsonObject, context: *const RequestContext) ?i64 {
    const program = if (context.program) |*program| program else return null;
    const spec = analysis_editor.importSpecAt(program, context.offset) orelse return null;
    const module = moduleForPath(allocator, root, context.doc_path) orelse return null;
    if (arrayFieldObject(module, "imports")) |imports| {
        for (imports.items) |item| {
            if (item != .object) continue;
            if (!spanContainsOffset(&item.object, context.offset)) continue;
            if (!std.mem.eql(u8, stringField(&item.object, "spec") orelse "", spec)) continue;
            return intField(&item.object, "module_id");
        }
    }
    return null;
}

fn appendModuleDefinitionLocation(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    root: *const JsonObject,
    module_id: i64,
    fallback_path: []const u8,
    first: *bool,
) !void {
    const path = try modulePathForDefinition(allocator, root, module_id);
    defer if (path) |value| allocator.free(value);
    const uri = try uriFromPath(allocator, path orelse fallback_path);
    defer allocator.free(uri);
    if (!first.*) try out.append(allocator, ',');
    first.* = false;
    try appendLocationObject(allocator, out, uri, 0, 0, 0, 1);
}

fn modulePathForDefinition(allocator: std.mem.Allocator, root: *const JsonObject, module_id: i64) !?[]u8 {
    const module = moduleObjectById(root, module_id) orelse return null;
    if (stringField(module, "path")) |path| return try allocator.dupe(u8, path);
    if (stringField(module, "spec")) |spec| return try stdModulePath(allocator, spec);
    return null;
}

fn spanContainsOffset(item: *const JsonObject, offset: usize) bool {
    const span = objectFieldObject(item, "span") orelse return false;
    const start = usizeField(span, "start") orelse return false;
    const end = usizeField(span, "end") orelse return false;
    return offset >= start and offset <= end;
}

fn completionRequest(context: *const RequestContext) analysis_completion.Request {
    return .{
        .doc_path = context.doc_path,
        .source = context.source,
        .offset = context.offset,
    };
}

fn hoverResult(server: *Server, params: ?JsonValue) ![]const u8 {
    var context = try requestContext(server, params) orelse return try server.allocator.dupe(u8, "null");
    defer context.deinit(server.allocator);
    var owned_snapshot: ?Snapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit(server.allocator);
    const snapshot = try snapshotForDocument(server, context.doc_path, &owned_snapshot) orelse return try server.allocator.dupe(u8, "null");
    if (!lspFeatureEnabledForSnapshot(snapshot, .hover)) return try server.allocator.dupe(u8, "null");
    if (snapshot.dump_json) |json_text| {
        var parsed = utils.json.parseValue(server.allocator, json_text, .{}) catch return try server.allocator.dupe(u8, "null");
        defer parsed.deinit();
        const root = parsed.value.object;
        const completion_index = if (snapshot.completion_index) |*index| index else null;
        const markdown = try hoverMarkdown(server.allocator, &root, &context, completion_index) orelse return try server.allocator.dupe(u8, "null");
        defer server.allocator.free(markdown);
        var out = std.ArrayList(u8).empty;
        try out.appendSlice(server.allocator, "{\"contents\":{\"kind\":\"markdown\",\"value\":");
        try appendJsonString(server.allocator, &out, markdown);
        try out.appendSlice(server.allocator, "}}");
        return out.toOwnedSlice(server.allocator);
    }
    return try server.allocator.dupe(u8, "null");
}

fn hoverMarkdown(
    allocator: std.mem.Allocator,
    root: *const JsonObject,
    context: *const RequestContext,
    completion_index: ?*const analysis_completion.Index,
) !?[]u8 {
    const target = context.target;
    if (aliasModuleIdForContext(allocator, root, context)) |module_id| {
        if (moduleObjectById(root, module_id)) |module| {
            return try std.fmt.allocPrint(allocator, "```ss\nimport {s}\n```", .{stringField(module, "spec") orelse context.target});
        }
    }
    if (completion_index) |index| {
        if (analysis_completion.visibleVariable(index, allocator, completionRequest(context), target)) |variable| {
            return try std.fmt.allocPrint(allocator, "```ss\n({s}: {s})\n```", .{ variable.name, variable.type_label });
        }
        if (analysis_completion.visibleFunction(index, allocator, .{
            .doc_path = context.doc_path,
            .source = context.source,
            .offset = context.offset,
        }, target, qualifiedCallableAliasForContext(context))) |item| {
            const signature = item.detail orelse target;
            const summary = item.documentation orelse "";
            return try std.fmt.allocPrint(allocator, "```ss\n{s}\n```\n{s}", .{ signature, summary });
        }
    }
    if (qualifiedModuleIdForContext(allocator, root, context)) |module_id| {
        if (functionObject(root, target, module_id)) |item| {
            const signature = stringField(item, "signature") orelse target;
            const summary = stringField(item, "summary") orelse "";
            return try std.fmt.allocPrint(allocator, "```ss\n{s}\n```\n{s}", .{ signature, summary });
        }
    }
    if (objectFieldObject(root, "declarations")) |decls| {
        if (arrayFieldObject(decls, "classes")) |classes| for (classes.items) |item| if (item == .object and std.mem.eql(u8, stringField(&item.object, "name") orelse "", target)) {
            return try std.fmt.allocPrint(allocator, "```ss\ntype {s} = object {{ ... }}\n```", .{target});
        };
        if (arrayFieldObject(decls, "fields")) |fields| for (fields.items) |item| if (item == .object and std.mem.eql(u8, stringField(&item.object, "name") orelse "", target)) {
            return try std.fmt.allocPrint(allocator, "```ss\n{s}: {s}\n```", .{ target, stringField(&item.object, "type") orelse "unknown" });
        };
    }
    return null;
}

fn definitionResult(server: *Server, params: ?JsonValue) ![]const u8 {
    var context = try requestContext(server, params) orelse return try server.allocator.dupe(u8, "null");
    defer context.deinit(server.allocator);
    var owned_snapshot: ?Snapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit(server.allocator);
    const snapshot = try snapshotForDocument(server, context.doc_path, &owned_snapshot) orelse return try server.allocator.dupe(u8, "null");
    if (!lspFeatureEnabledForSnapshot(snapshot, .definition)) return try server.allocator.dupe(u8, "null");
    if (snapshot.dump_json) |json_text| {
        var parsed = utils.json.parseValue(server.allocator, json_text, .{}) catch return try server.allocator.dupe(u8, "null");
        defer parsed.deinit();
        const root = parsed.value.object;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(server.allocator);
        try out.append(server.allocator, '[');
        var first = true;
        if (importSpecModuleIdForContext(server.allocator, &root, &context)) |module_id| {
            try appendModuleDefinitionLocation(server.allocator, &out, &root, module_id, snapshot.entry_path, &first);
            try out.append(server.allocator, ']');
            return out.toOwnedSlice(server.allocator);
        }
        if (qualifiedModuleIdForContext(server.allocator, &root, &context)) |module_id| {
            if (snapshot.completion_index) |*index| {
                if (resolvedDefinitionObject(server.allocator, &root, index, &context)) |definition| {
                    try appendDefinitionLocation(server.allocator, &out, &root, definition, snapshot.entry_path, &first);
                    try out.append(server.allocator, ']');
                    return out.toOwnedSlice(server.allocator);
                }
            }
            if (definitionObject(&root, context.target, module_id, definitionKindForContext(&context))) |definition| {
                try appendDefinitionLocation(server.allocator, &out, &root, definition, snapshot.entry_path, &first);
                try out.append(server.allocator, ']');
                return out.toOwnedSlice(server.allocator);
            }
        }
        if (aliasModuleIdForContext(server.allocator, &root, &context)) |module_id| {
            try appendModuleDefinitionLocation(server.allocator, &out, &root, module_id, snapshot.entry_path, &first);
            try out.append(server.allocator, ']');
            return out.toOwnedSlice(server.allocator);
        }
        if (snapshot.completion_index) |*index| {
            if (resolvedDefinitionObject(server.allocator, &root, index, &context)) |definition| {
                try appendDefinitionLocation(server.allocator, &out, &root, definition, snapshot.entry_path, &first);
            } else if (try appendResolvedTypeDefinitionLocation(server.allocator, &out, &root, index, &context, snapshot.entry_path, &first)) {}
        }
        if (first) return try server.allocator.dupe(u8, "null");
        try out.append(server.allocator, ']');
        return out.toOwnedSlice(server.allocator);
    }
    return try server.allocator.dupe(u8, "null");
}

fn resolvedDefinitionObject(
    allocator: std.mem.Allocator,
    root: *const JsonObject,
    index: *const analysis_completion.Index,
    context: *const RequestContext,
) ?*const JsonObject {
    const qualifier = qualifiedCallableAliasForContext(context);
    const request = completionRequest(context);
    if (resolvedDefinitionObjectOfKind(allocator, root, index, request, context.target, null, .variable)) |definition| return definition;
    const primary_kind = definitionKindForContext(context);
    if (resolvedDefinitionObjectOfKind(allocator, root, index, request, context.target, qualifier, primary_kind)) |definition| return definition;
    const fallback_kind: core.DefinitionKind = if (primary_kind == .function) .constant else .function;
    return resolvedDefinitionObjectOfKind(allocator, root, index, request, context.target, qualifier, fallback_kind);
}

fn resolvedDefinitionObjectOfKind(
    allocator: std.mem.Allocator,
    root: *const JsonObject,
    index: *const analysis_completion.Index,
    request: analysis_completion.Request,
    target: []const u8,
    qualifier: ?[]const u8,
    kind: core.DefinitionKind,
) ?*const JsonObject {
    const resolved = analysis_completion.visibleDefinition(index, allocator, request, target, qualifier, kind) orelse return null;
    const module_id = resolved.module_id orelse return null;
    return definitionObject(root, resolved.name, module_id, resolved.kind);
}

fn appendResolvedTypeDefinitionLocation(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    root: *const JsonObject,
    index: *const analysis_completion.Index,
    context: *const RequestContext,
    fallback_path: []const u8,
    first: *bool,
) !bool {
    const qualifier = qualifiedCallableAliasForContext(context);
    const request = completionRequest(context);
    const resolved = analysis_completion.visibleTypeDefinition(index, allocator, request, context.target, qualifier) orelse return false;
    const module_id: i64 = @intCast(resolved.module_id);
    const module = moduleObjectById(root, module_id) orelse return false;
    const module_source = stringField(module, "source") orelse return false;
    const location = typeDeclarationLocation(module, module_source, resolved.name) orelse return false;
    const path = try modulePathForDefinition(allocator, root, module_id);
    defer if (path) |value| allocator.free(value);
    try appendSourceLocation(allocator, out, path orelse fallback_path, module_source, location.offset, location.length, first);
    return true;
}

fn typeDeclarationLocation(module: *const JsonObject, text: []const u8, name: []const u8) ?analysis_editor.SourceIdentifierLocation {
    const program = objectFieldObject(module, "program") orelse return null;
    if (typeDeclarationLocationIn(program, text, "records", "record", name)) |location| return location;
    if (typeDeclarationLocationIn(program, text, "objects", "type", name)) |location| return location;
    return typeDeclarationLocationIn(program, text, "types", "type", name);
}

fn typeDeclarationLocationIn(program: *const JsonObject, text: []const u8, field: []const u8, keyword: []const u8, name: []const u8) ?analysis_editor.SourceIdentifierLocation {
    if (arrayFieldObject(program, field)) |items| for (items.items) |item| if (item == .object) {
        if (!std.mem.eql(u8, stringField(&item.object, "name") orelse "", name)) continue;
        const span = objectFieldObject(&item.object, "span") orelse continue;
        const start = usizeField(span, "start") orelse continue;
        if (analysis_editor.identifierOffsetAfterKeyword(text, start, keyword, name)) |location| return location;
    };
    return null;
}

fn appendSourceLocation(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    path: []const u8,
    text: []const u8,
    offset: usize,
    length: usize,
    first: *bool,
) !void {
    const uri = try uriFromPath(allocator, path);
    defer allocator.free(uri);
    const start = source.utf16PositionAt(text, offset);
    const end = source.utf16PositionAt(text, @min(text.len, offset + @max(length, 1)));
    if (!first.*) try out.append(allocator, ',');
    first.* = false;
    try appendLocationObject(allocator, out, uri, start.line, start.character, end.line, end.character);
}

fn appendDefinitionLocation(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    root: *const JsonObject,
    item: *const JsonObject,
    fallback_path: []const u8,
    first: *bool,
) !void {
    const path = definitionPath(allocator, root, item) catch null;
    defer if (path) |p| allocator.free(p);
    const uri = try uriFromPath(allocator, path orelse fallback_path);
    defer allocator.free(uri);
    const line: usize = @intCast(@max(0, (intField(item, "line") orelse 1) - 1));
    const column: usize = @intCast(@max(0, (intField(item, "column") orelse 1) - 1));
    const fallback_length: i64 = @intCast((stringField(item, "name") orelse @as([]const u8, "")).len);
    const length: usize = @intCast(@max(1, intField(item, "length") orelse fallback_length));
    if (!first.*) try out.append(allocator, ',');
    first.* = false;
    try appendLocationObject(allocator, out, uri, line, column, line, column + length);
}

fn inlayHintResult(server: *Server, params: ?JsonValue) ![]const u8 {
    const doc_path = try docPathFromParams(server.allocator, params) orelse return try server.allocator.dupe(u8, "[]");
    defer server.allocator.free(doc_path);
    var owned_snapshot: ?Snapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit(server.allocator);
    const snapshot = try snapshotForDocument(server, doc_path, &owned_snapshot) orelse return try server.allocator.dupe(u8, "[]");
    if (!lspFeatureEnabledForSnapshot(snapshot, .inlay_hints)) return try server.allocator.dupe(u8, "[]");
    var out = std.ArrayList(u8).empty;
    try out.append(server.allocator, '[');
    var first = true;
    if (snapshot.dump_json) |json_text| {
        var parsed = utils.json.parseValue(server.allocator, json_text, .{}) catch return try server.allocator.dupe(u8, "[]");
        defer parsed.deinit();
        if (arrayFieldObject(&parsed.value.object, "hints")) |hints| for (hints.items) |item| if (item == .object) {
            const file = stringField(&item.object, "file") orelse continue;
            if (!samePath(server.allocator, file, doc_path)) continue;
            const kind = stringField(&item.object, "kind") orelse "";
            if (!inlayHintKindEnabled(snapshot, kind)) continue;
            if (!first) try out.append(server.allocator, ',');
            first = false;
            const line: usize = @intCast(@max(0, (intField(&item.object, "line") orelse 1) - 1));
            const col: usize = @intCast(@max(0, (intField(&item.object, "column") orelse 1) - 1));
            try out.appendSlice(server.allocator, "{\"position\":{\"line\":");
            try appendInt(server.allocator, &out, line);
            try out.appendSlice(server.allocator, ",\"character\":");
            try appendInt(server.allocator, &out, col);
            try out.appendSlice(server.allocator, "},\"label\":");
            try appendJsonString(server.allocator, &out, stringField(&item.object, "label") orelse "");
            try out.appendSlice(server.allocator, ",\"kind\":");
            const hint_kind: i64 = if (std.mem.eql(u8, kind, "parameter_names")) 2 else 1;
            try appendInt(server.allocator, &out, hint_kind);
            try out.appendSlice(server.allocator, ",\"paddingLeft\":true}");
        };
    }
    try out.append(server.allocator, ']');
    return out.toOwnedSlice(server.allocator);
}

fn inlayHintKindEnabled(snapshot: *const Snapshot, kind: []const u8) bool {
    const cfg = snapshot.lsp;
    if (std.mem.eql(u8, kind, "parameter_names")) return cfg.inlay_hint_arguments;
    if (std.mem.eql(u8, kind, "solved_frame")) return cfg.inlay_hint_positions;
    return true;
}

fn documentTextFromParams(server: *Server, params: ?JsonValue) !?DocumentText {
    const doc_path = try docPathFromParams(server.allocator, params) orelse return null;
    errdefer server.allocator.free(doc_path);
    if (server.sourceForPath(doc_path)) |text| {
        return .{ .path = doc_path, .source = text };
    }
    const owned = utils.fs.readFileAlloc(server.io, server.allocator, doc_path) catch return null;
    errdefer server.allocator.free(owned);
    return .{ .path = doc_path, .source = owned, .owned_source = owned };
}

fn documentSymbolResult(server: *Server, params: ?JsonValue) ![]const u8 {
    if (!lspFeatureEnabled(server, .document_symbols)) return try server.allocator.dupe(u8, "[]");
    var doc = try documentTextFromParams(server, params) orelse return try server.allocator.dupe(u8, "[]");
    defer doc.deinit(server.allocator);
    var parsed = syntax.parseWithSourceName(server.allocator, doc.source, doc.path) catch {
        return document_features.documentSymbolsJson(server.allocator, doc.source);
    };
    defer parsed.deinit(server.allocator);
    return document_features.documentSymbolsFromProgramJson(server.allocator, doc.source, parsed);
}

fn foldingRangeResult(server: *Server, params: ?JsonValue) ![]const u8 {
    if (!lspFeatureEnabled(server, .folding_ranges)) return try server.allocator.dupe(u8, "[]");
    var doc = try documentTextFromParams(server, params) orelse return try server.allocator.dupe(u8, "[]");
    defer doc.deinit(server.allocator);
    var parsed = syntax.parseWithSourceName(server.allocator, doc.source, doc.path) catch {
        return document_features.foldingRangesJson(server.allocator, doc.source);
    };
    defer parsed.deinit(server.allocator);
    return document_features.foldingRangesFromProgramJson(server.allocator, doc.source, parsed);
}

fn semanticTokensResult(server: *Server, params: ?JsonValue) ![]const u8 {
    if (!lspFeatureEnabled(server, .semantic_tokens)) return try server.allocator.dupe(u8, "{\"data\":[]}");
    var doc = try documentTextFromParams(server, params) orelse return try server.allocator.dupe(u8, "{\"data\":[]}");
    defer doc.deinit(server.allocator);
    return document_features.semanticTokensJson(server.allocator, doc.source);
}

fn documentColorResult(server: *Server, params: ?JsonValue) ![]const u8 {
    if (!lspFeatureEnabled(server, .colors)) return try server.allocator.dupe(u8, "[]");
    var doc = try documentTextFromParams(server, params) orelse return try server.allocator.dupe(u8, "[]");
    defer doc.deinit(server.allocator);
    return document_features.documentColorsJson(server.allocator, doc.source);
}

fn colorPresentationResult(server: *Server, params: ?JsonValue) ![]const u8 {
    if (!lspFeatureEnabled(server, .colors)) return try server.allocator.dupe(u8, "[]");
    const color = if (params) |p| objectField(p, "color") else null;
    const red = if (color) |c| numberField(c, "red") orelse 0 else 0;
    const green = if (color) |c| numberField(c, "green") orelse 0 else 0;
    const blue = if (color) |c| numberField(c, "blue") orelse 0 else 0;
    return document_features.colorPresentationsJson(server.allocator, red, green, blue);
}

fn projectInfoResult(server: *Server, params: ?JsonValue) ![]const u8 {
    if (try docPathFromParams(server.allocator, params)) |doc_path| {
        defer server.allocator.free(doc_path);
        if (server.snapshot) |snapshot| {
            if (!snapshotCoversPath(&snapshot, doc_path)) {
                var diagnostics = DiagnosticSet.init(server.allocator);
                defer diagnostics.deinit();
                var requested_snapshot = try server.buildSnapshot(doc_path, &diagnostics);
                defer requested_snapshot.deinit(server.allocator);
                return try projectInfoJson(server.allocator, &requested_snapshot);
            }
        }
    }
    return try projectInfoJson(server.allocator, if (server.snapshot) |*snapshot| snapshot else null);
}

fn layoutConflictsResult(server: *Server, params: ?JsonValue) ![]const u8 {
    var owned_snapshot: ?Snapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit(server.allocator);

    const doc_path = try docPathFromParams(server.allocator, params);
    defer if (doc_path) |path| server.allocator.free(path);

    const snapshot = blk: {
        if (doc_path) |path| {
            if (server.snapshot) |*snap| {
                if (snapshotCoversPath(snap, path)) break :blk snap;
            }
            var diagnostics = DiagnosticSet.init(server.allocator);
            defer diagnostics.deinit();
            owned_snapshot = try server.buildSnapshot(path, &diagnostics);
            break :blk &owned_snapshot.?;
        }
        if (server.snapshot) |*snap| break :blk snap;
        break :blk null;
    } orelse return try emptyLayoutConflictReport(server.allocator);

    var overlay = module_loader.SourceOverlay.init(server.allocator);
    defer overlay.deinit();
    var doc_iterator = server.documents.iterator();
    while (doc_iterator.next()) |entry| {
        try overlay.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    return app.layoutConflictReportJsonWithAssetBaseAndOverlay(
        server.io,
        server.allocator,
        snapshot.entry_path,
        snapshot.asset_base_dir,
        &overlay,
        null,
    ) catch {
        return try emptyLayoutConflictReport(server.allocator);
    };
}

fn emptyLayoutConflictReport(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8,
        \\{"schema":1,"kind":"ss-layout-conflicts","entry_path":"","pages":[],"objects":[],"anchors":[],"relations":[],"failures":[]}
        \\
    );
}

fn projectInfoJson(allocator: std.mem.Allocator, snapshot: ?*const Snapshot) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '{');
    if (snapshot) |snap| {
        try out.appendSlice(allocator, "\"entryPath\":");
        try appendJsonString(allocator, &out, snap.entry_path);
        try out.appendSlice(allocator, ",\"assetBaseDir\":");
        try appendJsonString(allocator, &out, snap.asset_base_dir);
        try out.appendSlice(allocator, ",\"localModules\":[");
        for (snap.module_paths.items, 0..) |path, i| {
            if (i != 0) try out.append(allocator, ',');
            try appendJsonString(allocator, &out, path);
        }
        try out.append(allocator, ']');
        try appendProjectInfoSettings(allocator, &out, snap);
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendProjectInfoSettings(allocator: std.mem.Allocator, out: *std.ArrayList(u8), snapshot: *const Snapshot) !void {
    try out.appendSlice(allocator, ",\"lsp\":{");
    try appendBoolField(allocator, out, "enabled", snapshot.lsp.enabled, true);
    try appendIntField(allocator, out, "debounce", snapshot.lsp.debounce_ms, false);
    try appendBoolField(allocator, out, "diagnostics", snapshot.lsp.diagnostics, false);
    try appendBoolField(allocator, out, "completion", snapshot.lsp.completion, false);
    try appendBoolField(allocator, out, "hover", snapshot.lsp.hover, false);
    try appendBoolField(allocator, out, "definition", snapshot.lsp.definition, false);
    try appendBoolField(allocator, out, "inlayHints", snapshot.lsp.inlay_hints, false);
    try appendBoolField(allocator, out, "inlayHintArguments", snapshot.lsp.inlay_hint_arguments, false);
    try appendBoolField(allocator, out, "inlayHintPositions", snapshot.lsp.inlay_hint_positions, false);
    try appendBoolField(allocator, out, "documentSymbols", snapshot.lsp.document_symbols, false);
    try appendBoolField(allocator, out, "foldingRanges", snapshot.lsp.folding_ranges, false);
    try appendBoolField(allocator, out, "semanticTokens", snapshot.lsp.semantic_tokens, false);
    try appendBoolField(allocator, out, "colors", snapshot.lsp.colors, false);
    try out.append(allocator, '}');

    try out.appendSlice(allocator, ",\"preview\":{");
    try appendBoolField(allocator, out, "enabled", snapshot.preview.enabled, true);
    try appendIntField(allocator, out, "debounce", snapshot.preview.debounce_ms, false);
    try appendBoolField(allocator, out, "refreshOnSave", snapshot.preview.refresh_on_save, false);
    try appendBoolField(allocator, out, "refreshOnDependencyChange", snapshot.preview.refresh_on_dependency_change, false);
    try out.appendSlice(allocator, ",\"open\":");
    try appendJsonString(allocator, out, if (snapshot.preview.open_mode == .external) "external" else "vscode");
    try appendBoolField(allocator, out, "reveal", snapshot.preview.reveal_after_render, false);
    try appendIntField(allocator, out, "timeout", snapshot.preview.render_timeout_ms, false);
    try out.append(allocator, '}');

    try out.appendSlice(allocator, ",\"pageGuide\":{");
    try appendBoolField(allocator, out, "enabled", snapshot.page_guide.enabled, true);
    try appendBoolField(allocator, out, "bodyBackground", snapshot.page_guide.body_background, false);
    try appendBoolField(allocator, out, "boundary", snapshot.page_guide.boundary, false);
    try appendBoolField(allocator, out, "boundaryBackground", snapshot.page_guide.boundary_background, false);
    try appendBoolField(allocator, out, "gutterIcon", snapshot.page_guide.gutter_icon, false);
    try appendBoolField(allocator, out, "overviewRuler", snapshot.page_guide.overview_ruler, false);
    try out.append(allocator, '}');
}

fn appendBoolField(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: bool, first: bool) !void {
    if (!first) try out.append(allocator, ',');
    try appendJsonString(allocator, out, name);
    try out.append(allocator, ':');
    try appendBool(allocator, out, value);
}

fn appendIntField(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: anytype, first: bool) !void {
    if (!first) try out.append(allocator, ',');
    try appendJsonString(allocator, out, name);
    try out.append(allocator, ':');
    try appendInt(allocator, out, value);
}

fn snapshotCoversPath(snapshot: *const Snapshot, path: []const u8) bool {
    if (std.mem.eql(u8, snapshot.entry_path, path)) return true;
    for (snapshot.module_paths.items) |module_path| {
        if (std.mem.eql(u8, module_path, path)) return true;
    }
    return false;
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

fn requestPosition(server: *Server, params: ?JsonValue) !?RequestPosition {
    const p = params orelse return null;
    const doc_path = try docPathFromParams(server.allocator, params) orelse return null;
    errdefer server.allocator.free(doc_path);
    const pos_obj = objectField(p, "position") orelse {
        server.allocator.free(doc_path);
        return null;
    };
    const line: usize = @intCast(@max(0, intField(pos_obj, "line") orelse 0));
    const character: usize = @intCast(@max(0, intField(pos_obj, "character") orelse 0));
    const text = server.sourceForPath(doc_path) orelse {
        server.allocator.free(doc_path);
        return null;
    };
    return .{
        .doc_path = doc_path,
        .source = text,
        .offset = source.offsetForUtf16Position(text, line, character),
        .line = line,
        .character = character,
    };
}

fn targetAtOffset(allocator: std.mem.Allocator, text: []const u8, offset: usize, program: ?*const ast.Program) !?[]u8 {
    if (program) |parsed| {
        if (analysis_editor.importSpecAt(parsed, offset)) |spec| return try allocator.dupe(u8, spec);
    }
    const location = analysis_editor.sourceCallableNameAt(text, offset) orelse return null;
    return try allocator.dupe(u8, text[location.offset .. location.offset + location.length]);
}

fn requestContext(server: *Server, params: ?JsonValue) !?RequestContext {
    const p = params orelse return null;
    const doc_path = try docPathFromParams(server.allocator, params) orelse return null;
    errdefer server.allocator.free(doc_path);
    const pos_obj = objectField(p, "position") orelse {
        server.allocator.free(doc_path);
        return null;
    };
    const line: usize = @intCast(@max(0, intField(pos_obj, "line") orelse 0));
    const character: usize = @intCast(@max(0, intField(pos_obj, "character") orelse 0));
    const text = server.sourceForPath(doc_path) orelse {
        server.allocator.free(doc_path);
        return null;
    };
    const offset = source.offsetForUtf16Position(text, line, character);
    var cursor_program: ?ast.Program = syntax.parse(server.allocator, text) catch null;
    const program_ptr: ?*const ast.Program = if (cursor_program) |*program| program else null;
    const target = try targetAtOffset(server.allocator, text, offset, program_ptr) orelse {
        if (cursor_program) |*program| program.deinit(server.allocator);
        server.allocator.free(doc_path);
        return null;
    };
    return .{
        .target = target,
        .doc_path = doc_path,
        .source = text,
        .offset = offset,
        .program = cursor_program,
    };
}

fn dirnameAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(path) orelse ".";
    return project.absolutePath(allocator, dir);
}

fn definitionPath(allocator: std.mem.Allocator, root: *const JsonObject, item: *const JsonObject) !?[]u8 {
    if (stringField(item, "file")) |file| return try allocator.dupe(u8, file);
    if (stringField(item, "moduleSpec")) |spec| {
        if (try stdModulePath(allocator, spec)) |path| return path;
    }
    const module_id = intField(item, "moduleId") orelse return null;
    if (arrayFieldObject(root, "modules")) |modules| for (modules.items) |module| if (module == .object) {
        if ((intField(&module.object, "id") orelse -1) == module_id) {
            if (stringField(&module.object, "path")) |path| return try allocator.dupe(u8, path);
            if (stringField(&module.object, "spec")) |spec| {
                if (try stdModulePath(allocator, spec)) |path| return path;
            }
        }
    };
    return null;
}

fn stdModulePath(allocator: std.mem.Allocator, spec: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, spec, "std:")) return null;
    const module_name = spec["std:".len..];
    if (module_name.len == 0 or std.mem.indexOfScalar(u8, module_name, '\\') != null) return null;

    const relative = try std.fmt.allocPrint(allocator, "{s}.ss", .{module_name});
    defer allocator.free(relative);
    if (try stdModulePathFromEnv(allocator, relative)) |path| return path;
    if (try stdModulePathFromRoot(allocator, build_options.source_stdlib_dir, relative)) |path| return path;
    if (try stdModulePathFromRoot(allocator, build_options.installed_stdlib_dir, relative)) |path| return path;
    return stdModulePathFromRoot(allocator, "stdlib", relative);
}

fn stdModulePathFromEnv(allocator: std.mem.Allocator, relative: []const u8) !?[]u8 {
    const raw = std.c.getenv("SS_STDLIB_DIR") orelse return null;
    const root = std.mem.span(raw);
    return stdModulePathFromRoot(allocator, root, relative);
}

fn stdModulePathFromRoot(allocator: std.mem.Allocator, root: []const u8, relative: []const u8) !?[]u8 {
    if (root.len == 0) return null;
    const joined = try std.fs.path.join(allocator, &.{ root, relative });
    defer allocator.free(joined);
    const absolute = try project.absolutePath(allocator, joined);
    errdefer allocator.free(absolute);
    if (utils.fs.fileExists(allocator, absolute)) return absolute;
    allocator.free(absolute);
    return null;
}
