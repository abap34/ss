const std = @import("std");
const model = @import("model");
const utils = @import("utils");

pub const Mode = enum {
    absolute,
    relative,
    width,
};

pub const Replacement = struct {
    index: usize,
    expected: model.Constraint,
    offset_span: utils.source.ByteSpan,
    new_length: usize,
    literal_scale: f32,
    new_offset: f32,
};

pub const Edit = struct {
    path: []const u8,
    base_source: []const u8,
    source: []const u8,
    base_generation: u64,
    base_snapshot_id: []const u8,
    node_id: model.NodeId,
    page_id: model.NodeId,
    mode: Mode,
    replacements: []const Replacement,

    /// Validate the entire edit, including unchanged intervals and insertion points.
    pub fn onlyChangesOffsets(self: *const Edit) bool {
        var old_cursor: usize = 0;
        var new_cursor: usize = 0;
        var previous_start: ?usize = null;
        for (0..self.replacements.len) |_| {
            var next: ?Replacement = null;
            for (self.replacements) |replacement| {
                if (previous_start) |start| if (replacement.offset_span.start <= start) continue;
                if (next == null or replacement.offset_span.start < next.?.offset_span.start) next = replacement;
            }
            const replacement = next orelse return false;
            const span = replacement.offset_span;
            if (span.start < old_cursor or span.end < span.start or span.end > self.base_source.len) return false;
            const unchanged = span.start - old_cursor;
            const new_start = std.math.add(usize, new_cursor, unchanged) catch return false;
            const new_end = std.math.add(usize, new_start, replacement.new_length) catch return false;
            if (new_end > self.source.len) return false;
            if (!std.mem.eql(u8, self.base_source[old_cursor..span.start], self.source[new_cursor..new_start])) return false;
            const before = self.base_source[span.start..span.end];
            const after = self.source[new_start..new_end];
            if (std.mem.indexOfScalar(u8, before, '\n') != null or
                std.mem.indexOfScalar(u8, after, '\n') != null or std.mem.eql(u8, before, after)) return false;
            old_cursor = span.end;
            new_cursor = new_end;
            previous_start = span.start;
        }
        return std.mem.eql(u8, self.base_source[old_cursor..], self.source[new_cursor..]);
    }

    pub fn replacementSpan(self: *const Edit, replacement: Replacement) utils.source.ByteSpan {
        var start = replacement.offset_span.start;
        for (self.replacements) |other| {
            if (other.offset_span.start >= replacement.offset_span.start) continue;
            start = start - (other.offset_span.end - other.offset_span.start) + other.new_length;
        }
        return .{ .start = start, .end = start + replacement.new_length };
    }

    pub fn mapOffset(self: *const Edit, offset: usize) usize {
        if (offset == std.math.maxInt(usize)) return offset;
        var result = offset;
        for (self.replacements) |replacement| {
            const span = replacement.offset_span;
            if (offset >= span.end) result = result - (span.end - span.start) + replacement.new_length;
        }
        return result;
    }

    pub fn mapSpan(self: *const Edit, span: utils.source.ByteSpan) utils.source.ByteSpan {
        return .{ .start = self.mapOffset(span.start), .end = self.mapOffset(span.end) };
    }

    pub fn clone(edit: *const Edit, allocator: std.mem.Allocator) !Edit {
        const path = try allocator.dupe(u8, edit.path);
        errdefer allocator.free(path);
        const base_source = try allocator.dupe(u8, edit.base_source);
        errdefer allocator.free(base_source);
        const source = try allocator.dupe(u8, edit.source);
        errdefer allocator.free(source);
        const base_snapshot_id = try allocator.dupe(u8, edit.base_snapshot_id);
        errdefer allocator.free(base_snapshot_id);
        var replacements = std.ArrayList(Replacement).empty;
        errdefer {
            for (replacements.items) |replacement| {
                if (replacement.expected.origin) |origin| origin.deinit(allocator);
            }
            replacements.deinit(allocator);
        }
        for (edit.replacements) |replacement| {
            var owned = replacement;
            owned.expected.origin = if (replacement.expected.origin) |origin|
                try origin.clone(allocator)
            else
                null;
            errdefer if (owned.expected.origin) |origin| origin.deinit(allocator);
            try replacements.append(allocator, owned);
        }
        return .{
            .path = path,
            .base_source = base_source,
            .source = source,
            .base_generation = edit.base_generation,
            .base_snapshot_id = base_snapshot_id,
            .node_id = edit.node_id,
            .page_id = edit.page_id,
            .mode = edit.mode,
            .replacements = try replacements.toOwnedSlice(allocator),
        };
    }

    /// Releases the owned strings and replacements returned by clone.
    pub fn deinit(self: *Edit, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.base_source);
        allocator.free(self.source);
        allocator.free(self.base_snapshot_id);
        for (self.replacements) |replacement| {
            if (replacement.expected.origin) |origin| origin.deinit(allocator);
        }
        allocator.free(self.replacements);
        self.* = undefined;
    }
};
