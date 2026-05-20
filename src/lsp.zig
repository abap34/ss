const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const syntax = @import("syntax.zig");
const stage1 = @import("stage1.zig");
const typecheck = @import("analysis/typecheck.zig");
const module_loader = @import("modules/loader.zig");
const project = @import("project.zig");
const dump = @import("dump.zig");
const utils = @import("utils");

const JsonValue = std.json.Value;
const JsonObject = std.json.ObjectMap;
const JsonArray = std.json.Array;

const Snapshot = struct {
    entry_path: []u8,
    asset_base_dir: []u8,
    dump_json: ?[]u8 = null,
    module_paths: std.ArrayList([]u8),

    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_path);
        allocator.free(self.asset_base_dir);
        if (self.dump_json) |json| allocator.free(json);
        for (self.module_paths.items) |path| allocator.free(path);
        self.module_paths.deinit(allocator);
    }
};

const Server = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    documents: std.StringHashMap([]u8),
    snapshot: ?Snapshot = null,
    shutdown: bool = false,

    fn init(io: std.Io, allocator: std.mem.Allocator) Server {
        return .{
            .io = io,
            .allocator = allocator,
            .documents = std.StringHashMap([]u8).init(allocator),
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

    fn removeDocument(self: *Server, uri: []const u8) void {
        const path = pathFromUri(self.allocator, uri) catch return;
        defer self.allocator.free(path);
        if (self.documents.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
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
        self.snapshot = snapshot;
        try self.publishDiagnostics(&diagnostics);
    }

    fn buildSnapshot(self: *Server, changed_path: []const u8, diagnostics: *DiagnosticSet) !Snapshot {
        const changed_abs = try project.absolutePath(self.allocator, changed_path);
        defer self.allocator.free(changed_abs);
        const changed_dir = std.fs.path.dirname(changed_abs) orelse ".";

        var config = try project.discover(self.allocator, self.io, changed_dir);
        defer if (config) |*cfg| cfg.deinit(self.allocator);
        const entry_path = if (config) |cfg| try self.allocator.dupe(u8, cfg.entry) else try self.allocator.dupe(u8, changed_abs);
        errdefer self.allocator.free(entry_path);
        const asset_base_dir = if (config) |cfg| try self.allocator.dupe(u8, cfg.asset_base_dir) else try dirnameAlloc(self.allocator, entry_path);
        errdefer self.allocator.free(asset_base_dir);

        var snapshot = Snapshot{
            .entry_path = entry_path,
            .asset_base_dir = asset_base_dir,
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

        var index = typecheck.loadProgramIndexWithOverlay(self.allocator, self.io, asset_base_dir, program, &overlay) catch |err| {
            const span = if (program.imports.items.len != 0) program.imports.items[0].span else null;
            const message = try std.fmt.allocPrint(self.allocator, "ProjectLoadFailed: {s}", .{@errorName(err)});
            defer self.allocator.free(message);
            try diagnostics.add(entry_path, source, .@"error", @errorName(err), message, if (span) |s| .{ .start = s.start, .end = s.end } else null);
            program.deinit(self.allocator);
            self.allocator.free(source);
            return snapshot;
        };
        defer index.deinit();

        var ir = typecheck.buildIrWithOptions(self.allocator, entry_path, asset_base_dir, &source, &program, &index, .{ .allow_diagnostics = true }) catch |err| {
            const message = try std.fmt.allocPrint(self.allocator, "BuildFailed: {s}", .{@errorName(err)});
            defer self.allocator.free(message);
            try diagnostics.add(entry_path, source, .@"error", @errorName(err), message, null);
            program.deinit(self.allocator);
            if (source.len != 0) self.allocator.free(source);
            return snapshot;
        };
        defer ir.deinit();

        typecheck.typecheckProgram(self.allocator, &ir) catch {};
        try diagnostics.addIr(&ir);
        if (!diagnostics.hasErrors()) {
            stage1.lowerToIr(&ir) catch {};
            try diagnostics.addIr(&ir);
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
        return snapshot;
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

        var published = std.StringHashMap(void).init(self.allocator);
        defer published.deinit();

        var it = grouped.iterator();
        while (it.next()) |entry| {
            try published.put(entry.key_ptr.*, {});
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
        }

        var doc_iterator = self.documents.iterator();
        while (doc_iterator.next()) |entry| {
            const uri = try uriFromPath(self.allocator, entry.key_ptr.*);
            defer self.allocator.free(uri);
            if (published.contains(uri)) continue;
            var body = std.ArrayList(u8).empty;
            defer body.deinit(self.allocator);
            try body.appendSlice(self.allocator, "{\"uri\":");
            try appendJsonString(self.allocator, &body, uri);
            try body.appendSlice(self.allocator, ",\"diagnostics\":[]}");
            try sendNotification(self.allocator, "textDocument/publishDiagnostics", body.items);
        }
    }
};

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
        const uri = try uriFromPath(self.allocator, path);
        errdefer self.allocator.free(uri);
        const range = rangeFromSpan(source, span);
        try self.items.append(self.allocator, .{
            .uri = uri,
            .range = range,
            .severity = severity,
            .code = try self.allocator.dupe(u8, code),
            .message = try self.allocator.dupe(u8, message),
        });
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
};

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

    fn deinit(self: *LspDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.code);
        allocator.free(self.message);
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
        try out.append(allocator, '}');
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server = Server.init(io, allocator);
    defer server.deinit();

    while (!server.shutdown) {
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
        try respond(server.allocator, id, initializeResult);
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
                try server.rebuild(path);
            }
        };
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/didChange")) {
        if (params) |p| if (objectField(p, "textDocument")) |doc| {
            if (stringField(doc, "uri")) |uri| {
                if (arrayField(p, "contentChanges")) |changes| if (changes.items.len != 0 and changes.items[changes.items.len - 1] == .object) {
                    const text = stringField(&changes.items[changes.items.len - 1].object, "text") orelse "";
                    try server.replaceDocument(uri, text);
                    const path = try pathFromUri(server.allocator, uri);
                    defer server.allocator.free(path);
                    try server.rebuild(path);
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
                try server.rebuild(path);
            }
        };
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/didClose")) {
        if (params) |p| if (objectField(p, "textDocument")) |doc| {
            if (stringField(doc, "uri")) |uri| server.removeDocument(uri);
        };
        return;
    }

    if (std.mem.eql(u8, method, "textDocument/completion")) {
        try respond(server.allocator, id, try completionResult(server));
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/hover")) {
        try respond(server.allocator, id, try hoverResult(server, params));
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/definition")) {
        try respond(server.allocator, id, try definitionResult(server, params));
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
        try respond(server.allocator, id, try inlayHintResult(server, params));
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
        try respond(server.allocator, id, try documentSymbolResult(server, params));
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/foldingRange")) {
        try respond(server.allocator, id, try foldingRangeResult(server, params));
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
        try respond(server.allocator, id, try semanticTokensResult(server, params));
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/documentColor")) {
        try respond(server.allocator, id, try documentColorResult(server, params));
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/colorPresentation")) {
        try respond(server.allocator, id, try colorPresentationResult(server, params));
        return;
    }
    if (std.mem.eql(u8, method, "ss/projectInfo")) {
        try respond(server.allocator, id, try projectInfoResult(server));
        return;
    }
    if (id != null) try respondError(server.allocator, id, -32601, "method not found");
}

const initializeResult =
    \\{"capabilities":{"textDocumentSync":2,"completionProvider":{"triggerCharacters":[".","\"","@"]},"hoverProvider":true,"definitionProvider":true,"inlayHintProvider":true,"documentSymbolProvider":true,"foldingRangeProvider":true,"semanticTokensProvider":{"legend":{"tokenTypes":["keyword","function","variable","string","number","type","property"],"tokenModifiers":[]},"full":true},"colorProvider":true},"serverInfo":{"name":"ss-lsp","version":"0.1.0"}}
;

fn completionResult(server: *Server) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    const allocator = server.allocator;
    try out.appendSlice(allocator, "{\"isIncomplete\":false,\"items\":[");
    var first = true;
    const keywords = [_][]const u8{ "import", "const", "document", "page", "fn", "let", "bind", "return", "end", "constrain", "type", "extend", "if", "then", "else" };
    for (keywords) |keyword| try appendCompletion(allocator, &out, &first, keyword, 14, "keyword", null);
    if (server.snapshot) |snapshot| if (snapshot.dump_json) |json_text| {
        try appendDumpCompletions(allocator, &out, &first, json_text);
    };
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn appendDumpCompletions(allocator: std.mem.Allocator, out: *std.ArrayList(u8), first: *bool, json_text: []const u8) !void {
    var parsed = std.json.parseFromSlice(JsonValue, allocator, json_text, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value.object;
    if (arrayFieldObject(&root, "functions")) |functions| for (functions.items) |item| if (item == .object) {
        const label = stringField(&item.object, "name") orelse continue;
        const detail = stringField(&item.object, "signature");
        try appendCompletion(allocator, out, first, label, 3, detail, stringField(&item.object, "summary"));
    };
    if (arrayFieldObject(&root, "variables")) |variables| for (variables.items) |item| if (item == .object) {
        const label = stringField(&item.object, "name") orelse continue;
        try appendCompletion(allocator, out, first, label, 6, stringField(&item.object, "type"), null);
    };
    if (objectFieldObject(&root, "declarations")) |decls| {
        const fields = [_]struct { key: []const u8, kind: usize }{
            .{ .key = "valueDomains", .kind = 25 },
            .{ .key = "classes", .kind = 7 },
            .{ .key = "roles", .kind = 20 },
            .{ .key = "fields", .kind = 10 },
        };
        for (fields) |field| if (arrayFieldObject(decls, field.key)) |items| for (items.items) |item| if (item == .object) {
            const label = stringField(&item.object, "name") orelse continue;
            try appendCompletion(allocator, out, first, label, field.kind, stringField(&item.object, "type"), null);
        };
    }
}

fn appendCompletion(allocator: std.mem.Allocator, out: *std.ArrayList(u8), first: *bool, label: []const u8, kind: usize, detail: ?[]const u8, documentation: ?[]const u8) !void {
    if (!first.*) try out.append(allocator, ',');
    first.* = false;
    try out.appendSlice(allocator, "{\"label\":");
    try appendJsonString(allocator, out, label);
    try out.appendSlice(allocator, ",\"kind\":");
    try appendInt(allocator, out, kind);
    if (detail) |text| {
        try out.appendSlice(allocator, ",\"detail\":");
        try appendJsonString(allocator, out, text);
    }
    if (documentation) |text| if (text.len != 0) {
        try out.appendSlice(allocator, ",\"documentation\":");
        try appendJsonString(allocator, out, text);
    };
    try out.append(allocator, '}');
}

fn hoverResult(server: *Server, params: ?JsonValue) ![]const u8 {
    const target = try wordAtRequest(server, params) orelse return "null";
    defer server.allocator.free(target);
    if (server.snapshot) |snapshot| if (snapshot.dump_json) |json_text| {
        var parsed = std.json.parseFromSlice(JsonValue, server.allocator, json_text, .{}) catch return "null";
        defer parsed.deinit();
        const root = parsed.value.object;
        const markdown = try hoverMarkdown(server.allocator, &root, target) orelse return "null";
        defer server.allocator.free(markdown);
        var out = std.ArrayList(u8).empty;
        try out.appendSlice(server.allocator, "{\"contents\":{\"kind\":\"markdown\",\"value\":");
        try appendJsonString(server.allocator, &out, markdown);
        try out.appendSlice(server.allocator, "}}");
        return out.toOwnedSlice(server.allocator);
    };
    return "null";
}

fn hoverMarkdown(allocator: std.mem.Allocator, root: *const JsonObject, target: []const u8) !?[]u8 {
    if (arrayFieldObject(root, "functions")) |functions| for (functions.items) |item| if (item == .object) {
        if (!std.mem.eql(u8, stringField(&item.object, "name") orelse "", target)) continue;
        const signature = stringField(&item.object, "signature") orelse target;
        const summary = stringField(&item.object, "summary") orelse "";
        return try std.fmt.allocPrint(allocator, "```ss\n{s}\n```\n{s}", .{ signature, summary });
    };
    if (arrayFieldObject(root, "variables")) |variables| for (variables.items) |item| if (item == .object) {
        if (!std.mem.eql(u8, stringField(&item.object, "name") orelse "", target)) continue;
        return try std.fmt.allocPrint(allocator, "```ss\n({s}: {s})\n```", .{ target, stringField(&item.object, "type") orelse "unknown" });
    };
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
    const target = try wordAtRequest(server, params) orelse return "null";
    defer server.allocator.free(target);
    if (server.snapshot) |snapshot| if (snapshot.dump_json) |json_text| {
        var parsed = std.json.parseFromSlice(JsonValue, server.allocator, json_text, .{}) catch return "null";
        defer parsed.deinit();
        const root = parsed.value.object;
        if (arrayFieldObject(&root, "definitions")) |defs| for (defs.items) |item| if (item == .object) {
            if (!std.mem.eql(u8, stringField(&item.object, "name") orelse "", target)) continue;
            const path = definitionPath(server.allocator, &root, &item.object) catch null;
            defer if (path) |p| server.allocator.free(p);
            const uri = try uriFromPath(server.allocator, path orelse snapshot.entry_path);
            defer server.allocator.free(uri);
            const line: usize = @intCast(@max(0, (intField(&item.object, "line") orelse 1) - 1));
            const column: usize = @intCast(@max(0, (intField(&item.object, "column") orelse 1) - 1));
            const length: usize = @intCast(@max(1, intField(&item.object, "length") orelse @as(i64, @intCast(target.len))));
            return try locationJson(server.allocator, uri, line, column, line, column + length);
        };
    };
    return "null";
}

fn inlayHintResult(server: *Server, params: ?JsonValue) ![]const u8 {
    const doc_path = try docPathFromParams(server.allocator, params) orelse return "[]";
    defer server.allocator.free(doc_path);
    var out = std.ArrayList(u8).empty;
    try out.append(server.allocator, '[');
    var first = true;
    if (server.snapshot) |snapshot| if (snapshot.dump_json) |json_text| {
        var parsed = std.json.parseFromSlice(JsonValue, server.allocator, json_text, .{}) catch return "[]";
        defer parsed.deinit();
        if (arrayFieldObject(&parsed.value.object, "hints")) |hints| for (hints.items) |item| if (item == .object) {
            const file = stringField(&item.object, "file") orelse continue;
            if (!samePath(server.allocator, file, doc_path)) continue;
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
            const hint_kind: i64 = if (std.mem.eql(u8, stringField(&item.object, "kind") orelse "", "parameter_names")) 2 else 1;
            try appendInt(server.allocator, &out, hint_kind);
            try out.appendSlice(server.allocator, ",\"paddingLeft\":true}");
        };
    };
    try out.append(server.allocator, ']');
    return out.toOwnedSlice(server.allocator);
}

fn documentSymbolResult(server: *Server, params: ?JsonValue) ![]const u8 {
    const doc_path = try docPathFromParams(server.allocator, params) orelse return "[]";
    defer server.allocator.free(doc_path);
    const source = server.sourceForPath(doc_path) orelse utils.fs.readFileAlloc(server.io, server.allocator, doc_path) catch return "[]";
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
    const doc_path = try docPathFromParams(server.allocator, params) orelse return "[]";
    defer server.allocator.free(doc_path);
    const source = server.sourceForPath(doc_path) orelse utils.fs.readFileAlloc(server.io, server.allocator, doc_path) catch return "[]";
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
    const doc_path = try docPathFromParams(server.allocator, params) orelse return "{\"data\":[]}";
    defer server.allocator.free(doc_path);
    const source = server.sourceForPath(doc_path) orelse utils.fs.readFileAlloc(server.io, server.allocator, doc_path) catch return "{\"data\":[]}";
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
        if ((byte == 'c' and index + 1 < line.len and line[index + 1] == '"') or byte == '"') {
            const start = index;
            index += if (byte == 'c') @as(usize, 2) else 1;
            var escaped = false;
            while (index < line.len) : (index += 1) {
                if (escaped) {
                    escaped = false;
                } else if (line[index] == '\\') {
                    escaped = true;
                } else if (line[index] == '"') {
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
        if (std.mem.eql(u8, prev, "let") or std.mem.eql(u8, prev, "bind") or std.mem.eql(u8, prev, "const")) return 2;
    }
    if (next == '(') return 1;
    return null;
}

fn isKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{ "import", "const", "document", "page", "fn", "let", "bind", "return", "end", "constrain", "type", "extend", "if", "then", "else", "for", "in", "property" };
    for (keywords) |keyword| if (std.mem.eql(u8, word, keyword)) return true;
    return false;
}

fn isBuiltinType(word: []const u8) bool {
    const types = [_][]const u8{ "object", "selection", "anchor", "function", "style", "string", "number", "bool", "boolean", "constraints", "fragment", "code", "list" };
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
    const doc_path = try docPathFromParams(server.allocator, params) orelse return "[]";
    defer server.allocator.free(doc_path);
    const source = server.sourceForPath(doc_path) orelse utils.fs.readFileAlloc(server.io, server.allocator, doc_path) catch return "[]";
    const owned_source = server.sourceForPath(doc_path) == null;
    defer if (owned_source) server.allocator.free(source);
    var out = std.ArrayList(u8).empty;
    try out.append(server.allocator, '[');
    var first = true;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, source, index, "c\"")) |start| {
        var end = start + 2;
        var escaped = false;
        while (end < source.len) : (end += 1) {
            if (escaped) {
                escaped = false;
            } else if (source[end] == '\\') {
                escaped = true;
            } else if (source[end] == '"') {
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

fn projectInfoResult(server: *Server) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(server.allocator, '{');
    if (server.snapshot) |snapshot| {
        try out.appendSlice(server.allocator, "\"entryPath\":");
        try appendJsonString(server.allocator, &out, snapshot.entry_path);
        try out.appendSlice(server.allocator, ",\"assetBaseDir\":");
        try appendJsonString(server.allocator, &out, snapshot.asset_base_dir);
        try out.appendSlice(server.allocator, ",\"localModules\":[");
        for (snapshot.module_paths.items, 0..) |path, i| {
            if (i != 0) try out.append(server.allocator, ',');
            try appendJsonString(server.allocator, &out, path);
        }
        try out.append(server.allocator, ']');
    }
    try out.append(server.allocator, '}');
    return out.toOwnedSlice(server.allocator);
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

fn wordAtRequest(server: *Server, params: ?JsonValue) !?[]u8 {
    const p = params orelse return null;
    const doc_path = try docPathFromParams(server.allocator, params) orelse return null;
    defer server.allocator.free(doc_path);
    const pos_obj = objectField(p, "position") orelse return null;
    const line: usize = @intCast(@max(0, intField(pos_obj, "line") orelse 0));
    const character: usize = @intCast(@max(0, intField(pos_obj, "character") orelse 0));
    const source = server.sourceForPath(doc_path) orelse return null;
    return try wordAt(server.allocator, source, line, character);
}

fn wordAt(allocator: std.mem.Allocator, source: []const u8, target_line: usize, character: usize) !?[]u8 {
    var line_index: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| : (line_index += 1) {
        if (line_index != target_line) continue;
        const pos = @min(character, line.len);
        var start = pos;
        while (start > 0 and isIdentChar(line[start - 1])) start -= 1;
        var end = pos;
        while (end < line.len and isIdentChar(line[end])) end += 1;
        if (end <= start) return null;
        return try allocator.dupe(u8, line[start..end]);
    }
    return null;
}

fn isIdentChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
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
    const start = utils.err.computeLineColumn(source, @min(s.start, source.len));
    const end = utils.err.computeLineColumn(source, @min(@max(s.end, s.start + 1), source.len));
    return .{
        .start_line = start.line - 1,
        .start_character = start.column - 1,
        .end_line = end.line - 1,
        .end_character = end.column - 1,
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
    try out.appendSlice(allocator, "{\"uri\":");
    try appendJsonString(allocator, &out, uri);
    try out.appendSlice(allocator, ",\"range\":{\"start\":{\"line\":");
    try appendInt(allocator, &out, sl);
    try out.appendSlice(allocator, ",\"character\":");
    try appendInt(allocator, &out, sc);
    try out.appendSlice(allocator, "},\"end\":{\"line\":");
    try appendInt(allocator, &out, el);
    try out.appendSlice(allocator, ",\"character\":");
    try appendInt(allocator, &out, ec);
    try out.appendSlice(allocator, "}}}");
    return out.toOwnedSlice(allocator);
}

fn diagnosticCode(diagnostic: core.Diagnostic) []const u8 {
    return switch (diagnostic.data) {
        .user_report => "user_report",
        .asset_not_found => "asset_not_found",
        .asset_invalid => "asset_invalid",
        .type_mismatch => |data| @tagName(data.code),
        .recursive_function => "RecursiveFunction",
        .unresolved_frame => "unresolved_frame",
        .page_overflow => "page_overflow",
    };
}

fn formatParseDiagnostic(buf: []u8, diagnostic: anytype) []const u8 {
    return switch (diagnostic.err) {
        error.UnterminatedString => "UnterminatedString: unterminated string",
        error.UnterminatedEscape => "UnterminatedEscape: unterminated escape sequence",
        error.InvalidEscape => "InvalidEscape: invalid escape sequence",
        error.UnknownAnchor => "UnknownAnchor: unknown anchor name",
        error.AssignmentRequiresLet => "AssignmentRequiresLet: plain assignment statements are not supported; use 'let name = expr'",
        error.ZeroArgCallRequiresParens => "ZeroArgCallRequiresParens: zero-argument calls require parentheses; use 'name()'",
        else => blk: {
            const expected = diagnostic.expected orelse @errorName(diagnostic.err);
            const found = diagnostic.found orelse "unknown token";
            break :blk std.fmt.bufPrint(buf, "{s}: expected {s}, found {s}", .{ @errorName(diagnostic.err), expected, found }) catch @errorName(diagnostic.err);
        },
    };
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
    const module_id = intField(item, "moduleId") orelse return null;
    if (arrayFieldObject(root, "modules")) |modules| for (modules.items) |module| if (module == .object) {
        if ((intField(&module.object, "id") orelse -1) == module_id) {
            if (stringField(&module.object, "path")) |path| return try allocator.dupe(u8, path);
        }
    };
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
