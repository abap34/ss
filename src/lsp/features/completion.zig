const std = @import("std");

const analysis_snapshot = @import("../../analysis/snapshot.zig");
const protocol = @import("../protocol.zig");
const query_budget = @import("../query_budget.zig");
const lsp_state = @import("../state.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    provider: *lsp_state.SnapshotProvider,
    documents: *lsp_state.DocumentStore,
};

pub fn result(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(ctx.allocator);
    var position = try lsp_state.requestPosition(ctx.allocator, ctx.documents, params);
    defer if (position) |*pos| pos.deinit(ctx.allocator);
    var builder = try begin(ctx.allocator, &out);
    defer builder.deinit();
    if (position) |*pos| {
        var owned_snapshot: ?lsp_state.Snapshot = null;
        defer if (owned_snapshot) |*snapshot| snapshot.deinit();
        const snapshot = try ctx.provider.forDocument(pos.doc_path, &owned_snapshot) orelse return finish(ctx.allocator, &out);
        if (!lsp_state.featureEnabledForSnapshot(snapshot, .completion)) return finish(ctx.allocator, &out);
        var completion_result = try analysis_snapshot.completeAt(ctx.allocator, snapshot, .{
            .path = pos.doc_path,
            .source = pos.source,
            .offset = pos.offset,
            .source_version = snapshot.generation,
        }, .{ .budget_ms = query_budget.completion_ms });
        defer completion_result.deinit(ctx.allocator);
        for (completion_result.items) |item| try builder.addCandidate(item);
    }
    return finish(ctx.allocator, &out);
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
        try self.add(candidate.label, kind(candidate.kind), candidate.detail, candidate.documentation);
    }

    fn add(self: *Builder, label: []const u8, item_kind: usize, detail: ?[]const u8, documentation: ?[]const u8) !void {
        if (label.len == 0 or self.seen.contains(label)) return;
        try self.seen.put(label, {});
        if (!self.first) try self.out.append(self.allocator, ',');
        self.first = false;
        try self.out.appendSlice(self.allocator, "{\"label\":");
        try protocol.appendJsonString(self.allocator, self.out, label);
        try self.out.appendSlice(self.allocator, ",\"kind\":");
        try protocol.appendInt(self.allocator, self.out, item_kind);
        if (detail) |text| {
            try self.out.appendSlice(self.allocator, ",\"detail\":");
            try protocol.appendJsonString(self.allocator, self.out, text);
        }
        if (documentation) |text| if (text.len != 0) {
            try self.out.appendSlice(self.allocator, ",\"documentation\":");
            try protocol.appendJsonString(self.allocator, self.out, text);
        };
        try self.out.append(self.allocator, '}');
    }
};

pub fn emptyJson(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8, "{\"isIncomplete\":false,\"items\":[]}");
}

pub fn begin(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !Builder {
    try out.appendSlice(allocator, "{\"isIncomplete\":false,\"items\":[");
    return Builder.init(allocator, out);
}

pub fn finish(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) ![]const u8 {
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn kind(completion_kind: analysis_snapshot.CompletionKind) usize {
    return switch (completion_kind) {
        .keyword => 14,
        .function => 3,
        .variable => 6,
        .property => 10,
        .enum_case => 20,
        .type_decl => 25,
        .class => 7,
        .role => 20,
    };
}
