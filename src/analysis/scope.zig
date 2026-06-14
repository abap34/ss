const std = @import("std");
const ast = @import("ast");
const core = @import("core");

pub const SourceScope = struct {
    kind: core.DefinitionScopeKind,
    name: ?[]const u8 = null,
    start: usize = 0,
    end: usize = std.math.maxInt(usize),
};

pub fn statementsVisibleEnd(statements: []const ast.Statement, fallback: usize) usize {
    if (statements.len == 0) return fallback;
    return statements[statements.len - 1].span.end;
}

pub fn functionScope(func: ast.FunctionDecl) SourceScope {
    return .{
        .kind = .function,
        .name = func.name,
        .start = func.span.start,
        .end = func.span.end,
    };
}

pub fn documentScope(source_len: usize) SourceScope {
    return .{
        .kind = .document,
        .name = null,
        .start = 0,
        .end = source_len,
    };
}

pub fn pageScope(page: ast.PageDecl) SourceScope {
    return .{
        .kind = .page,
        .name = page.name,
        .start = page.span.start,
        .end = page.span.end,
    };
}

pub fn contains(scope: SourceScope, offset: usize) bool {
    return offset >= scope.start and offset <= scope.end;
}
