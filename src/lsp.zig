const std = @import("std");
const ast = @import("ast");
const build_options = @import("build_options");
const core = @import("core");
const app = @import("app.zig");
const syntax = @import("syntax.zig");
const lowering = @import("lowering.zig");
const analysis = @import("analysis.zig");
const module_loader = @import("modules/loader.zig");
const project = @import("project.zig");
const dump = @import("dump.zig");
const utils = @import("utils");
const analysis_completion = @import("analysis/completion.zig");
const lsp_scope = @import("lsp/scope.zig");

const JsonValue = std.json.Value;
const JsonObject = std.json.ObjectMap;
const JsonArray = std.json.Array;
const RequestContext = lsp_scope.RequestContext;
const max_poll_timeout_ms = std.math.maxInt(i32);

const RequestPosition = struct {
    doc_path: []u8,
    source: []const u8,
    offset: usize,
    line: usize,
    character: usize,

    fn deinit(self: *RequestPosition, allocator: std.mem.Allocator) void {
        allocator.free(self.doc_path);
    }
};

const Snapshot = struct {
    entry_path: []u8,
    asset_base_dir: []u8,
    lsp: project.LspConfig = .{},
    preview: project.PreviewConfig = .{},
    page_guide: project.PageGuideConfig = .{},
    dump_json: ?[]u8 = null,
    completion_index: ?analysis_completion.Index = null,
    module_paths: std.ArrayList([]u8),

    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_path);
        allocator.free(self.asset_base_dir);
        if (self.dump_json) |json| allocator.free(json);
        if (self.completion_index) |*index| index.deinit();
        for (self.module_paths.items) |path| allocator.free(path);
        self.module_paths.deinit(allocator);
    }
};

const CompletionCache = struct {
    entry_path: []u8,
    index: analysis_completion.Index,

    fn deinit(self: *CompletionCache, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_path);
        self.index.deinit();
    }
};

