const std = @import("std");
const analysis_snapshot = @import("../analysis/snapshot.zig");
const module_loader = @import("../modules/loader.zig");
const project = @import("../project.zig");
const utils = @import("utils");

const protocol = @import("protocol.zig");

const source = utils.source;

pub const JsonValue = protocol.JsonValue;
pub const Snapshot = analysis_snapshot.AnalysisSnapshot;

pub const DocumentStore = struct {
    allocator: std.mem.Allocator,
    items: std.StringHashMap([]u8),
    generation: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) DocumentStore {
        return .{
            .allocator = allocator,
            .items = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *DocumentStore) void {
        var it = self.items.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.items.deinit();
    }

    pub fn replaceUri(self: *DocumentStore, uri: []const u8, text: []const u8) ![]u8 {
        const path = try self.absolutePathFromUri(uri);
        errdefer self.allocator.free(path);
        try self.replacePath(path, text);
        return path;
    }

    pub fn applyChangeAtPath(self: *DocumentStore, path: []const u8, change: *const protocol.JsonObject) !void {
        const text = protocol.stringField(change, "text") orelse "";
        const range = protocol.objectFieldObject(change, "range") orelse {
            try self.replacePath(path, text);
            return;
        };
        const start = protocol.objectFieldObject(range, "start") orelse {
            try self.replacePath(path, text);
            return;
        };
        const end = protocol.objectFieldObject(range, "end") orelse {
            try self.replacePath(path, text);
            return;
        };

        const old_source = self.items.get(path) orelse "";
        const start_offset = source.offsetForUtf16Position(old_source, protocol.lspLine(start), protocol.lspCharacter(start));
        const end_offset = source.offsetForUtf16Position(old_source, protocol.lspLine(end), protocol.lspCharacter(end));
        if (end_offset < start_offset) return error.InvalidLspRange;

        var next = std.ArrayList(u8).empty;
        errdefer next.deinit(self.allocator);
        try next.appendSlice(self.allocator, old_source[0..start_offset]);
        try next.appendSlice(self.allocator, text);
        try next.appendSlice(self.allocator, old_source[end_offset..]);
        const document_text = try next.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(document_text);

        try self.putOwned(path, document_text);
        self.generation += 1;
    }

    pub fn removeUri(self: *DocumentStore, uri: []const u8) ?[]u8 {
        const path = self.absolutePathFromUri(uri) catch return null;
        if (self.items.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
            self.generation += 1;
        }
        return path;
    }

    pub fn sourceForPath(self: *DocumentStore, path: []const u8) ?[]const u8 {
        const absolute = project.absolutePath(self.allocator, path) catch return null;
        defer self.allocator.free(absolute);
        return self.items.get(absolute);
    }

    pub fn fillOverlay(self: *DocumentStore, overlay: *module_loader.SourceOverlay) !void {
        var it = self.items.iterator();
        while (it.next()) |entry| {
            try overlay.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    pub fn iterator(self: *DocumentStore) std.StringHashMap([]u8).Iterator {
        return self.items.iterator();
    }

    pub fn absolutePathFromUri(self: *DocumentStore, uri: []const u8) ![]u8 {
        const decoded = try protocol.pathFromUri(self.allocator, uri);
        defer self.allocator.free(decoded);
        return try project.absolutePath(self.allocator, decoded);
    }

    fn replacePath(self: *DocumentStore, path: []const u8, text: []const u8) !void {
        const document_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(document_text);
        try self.putOwned(path, document_text);
        self.generation += 1;
    }

    fn putOwned(self: *DocumentStore, path: []const u8, document_text: []u8) !void {
        if (self.items.getPtr(path)) |existing| {
            self.allocator.free(existing.*);
            existing.* = document_text;
            return;
        }
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        try self.items.put(key, document_text);
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
    owned_source: ?[]u8 = null,

    pub fn deinit(self: *DocumentText, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.owned_source) |text| allocator.free(text);
    }
};

pub fn requestPosition(
    allocator: std.mem.Allocator,
    documents: *DocumentStore,
    params: ?JsonValue,
) !?RequestPosition {
    const p = params orelse return null;
    const doc_path = try protocol.docPathFromParams(allocator, params) orelse return null;
    errdefer allocator.free(doc_path);
    const pos_obj = protocol.objectField(p, "position") orelse {
        allocator.free(doc_path);
        return null;
    };
    const line: usize = @intCast(@max(0, protocol.intField(pos_obj, "line") orelse 0));
    const character: usize = @intCast(@max(0, protocol.intField(pos_obj, "character") orelse 0));
    const text = documents.sourceForPath(doc_path) orelse {
        allocator.free(doc_path);
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

pub fn documentTextFromParams(
    io: std.Io,
    allocator: std.mem.Allocator,
    documents: *DocumentStore,
    params: ?JsonValue,
) !?DocumentText {
    const doc_path = try protocol.docPathFromParams(allocator, params) orelse return null;
    errdefer allocator.free(doc_path);
    if (documents.sourceForPath(doc_path)) |text| {
        return .{ .path = doc_path, .source = text };
    }
    const owned = utils.fs.readFileAlloc(io, allocator, doc_path) catch return null;
    errdefer allocator.free(owned);
    return .{ .path = doc_path, .source = owned, .owned_source = owned };
}

pub const Feature = enum {
    completion,
    hover,
    definition,
    inlay_hints,
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
        .inlay_hints => cfg.inlay_hints,
        .document_symbols => cfg.document_symbols,
        .folding_ranges => cfg.folding_ranges,
        .semantic_tokens => cfg.semantic_tokens,
        .colors => cfg.colors,
    };
}

pub fn featureEnabledForSnapshot(snapshot: *const Snapshot, feature: Feature) bool {
    return featureEnabledInConfig(snapshot.project.lsp, feature);
}

pub fn featureEnabledForCurrent(snapshot: ?*const Snapshot, feature: Feature) bool {
    const cfg = if (snapshot) |value| value.project.lsp else project.LspConfig{};
    return featureEnabledInConfig(cfg, feature);
}

pub const SnapshotProvider = struct {
    context: *anyopaque,
    current: ?*Snapshot,
    generation: u64,
    build: *const fn (context: *anyopaque, path: []const u8) anyerror!Snapshot,

    pub fn forDocument(self: *SnapshotProvider, doc_path: []const u8, owned_snapshot: *?Snapshot) !?*Snapshot {
        if (self.current) |snapshot| {
            if (snapshot.generation == self.generation and snapshot.coversPath(doc_path)) return snapshot;
        }
        owned_snapshot.* = try self.build(self.context, doc_path);
        if (owned_snapshot.*) |*snapshot| return snapshot;
        return null;
    }
};

pub const LayoutSnapshot = struct {
    entry_path: []u8,
    generation: u64,
    json: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        entry_path: []const u8,
        generation: u64,
        json: []const u8,
    ) !LayoutSnapshot {
        const owned_entry_path = try allocator.dupe(u8, entry_path);
        errdefer allocator.free(owned_entry_path);
        return .{
            .entry_path = owned_entry_path,
            .generation = generation,
            .json = try allocator.dupe(u8, json),
        };
    }

    pub fn deinit(self: *LayoutSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_path);
        allocator.free(self.json);
        self.* = .{ .entry_path = &.{}, .generation = 0, .json = &.{} };
    }

    pub fn matchesEntry(self: *const LayoutSnapshot, entry_path: []const u8) bool {
        return std.mem.eql(u8, self.entry_path, entry_path);
    }

    pub fn cloneJson(self: *const LayoutSnapshot, allocator: std.mem.Allocator) ![]u8 {
        return try allocator.dupe(u8, self.json);
    }
};

pub const LayoutStore = struct {
    last_good: ?LayoutSnapshot = null,

    pub fn deinit(self: *LayoutStore, allocator: std.mem.Allocator) void {
        if (self.last_good) |*layout| layout.deinit(allocator);
        self.last_good = null;
    }

    pub fn remember(self: *LayoutStore, allocator: std.mem.Allocator, snapshot: *const Snapshot, json: []const u8) !void {
        const next = try LayoutSnapshot.init(
            allocator,
            snapshot.project.entry_path,
            snapshot.generation,
            json,
        );
        if (self.last_good) |*layout| layout.deinit(allocator);
        self.last_good = next;
    }

    pub fn jsonForEntry(self: *const LayoutStore, allocator: std.mem.Allocator, entry_path: []const u8) !?[]const u8 {
        const layout = if (self.last_good) |*value| value else return null;
        if (!layout.matchesEntry(entry_path)) return null;
        return try layout.cloneJson(allocator);
    }
};

pub fn deinitStringSet(allocator: std.mem.Allocator, set: *std.StringHashMap(void)) void {
    var iterator = set.iterator();
    while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
    set.deinit();
}
