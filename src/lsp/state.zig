const std = @import("std");
const analysis_snapshot = @import("../analysis/snapshot.zig");
const module_loader = @import("../modules/loader.zig");
const project = @import("project");
const utils = @import("utils");

const protocol = @import("protocol.zig");

const source = utils.source;

pub const JsonValue = protocol.JsonValue;
pub const AnalysisSnapshot = analysis_snapshot.AnalysisSnapshot;

const OpenDocument = struct {
    text: []u8,
    line_index: source.LineIndex,

    fn init(allocator: std.mem.Allocator, text: []u8) !OpenDocument {
        return .{ .text = text, .line_index = try source.LineIndex.init(allocator, text) };
    }

    fn deinit(self: OpenDocument, allocator: std.mem.Allocator) void {
        self.line_index.deinit(allocator);
        allocator.free(self.text);
    }
};

pub const DocumentStore = struct {
    allocator: std.mem.Allocator,
    items: std.StringHashMap(OpenDocument),
    versions: std.StringHashMap(i64),
    generation: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) DocumentStore {
        return .{
            .allocator = allocator,
            .items = std.StringHashMap(OpenDocument).init(allocator),
            .versions = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *DocumentStore) void {
        var it = self.items.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.items.deinit();
        var version_iterator = self.versions.iterator();
        while (version_iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.versions.deinit();
    }

    pub fn replaceUri(self: *DocumentStore, uri: []const u8, text: []const u8, version: ?i64) ![]u8 {
        const path = try self.absolutePathFromUri(uri);
        errdefer self.allocator.free(path);
        try self.replacePath(path, text);
        if (version) |value| try self.setVersionAtPath(path, value);
        return path;
    }

    pub fn applyChangesAtPath(self: *DocumentStore, path: []const u8, changes: *const protocol.JsonArray) !bool {
        if (changes.items.len == 0) return error.InvalidParams;
        const original = self.items.get(path);
        var current: ?OpenDocument = null;
        defer if (current) |document| document.deinit(self.allocator);

        for (changes.items) |*change| {
            if (change.* != .object) return error.InvalidParams;
            const old_index = if (current) |document| document.line_index else if (original) |document| document.line_index else source.LineIndex.empty;
            const next_text = try applyChange(self.allocator, old_index, &change.object);
            const next = OpenDocument.init(self.allocator, next_text) catch |err| {
                self.allocator.free(next_text);
                return err;
            };
            if (current) |document| document.deinit(self.allocator);
            current = next;
        }

        const original_text = if (original) |document| document.text else "";
        if (std.mem.eql(u8, original_text, current.?.text)) return false;
        try self.putOwned(path, current.?);
        current = null;
        self.generation += 1;
        return true;
    }

    pub fn removeUri(self: *DocumentStore, uri: []const u8) ?[]u8 {
        const path = self.absolutePathFromUri(uri) catch return null;
        if (self.items.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            entry.value.deinit(self.allocator);
            self.generation += 1;
        }
        if (self.versions.fetchRemove(path)) |entry| self.allocator.free(entry.key);
        return path;
    }

    pub fn sourceForPath(self: *DocumentStore, path: []const u8) ?[]const u8 {
        return if (self.indexForPath(path)) |index| index.text else null;
    }

    pub fn indexForPath(self: *DocumentStore, path: []const u8) ?source.LineIndex {
        const absolute = project.absolutePath(self.allocator, path) catch return null;
        defer self.allocator.free(absolute);
        const document = self.items.get(absolute) orelse return null;
        return document.line_index;
    }

    pub fn fillOverlay(self: *DocumentStore, overlay: *module_loader.SourceOverlay) !void {
        var it = self.items.iterator();
        while (it.next()) |entry| {
            try overlay.put(entry.key_ptr.*, entry.value_ptr.text);
        }
    }

    pub fn setVersionAtPath(self: *DocumentStore, path: []const u8, version: i64) !void {
        if (self.versions.getPtr(path)) |current| {
            current.* = version;
            return;
        }
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.versions.put(owned_path, version);
    }

    pub fn versionForPath(self: *const DocumentStore, path: []const u8) ?i64 {
        const absolute = project.absolutePath(self.allocator, path) catch return null;
        defer self.allocator.free(absolute);
        return self.versions.get(absolute);
    }

    pub fn versionForUri(self: *const DocumentStore, uri: []const u8) ?i64 {
        const path = protocol.pathFromUri(self.allocator, uri) catch return null;
        defer self.allocator.free(path);
        return self.versionForPath(path);
    }

    pub fn iterator(self: *DocumentStore) std.StringHashMap(OpenDocument).Iterator {
        return self.items.iterator();
    }

    pub fn absolutePathFromUri(self: *DocumentStore, uri: []const u8) ![]u8 {
        const decoded = try protocol.pathFromUri(self.allocator, uri);
        defer self.allocator.free(decoded);
        return try project.absolutePath(self.allocator, decoded);
    }

    fn replacePath(self: *DocumentStore, path: []const u8, text: []const u8) !void {
        if (self.items.get(path)) |current| {
            if (std.mem.eql(u8, current.text, text)) return;
        }
        const document_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(document_text);
        const document = try OpenDocument.init(self.allocator, document_text);
        errdefer document.line_index.deinit(self.allocator);
        try self.putOwned(path, document);
        self.generation += 1;
    }

    fn putOwned(self: *DocumentStore, path: []const u8, document: OpenDocument) !void {
        if (self.items.getPtr(path)) |existing| {
            existing.deinit(self.allocator);
            existing.* = document;
            return;
        }
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        try self.items.put(key, document);
    }
};

pub const RequestPosition = struct {
    doc_path: []u8,
    source: []const u8,
    offset: usize,
    line: usize,
    character: usize,

    pub fn deinit(self: *RequestPosition, allocator: std.mem.Allocator) void {
        allocator.free(self.doc_path);
    }
};

pub const DocumentText = struct {
    path: []u8,
    source: []const u8,
    line_index: source.LineIndex,
    owned_source: ?[]u8 = null,

    pub fn deinit(self: *DocumentText, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.owned_source) |text| {
            self.line_index.deinit(allocator);
            allocator.free(text);
        }
    }
};