const DocumentCompletionCache = struct {
    source_hash: u64,
    index: analysis_completion.Index,

    fn deinit(self: *DocumentCompletionCache) void {
        self.index.deinit();
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
        deinitCompletionIndexMap(self.allocator, &self.document_completion_cache);
        deinitStringSet(self.allocator, &self.published_diagnostic_uris);
        self.clearPendingRebuild();
    }

    fn replaceDocument(self: *Server, uri: []const u8, text: []const u8) !void {
        const path = try pathFromUri(self.allocator, uri);
        errdefer self.allocator.free(path);
        const source = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(source);
        if (self.documents.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        try self.documents.put(path, source);
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
        const start_offset = positionOffset(old_source, lspLine(start), lspCharacter(start));
        const end_offset = positionOffset(old_source, lspLine(end), lspCharacter(end));
        if (end_offset < start_offset) return error.InvalidLspRange;

        var next = std.ArrayList(u8).empty;
        errdefer next.deinit(self.allocator);
        try next.appendSlice(self.allocator, old_source[0..start_offset]);
        try next.appendSlice(self.allocator, text);
        try next.appendSlice(self.allocator, old_source[end_offset..]);
        const source = try next.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(source);

        if (self.documents.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        try self.documents.put(path, source);
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

        var source = if (self.sourceForPath(entry_path)) |text|
            try self.allocator.dupe(u8, text)
        else
            utils.fs.readFileAlloc(self.io, self.allocator, entry_path) catch |err| {
                const message = try std.fmt.allocPrint(self.allocator, "ProjectReadFailed: {s}", .{@errorName(err)});
                defer self.allocator.free(message);
                try diagnostics.add(entry_path, "", .@"error", "ProjectReadFailed", message, null);
                return snapshot;
            };

        var program = syntax.parseWithSourceName(self.allocator, source, entry_path) catch |err| {
            const diagnostic = syntax.lastParseDiagnostic();
            var message_buf: [256]u8 = undefined;
            const message = if (diagnostic) |diag| formatParseDiagnostic(&message_buf, diag) else @errorName(err);
            try diagnostics.add(entry_path, source, .@"error", @errorName(err), message, if (diagnostic) |diag| .{ .start = diag.span.start, .end = diag.span.end } else null);
            self.allocator.free(source);
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
            const span = importFailureSpan(self.allocator, asset_base_dir, &program, &load_diagnostics);
            if (load_diagnostics.items.items.len != 0) {
                try diagnostics.add(entry_path, source, .@"error", "ImportFailed", "ImportFailed: imported module failed to load", span);
            } else {
                const message = try std.fmt.allocPrint(self.allocator, "ProjectLoadFailed: {s}", .{@errorName(err)});
                defer self.allocator.free(message);
                try diagnostics.add(entry_path, source, .@"error", @errorName(err), message, span);
            }
            program.deinit(self.allocator);
            self.allocator.free(source);
            return snapshot;
        };
        defer index.deinit();

        var ir = analysis.buildIrWithOptions(self.allocator, entry_path, asset_base_dir, &source, &program, &index, .{ .allow_diagnostics = true }) catch |err| {
            const message = try std.fmt.allocPrint(self.allocator, "BuildFailed: {s}", .{@errorName(err)});
            defer self.allocator.free(message);
            try diagnostics.add(entry_path, source, .@"error", @errorName(err), message, null);
            program.deinit(self.allocator);
            if (source.len != 0) self.allocator.free(source);
            return snapshot;
        };
        defer ir.deinit();

        analysis.analyzeProgram(self.allocator, &ir) catch {};
        try diagnostics.addIr(&ir);
        if (!diagnostics.hasErrors()) {
            if (lowering.lowerToIr(&ir)) {
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
                        try diagnostics.add(entry_path, source, .@"error", @errorName(err), message, null);
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

    fn addProjectConfigDiagnostic(self: *Server, diagnostics: *DiagnosticSet, path: []const u8, err: anyerror) !void {
        var owned_source: ?[]u8 = null;
        defer if (owned_source) |source| self.allocator.free(source);
        const source = self.sourceForPath(path) orelse blk: {
            owned_source = utils.fs.readFileAlloc(self.io, self.allocator, path) catch null;
            break :blk owned_source orelse "";
        };
        const message = try std.fmt.allocPrint(self.allocator, "ProjectConfigFailed: {s}", .{@errorName(err)});
        defer self.allocator.free(message);
        try diagnostics.add(path, source, .@"error", @errorName(err), message, null);
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
        const source = self.sourceForPath(path) orelse return;
        const source_hash = completionSourceHash(source);
        if (self.snapshot) |*snapshot| {
            if (snapshot.completion_index) |*index| {
                if (index.containsDocument(self.allocator, path)) {
                    const cloned = try index.clone(self.allocator);
                    try self.rememberDocumentCompletion(path, source_hash, cloned);
                    return;
                }
            }
        }
        const index = try buildDocumentCompletionIndex(self, path, source) orelse return;
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
        errdefer deinitStringSet(self.allocator, &current_published);

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

        deinitStringSet(self.allocator, &self.published_diagnostic_uris);
        self.published_diagnostic_uris = current_published;
    }
};

fn putStringSet(allocator: std.mem.Allocator, set: *std.StringHashMap(void), value: []const u8) !void {
    if (set.contains(value)) return;
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try set.put(owned, {});
}

fn deinitStringSet(allocator: std.mem.Allocator, set: *std.StringHashMap(void)) void {
    var iterator = set.keyIterator();
    while (iterator.next()) |key| allocator.free(key.*);
    set.deinit();
}

fn deinitCompletionIndexMap(allocator: std.mem.Allocator, map: *std.StringHashMap(DocumentCompletionCache)) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit();
    }
    map.deinit();
}

const DiagnosticSet = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(LspDiagnostic),

    fn init(allocator: std.mem.Allocator) DiagnosticSet {
        return .{ .allocator = allocator, .items = .empty };
    }

    fn deinit(self: *DiagnosticSet) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    fn hasErrors(self: *const DiagnosticSet) bool {
        for (self.items.items) |item| if (item.severity == .@"error") return true;
        return false;
    }

    fn add(
        self: *DiagnosticSet,
        path: []const u8,
        source: []const u8,
        severity: core.DiagnosticSeverity,
        code: []const u8,
        message: []const u8,
        span: ?utils.err.ByteSpan,
    ) !void {
        try self.addWithRelated(path, source, severity, code, message, span, &.{});
    }

    fn addWithRelated(
        self: *DiagnosticSet,
        path: []const u8,
        source: []const u8,
        severity: core.DiagnosticSeverity,
        code: []const u8,
        message: []const u8,
        span: ?utils.err.ByteSpan,
        related: []const LspRelatedInput,
    ) !void {
        const uri = try uriFromPath(self.allocator, path);
        const range = rangeFromSpan(source, span);
        const code_copy = self.allocator.dupe(u8, code) catch |err| {
            self.allocator.free(uri);
            return err;
        };
        const message_copy = self.allocator.dupe(u8, message) catch |err| {
            self.allocator.free(uri);
            self.allocator.free(code_copy);
            return err;
        };
        var diagnostic = LspDiagnostic{
            .uri = uri,
            .range = range,
            .severity = severity,
            .code = code_copy,
            .message = message_copy,
        };
        errdefer diagnostic.deinit(self.allocator);
        for (related) |item| {
            const related_uri = try uriFromPath(self.allocator, item.path);
            const related_message = self.allocator.dupe(u8, item.message) catch |err| {
                self.allocator.free(related_uri);
                return err;
            };
            diagnostic.related_information.append(self.allocator, .{
                .uri = related_uri,
                .range = rangeFromSpan(item.source, item.span),
                .message = related_message,
            }) catch |err| {
                self.allocator.free(related_uri);
                self.allocator.free(related_message);
                return err;
            };
        }
        try self.items.append(self.allocator, diagnostic);
    }

    fn addLoadDiagnostics(self: *DiagnosticSet, load_diagnostics: *const module_loader.LoadDiagnostics) !void {
        for (load_diagnostics.items.items) |item| {
            try self.add(item.path, item.source, item.severity, item.code, item.message, item.span);
        }
    }

    fn addIr(self: *DiagnosticSet, ir: *core.Ir) !void {
        for (ir.diagnostics.items) |diagnostic| {
            const message = try utils.err.formatIrDiagnostic(ir.allocator, diagnostic);
            defer ir.allocator.free(message);
            var report_path = ir.projectPath();
            var report_source = ir.projectSource();
            const located = if (diagnostic.origin) |origin|
                utils.err.parseLocatedOrigin(origin)
            else if (diagnostic.node_id) |node_id| blk: {
                const node = ir.getNode(node_id) orelse break :blk null;
                break :blk if (node.origin) |origin| utils.err.parseLocatedOrigin(origin) else null;
            } else null;
            const span = if (located) |origin| blk: {
                if (origin.path) |origin_path| {
                    if (ir.moduleByPathOrSpec(origin_path)) |module| {
                        report_path = module.path orelse module.spec;
                        report_source = module.source;
                    } else {
                        report_path = origin_path;
                    }
                }
                break :blk origin.span;
            } else null;
            try self.add(report_path, report_source, diagnostic.severity, diagnosticCode(diagnostic), message, span);
        }
    }

    fn addConstraintFailure(self: *DiagnosticSet, ir: *core.Ir, err: anyerror) !void {
        if (ir.constraint_failures.items.len > 0) {
            try self.addConstraintFailureItem(ir, ir.constraint_failures.items[0]);
            return;
        }
        if (ir.last_constraint_failure) |failure| {
            try self.addConstraintFailureItem(ir, failure);
            return;
        }

        const message = try std.fmt.allocPrint(self.allocator, "BuildFailed: {s}", .{@errorName(err)});
        defer self.allocator.free(message);
        try self.add(ir.projectPath(), ir.projectSource(), .@"error", @errorName(err), message, null);
    }

    fn addConstraintFailureItem(self: *DiagnosticSet, ir: *core.Ir, failure: core.ConstraintFailure) !void {
        const kind_text = constraintFailureText(failure);
        const message = try formatConstraintFailureMessage(self.allocator, failure, kind_text);
        defer self.allocator.free(message);

        const primary = constraintFailureLocation(ir, constraintFailureOrigin(failure));
        var related = std.ArrayList(LspRelatedInput).empty;
        defer related.deinit(self.allocator);
        if (failure.existing_constraint) |constraint| {
            const location = constraintFailureLocation(ir, constraint.origin);
            if (location.span != null) {
                try related.append(self.allocator, .{
                    .path = location.path,
                    .source = location.source,
                    .span = location.span,
                    .message = "current value source",
                });
            }
        }
        if (failure.constraint.origin != null and failure.existing_constraint == null) {
            const location = constraintFailureLocation(ir, failure.constraint.origin);
            if (location.span != null and (primary.span == null or !spanEq(primary.span.?, location.span.?))) {
                try related.append(self.allocator, .{
                    .path = location.path,
                    .source = location.source,
                    .span = location.span,
                    .message = "propagating value source",
                });
            }
        }

        try self.addWithRelated(primary.path, primary.source, .@"error", constraintFailureCode(failure), message, primary.span, related.items);
    }
};

const LspRelatedInput = struct {
    path: []const u8,
    source: []const u8,
    span: ?utils.err.ByteSpan,
    message: []const u8,
};

fn constraintFailureCode(failure: core.ConstraintFailure) []const u8 {
    return switch (failure.kind) {
        .conflict => "ConstraintConflict",
        .negative_frame_size => "NegativeFrameSize",
    };
}

fn constraintFailureText(failure: core.ConstraintFailure) []const u8 {
    return switch (failure.kind) {
        .conflict => "ConstraintConflict: constraint conflict",
        .negative_frame_size => "NegativeFrameSize: negative frame size from constraints",
    };
}

fn constraintFailureOrigin(failure: core.ConstraintFailure) ?[]const u8 {
    if (failure.constraint.origin) |origin| return origin;
    if (failure.existing_constraint) |constraint| return constraint.origin;
    return null;
}

const ConstraintFailureLocation = struct {
    path: []const u8,
    source: []const u8,
    span: ?utils.err.ByteSpan,
};

fn constraintFailureLocation(ir: *core.Ir, origin: ?[]const u8) ConstraintFailureLocation {
    var report_path = ir.projectPath();
    var report_source = ir.projectSource();
    var span: ?utils.err.ByteSpan = null;
    if (origin) |origin_text| {
        if (utils.err.parseLocatedOrigin(origin_text)) |located| {
            span = located.span;
            if (located.path) |origin_path| {
                if (ir.moduleByPathOrSpec(origin_path)) |module| {
                    report_path = module.path orelse module.spec;
                    report_source = module.source;
                } else {
                    report_path = origin_path;
                }
            }
        }
    }
    return .{ .path = report_path, .source = report_source, .span = span };
}

fn spanEq(left: utils.err.ByteSpan, right: utils.err.ByteSpan) bool {
    return left.start == right.start and left.end == right.end;
}

fn formatConstraintFailureMessage(
    allocator: std.mem.Allocator,
    failure: core.ConstraintFailure,
    kind_text: []const u8,
) ![]u8 {
    var message = std.ArrayList(u8).empty;
    errdefer message.deinit(allocator);
    try message.appendSlice(allocator, kind_text);
    try message.appendSlice(allocator, "\nreason: ");
    try message.appendSlice(allocator, @tagName(failure.reason));
    if (failure.axis) |axis| {
        try message.appendSlice(allocator, "\naxis: ");
        try message.appendSlice(allocator, @tagName(axis));
    }
    if (failure.actual) |actual| {
        const value = try std.fmt.allocPrint(allocator, "\nactual: {d:.1}", .{actual});
        defer allocator.free(value);
        try message.appendSlice(allocator, value);
    }
    if (failure.expected) |expected| {
        const value = try std.fmt.allocPrint(allocator, "\nexpected: {d:.1}", .{expected});
        defer allocator.free(value);
        try message.appendSlice(allocator, value);
    }
    if (failure.propagation) |propagation| {
        try appendConstraintPropagationMessage(allocator, &message, propagation);
    }

    return try message.toOwnedSlice(allocator);
}

fn appendConstraintPropagationMessage(
    allocator: std.mem.Allocator,
    message: *std.ArrayList(u8),
    propagation: core.ConstraintPropagation,
) !void {
    if (propagation.target) |target| {
        try message.appendSlice(allocator, "\ntarget: ");
        try message.appendSlice(allocator, target);
    }
    for (propagation.paths) |path| {
        try message.appendSlice(allocator, "\n\n");
        try message.appendSlice(allocator, path.title);
        try message.appendSlice(allocator, ":");
        for (path.lines, 0..) |line, index| {
            try message.appendSlice(allocator, "\n  ");
            try message.appendSlice(allocator, line);
            const source = if (index < path.line_sources.len) path.line_sources[index] else null;
            if (source) |origin| {
                try message.appendSlice(allocator, "  ");
                try message.appendSlice(allocator, origin);
            }
        }
    }
    if (propagation.result.len > 0) {
        try message.appendSlice(allocator, "\n\nresult:");
        for (propagation.result) |line| {
            try message.appendSlice(allocator, "\n  ");
            try message.appendSlice(allocator, line);
        }
    }
}

const LspRange = struct {
    start_line: usize = 0,
    start_character: usize = 0,
    end_line: usize = 0,
    end_character: usize = 1,
};

const LspDiagnostic = struct {
    uri: []u8,
    range: LspRange,
    severity: core.DiagnosticSeverity,
    code: []u8,
    message: []u8,
    related_information: std.ArrayList(LspRelatedInformation) = .empty,

    fn deinit(self: *LspDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.code);
        allocator.free(self.message);
        for (self.related_information.items) |*item| item.deinit(allocator);
        self.related_information.deinit(allocator);
    }

    fn appendJson(self: *const LspDiagnostic, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(allocator, "{\"range\":{\"start\":{\"line\":");
        try appendInt(allocator, out, self.range.start_line);
        try out.appendSlice(allocator, ",\"character\":");
        try appendInt(allocator, out, self.range.start_character);
        try out.appendSlice(allocator, "},\"end\":{\"line\":");
        try appendInt(allocator, out, self.range.end_line);
        try out.appendSlice(allocator, ",\"character\":");
        try appendInt(allocator, out, self.range.end_character);
        try out.appendSlice(allocator, "}},\"severity\":");
        const lsp_severity: i64 = if (self.severity == .@"error") 1 else 2;
        try appendInt(allocator, out, lsp_severity);
        try out.appendSlice(allocator, ",\"source\":\"ss\",\"code\":");
        try appendJsonString(allocator, out, self.code);
        try out.appendSlice(allocator, ",\"message\":");
        try appendJsonString(allocator, out, self.message);
        if (self.related_information.items.len != 0) {
            try out.appendSlice(allocator, ",\"relatedInformation\":[");
            for (self.related_information.items, 0..) |item, index| {
                if (index != 0) try out.append(allocator, ',');
                try item.appendJson(allocator, out);
            }
            try out.append(allocator, ']');
        }
        try out.append(allocator, '}');
    }
};

const LspRelatedInformation = struct {
    uri: []u8,
    range: LspRange,
    message: []u8,

    fn deinit(self: *LspRelatedInformation, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.message);
    }

    fn appendJson(self: *const LspRelatedInformation, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(allocator, "{\"location\":{\"uri\":");
        try appendJsonString(allocator, out, self.uri);
        try out.appendSlice(allocator, ",\"range\":");
        try appendRange(allocator, out, self.range);
        try out.appendSlice(allocator, "},\"message\":");
        try appendJsonString(allocator, out, self.message);
        try out.append(allocator, '}');
    }
};

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
    var parsed = std.json.parseFromSlice(JsonValue, server.allocator, body, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value.object;
    const method = stringField(&root, "method") orelse return;
    const id = root.get("id");
    const params = root.get("params");

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

fn jsonLiteral(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return allocator.dupe(u8, text);
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

fn completionResult(server: *Server, params: ?JsonValue) ![]const u8 {
    if (!lspFeatureEnabled(server, .completion)) return try jsonLiteral(server.allocator, "{\"isIncomplete\":false,\"items\":[]}");
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

    var source = try server.allocator.dupe(u8, doc_source);
    defer server.allocator.free(source);

    var start = access.separator_offset;
    while (start > 0 and source[start - 1] != '\n') start -= 1;

    var cursor = start;
    while (cursor < source.len and source[cursor] != '\n') : (cursor += 1) {
        source[cursor] = ' ';
    }

    return buildDocumentCompletionIndex(server, doc_path, source);
}

fn completionSourceHash(source: []const u8) u64 {
    return std.hash.Wyhash.hash(0, source);
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

    var source = try server.allocator.dupe(u8, doc_source);
    var program = syntax.parseWithSourceName(server.allocator, source, doc_path) catch {
        server.allocator.free(source);
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
        server.allocator.free(source);
        return null;
    };
    defer index.deinit();

    var ir = analysis.buildIrWithOptions(server.allocator, doc_path, asset_base_dir, &source, &program, &index, .{ .allow_diagnostics = true }) catch {
        program.deinit(server.allocator);
        if (source.len != 0) server.allocator.free(source);
        return null;
    };
    defer ir.deinit();

    analysis.analyzeProgram(server.allocator, &ir) catch {};
    return analysis_completion.Index.fromIr(server.allocator, &ir) catch null;
}

fn buildImportEnvironmentCompletionIndex(server: *Server, doc_path: []const u8, doc_source: []const u8) !?analysis_completion.Index {
    var source = std.ArrayList(u8).empty;
    defer source.deinit(server.allocator);

    var cursor: usize = 0;
    while (cursor < doc_source.len) {
        const line_start = cursor;
        while (cursor < doc_source.len and doc_source[cursor] != '\n') cursor += 1;
        const line = doc_source[line_start..cursor];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "import ") and trimmed.len > "import ".len) {
            try source.appendSlice(server.allocator, line);
            try source.append(server.allocator, '\n');
        }
        if (cursor < doc_source.len and doc_source[cursor] == '\n') cursor += 1;
    }
    try source.appendSlice(server.allocator, "\npage __completion_probe\nend\n");
    return buildDocumentCompletionIndex(server, doc_path, source.items);
}

