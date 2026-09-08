const std = @import("std");
const CaptureRole = @import("utils").highlight.CaptureRole;

pub const Span = struct {
    start: usize,
    end: usize,
    role: CaptureRole,
};

pub const Segment = struct {
    start: usize,
    end: usize,
    role: ?CaptureRole,
};

const Boundary = struct {
    position: usize,
    span: usize,
    begins: bool,

    fn lessThan(_: void, left: Boundary, right: Boundary) bool {
        return left.position < right.position;
    }
};

fn precedence(spans: []const Span, left_index: usize, right_index: usize) std.math.Order {
    const left = spans[left_index];
    const right = spans[right_index];
    const length_order = std.math.order(left.end - left.start, right.end - right.start);
    if (length_order != .eq) return length_order;
    const start_order = std.math.order(right.start, left.start);
    if (start_order != .eq) return start_order;
    // The original ordered scan lets the last equal-range capture win.
    return std.math.order(right_index, left_index);
}

pub fn compile(allocator: std.mem.Allocator, spans: []const Span, content_end: usize) ![]Segment {
    var boundaries = std.ArrayList(Boundary).empty;
    defer boundaries.deinit(allocator);
    for (spans, 0..) |span, index| {
        if (span.start >= span.end or span.end > content_end) continue;
        try boundaries.append(allocator, .{ .position = span.start, .span = index, .begins = true });
        try boundaries.append(allocator, .{ .position = span.end, .span = index, .begins = false });
    }
    std.mem.sort(Boundary, boundaries.items, {}, Boundary.lessThan);
    var active = std.PriorityQueue(usize, []const Span, precedence).initContext(spans);
    defer active.deinit(allocator);
    var result = std.ArrayList(Segment).empty;
    errdefer result.deinit(allocator);
    var position: usize = 0;
    var boundary: usize = 0;
    while (position < content_end) {
        while (boundary < boundaries.items.len and boundaries.items[boundary].position == position) : (boundary += 1) {
            const event = boundaries.items[boundary];
            if (event.begins) try active.push(allocator, event.span);
        }
        while (active.peek()) |index| {
            if (spans[index].end > position) break;
            _ = active.pop();
        }
        const next = if (boundary < boundaries.items.len) boundaries.items[boundary].position else content_end;
        try result.append(allocator, .{
            .start = position,
            .end = next,
            .role = if (active.peek()) |index| spans[index].role else null,
        });
        position = next;
    }
    return result.toOwnedSlice(allocator);
}

// One cursor crosses all lines, including skipped CR/LF bytes. Capture
// boundaries remain separate even when adjacent segments share the same role.
pub const Cursor = struct {
    segments: []const Segment,
    index: usize = 0,

    pub fn next(self: *Cursor, start: usize, line_end: usize) ?Segment {
        if (start >= line_end) return null;
        while (self.index < self.segments.len and self.segments[self.index].end <= start) self.index += 1;
        if (self.index == self.segments.len) return null;
        const segment = self.segments[self.index];
        const end = @min(segment.end, line_end);
        if (end == segment.end) self.index += 1;
        return .{ .start = @max(segment.start, start), .end = end, .role = segment.role };
    }
};
