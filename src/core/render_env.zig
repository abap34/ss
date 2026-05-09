const std = @import("std");
const model = @import("model");

pub const OpAdd = "add";
pub const KeyMathLatexPackages = "math.latex.packages";

pub const Resolved = struct {
    math_latex_packages: std.ArrayList([]const u8),

    pub fn init() Resolved {
        return .{ .math_latex_packages = .empty };
    }

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        self.math_latex_packages.deinit(allocator);
    }

    pub fn addMathLatexPackage(self: *Resolved, allocator: std.mem.Allocator, package: []const u8) !void {
        for (self.math_latex_packages.items) |existing| {
            if (std.mem.eql(u8, existing, package)) return;
        }
        try self.math_latex_packages.append(allocator, package);
    }
};

pub fn isSupported(op: []const u8, key: []const u8) bool {
    return std.mem.eql(u8, op, OpAdd) and std.mem.eql(u8, key, KeyMathLatexPackages);
}

pub fn isValidLatexPackageName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') continue;
        return false;
    }
    return true;
}

pub fn resolveForNode(allocator: std.mem.Allocator, ir: anytype, node: *const model.Node) !Resolved {
    var env = Resolved.init();
    errdefer env.deinit(allocator);

    if (ir.getNode(ir.document_id)) |document| {
        try applyNode(allocator, &env, document);
    }

    switch (node.kind) {
        .document => {},
        .page => try applyNode(allocator, &env, node),
        .object => {
            if (ir.parentPageOf(node.id)) |page_id| {
                if (ir.getNode(page_id)) |page| try applyNode(allocator, &env, page);
            }
            try applyNode(allocator, &env, node);
        },
    }

    return env;
}

fn applyNode(allocator: std.mem.Allocator, env: *Resolved, node: *const model.Node) !void {
    for (node.render_env.items) |entry| {
        if (!isSupported(entry.op, entry.key)) continue;
        try env.addMathLatexPackage(allocator, entry.value);
    }
}

pub fn joinMathLatexPackages(allocator: std.mem.Allocator, env: Resolved) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (env.math_latex_packages.items, 0..) |package, index| {
        if (index != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, package);
    }
    return try out.toOwnedSlice(allocator);
}