pub fn requestPosition(
    allocator: std.mem.Allocator,
    documents: *DocumentStore,
    params: ?JsonValue,
) !?RequestPosition {
    const p = params orelse return error.InvalidParams;
    const doc_path = try protocol.docPathFromParams(allocator, params) orelse return error.InvalidParams;
    errdefer allocator.free(doc_path);
    const pos_obj = protocol.objectField(p, "position") orelse return error.InvalidParams;
    const line = try protocol.lspLine(pos_obj);
    const character = try protocol.lspCharacter(pos_obj);
    const index = documents.indexForPath(doc_path) orelse {
        allocator.free(doc_path);
        return null;
    };
    return .{
        .doc_path = doc_path,
        .source = index.text,
        .offset = index.offsetForUtf16Position(line, character),
        .line = line,
        .character = character,
    };
}

fn applyChange(allocator: std.mem.Allocator, old_index: source.LineIndex, change: *const protocol.JsonObject) ![]u8 {
    const old_source = old_index.text;
    const text = protocol.stringField(change, "text") orelse return error.InvalidParams;
    const range_value = utils.json.fieldValue(change, "range") orelse return allocator.dupe(u8, text);
    if (range_value.* != .object) return error.InvalidParams;
    const range = &range_value.object;
    const start = protocol.objectFieldObject(range, "start") orelse return error.InvalidParams;
    const end = protocol.objectFieldObject(range, "end") orelse return error.InvalidParams;
    const start_offset = old_index.offsetForUtf16Position(try protocol.lspLine(start), try protocol.lspCharacter(start));
    const end_offset = old_index.offsetForUtf16Position(try protocol.lspLine(end), try protocol.lspCharacter(end));
    if (end_offset < start_offset) return error.InvalidParams;

    var next = std.ArrayList(u8).empty;
    errdefer next.deinit(allocator);
    try next.appendSlice(allocator, old_source[0..start_offset]);
    try next.appendSlice(allocator, text);
    try next.appendSlice(allocator, old_source[end_offset..]);
    return next.toOwnedSlice(allocator);
}

pub fn documentTextFromParams(
    io: std.Io,
    allocator: std.mem.Allocator,
    documents: *DocumentStore,
    params: ?JsonValue,
) !?DocumentText {
    const doc_path = try protocol.docPathFromParams(allocator, params) orelse return null;
    errdefer allocator.free(doc_path);
    if (documents.indexForPath(doc_path)) |index| {
        return .{ .path = doc_path, .source = index.text, .line_index = index };
    }
    const owned = utils.fs.readFileAlloc(io, allocator, doc_path) catch {
        allocator.free(doc_path);
        return null;
    };
    errdefer allocator.free(owned);
    return .{ .path = doc_path, .source = owned, .line_index = try source.LineIndex.init(allocator, owned), .owned_source = owned };
}

pub const Feature = enum {
    completion,
    hover,
    definition,
    document_symbols,
    folding_ranges,
    semantic_tokens,
    colors,
};

pub fn featureEnabledInConfig(cfg: project.LspConfig, feature: Feature) bool {
    if (!cfg.enabled) return false;
    return switch (feature) {
        .completion => cfg.completion,
        .hover => cfg.hover,
        .definition => cfg.definition,
        .document_symbols => cfg.document_symbols,
        .folding_ranges => cfg.folding_ranges,
        .semantic_tokens => cfg.semantic_tokens,
        .colors => cfg.colors,
    };
}

