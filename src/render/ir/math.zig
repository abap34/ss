const std = @import("std");
const geometry = @import("geometry.zig");
const text_ir = @import("text.zig");

const ParseError = error{ UnsupportedMathSyntax, OutOfMemory };

pub const TreeId = u64;
pub const NodeId = u32;

pub const InputKind = enum {
    @"inline",
    display,
    block,
    raw,
};

pub const Kind = enum {
    row,
    identifier,
    number,
    operator,
    text,
    space,
    fraction,
    square_root,
    superscript,
    subscript,
    subscript_superscript,
    raw_tex,
};

pub const Node = struct {
    id: NodeId,
    kind: Kind,
    text: ?[]u8 = null,
    children: []NodeId = &.{},

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        if (self.text) |value| allocator.free(value);
        allocator.free(self.children);
    }
};

pub const TextElement = struct {
    node: NodeId,
    x: f64,
    y: f64,
    font_size: f64,
    layout: text_ir.Layout,

    fn deinit(self: *TextElement, allocator: std.mem.Allocator) void {
        self.layout.deinit(allocator);
    }
};

pub const RuleElement = struct {
    node: NodeId,
    rect: geometry.Rect,
};

pub const Element = union(enum) {
    text: TextElement,
    rule: RuleElement,

    fn deinit(self: *Element, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |*value| value.deinit(allocator),
            .rule => {},
        }
    }
};

pub const Layout = struct {
    width: f64,
    height: f64,
    baseline: f64,
    elements: []Element,

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        for (self.elements) |*element| element.deinit(allocator);
        allocator.free(self.elements);
        self.* = .{ .width = 0, .height = 0, .baseline = 0, .elements = &.{} };
    }
};

pub const Tree = struct {
    id: TreeId,
    input_kind: InputKind,
    source: []u8,
    root: NodeId,
    nodes: []Node,

    fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        for (self.nodes) |*node| node.deinit(allocator);
        allocator.free(self.nodes);
    }

    pub fn find(self: *const Tree, id: NodeId) ?*const Node {
        if (id >= self.nodes.len or self.nodes[id].id != id) return null;
        return &self.nodes[id];
    }
};

pub const Catalog = struct {
    trees: []Tree = &.{},

    pub fn deinit(self: *Catalog, allocator: std.mem.Allocator) void {
        for (self.trees) |*tree| tree.deinit(allocator);
        allocator.free(self.trees);
        self.* = .{};
    }

    pub fn find(self: *const Catalog, id: TreeId) ?*const Tree {
        for (self.trees) |*tree| if (tree.id == id) return tree;
        return null;
    }
};

pub const Builder = struct {
    trees: std.ArrayList(Tree) = .empty,

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        for (self.trees.items) |*tree| tree.deinit(allocator);
        self.trees.deinit(allocator);
        self.* = .{};
    }

    pub fn add(self: *Builder, allocator: std.mem.Allocator, source: []const u8, input_kind: InputKind) !TreeId {
        for (self.trees.items) |tree| {
            if (tree.input_kind == input_kind and std.mem.eql(u8, tree.source, source)) return tree.id;
        }
        const id: TreeId = @intCast(self.trees.items.len + 1);
        var tree = if (input_kind == .raw)
            try rawTree(allocator, id, source)
        else blk: {
            var parser = Parser{ .allocator = allocator, .source = source };
            break :blk try parser.parse(id, input_kind);
        };
        errdefer tree.deinit(allocator);
        try self.trees.append(allocator, tree);
        return id;
    }

    pub fn find(self: *const Builder, id: TreeId) ?*const Tree {
        for (self.trees.items) |*tree| if (tree.id == id) return tree;
        return null;
    }

    pub fn mergeFrom(self: *Builder, allocator: std.mem.Allocator, other: *Builder) ![]TreeId {
        const mapping = try allocator.alloc(TreeId, other.trees.items.len);
        errdefer allocator.free(mapping);
        try self.trees.ensureUnusedCapacity(allocator, other.trees.items.len);
        for (other.trees.items, 0..) |*tree, index| {
            const existing = for (self.trees.items) |candidate| {
                if (candidate.input_kind == tree.input_kind and std.mem.eql(u8, candidate.source, tree.source)) break candidate.id;
            } else null;
            if (existing) |id| {
                mapping[index] = id;
                tree.deinit(allocator);
            } else {
                const id: TreeId = @intCast(self.trees.items.len + 1);
                tree.id = id;
                mapping[index] = id;
                self.trees.appendAssumeCapacity(tree.*);
            }
        }
        other.trees.items.len = 0;
        return mapping;
    }

    pub fn take(self: *Builder, allocator: std.mem.Allocator) !Catalog {
        const trees = try self.trees.toOwnedSlice(allocator);
        self.* = .{};
        return .{ .trees = trees };
    }
};

