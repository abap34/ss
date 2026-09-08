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

    /// Checks every unchanged interval once, accepting replacements in either source order.
    pub fn onlyChangesOffsets(self: *const Edit) bool {
        if (self.base_source.len != self.source.len) return false;
        var cursor: usize = 0;
        for (0..self.replacements.len) |_| {
            var next: ?utils.source.ByteSpan = null;
            for (self.replacements) |replacement| {
                const span = replacement.offset_span;
                if (span.start < cursor) continue;
                if (next == null or span.start < next.?.start) next = span;
            }
            const span = next orelse return false;
            if (span.end <= span.start or span.end > self.source.len) return false;
            if (!std.mem.eql(u8, self.base_source[cursor..span.start], self.source[cursor..span.start])) return false;
            const before = self.base_source[span.start..span.end];
            const after = self.source[span.start..span.end];
            if (std.mem.indexOfScalar(u8, before, '\n') != null or
                std.mem.indexOfScalar(u8, after, '\n') != null or std.mem.eql(u8, before, after)) return false;
            cursor = span.end;
        }
        return std.mem.eql(u8, self.base_source[cursor..], self.source[cursor..]);
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
                if (replacement.expected.origin) |origin| allocator.free(origin);
            }
            replacements.deinit(allocator);
        }
        for (edit.replacements) |replacement| {
            var owned = replacement;
            owned.expected.origin = if (replacement.expected.origin) |origin|
                try allocator.dupe(u8, origin)
            else
                null;
            errdefer if (owned.expected.origin) |origin| allocator.free(origin);
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
            if (replacement.expected.origin) |origin| allocator.free(origin);
        }
        allocator.free(self.replacements);
        self.* = undefined;
    }
};