fn qualifiedAliasBeforeOffset(source: []const u8, offset: usize) ?[]const u8 {
    var cursor = @min(offset, source.len);
    while (cursor > 0 and isIdentChar(source[cursor - 1])) cursor -= 1;
    if (cursor < 2 or !std.mem.eql(u8, source[cursor - 2 .. cursor], "::")) return null;
    var alias_start = cursor - 2;
    while (alias_start > 0 and (std.ascii.isAlphanumeric(source[alias_start - 1]) or source[alias_start - 1] == '_')) alias_start -= 1;
    if (alias_start == cursor - 2) return null;
    return source[alias_start .. cursor - 2];
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

fn definitionObject(root: *const JsonObject, target: []const u8, module_id: i64) ?*const JsonObject {
    if (arrayFieldObject(root, "definitions")) |defs| for (defs.items) |*item| if (item.* == .object) {
        if (!std.mem.eql(u8, stringField(&item.object, "name") orelse "", target)) continue;
        if ((intField(&item.object, "moduleId") orelse -1) != module_id) continue;
        if (std.mem.eql(u8, stringField(&item.object, "kind") orelse "", "variable")) continue;
        return &item.object;
    };
    return null;
}

fn qualifiedModuleIdForContext(allocator: std.mem.Allocator, root: *const JsonObject, context: *const RequestContext) ?i64 {
    const alias = qualifiedAliasBeforeOffset(context.source, context.offset) orelse return null;
    return resolveAliasModuleId(allocator, root, context.doc_path, alias);
}

fn aliasModuleIdForContext(allocator: std.mem.Allocator, root: *const JsonObject, context: *const RequestContext) ?i64 {
    if (!targetFollowedByDoubleColon(context) and !isImportAliasTarget(context)) return null;
    return resolveAliasModuleId(allocator, root, context.doc_path, context.target);
}

fn targetFollowedByDoubleColon(context: *const RequestContext) bool {
    const bounds = wordBoundsAtOffset(context.source, context.offset) orelse return false;
    return bounds.end + 2 <= context.source.len and std.mem.eql(u8, context.source[bounds.end .. bounds.end + 2], "::");
}

fn isImportAliasTarget(context: *const RequestContext) bool {
    const bounds = wordBoundsAtOffset(context.source, context.offset) orelse return false;
    var line_start = bounds.start;
    while (line_start > 0 and context.source[line_start - 1] != '\n') line_start -= 1;
    var line_end = bounds.end;
    while (line_end < context.source.len and context.source[line_end] != '\n') line_end += 1;
    const line = context.source[line_start..line_end];
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "import ")) return false;
    const as_index = std.mem.lastIndexOf(u8, line, " as ") orelse return false;
    return bounds.start >= line_start + as_index + " as ".len;
}