fn rawTree(allocator: std.mem.Allocator, id: TreeId, source: []const u8) !Tree {
    const owned_source = try allocator.dupe(u8, source);
    errdefer allocator.free(owned_source);
    const nodes = try allocator.alloc(Node, 1);
    errdefer allocator.free(nodes);
    const text = try allocator.dupe(u8, source);
    errdefer allocator.free(text);
    nodes[0] = .{ .id = 0, .kind = .raw_tex, .text = text };
    return .{ .id = id, .input_kind = .raw, .source = owned_source, .root = 0, .nodes = nodes };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    offset: usize = 0,
    nodes: std.ArrayList(Node) = .empty,

    fn parse(self: *Parser, id: TreeId, input_kind: InputKind) ParseError!Tree {
        errdefer {
            for (self.nodes.items) |*node| node.deinit(self.allocator);
            self.nodes.deinit(self.allocator);
        }
        const root = try self.parseRow(null);
        self.skipWhitespace();
        if (self.offset != self.source.len) return error.UnsupportedMathSyntax;
        const owned_source = try self.allocator.dupe(u8, self.source);
        errdefer self.allocator.free(owned_source);
        return .{
            .id = id,
            .input_kind = input_kind,
            .source = owned_source,
            .root = root,
            .nodes = try self.nodes.toOwnedSlice(self.allocator),
        };
    }

    fn parseRow(self: *Parser, terminator: ?u8) ParseError!NodeId {
        var children = std.ArrayList(NodeId).empty;
        defer children.deinit(self.allocator);
        while (self.offset < self.source.len) {
            if (terminator) |expected| {
                if (self.source[self.offset] == expected) break;
            }
            if (std.ascii.isWhitespace(self.source[self.offset])) {
                self.skipWhitespace();
                if (children.items.len != 0) try children.append(self.allocator, try self.leaf(.space, " "));
                continue;
            }
            if (self.source[self.offset] == '}') return error.UnsupportedMathSyntax;
            var base = try self.parseAtom();
            var subscript: ?NodeId = null;
            var superscript: ?NodeId = null;
            while (self.offset < self.source.len and (self.source[self.offset] == '^' or self.source[self.offset] == '_')) {
                const marker = self.source[self.offset];
                self.offset += 1;
                const script = try self.parseScriptAtom();
                if (marker == '^') {
                    if (superscript != null) return error.UnsupportedMathSyntax;
                    superscript = script;
                } else {
                    if (subscript != null) return error.UnsupportedMathSyntax;
                    subscript = script;
                }
            }
            if (subscript != null and superscript != null) {
                base = try self.parent(.subscript_superscript, &.{ base, subscript.?, superscript.? });
            } else if (subscript) |script| {
                base = try self.parent(.subscript, &.{ base, script });
            } else if (superscript) |script| {
                base = try self.parent(.superscript, &.{ base, script });
            }
            try children.append(self.allocator, base);
        }
        return try self.parent(.row, children.items);
    }

    fn parseScriptAtom(self: *Parser) ParseError!NodeId {
        self.skipWhitespace();
        if (self.offset >= self.source.len) return error.UnsupportedMathSyntax;
        return try self.parseAtom();
    }

    fn parseAtom(self: *Parser) ParseError!NodeId {
        if (self.offset >= self.source.len) return error.UnsupportedMathSyntax;
        const byte = self.source[self.offset];
        if (byte == '{') {
            self.offset += 1;
            const row = try self.parseRow('}');
            if (self.offset >= self.source.len or self.source[self.offset] != '}') return error.UnsupportedMathSyntax;
            self.offset += 1;
            return row;
        }
        if (byte == '\\') return try self.parseCommand();
        if (std.ascii.isDigit(byte)) {
            const start = self.offset;
            while (self.offset < self.source.len and (std.ascii.isDigit(self.source[self.offset]) or self.source[self.offset] == '.')) self.offset += 1;
            return try self.leaf(.number, self.source[start..self.offset]);
        }
        if (std.ascii.isAlphabetic(byte)) {
            self.offset += 1;
            return try self.leaf(.identifier, self.source[self.offset - 1 .. self.offset]);
        }
        if (byte < 0x20 or byte == '<' or byte == '>') return error.UnsupportedMathSyntax;
        const length = std.unicode.utf8ByteSequenceLength(byte) catch return error.UnsupportedMathSyntax;
        if (self.offset + length > self.source.len) return error.UnsupportedMathSyntax;
        self.offset += length;
        return try self.leaf(.operator, self.source[self.offset - length .. self.offset]);
    }

    fn parseCommand(self: *Parser) ParseError!NodeId {
        self.offset += 1;
        if (self.offset >= self.source.len) return error.UnsupportedMathSyntax;
        if (!std.ascii.isAlphabetic(self.source[self.offset])) {
            const byte = self.source[self.offset];
            self.offset += 1;
            return switch (byte) {
                ',', ';', ':', '!' => self.leaf(.space, " "),
                '{', '}', '%', '_', '#', '&', '$' => self.leaf(.operator, self.source[self.offset - 1 .. self.offset]),
                else => error.UnsupportedMathSyntax,
            };
        }
        const start = self.offset;
        while (self.offset < self.source.len and std.ascii.isAlphabetic(self.source[self.offset])) self.offset += 1;
        const name = self.source[start..self.offset];
        if (std.mem.eql(u8, name, "frac")) {
            const numerator = try self.parseRequiredGroup();
            const denominator = try self.parseRequiredGroup();
            return try self.parent(.fraction, &.{ numerator, denominator });
        }
        if (std.mem.eql(u8, name, "sqrt")) {
            const radicand = try self.parseRequiredGroup();
            return try self.parent(.square_root, &.{radicand});
        }
        if (std.mem.eql(u8, name, "text") or std.mem.eql(u8, name, "mathrm") or std.mem.eql(u8, name, "mathbf")) {
            const value = try self.parseRawGroup();
            defer self.allocator.free(value);
            return try self.leaf(.text, value);
        }
        if (std.mem.eql(u8, name, "left") or std.mem.eql(u8, name, "right")) {
            self.skipWhitespace();
            return try self.parseAtom();
        }
        if (commandSymbol(name)) |symbol| return try self.leaf(if (isIdentifierCommand(name)) .identifier else .operator, symbol);
        return error.UnsupportedMathSyntax;
    }

    fn parseRequiredGroup(self: *Parser) ParseError!NodeId {
        self.skipWhitespace();
        if (self.offset >= self.source.len or self.source[self.offset] != '{') return error.UnsupportedMathSyntax;
        return try self.parseAtom();
    }

    fn parseRawGroup(self: *Parser) ParseError![]u8 {
        self.skipWhitespace();
        if (self.offset >= self.source.len or self.source[self.offset] != '{') return error.UnsupportedMathSyntax;
        self.offset += 1;
        const start = self.offset;
        var depth: usize = 1;
        while (self.offset < self.source.len) : (self.offset += 1) {
            switch (self.source[self.offset]) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        const result = try self.allocator.dupe(u8, self.source[start..self.offset]);
                        self.offset += 1;
                        return result;
                    }
                },
                else => {},
            }
        }
        return error.UnsupportedMathSyntax;
    }

    fn leaf(self: *Parser, kind: Kind, text: []const u8) ParseError!NodeId {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        const id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .id = id, .kind = kind, .text = owned });
        return id;
    }

    fn parent(self: *Parser, kind: Kind, children: []const NodeId) ParseError!NodeId {
        const owned = try self.allocator.dupe(NodeId, children);
        errdefer self.allocator.free(owned);
        const id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .id = id, .kind = kind, .children = owned });
        return id;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.offset < self.source.len and std.ascii.isWhitespace(self.source[self.offset])) self.offset += 1;
    }
};

