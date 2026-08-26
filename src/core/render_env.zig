const std = @import("std");
const model = @import("model");

pub const OpAdd = "add";
pub const OpSet = "set";
pub const KeyLatexPreamble = "latex.preamble";
pub const KeyLatexPreambleFile = "latex.preamble.file";
pub const KeyLatexEngine = "latex.engine";

pub const LatexEngine = enum {
    pdflatex,
    lualatex,

    pub fn executable(self: LatexEngine) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) ?LatexEngine {
        if (std.mem.eql(u8, value, "pdflatex")) return .pdflatex;
        if (std.mem.eql(u8, value, "lualatex")) return .lualatex;
        return null;
    }
};

pub const LatexPreambleSource = enum {
    text,
    file,
};

pub const LatexPreambleEntry = struct {
    source: LatexPreambleSource,
    value: []const u8,
};

pub const Resolved = struct {
    latex_preamble: std.ArrayList(LatexPreambleEntry),
    latex_engine: LatexEngine,

    pub fn init() Resolved {
        return .{ .latex_preamble = .empty, .latex_engine = .pdflatex };
    }

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        self.latex_preamble.deinit(allocator);
    }

    pub fn addLatexPreamble(self: *Resolved, allocator: std.mem.Allocator, source: LatexPreambleSource, value: []const u8) !void {
        try self.latex_preamble.append(allocator, .{
            .source = source,
            .value = value,
        });
    }
};

pub fn isSupported(op: []const u8, key: []const u8) bool {
    if (std.mem.eql(u8, op, OpAdd)) {
        return std.mem.eql(u8, key, KeyLatexPreamble) or
            std.mem.eql(u8, key, KeyLatexPreambleFile);
    }
    return std.mem.eql(u8, op, OpSet) and std.mem.eql(u8, key, KeyLatexEngine);
}

pub fn isLatexPreambleFileKey(key: []const u8) bool {
    return std.mem.eql(u8, key, KeyLatexPreambleFile);
}

pub fn isValidLatexPreambleFilePath(path: []const u8) bool {
    return path.len != 0;
}

pub fn isLatexEngineKey(key: []const u8) bool {
    return std.mem.eql(u8, key, KeyLatexEngine);
}

pub fn isValidLatexEngine(value: []const u8) bool {
    return LatexEngine.parse(value) != null;
}

pub fn resolveForNode(allocator: std.mem.Allocator, state: anytype, node: *const model.Node) !Resolved {
    var env = Resolved.init();
    errdefer env.deinit(allocator);

    if (state.getNode(state.document_id)) |document| {
        try applyNode(allocator, &env, document);
    }

    switch (node.kind) {
        .document => {},
        .page => try applyNode(allocator, &env, node),
        .object => {
            if (state.parentPageOf(node.id)) |page_id| {
                if (state.getNode(page_id)) |page| try applyNode(allocator, &env, page);
            }
            try applyNode(allocator, &env, node);
        },
    }

    return env;
}

fn applyNode(allocator: std.mem.Allocator, env: *Resolved, node: *const model.Node) !void {
    for (node.render_env.items) |entry| {
        if (!isSupported(entry.op, entry.key)) continue;
        if (std.mem.eql(u8, entry.key, KeyLatexPreamble)) {
            try env.addLatexPreamble(allocator, .text, entry.value);
        } else if (std.mem.eql(u8, entry.key, KeyLatexPreambleFile)) {
            try env.addLatexPreamble(allocator, .file, entry.value);
        } else if (std.mem.eql(u8, entry.key, KeyLatexEngine)) {
            env.latex_engine = LatexEngine.parse(entry.value) orelse continue;
        }
    }
}

pub fn joinLatexPreambleEntries(allocator: std.mem.Allocator, env: Resolved) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (env.latex_preamble.items, 0..) |entry, index| {
        if (index != 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, @tagName(entry.source));
        try out.append(allocator, ':');
        try out.appendSlice(allocator, entry.value);
    }
    return try out.toOwnedSlice(allocator);
}