fn wordBoundsAtOffset(source: []const u8, offset: usize) ?struct { start: usize, end: usize } {
    const pos = @min(offset, source.len);
    var line_start = pos;
    while (line_start > 0 and source[line_start - 1] != '\n') line_start -= 1;
    var line_end = pos;
    while (line_end < source.len and source[line_end] != '\n') line_end += 1;
    var start = pos;
    while (start > line_start and isIdentChar(source[start - 1])) start -= 1;
    var end = pos;
    while (end < line_end and isIdentChar(source[end])) end += 1;
    if (end <= start) return null;
    return .{ .start = start, .end = end };
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

fn hoverResult(server: *Server, params: ?JsonValue) ![]const u8 {
    if (!lspFeatureEnabled(server, .hover)) return try jsonLiteral(server.allocator, "null");
    var context = try requestContext(server, params) orelse return try jsonLiteral(server.allocator, "null");
    defer context.deinit(server.allocator);
    if (server.snapshot) |snapshot| if (snapshot.dump_json) |json_text| {
        var parsed = std.json.parseFromSlice(JsonValue, server.allocator, json_text, .{}) catch return try jsonLiteral(server.allocator, "null");
        defer parsed.deinit();
        const root = parsed.value.object;
        const markdown = try hoverMarkdown(server.allocator, &root, &context) orelse return try jsonLiteral(server.allocator, "null");
        defer server.allocator.free(markdown);
        var out = std.ArrayList(u8).empty;
        try out.appendSlice(server.allocator, "{\"contents\":{\"kind\":\"markdown\",\"value\":");
        try appendJsonString(server.allocator, &out, markdown);
        try out.appendSlice(server.allocator, "}}");
        return out.toOwnedSlice(server.allocator);
    };
    return try jsonLiteral(server.allocator, "null");
}

fn hoverMarkdown(allocator: std.mem.Allocator, root: *const JsonObject, context: *const RequestContext) !?[]u8 {
    const target = context.target;
    if (qualifiedModuleIdForContext(allocator, root, context)) |module_id| {
        if (functionObject(root, target, module_id)) |item| {
            const signature = stringField(item, "signature") orelse target;
            const summary = stringField(item, "summary") orelse "";
            return try std.fmt.allocPrint(allocator, "```ss\n{s}\n```\n{s}", .{ signature, summary });
        }
    }
    if (aliasModuleIdForContext(allocator, root, context)) |module_id| {
        if (moduleObjectById(root, module_id)) |module| {
            return try std.fmt.allocPrint(allocator, "```ss\nimport {s}\n```", .{stringField(module, "spec") orelse context.target});
        }
    }
    if (lsp_scope.bestVisibleVariable(allocator, root, target, context)) |item| {
        return try std.fmt.allocPrint(allocator, "```ss\n({s}: {s})\n```", .{ target, stringField(item, "type") orelse "unknown" });
    }
    if (functionObject(root, target, null)) |item| {
        const signature = stringField(item, "signature") orelse target;
        const summary = stringField(item, "summary") orelse "";
        return try std.fmt.allocPrint(allocator, "```ss\n{s}\n```\n{s}", .{ signature, summary });
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
    if (!lspFeatureEnabled(server, .definition)) return try jsonLiteral(server.allocator, "null");
    var context = try requestContext(server, params) orelse return try jsonLiteral(server.allocator, "null");
    defer context.deinit(server.allocator);
    if (server.snapshot) |snapshot| if (snapshot.dump_json) |json_text| {
        var parsed = std.json.parseFromSlice(JsonValue, server.allocator, json_text, .{}) catch return try jsonLiteral(server.allocator, "null");
        defer parsed.deinit();
        const root = parsed.value.object;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(server.allocator);
        try out.append(server.allocator, '[');
        var first = true;
        if (lsp_scope.bestVisibleDefinition(server.allocator, &root, context.target, &context)) |definition| {
            try appendDefinitionLocation(server.allocator, &out, &root, definition, snapshot.entry_path, &first);
            try out.append(server.allocator, ']');
            return out.toOwnedSlice(server.allocator);
        }
        if (qualifiedModuleIdForContext(server.allocator, &root, &context)) |module_id| {
            if (definitionObject(&root, context.target, module_id)) |definition| {
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
        if (arrayFieldObject(&root, "definitions")) |defs| for (defs.items) |item| if (item == .object) {
            if (!std.mem.eql(u8, stringField(&item.object, "name") orelse "", context.target)) continue;
            if (std.mem.eql(u8, stringField(&item.object, "kind") orelse "", "variable")) continue;
            try appendDefinitionLocation(server.allocator, &out, &root, &item.object, snapshot.entry_path, &first);
        };
        if (first) return try jsonLiteral(server.allocator, "null");
        try out.append(server.allocator, ']');
        return out.toOwnedSlice(server.allocator);
    };
    return try jsonLiteral(server.allocator, "null");
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
    if (!lspFeatureEnabled(server, .inlay_hints)) return try jsonLiteral(server.allocator, "[]");
    const doc_path = try docPathFromParams(server.allocator, params) orelse return try jsonLiteral(server.allocator, "[]");
    defer server.allocator.free(doc_path);
    var out = std.ArrayList(u8).empty;
    try out.append(server.allocator, '[');
    var first = true;
    if (server.snapshot) |snapshot| if (snapshot.dump_json) |json_text| {
        var parsed = std.json.parseFromSlice(JsonValue, server.allocator, json_text, .{}) catch return try jsonLiteral(server.allocator, "[]");
        defer parsed.deinit();
        if (arrayFieldObject(&parsed.value.object, "hints")) |hints| for (hints.items) |item| if (item == .object) {
            const file = stringField(&item.object, "file") orelse continue;
            if (!samePath(server.allocator, file, doc_path)) continue;
            const kind = stringField(&item.object, "kind") orelse "";
            if (!inlayHintKindEnabled(server, kind)) continue;
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
    };
    try out.append(server.allocator, ']');
    return out.toOwnedSlice(server.allocator);
}

fn inlayHintKindEnabled(server: *const Server, kind: []const u8) bool {
    const cfg = if (server.snapshot) |snapshot| snapshot.lsp else project.LspConfig{};
    if (std.mem.eql(u8, kind, "parameter_names")) return cfg.inlay_hint_arguments;
    if (std.mem.eql(u8, kind, "solved_frame")) return cfg.inlay_hint_positions;
    return true;
}

fn documentSymbolResult(server: *Server, params: ?JsonValue) ![]const u8 {
    if (!lspFeatureEnabled(server, .document_symbols)) return try jsonLiteral(server.allocator, "[]");
    const doc_path = try docPathFromParams(server.allocator, params) orelse return try jsonLiteral(server.allocator, "[]");
    defer server.allocator.free(doc_path);
    const source = server.sourceForPath(doc_path) orelse utils.fs.readFileAlloc(server.io, server.allocator, doc_path) catch return try jsonLiteral(server.allocator, "[]");
    const owned_source = server.sourceForPath(doc_path) == null;
    defer if (owned_source) server.allocator.free(source);
    var out = std.ArrayList(u8).empty;
    try out.append(server.allocator, '[');
    var first = true;
    var line_index: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| : (line_index += 1) {
        const trimmed = trimLeft(line, " \t");
        const kind: ?usize = if (std.mem.startsWith(u8, trimmed, "fn "))
            12
        else if (std.mem.startsWith(u8, trimmed, "const "))
            13
        else if (std.mem.startsWith(u8, trimmed, "page "))
            5
        else if (std.mem.startsWith(u8, trimmed, "type "))
            5
        else
            null;
        if (kind == null) continue;
        const name = symbolName(trimmed) orelse continue;
        if (!first) try out.append(server.allocator, ',');
        first = false;
        try appendSymbol(server.allocator, &out, name, kind.?, line_index, 0, line_index, line.len);
    }
    try out.append(server.allocator, ']');
    return out.toOwnedSlice(server.allocator);
}

fn foldingRangeResult(server: *Server, params: ?JsonValue) ![]const u8 {
    if (!lspFeatureEnabled(server, .folding_ranges)) return try jsonLiteral(server.allocator, "[]");
    const doc_path = try docPathFromParams(server.allocator, params) orelse return try jsonLiteral(server.allocator, "[]");
    defer server.allocator.free(doc_path);
    const source = server.sourceForPath(doc_path) orelse utils.fs.readFileAlloc(server.io, server.allocator, doc_path) catch return try jsonLiteral(server.allocator, "[]");
    const owned_source = server.sourceForPath(doc_path) == null;
    defer if (owned_source) server.allocator.free(source);
    var out = std.ArrayList(u8).empty;
    try out.append(server.allocator, '[');
    var first = true;
    var stack = std.ArrayList(usize).empty;
    defer stack.deinit(server.allocator);
    var block_start: ?usize = null;
    var line_index: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| : (line_index += 1) {
        const trimmed = trimLeft(line, " \t");
        if (std.mem.startsWith(u8, trimmed, "page ") or std.mem.startsWith(u8, trimmed, "fn ")) {
            try stack.append(server.allocator, line_index);
        } else if (std.mem.eql(u8, std.mem.trim(u8, trimmed, " \t\r"), "end") and stack.items.len != 0) {
            const start = stack.pop().?;
            try appendFolding(server.allocator, &out, &first, start, line_index);
        }
        if (std.mem.endsWith(u8, trimRight(line, " \t\r"), "<<")) block_start = line_index;
        if (block_start) |start| if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), ">>") and line_index > start) {
            try appendFolding(server.allocator, &out, &first, start, line_index);
            block_start = null;
        };
    }
    try out.append(server.allocator, ']');
    return out.toOwnedSlice(server.allocator);
}

const SemanticToken = struct {
    line: usize,
    start: usize,
    length: usize,
    token_type: usize,
};

fn semanticTokensResult(server: *Server, params: ?JsonValue) ![]const u8 {
    if (!lspFeatureEnabled(server, .semantic_tokens)) return try jsonLiteral(server.allocator, "{\"data\":[]}");
    const doc_path = try docPathFromParams(server.allocator, params) orelse return try jsonLiteral(server.allocator, "{\"data\":[]}");
    defer server.allocator.free(doc_path);
    const source = server.sourceForPath(doc_path) orelse utils.fs.readFileAlloc(server.io, server.allocator, doc_path) catch return try jsonLiteral(server.allocator, "{\"data\":[]}");
    const owned_source = server.sourceForPath(doc_path) == null;
    defer if (owned_source) server.allocator.free(source);

    var tokens = std.ArrayList(SemanticToken).empty;
    defer tokens.deinit(server.allocator);
    var line_index: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| : (line_index += 1) {
        try scanSemanticLine(server.allocator, &tokens, line, line_index);
    }

    var out = std.ArrayList(u8).empty;
    try out.appendSlice(server.allocator, "{\"data\":[");
    var previous_line: usize = 0;
    var previous_start: usize = 0;
    for (tokens.items, 0..) |token, i| {
        if (i != 0) try out.append(server.allocator, ',');
        const delta_line = token.line - previous_line;
        const delta_start = if (delta_line == 0) token.start - previous_start else token.start;
        try appendInt(server.allocator, &out, delta_line);
        try out.append(server.allocator, ',');
        try appendInt(server.allocator, &out, delta_start);
        try out.append(server.allocator, ',');
        try appendInt(server.allocator, &out, token.length);
        try out.append(server.allocator, ',');
        try appendInt(server.allocator, &out, token.token_type);
        try out.appendSlice(server.allocator, ",0");
        previous_line = token.line;
        previous_start = token.start;
    }
    try out.appendSlice(server.allocator, "]}");
    return out.toOwnedSlice(server.allocator);
}

fn scanSemanticLine(allocator: std.mem.Allocator, tokens: *std.ArrayList(SemanticToken), line: []const u8, line_index: usize) !void {
    var index: usize = 0;
    var previous_word: ?[]const u8 = null;
    while (index < line.len) {
        const byte = line[index];
        if (byte == ';' and index + 1 < line.len and line[index + 1] == ';') break;
        if (byte == '/' and index + 1 < line.len and line[index + 1] == '/') break;
        if (byte == '#') break;
        if (std.ascii.isWhitespace(byte)) {
            index += 1;
            continue;
        }
        if (byte == ':' and index + 1 < line.len and line[index + 1] == ':') {
            try appendSemanticToken(allocator, tokens, line, line_index, index, index + 2, 7);
            previous_word = null;
            index += 2;
            continue;
        }
        if ((byte == 'c' and index + 1 < line.len and line[index + 1] == '"') or byte == '"') {
            const start = index;
            index += if (byte == 'c') @as(usize, 2) else 1;
            while (index < line.len) : (index += 1) {
                if (line[index] == '"') {
                    index += 1;
                    break;
                }
            }
            try appendSemanticToken(allocator, tokens, line, line_index, start, @min(index, line.len), 3);
            previous_word = null;
            continue;
        }
        if (std.ascii.isDigit(byte)) {
            const start = index;
            index += 1;
            while (index < line.len and (std.ascii.isDigit(line[index]) or line[index] == '.')) index += 1;
            try appendSemanticToken(allocator, tokens, line, line_index, start, index, 4);
            previous_word = null;
            continue;
        }
        if (isIdentifierStart(byte)) {
            const start = index;
            index += 1;
            while (index < line.len and isIdentChar(line[index])) index += 1;
            const word = line[start..index];
            const next = nextNonSpace(line, index);
            const prev = previousNonSpace(line, start);
            const token_type = semanticTokenType(word, previous_word, next, prev);
            if (token_type) |kind| try appendSemanticToken(allocator, tokens, line, line_index, start, index, kind);
            previous_word = word;
            continue;
        }
        previous_word = null;
        index += std.unicode.utf8ByteSequenceLength(byte) catch 1;
    }
}

fn appendSemanticToken(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayList(SemanticToken),
    line: []const u8,
    line_index: usize,
    start: usize,
    end: usize,
    token_type: usize,
) !void {
    try tokens.append(allocator, .{
        .line = line_index,
        .start = utf16Units(line[0..start]),
        .length = @max(1, utf16Units(line[start..end])),
        .token_type = token_type,
    });
}

fn semanticTokenType(word: []const u8, previous_word: ?[]const u8, next: ?u8, previous: ?u8) ?usize {
    if (isKeyword(word)) return 0;
    if (isBuiltinType(word) or std.ascii.isUpper(word[0])) return 5;
    if (previous == '.') return 6;
    if (previous_word) |prev| {
        if (std.mem.eql(u8, prev, "fn")) return 1;
        if (std.mem.eql(u8, prev, "let") or std.mem.eql(u8, prev, "const")) return 2;
    }
    if (next == '(') return 1;
    return null;
}

fn isKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{ "import", "as", "const", "document", "page", "fn", "let", "return", "end", "type", "extend", "protocol", "base", "implements", "roles", "if", "then", "else", "for", "in", "property" };
    for (keywords) |keyword| if (std.mem.eql(u8, word, keyword)) return true;
    return false;
}

fn isBuiltinType(word: []const u8) bool {
    const types = [_][]const u8{ "document", "page", "object", "selection", "anchor", "string", "number", "bool", "boolean", "constraints", "void", "Void" };
    for (types) |name| if (std.mem.eql(u8, word, name)) return true;
    return false;
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn nextNonSpace(line: []const u8, start: usize) ?u8 {
    var index = start;
    while (index < line.len) : (index += 1) {
        if (!std.ascii.isWhitespace(line[index])) return line[index];
    }
    return null;
}

fn previousNonSpace(line: []const u8, start: usize) ?u8 {
    var index = start;
    while (index > 0) {
        index -= 1;
        if (!std.ascii.isWhitespace(line[index])) return line[index];
    }
    return null;
}

fn utf16Units(bytes: []const u8) usize {
    var units: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch 1;
        const end = @min(index + len, bytes.len);
        const cp = std.unicode.utf8Decode(bytes[index..end]) catch bytes[index];
        units += if (cp > 0xFFFF) @as(usize, 2) else 1;
        index = end;
    }
    return units;
}

fn documentColorResult(server: *Server, params: ?JsonValue) ![]const u8 {
    if (!lspFeatureEnabled(server, .colors)) return try jsonLiteral(server.allocator, "[]");
    const doc_path = try docPathFromParams(server.allocator, params) orelse return try jsonLiteral(server.allocator, "[]");
    defer server.allocator.free(doc_path);
    const source = server.sourceForPath(doc_path) orelse utils.fs.readFileAlloc(server.io, server.allocator, doc_path) catch return try jsonLiteral(server.allocator, "[]");
    const owned_source = server.sourceForPath(doc_path) == null;
    defer if (owned_source) server.allocator.free(source);
    var out = std.ArrayList(u8).empty;
    try out.append(server.allocator, '[');
    var first = true;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, source, index, "c\"")) |start| {
        var end = start + 2;
        while (end < source.len) : (end += 1) {
            if (source[end] == '"') {
                end += 1;
                break;
            }
        }
        if (end <= source.len) if (parseColor(source[start..end])) |rgb| {
            if (!first) try out.append(server.allocator, ',');
            first = false;
            const range = rangeFromSpan(source, .{ .start = start, .end = end });
            try out.appendSlice(server.allocator, "{\"range\":");
            try appendRange(server.allocator, &out, range);
            try out.appendSlice(server.allocator, ",\"color\":{\"red\":");
            try appendFloat(server.allocator, &out, rgb[0]);
            try out.appendSlice(server.allocator, ",\"green\":");
            try appendFloat(server.allocator, &out, rgb[1]);
            try out.appendSlice(server.allocator, ",\"blue\":");
            try appendFloat(server.allocator, &out, rgb[2]);
            try out.appendSlice(server.allocator, ",\"alpha\":1}}");
        };
        index = @max(end, start + 2);
    }
    try out.append(server.allocator, ']');
    return out.toOwnedSlice(server.allocator);
}

