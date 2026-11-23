const std = @import("std");
const syntax = @import("../syntax.zig");
const scanner = @import("../syntax/scanner.zig");
const source = @import("utils").source;

/// Retain unaffected declaration anchors while incomplete syntax makes a later
/// page look like part of a string. A complete parse confirms real removals.
pub fn collect(allocator: std.mem.Allocator, text: []const u8, previous_text: []const u8, previous_starts: []const usize) ![]usize {
    var current: std.ArrayList(usize) = .empty;
    defer current.deinit(allocator);
    var headers = scanner.pageHeaders(text);
    while (headers.next()) |header| try current.append(allocator, header.span.start);
    if (previous_starts.len == 0) return current.toOwnedSlice(allocator);

    const shared_length = @min(text.len, previous_text.len);
    var prefix: usize = 0;
    while (prefix < shared_length and text[prefix] == previous_text[prefix]) prefix += 1;
    var suffix: usize = 0;
    while (suffix < shared_length - prefix and text[text.len - suffix - 1] == previous_text[previous_text.len - suffix - 1]) suffix += 1;

    var retained: std.ArrayList(usize) = .empty;
    defer retained.deinit(allocator);
    var current_index: usize = 0;
    for (previous_starts) |old_start| {
        const start = if (old_start + 4 <= prefix) old_start else if (old_start >= previous_text.len - suffix)
            text.len - (previous_text.len - old_start)
        else
            continue;
        if (!isPageKeyword(text, start)) continue;
        while (current_index < current.items.len and current.items[current_index] < start) current_index += 1;
        if (current_index < current.items.len and current.items[current_index] == start) continue;
        try retained.append(allocator, start);
    }
    if (retained.items.len == 0 or try parsesCompletely(allocator, text)) return current.toOwnedSlice(allocator);

    var merged = try std.ArrayList(usize).initCapacity(allocator, current.items.len + retained.items.len);
    errdefer merged.deinit(allocator);
    var i: usize = 0;
    var j: usize = 0;
    while (i < current.items.len or j < retained.items.len) {
        if (j == retained.items.len or (i < current.items.len and current.items[i] < retained.items[j])) {
            merged.appendAssumeCapacity(current.items[i]);
            i += 1;
        } else {
            merged.appendAssumeCapacity(retained.items[j]);
            j += 1;
        }
    }
    return merged.toOwnedSlice(allocator);
}

fn isPageKeyword(text: []const u8, start: usize) bool {
    if (!source.startsWithAt(text, start, "page")) return false;
    const end = start + 4;
    if (end < text.len and !source.isInlineSpace(text[end]) and text[end] != '\n' and text[end] != '"') return false;
    var cursor = start;
    while (cursor > 0 and text[cursor - 1] != '\n') {
        cursor -= 1;
        if (!source.isInlineSpace(text[cursor])) return false;
    }
    return true;
}

fn parsesCompletely(allocator: std.mem.Allocator, text: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = syntax.parseSurface(arena.allocator(), text) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    return true;
}
