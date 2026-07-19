const std = @import("std");
const model = @import("model");

pub const OpAdd = "add";
pub const OpSet = "set";
pub const KeyMathTexPreamble = "math.tex.preamble";
pub const KeyMathTexPreambleFile = "math.tex.preamble.file";
pub const KeyMathTexEngine = "math.tex.engine";

pub const TexEngine = enum {
    pdflatex,
    lualatex,

    pub fn executable(self: TexEngine) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) ?TexEngine {
        if (std.mem.eql(u8, value, "pdflatex")) return .pdflatex;
        if (std.mem.eql(u8, value, "lualatex")) return .lualatex;
        return null;
    }
};

pub const TexPreambleSource = enum {
    text,
    file,
};

pub const TexPreambleEntry = struct {
    source: TexPreambleSource,
    value: []const u8,
};

pub const Resolved = struct {
    tex_preamble: std.ArrayList(TexPreambleEntry),
    tex_engine: TexEngine,

    pub fn init() Resolved {
        return .{ .tex_preamble = .empty, .tex_engine = .pdflatex };
    }

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        self.tex_preamble.deinit(allocator);
    }

    pub fn addTexPreamble(self: *Resolved, allocator: std.mem.Allocator, source: TexPreambleSource, value: []const u8) !void {
        try self.tex_preamble.append(allocator, .{
            .source = source,
            .value = value,
        });
    }
};

pub fn isSupported(op: []const u8, key: []const u8) bool {
    if (std.mem.eql(u8, op, OpAdd)) {
        return std.mem.eql(u8, key, KeyMathTexPreamble) or
            std.mem.eql(u8, key, KeyMathTexPreambleFile);
    }
    return std.mem.eql(u8, op, OpSet) and std.mem.eql(u8, key, KeyMathTexEngine);
}

pub fn isTexPreambleFileKey(key: []const u8) bool {
    return std.mem.eql(u8, key, KeyMathTexPreambleFile);
}

pub fn isValidTexPreambleFilePath(path: []const u8) bool {
    return path.len != 0;
}

pub fn isTexEngineKey(key: []const u8) bool {
    return std.mem.eql(u8, key, KeyMathTexEngine);
}

pub fn isValidTexEngine(value: []const u8) bool {
    return TexEngine.parse(value) != null;
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
        if (std.mem.eql(u8, entry.key, KeyMathTexPreamble)) {
            try env.addTexPreamble(allocator, .text, entry.value);
        } else if (std.mem.eql(u8, entry.key, KeyMathTexPreambleFile)) {
            try env.addTexPreamble(allocator, .file, entry.value);
        } else if (std.mem.eql(u8, entry.key, KeyMathTexEngine)) {
            env.tex_engine = TexEngine.parse(entry.value) orelse continue;
        }
    }
}

pub fn joinTexPreambleEntries(allocator: std.mem.Allocator, env: Resolved) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (env.tex_preamble.items, 0..) |entry, index| {
        if (index != 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, @tagName(entry.source));
        try out.append(allocator, ':');
        try out.appendSlice(allocator, entry.value);
    }
    return try out.toOwnedSlice(allocator);
}