fn colorPresentationResult(server: *Server, params: ?JsonValue) ![]const u8 {
    if (!lspFeatureEnabled(server, .colors)) return try jsonLiteral(server.allocator, "[]");
    const color = if (params) |p| objectField(p, "color") else null;
    const red = if (color) |c| numberField(c, "red") orelse 0 else 0;
    const green = if (color) |c| numberField(c, "green") orelse 0 else 0;
    const blue = if (color) |c| numberField(c, "blue") orelse 0 else 0;
    const label = try std.fmt.allocPrint(server.allocator, "c\"#{x:0>2}{x:0>2}{x:0>2}\"", .{ toByte(red), toByte(green), toByte(blue) });
    defer server.allocator.free(label);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(server.allocator, "[{\"label\":");
    try appendJsonString(server.allocator, &out, label);
    try out.appendSlice(server.allocator, "}]");
    return out.toOwnedSlice(server.allocator);
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

fn readMessage(allocator: std.mem.Allocator) !?[]u8 {
    var header = std.ArrayList(u8).empty;
    defer header.deinit(allocator);
    var last4 = [_]u8{ 0, 0, 0, 0 };
    while (true) {
        var byte: [1]u8 = undefined;
        const n = std.c.read(0, &byte, 1);
        if (n == 0) return null;
        if (n < 0) return error.ReadFailed;
        try header.append(allocator, byte[0]);
        last4 = .{ last4[1], last4[2], last4[3], byte[0] };
        if (std.mem.eql(u8, &last4, "\r\n\r\n")) break;
    }
    const content_length = parseContentLength(header.items) orelse return error.InvalidHeader;
    const body = try allocator.alloc(u8, content_length);
    var offset: usize = 0;
    while (offset < body.len) {
        const n = std.c.read(0, body[offset..].ptr, body.len - offset);
        if (n <= 0) return error.ReadFailed;
        offset += @intCast(n);
    }
    return body;
}

fn parseContentLength(header: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseUnsigned(usize, value, 10) catch null;
    }
    return null;
}

