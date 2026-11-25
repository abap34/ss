const std = @import("std");

const analysis_snapshot = @import("../../analysis/snapshot.zig");
const protocol = @import("../protocol.zig");
const query_budget = @import("../query_budget.zig");
const lsp_state = @import("../state.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: *lsp_state.AnalysisProvider,
    documents: *lsp_state.DocumentStore,
};

pub fn result(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    ctx.provider.beginQuery(query_budget.completion_ms);
    ctx.provider.query_options.?.io = ctx.io;
    var position = try lsp_state.requestPosition(ctx.allocator, ctx.documents, params);
    defer if (position) |*pos| pos.deinit(ctx.allocator);
    if (position) |*pos| {
        const snapshot = try ctx.provider.forDocument(pos.doc_path) orelse return json(ctx.allocator, .{ .items = &.{}, .is_incomplete = true });
        if (!lsp_state.featureEnabledForAnalysis(snapshot, .completion)) return emptyJson(ctx.allocator);
        var completion_result = try analysis_snapshot.completeAt(ctx.allocator, snapshot, .{
            .path = pos.doc_path,
            .source = pos.source,
            .line_index = ctx.documents.indexForPath(pos.doc_path),
            .offset = pos.offset,
        }, ctx.provider.query_options.?);
        defer completion_result.deinit(ctx.allocator);
        return json(ctx.allocator, completion_result);
    }
    return emptyJson(ctx.allocator);
}

pub fn json(allocator: std.mem.Allocator, completion: analysis_snapshot.CompletionResult) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, if (completion.is_incomplete)
        "{\"isIncomplete\":true,\"items\":["
    else
        "{\"isIncomplete\":false,\"items\":[");
    var builder = Builder.init(allocator, &out);
    defer builder.deinit();
    for (completion.items) |item| try builder.addCandidate(item);
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

pub const Builder = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    seen: std.StringHashMap(void),
    first: bool = true,

    pub fn init(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) Builder {
        return .{
            .allocator = allocator,
            .out = out,
            .seen = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.seen.deinit();
    }

    pub fn addCandidate(self: *Builder, candidate: analysis_snapshot.CompletionCandidate) !void {
        if (candidate.label.len == 0 or self.seen.contains(candidate.label)) return;
        try self.seen.put(candidate.label, {});
        if (!self.first) try self.out.append(self.allocator, ',');
        self.first = false;
        try self.out.appendSlice(self.allocator, "{\"label\":");
        try protocol.appendJsonString(self.allocator, self.out, candidate.label);
        try self.out.appendSlice(self.allocator, ",\"kind\":");
        try protocol.appendInt(self.allocator, self.out, kind(candidate.kind));
        if (candidate.detail) |text| {
            try self.out.appendSlice(self.allocator, ",\"detail\":");
            try protocol.appendJsonString(self.allocator, self.out, text);
        }
        if (candidate.documentation) |text| if (text.len != 0) {
            try self.out.appendSlice(self.allocator, ",\"documentation\":");
            try protocol.appendJsonString(self.allocator, self.out, text);
        };
        if (candidate.text_edit) |edit| {
            try self.out.appendSlice(self.allocator, ",\"textEdit\":{\"range\":{\"start\":{\"line\":");
            try protocol.appendInt(self.allocator, self.out, edit.start.line);
            try self.out.appendSlice(self.allocator, ",\"character\":");
            try protocol.appendInt(self.allocator, self.out, edit.start.character);
            try self.out.appendSlice(self.allocator, "},\"end\":{\"line\":");
            try protocol.appendInt(self.allocator, self.out, edit.end.line);
            try self.out.appendSlice(self.allocator, ",\"character\":");
            try protocol.appendInt(self.allocator, self.out, edit.end.character);
            try self.out.appendSlice(self.allocator, "}},\"newText\":");
            try protocol.appendJsonString(self.allocator, self.out, edit.text);
            try self.out.append(self.allocator, '}');
        }
        try self.out.append(self.allocator, '}');
    }
};

pub fn emptyJson(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8, "{\"isIncomplete\":false,\"items\":[]}");
}

fn kind(completion_kind: analysis_snapshot.CompletionKind) usize {
    return switch (completion_kind) {
        .module => 9,
        .folder => 19,
        .keyword => 14,
        .function => 3,
        .variable => 6,
        .property => 10,
        .enum_case => 20,
        .type_decl => 25,
    };
}
