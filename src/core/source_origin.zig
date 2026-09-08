const std = @import("std");

pub const Span = struct {
    start: usize,
    end: usize,
};

/// A source reference borrows its strings. Independent owners use clone/deinit.
pub const Origin = struct {
    path: ?[]const u8 = null,
    span: ?Span = null,
    label: ?[]const u8 = null,

    pub const Location = struct {
        path: ?[]const u8,
        span: Span,
    };

    pub fn at(path: []const u8, span: Span) Origin {
        return .{ .path = if (path.len == 0) null else path, .span = span };
    }

    pub fn withSpan(self: Origin, span: Span) Origin {
        var result = self;
        result.span = span;
        return result;
    }

    pub fn location(self: Origin) ?Location {
        return .{ .path = self.path, .span = self.span orelse return null };
    }

    pub fn clone(self: Origin, allocator: std.mem.Allocator) !Origin {
        const path = if (self.path) |text| try allocator.dupe(u8, text) else null;
        errdefer if (path) |text| allocator.free(text);
        return .{
            .path = path,
            .span = self.span,
            .label = if (self.label) |text| try allocator.dupe(u8, text) else null,
        };
    }

    pub fn deinit(self: Origin, allocator: std.mem.Allocator) void {
        if (self.path) |text| allocator.free(text);
        if (self.label) |text| allocator.free(text);
    }

    pub fn eql(self: Origin, other: Origin) bool {
        return stringEql(self.path, other.path) and stringEql(self.label, other.label) and
            std.meta.eql(self.span, other.span);
    }

    pub fn optionalEql(left: ?Origin, right: ?Origin) bool {
        if (left) |value| return if (right) |other| value.eql(other) else false;
        return right == null;
    }

    /// Human-readable source references are produced only at output boundaries.
    pub fn format(self: Origin, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.path) |path| try writer.print("path:{s}", .{path});
        if (self.span) |span| {
            if (self.path != null) try writer.writeByte(':');
            try writer.print("bytes:{d}-{d}", .{ span.start, span.end });
        }
        if (self.label) |label| {
            if (self.path != null or self.span != null) try writer.writeByte(':');
            try writer.writeAll(label);
        }
    }

    fn stringEql(left: ?[]const u8, right: ?[]const u8) bool {
        if (left) |text| return if (right) |other| std.mem.eql(u8, text, other) else false;
        return right == null;
    }
};