fn commandSymbol(name: []const u8) ?[]const u8 {
    const Entry = struct { name: []const u8, symbol: []const u8 };
    const entries = [_]Entry{
        .{ .name = "alpha", .symbol = "α" },
        .{ .name = "beta", .symbol = "β" },
        .{ .name = "gamma", .symbol = "γ" },
        .{ .name = "delta", .symbol = "δ" },
        .{ .name = "epsilon", .symbol = "ε" },
        .{ .name = "theta", .symbol = "θ" },
        .{ .name = "lambda", .symbol = "λ" },
        .{ .name = "mu", .symbol = "μ" },
        .{ .name = "pi", .symbol = "π" },
        .{ .name = "rho", .symbol = "ρ" },
        .{ .name = "sigma", .symbol = "σ" },
        .{ .name = "phi", .symbol = "φ" },
        .{ .name = "omega", .symbol = "ω" },
        .{ .name = "Gamma", .symbol = "Γ" },
        .{ .name = "Delta", .symbol = "Δ" },
        .{ .name = "Theta", .symbol = "Θ" },
        .{ .name = "Lambda", .symbol = "Λ" },
        .{ .name = "Pi", .symbol = "Π" },
        .{ .name = "Sigma", .symbol = "Σ" },
        .{ .name = "Phi", .symbol = "Φ" },
        .{ .name = "Omega", .symbol = "Ω" },
        .{ .name = "sum", .symbol = "∑" },
        .{ .name = "prod", .symbol = "∏" },
        .{ .name = "int", .symbol = "∫" },
        .{ .name = "infty", .symbol = "∞" },
        .{ .name = "times", .symbol = "×" },
        .{ .name = "cdot", .symbol = "⋅" },
        .{ .name = "pm", .symbol = "±" },
        .{ .name = "le", .symbol = "≤" },
        .{ .name = "ge", .symbol = "≥" },
        .{ .name = "neq", .symbol = "≠" },
        .{ .name = "to", .symbol = "→" },
    };
    for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.symbol;
    return null;
}

fn isIdentifierCommand(name: []const u8) bool {
    const first = commandSymbol(name) orelse return false;
    const count = std.unicode.utf8CountCodepoints(first) catch return false;
    return count == 1 and !std.mem.eql(u8, name, "sum") and
        !std.mem.eql(u8, name, "prod") and !std.mem.eql(u8, name, "int") and
        !std.mem.eql(u8, name, "infty") and !std.mem.eql(u8, name, "times") and
        !std.mem.eql(u8, name, "cdot") and !std.mem.eql(u8, name, "pm") and
        !std.mem.eql(u8, name, "le") and !std.mem.eql(u8, name, "ge") and
        !std.mem.eql(u8, name, "neq") and !std.mem.eql(u8, name, "to");
}
