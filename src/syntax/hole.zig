const std = @import("std");
const ast = @import("ast");

pub const HoleId = ast.HoleId;

pub const HoleKind = enum {
    expr,
    stmt,
    type_expr,
    name,
    member_name,
    import_spec,
    record_field_path,
    call_arg,
    block,
};

pub const ExpectedSyntax = enum {
    expression,
    statement,
    type_expr,
    name,
    member_name,
    import_spec,
    record_field_path,
    call_arg,
    block,
};

pub const Hole = struct {
    id: HoleId,
    kind: HoleKind,
    span: ast.Span,
    expected: ExpectedSyntax,
    expected_type: ?ast.Type = null,

    pub fn deinit(self: *Hole, allocator: std.mem.Allocator) void {
        if (self.expected_type) |*ty| ty.deinit(allocator);
    }
};

pub const HoleType = struct {
    hole_id: HoleId,
    expected: ?ast.Type = null,
};

pub const Diagnostic = struct {
    hole_id: HoleId,
    caused_by: ?HoleId = null,
    err: anyerror,
    span: ast.Span,
    expected: ?[]const u8 = null,
    found: ?[]const u8 = null,
};

pub const Result = struct {
    holes: []Hole,
    diagnostics: []Diagnostic,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.holes) |*hole| hole.deinit(allocator);
        allocator.free(self.holes);
        allocator.free(self.diagnostics);
    }

    pub fn setExpectedType(self: *Result, allocator: std.mem.Allocator, hole_id: HoleId, expected: ast.Type) !void {
        if (hole_id >= self.holes.len) return;
        const hole = &self.holes[hole_id];
        if (hole.expected_type) |*existing| existing.deinit(allocator);
        hole.expected_type = try expected.clone(allocator);
    }
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    holes: std.ArrayList(Hole) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    pub fn deinit(self: *Builder) void {
        for (self.holes.items) |*hole| hole.deinit(self.allocator);
        self.holes.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
    }

    pub fn add(self: *Builder, kind: HoleKind, expected: ExpectedSyntax, span: ast.Span, err: anyerror, found: ?[]const u8) !HoleId {
        if (self.equivalentId(kind, span)) |existing| return existing;
        const id: HoleId = @intCast(self.holes.items.len);
        try self.holes.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .span = span,
            .expected = expected,
        });
        try self.diagnostics.append(self.allocator, .{
            .hole_id = id,
            .caused_by = id,
            .err = err,
            .span = span,
            .expected = expectedText(expected),
            .found = found,
        });
        return id;
    }

    fn equivalentId(self: *const Builder, kind: HoleKind, span: ast.Span) ?HoleId {
        for (self.holes.items) |hole| {
            if (hole.kind == kind and hole.span.start == span.start and hole.span.end == span.end) return hole.id;
        }
        return null;
    }

    pub fn finish(self: *Builder) !Result {
        const owned_holes = try self.holes.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_holes);
        const owned_diagnostics = try self.diagnostics.toOwnedSlice(self.allocator);
        return .{
            .holes = owned_holes,
            .diagnostics = owned_diagnostics,
        };
    }
};

fn expectedText(expected: ExpectedSyntax) []const u8 {
    return switch (expected) {
        .expression => "expression",
        .statement => "statement",
        .type_expr => "type expression",
        .name => "name",
        .member_name => "member name",
        .import_spec => "import path without a file extension",
        .record_field_path => "record field path",
        .call_arg => "call argument",
        .block => "block",
    };
}