fn sendRaw(payload: []const u8) !void {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{payload.len});
    try writeAll(header);
    try writeAll(payload);
}

fn writeAll(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(1, bytes[offset..].ptr, bytes.len - offset);
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}

fn respond(allocator: std.mem.Allocator, id: ?JsonValue, result_json: []const u8) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(allocator, &out, id orelse .null);
    try out.appendSlice(allocator, ",\"result\":");
    try out.appendSlice(allocator, result_json);
    try out.append(allocator, '}');
    try sendRaw(out.items);
}

fn respondError(allocator: std.mem.Allocator, id: ?JsonValue, code: i64, message: []const u8) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(allocator, &out, id orelse .null);
    try out.appendSlice(allocator, ",\"error\":{\"code\":");
    try appendInt(allocator, &out, code);
    try out.appendSlice(allocator, ",\"message\":");
    try appendJsonString(allocator, &out, message);
    try out.appendSlice(allocator, "}}");
    try sendRaw(out.items);
}

fn sendNotification(allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"method\":");
    try appendJsonString(allocator, &out, method);
    try out.appendSlice(allocator, ",\"params\":");
    try out.appendSlice(allocator, params_json);
    try out.append(allocator, '}');
    try sendRaw(out.items);
}

fn appendJsonValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: JsonValue) !void {
    const text = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const escaped = try std.json.Stringify.valueAlloc(allocator, text, .{});
    defer allocator.free(escaped);
    try out.appendSlice(allocator, escaped);
}

