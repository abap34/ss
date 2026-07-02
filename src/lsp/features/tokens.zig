const std = @import("std");

const scanner = @import("../../syntax/scanner.zig");
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    documents: *lsp_state.DocumentStore,
    current_snapshot: ?*const lsp_state.Snapshot,
};

pub fn result(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    if (!lsp_state.featureEnabledForCurrent(ctx.current_snapshot, .semantic_tokens)) return try ctx.allocator.dupe(u8, "{\"data\":[]}");
    var doc = try lsp_state.documentTextFromParams(ctx.io, ctx.allocator, ctx.documents, params) orelse return try ctx.allocator.dupe(u8, "{\"data\":[]}");
    defer doc.deinit(ctx.allocator);
    return json(ctx.allocator, doc.source);
}

pub fn json(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const tokens = try scanner.semanticTokens(allocator, text);
    defer allocator.free(tokens);

    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "{\"data\":[");
    var previous_line: usize = 0;
    var previous_start: usize = 0;
    for (tokens, 0..) |semantic, index| {
        if (index != 0) try out.append(allocator, ',');
        const range = protocol.rangeFromSpan(text, semantic.token.span);
        const line = range.start_line;
        const start = range.start_character;
        const length = @max(1, range.end_character - range.start_character);
        const delta_line = line - previous_line;
        const delta_start = if (delta_line == 0) start - previous_start else start;
        try protocol.appendInt(allocator, &out, delta_line);
        try out.append(allocator, ',');
        try protocol.appendInt(allocator, &out, delta_start);
        try out.append(allocator, ',');
        try protocol.appendInt(allocator, &out, length);
        try out.append(allocator, ',');
        try protocol.appendInt(allocator, &out, tokenKind(semantic.kind));
        try out.appendSlice(allocator, ",0");
        previous_line = line;
        previous_start = start;
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn tokenKind(kind: scanner.SemanticKind) usize {
    return switch (kind) {
        .keyword => 0,
        .function => 1,
        .variable => 2,
        .string => 3,
        .number => 4,
        .type => 5,
        .property => 6,
        .operator => 7,
    };
}