pub fn featureEnabledForAnalysis(snapshot: *const AnalysisSnapshot, feature: Feature) bool {
    return featureEnabledInConfig(snapshot.project.lsp, feature);
}

pub fn featureEnabledForCurrent(snapshot: ?*const AnalysisSnapshot, feature: Feature) bool {
    const cfg = if (snapshot) |value| value.project.lsp else project.LspConfig{};
    return featureEnabledInConfig(cfg, feature);
}

pub const AnalysisProvider = struct {
    context: *anyopaque,
    current: ?*AnalysisSnapshot,
    generation: u64,
    cancellation: ?utils.Cancellation = null,
    build: *const fn (context: *anyopaque, path: []const u8) anyerror!AnalysisSnapshot,

    pub fn forDocument(self: *AnalysisProvider, doc_path: []const u8, owned_snapshot: *?AnalysisSnapshot) !?*AnalysisSnapshot {
        if (self.current) |snapshot| {
            if (snapshot.generation == self.generation and snapshot.coversPath(doc_path)) return snapshot;
        }
        owned_snapshot.* = try self.build(self.context, doc_path);
        if (owned_snapshot.*) |*snapshot| return snapshot;
        return null;
    }
};

pub const CachedResponse = struct {
    entry_path: []u8,
    generation: u64,
    json: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        entry_path: []const u8,
        generation: u64,
        json: []const u8,
    ) !CachedResponse {
        const owned_entry_path = try allocator.dupe(u8, entry_path);
        errdefer allocator.free(owned_entry_path);
        return .{
            .entry_path = owned_entry_path,
            .generation = generation,
            .json = try allocator.dupe(u8, json),
        };
    }

    pub fn deinit(self: *CachedResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_path);
        allocator.free(self.json);
        self.* = .{ .entry_path = &.{}, .generation = 0, .json = &.{} };
    }

    pub fn matchesEntry(self: *const CachedResponse, entry_path: []const u8) bool {
        return std.mem.eql(u8, self.entry_path, entry_path);
    }

    pub fn cloneJson(self: *const CachedResponse, allocator: std.mem.Allocator) ![]u8 {
        return try allocator.dupe(u8, self.json);
    }
};

pub const ResponseStore = struct {
    items: std.ArrayList(CachedResponse) = .empty,
    total_bytes: usize = 0,

    const max_entries = 16;
    const max_bytes = 64 * 1024 * 1024;

    pub fn deinit(self: *ResponseStore, allocator: std.mem.Allocator) void {
        for (self.items.items) |*response| response.deinit(allocator);
        self.items.deinit(allocator);
        self.* = .{};
    }

    pub fn store(self: *ResponseStore, allocator: std.mem.Allocator, snapshot: *const AnalysisSnapshot, json: []const u8) !void {
        if (json.len > max_bytes) return;
        for (self.items.items, 0..) |*response, index| {
            if (!response.matchesEntry(snapshot.project.entry_path)) continue;
            if (response.generation == snapshot.generation and std.mem.eql(u8, response.json, json)) {
                return;
            }
            var next = try CachedResponse.init(
                allocator,
                snapshot.project.entry_path,
                snapshot.generation,
                json,
            );
            errdefer next.deinit(allocator);
            const remaining_bytes = self.total_bytes - response.json.len;
            if (remaining_bytes > max_bytes - next.json.len) {
                self.clear(allocator);
                try self.items.append(allocator, next);
                self.total_bytes = next.json.len;
                return;
            }
            self.total_bytes = remaining_bytes + next.json.len;
            response.deinit(allocator);
            self.items.items[index] = next;
            return;
        }
        var next = try CachedResponse.init(
            allocator,
            snapshot.project.entry_path,
            snapshot.generation,
            json,
        );
        errdefer next.deinit(allocator);
        if (self.items.items.len >= max_entries or self.total_bytes > max_bytes - next.json.len) {
            self.clear(allocator);
        }
        try self.items.append(allocator, next);
        self.total_bytes += next.json.len;
    }

    pub fn cloneForEntry(self: *const ResponseStore, allocator: std.mem.Allocator, entry_path: []const u8) !?[]const u8 {
        for (self.items.items) |*response| {
            if (response.matchesEntry(entry_path)) return try response.cloneJson(allocator);
        }
        return null;
    }

    fn clear(self: *ResponseStore, allocator: std.mem.Allocator) void {
        for (self.items.items) |*response| response.deinit(allocator);
        self.items.clearRetainingCapacity();
        self.total_bytes = 0;
    }
};

pub fn deinitStringSet(allocator: std.mem.Allocator, set: *std.StringHashMap(void)) void {
    var iterator = set.iterator();
    while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
    set.deinit();
}