fn appendInt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn appendBool(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: bool) !void {
    try out.appendSlice(allocator, if (value) "true" else "false");
}

fn appendFloat(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: f64) !void {
    const text = try std.fmt.allocPrint(allocator, "{d:.4}", .{value});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn stringField(object: *const JsonObject, key: []const u8) ?[]const u8 {
    const value = @constCast(object).getPtr(key) orelse return null;
    return if (value.* == .string) value.string else null;
}

fn intField(object: *const JsonObject, key: []const u8) ?i64 {
    const value = @constCast(object).getPtr(key) orelse return null;
    return switch (value.*) {
        .integer => |v| v,
        .float => |v| @intFromFloat(v),
        else => null,
    };
}

fn lspLine(object: *const JsonObject) usize {
    return @intCast(@max(0, intField(object, "line") orelse 0));
}

fn lspCharacter(object: *const JsonObject) usize {
    return @intCast(@max(0, intField(object, "character") orelse 0));
}

fn positionOffset(source: []const u8, target_line: usize, target_character: usize) usize {
    var line: usize = 0;
    var line_start: usize = 0;
    var index: usize = 0;
    while (index < source.len and line < target_line) : (index += 1) {
        if (source[index] == '\n') {
            line += 1;
            line_start = index + 1;
        }
    }
    if (line < target_line) return source.len;

    var character: usize = 0;
    index = line_start;
    while (index < source.len and source[index] != '\n') {
        if (character >= target_character) return index;
        const len = std.unicode.utf8ByteSequenceLength(source[index]) catch 1;
        const end = @min(index + len, source.len);
        const cp = std.unicode.utf8Decode(source[index..end]) catch source[index];
        const width: usize = if (cp >= 0x10000) 2 else 1;
        if (character + width > target_character) return index;
        character += width;
        index = end;
    }
    return index;
}

fn numberField(object: *const JsonObject, key: []const u8) ?f64 {
    const value = @constCast(object).getPtr(key) orelse return null;
    return switch (value.*) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        else => null,
    };
}

fn objectField(value: JsonValue, key: []const u8) ?*const JsonObject {
    if (value != .object) return null;
    const child = @constCast(&value.object).getPtr(key) orelse return null;
    if (child.* != .object) return null;
    return &child.object;
}

fn objectFieldObject(object: *const JsonObject, key: []const u8) ?*const JsonObject {
    const child = @constCast(object).getPtr(key) orelse return null;
    if (child.* != .object) return null;
    return &child.object;
}

fn arrayField(value: JsonValue, key: []const u8) ?*const JsonArray {
    if (value != .object) return null;
    const child = @constCast(&value.object).getPtr(key) orelse return null;
    if (child.* != .array) return null;
    return &child.array;
}

fn arrayFieldObject(object: *const JsonObject, key: []const u8) ?*const JsonArray {
    const child = @constCast(object).getPtr(key) orelse return null;
    if (child.* != .array) return null;
    return &child.array;
}

fn docPathFromParams(allocator: std.mem.Allocator, params: ?JsonValue) !?[]u8 {
    const p = params orelse return null;
    const doc = objectField(p, "textDocument") orelse return null;
    const uri = stringField(doc, "uri") orelse return null;
    return try pathFromUri(allocator, uri);
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
    const source = server.sourceForPath(doc_path) orelse {
        server.allocator.free(doc_path);
        return null;
    };
    return .{
        .doc_path = doc_path,
        .source = source,
        .offset = positionOffset(source, line, character),
        .line = line,
        .character = character,
    };
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
    const source = server.sourceForPath(doc_path) orelse {
        server.allocator.free(doc_path);
        return null;
    };
    const target = try wordAt(server.allocator, source, line, character) orelse {
        server.allocator.free(doc_path);
        return null;
    };
    return .{
        .target = target,
        .doc_path = doc_path,
        .source = source,
        .offset = positionOffset(source, line, character),
    };
}

fn wordAt(allocator: std.mem.Allocator, source: []const u8, target_line: usize, character: usize) !?[]u8 {
    const pos = positionOffset(source, target_line, character);
    var line_start = pos;
    while (line_start > 0 and source[line_start - 1] != '\n') line_start -= 1;
    var line_end = pos;
    while (line_end < source.len and source[line_end] != '\n') line_end += 1;
    var start = pos;
    while (start > line_start and isIdentChar(source[start - 1])) start -= 1;
    var end = pos;
    while (end < line_end and isIdentChar(source[end])) end += 1;
    if (end <= start) return null;
    return try allocator.dupe(u8, source[start..end]);
}

fn isIdentChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '!';
}

fn pathFromUri(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return allocator.dupe(u8, uri);
    const raw = uri["file://".len..];
    return percentDecode(allocator, raw);
}

fn uriFromPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const absolute = try project.absolutePath(allocator, path);
    defer allocator.free(absolute);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "file://");
    for (absolute) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '_' or byte == '-' or byte == '.') {
            try out.append(allocator, byte);
        } else {
            try out.print(allocator, "%{X:0>2}", .{byte});
        }
    }
    return out.toOwnedSlice(allocator);
}

