const std = @import("std");
const model = @import("model");
const ast = @import("ast");
const source = @import("utils").source;

pub const SourceId = enum(u32) { _ };

pub const Source = struct {
    path: []const u8,
    text: []u8,
    previous: ?SourceId,
};

pub const Diagnostic = struct {
    source_id: SourceId,
    // These views borrow storage from the owning bag's source table.
    path: []const u8,
    source: []const u8,
    severity: model.DiagnosticSeverity,
    code: []u8,
    message: []u8,
    span: ?source.ByteSpan = null,
    caused_by: ?ast.HoleId = null,

    fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.message);
    }
};

pub const Bag = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,
    sources: std.ArrayList(Source) = .empty,
    by_path: std.StringHashMapUnmanaged(SourceId) = .empty,

    pub fn init(allocator: std.mem.Allocator) Bag {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Bag) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
        for (self.sources.items) |entry| {
            self.allocator.free(entry.path);
            self.allocator.free(entry.text);
        }
        self.sources.deinit(self.allocator);
        self.by_path.deinit(self.allocator);
    }

    /// Register each immutable source once before adding its diagnostics.
    /// Different versions of the same path keep distinct source identities.
    pub fn registerSource(self: *Bag, path: []const u8, text: []const u8) !SourceId {
        const previous = self.by_path.get(path);
        var candidate = previous;
        while (candidate) |id| {
            const entry = self.sources.items[@intFromEnum(id)];
            if (std.mem.eql(u8, entry.text, text)) return id;
            candidate = entry.previous;
        }
        try self.sources.ensureUnusedCapacity(self.allocator, 1);
        try self.by_path.ensureUnusedCapacity(self.allocator, 1);
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        const text_copy = try self.allocator.dupe(u8, text);
        const id: SourceId = @enumFromInt(self.sources.items.len);
        self.sources.appendAssumeCapacity(.{ .path = path_copy, .text = text_copy, .previous = previous });
        self.by_path.putAssumeCapacity(path_copy, id);
        return id;
    }

    pub fn add(self: *Bag, path: []const u8, text: []const u8, severity: model.DiagnosticSeverity, code: []const u8, message: []const u8, span: ?source.ByteSpan, caused_by: ?ast.HoleId) !void {
        try self.addAt(try self.registerSource(path, text), severity, code, message, span, caused_by);
    }

    pub fn addAt(self: *Bag, source_id: SourceId, severity: model.DiagnosticSeverity, code: []const u8, message: []const u8, span: ?source.ByteSpan, caused_by: ?ast.HoleId) !void {
        if (caused_by) |hole| {
            for (self.items.items) |item| {
                if (item.source_id == source_id and item.caused_by == hole) return;
            }
        }
        const code_copy = try self.allocator.dupe(u8, code);
        errdefer self.allocator.free(code_copy);
        const message_copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(message_copy);
        const text = self.sources.items[@intFromEnum(source_id)];
        try self.items.append(self.allocator, .{
            .source_id = source_id,
            .path = text.path,
            .source = text.text,
            .severity = severity,
            .code = code_copy,
            .message = message_copy,
            .span = span,
            .caused_by = caused_by,
        });
    }

    pub fn appendFrom(self: *Bag, other: *const Bag) !void {
        const ids = try self.allocator.alloc(SourceId, other.sources.items.len);
        defer self.allocator.free(ids);
        for (other.sources.items, ids) |entry, *id| id.* = try self.registerSource(entry.path, entry.text);
        for (other.items.items) |item| {
            try self.addAt(ids[@intFromEnum(item.source_id)], item.severity, item.code, item.message, item.span, item.caused_by);
        }
    }

    pub fn hasErrors(self: *const Bag) bool {
        for (self.items.items) |item| if (item.severity == .@"error") return true;
        return false;
    }

    pub fn sortByPath(self: *Bag) void {
        std.mem.sort(Diagnostic, self.items.items, {}, diagnosticLessThan);
    }

    pub fn itemsForPath(self: *const Bag, path: []const u8) []const Diagnostic {
        var start: ?usize = null;
        var end: usize = 0;
        for (self.items.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.path, path)) {
                if (start == null) start = index;
                end = index + 1;
                continue;
            }
            if (start != null) break;
        }
        return self.items.items[start orelse return &.{} .. end];
    }

    pub fn sourcesMatch(self: *const Bag, path: []const u8, text: []const u8) bool {
        var candidate = self.by_path.get(path);
        while (candidate) |id| {
            const entry = self.sources.items[@intFromEnum(id)];
            if (!std.mem.eql(u8, entry.text, text)) return false;
            candidate = entry.previous;
        }
        return true;
    }

    /// Position-only edits keep byte lengths and source identities unchanged.
    pub fn rebaseSource(self: *Bag, path: []const u8, text: []const u8) void {
        var candidate = self.by_path.get(path);
        while (candidate) |id| {
            const entry = self.sources.items[@intFromEnum(id)];
            std.debug.assert(entry.text.len == text.len);
            @memcpy(entry.text, text);
            candidate = entry.previous;
        }
    }
};

fn diagnosticLessThan(_: void, left: Diagnostic, right: Diagnostic) bool {
    const path_order = std.mem.order(u8, left.path, right.path);
    if (path_order != .eq) return path_order == .lt;
    const left_start = if (left.span) |span| span.start else 0;
    const right_start = if (right.span) |span| span.start else 0;
    if (left_start != right_start) return left_start < right_start;
    return std.mem.lessThan(u8, left.code, right.code);
}