fn percentDecode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            const value = std.fmt.parseUnsigned(u8, text[i + 1 .. i + 3], 16) catch {
                try out.append(allocator, text[i]);
                continue;
            };
            try out.append(allocator, value);
            i += 2;
        } else {
            try out.append(allocator, text[i]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn rangeFromSpan(source: []const u8, span: ?utils.err.ByteSpan) LspRange {
    const s = span orelse return .{};
    const start = lspPositionFromOffset(source, @min(s.start, source.len));
    const end = lspPositionFromOffset(source, @min(@max(s.end, s.start + 1), source.len));
    return .{
        .start_line = start.line,
        .start_character = start.character,
        .end_line = end.line,
        .end_character = end.character,
    };
}

fn lspPositionFromOffset(source: []const u8, byte_offset: usize) struct { line: usize, character: usize } {
    const limit = @min(byte_offset, source.len);
    var line: usize = 0;
    var line_start: usize = 0;
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        if (source[index] == '\n') {
            line += 1;
            line_start = index + 1;
        }
    }
    return .{
        .line = line,
        .character = utf16Units(source[line_start..limit]),
    };
}

fn appendRange(allocator: std.mem.Allocator, out: *std.ArrayList(u8), range: LspRange) !void {
    try out.appendSlice(allocator, "{\"start\":{\"line\":");
    try appendInt(allocator, out, range.start_line);
    try out.appendSlice(allocator, ",\"character\":");
    try appendInt(allocator, out, range.start_character);
    try out.appendSlice(allocator, "},\"end\":{\"line\":");
    try appendInt(allocator, out, range.end_line);
    try out.appendSlice(allocator, ",\"character\":");
    try appendInt(allocator, out, range.end_character);
    try out.appendSlice(allocator, "}}");
}

fn locationJson(allocator: std.mem.Allocator, uri: []const u8, sl: usize, sc: usize, el: usize, ec: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try appendLocationObject(allocator, &out, uri, sl, sc, el, ec);
    return out.toOwnedSlice(allocator);
}

fn appendLocationObject(allocator: std.mem.Allocator, out: *std.ArrayList(u8), uri: []const u8, sl: usize, sc: usize, el: usize, ec: usize) !void {
    try out.appendSlice(allocator, "{\"uri\":");
    try appendJsonString(allocator, out, uri);
    try out.appendSlice(allocator, ",\"range\":{\"start\":{\"line\":");
    try appendInt(allocator, out, sl);
    try out.appendSlice(allocator, ",\"character\":");
    try appendInt(allocator, out, sc);
    try out.appendSlice(allocator, "},\"end\":{\"line\":");
    try appendInt(allocator, out, el);
    try out.appendSlice(allocator, ",\"character\":");
    try appendInt(allocator, out, ec);
    try out.appendSlice(allocator, "}}}");
}

fn diagnosticCode(diagnostic: core.Diagnostic) []const u8 {
    return switch (diagnostic.data) {
        .user_report => |data| if (std.mem.startsWith(u8, data.message, "DependencyQuery:")) "DependencyQuery" else "user_report",
        .asset_not_found => "asset_not_found",
        .asset_invalid => "asset_invalid",
        .render_failed => "render_failed",
        .type_mismatch => |data| @tagName(data.code),
        .recursive_function => "RecursiveFunction",
        .page_overflow => "page_overflow",
        .content_overflow => "content_overflow",
    };
}

fn formatParseDiagnostic(buf: []u8, diagnostic: anytype) []const u8 {
    return switch (diagnostic.err) {
        error.UnterminatedString => "UnterminatedString: unterminated string",
        error.UnknownAnchor => "UnknownAnchor: unknown anchor name",
        error.AssignmentRequiresLet => "AssignmentRequiresLet: plain assignment statements are not supported; use 'let name = expr'",
        error.ZeroArgCallRequiresParens => "ZeroArgCallRequiresParens: a bare name is not a statement; use parentheses for a zero-argument call, or pass the value to a placing function such as 'text!(name)'",
        else => blk: {
            const expected = diagnostic.expected orelse @errorName(diagnostic.err);
            const found = diagnostic.found orelse "unknown token";
            break :blk std.fmt.bufPrint(buf, "{s}: expected {s}, found {s}", .{ @errorName(diagnostic.err), expected, found }) catch @errorName(diagnostic.err);
        },
    };
}

fn importFailureSpan(
    allocator: std.mem.Allocator,
    asset_base_dir: []const u8,
    program: *const ast.Program,
    load_diagnostics: *const module_loader.LoadDiagnostics,
) ?utils.err.ByteSpan {
    for (load_diagnostics.items.items) |diagnostic| {
        for (program.imports.items) |import_decl| {
            if (importMatchesDiagnosticPath(allocator, asset_base_dir, import_decl.spec, diagnostic.path) catch false) {
                return .{ .start = import_decl.span.start, .end = import_decl.span.end };
            }
        }
    }
    if (program.imports.items.len == 0) return null;
    const span = program.imports.items[0].span;
    return .{ .start = span.start, .end = span.end };
}

fn importMatchesDiagnosticPath(
    allocator: std.mem.Allocator,
    asset_base_dir: []const u8,
    import_spec: []const u8,
    diagnostic_path: []const u8,
) !bool {
    if (std.mem.startsWith(u8, import_spec, "std:")) {
        return std.mem.eql(u8, import_spec, diagnostic_path);
    }
    const resolved = if (std.fs.path.isAbsolute(import_spec))
        try allocator.dupe(u8, import_spec)
    else
        try std.fs.path.resolve(allocator, &.{ asset_base_dir, import_spec });
    defer allocator.free(resolved);
    return std.mem.eql(u8, resolved, diagnostic_path);
}

fn dirnameAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(path) orelse ".";
    return project.absolutePath(allocator, dir);
}

fn samePath(allocator: std.mem.Allocator, left: []const u8, right: []const u8) bool {
    const a = project.absolutePath(allocator, left) catch return false;
    defer allocator.free(a);
    const b = project.absolutePath(allocator, right) catch return false;
    defer allocator.free(b);
    return std.mem.eql(u8, a, b);
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

fn symbolName(line: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t(:=");
    _ = it.next() orelse return null;
    return it.next();
}

fn appendSymbol(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, kind: usize, sl: usize, sc: usize, el: usize, ec: usize) !void {
    try out.appendSlice(allocator, "{\"name\":");
    try appendJsonString(allocator, out, name);
    try out.appendSlice(allocator, ",\"kind\":");
    try appendInt(allocator, out, kind);
    try out.appendSlice(allocator, ",\"range\":{\"start\":{\"line\":");
    try appendInt(allocator, out, sl);
    try out.appendSlice(allocator, ",\"character\":");
    try appendInt(allocator, out, sc);
    try out.appendSlice(allocator, "},\"end\":{\"line\":");
    try appendInt(allocator, out, el);
    try out.appendSlice(allocator, ",\"character\":");
    try appendInt(allocator, out, ec);
    try out.appendSlice(allocator, "}},\"selectionRange\":{\"start\":{\"line\":");
    try appendInt(allocator, out, sl);
    try out.appendSlice(allocator, ",\"character\":");
    try appendInt(allocator, out, sc);
    try out.appendSlice(allocator, "},\"end\":{\"line\":");
    try appendInt(allocator, out, el);
    try out.appendSlice(allocator, ",\"character\":");
    try appendInt(allocator, out, ec);
    try out.appendSlice(allocator, "}}}");
}

fn appendFolding(allocator: std.mem.Allocator, out: *std.ArrayList(u8), first: *bool, start: usize, end: usize) !void {
    if (end <= start) return;
    if (!first.*) try out.append(allocator, ',');
    first.* = false;
    try out.appendSlice(allocator, "{\"startLine\":");
    try appendInt(allocator, out, start);
    try out.appendSlice(allocator, ",\"endLine\":");
    try appendInt(allocator, out, end);
    try out.append(allocator, '}');
}

fn parseColor(literal: []const u8) ?[3]f64 {
    if (literal.len < 3 or literal[0] != 'c' or literal[1] != '"' or literal[literal.len - 1] != '"') return null;
    const inner = literal[2 .. literal.len - 1];
    if (inner.len == 7 and inner[0] == '#') {
        return .{
            @as(f64, @floatFromInt(std.fmt.parseUnsigned(u8, inner[1..3], 16) catch return null)) / 255.0,
            @as(f64, @floatFromInt(std.fmt.parseUnsigned(u8, inner[3..5], 16) catch return null)) / 255.0,
            @as(f64, @floatFromInt(std.fmt.parseUnsigned(u8, inner[5..7], 16) catch return null)) / 255.0,
        };
    }
    var parts = std.mem.splitScalar(u8, inner, ',');
    const r = std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse return null, " \t")) catch return null;
    const g = std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse return null, " \t")) catch return null;
    const b = std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse return null, " \t")) catch return null;
    if (parts.next() != null) return null;
    return .{ r, g, b };
}

fn toByte(value: f64) u8 {
    return @intFromFloat(@max(0, @min(255, std.math.round(value * 255.0))));
}

fn trimLeft(text: []const u8, values: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and std.mem.indexOfScalar(u8, values, text[start]) != null) : (start += 1) {}
    return text[start..];
}

fn trimRight(text: []const u8, values: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and std.mem.indexOfScalar(u8, values, text[end - 1]) != null) : (end -= 1) {}
    return text[0..end];
}
