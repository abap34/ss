const std = @import("std");
const core = @import("model");

const Allocator = std.mem.Allocator;

pub const Program = struct {
    imports: std.ArrayList(ImportDecl),
    functions: std.ArrayList(FunctionDecl),
    pages: std.ArrayList(PageDecl),

    pub fn init() Program {
        return .{ .imports = .empty, .functions = .empty, .pages = .empty };
    }

    pub fn deinit(self: *Program, allocator: Allocator) void {
        for (self.imports.items) |import_decl| allocator.free(import_decl.spec);
        self.imports.deinit(allocator);
        for (self.functions.items) |*func| func.deinit(allocator);
        self.functions.deinit(allocator);
        for (self.pages.items) |*page| {
            for (page.statements.items) |*stmt| stmt.deinit(allocator);
            page.statements.deinit(allocator);
        }
        self.pages.deinit(allocator);
    }
};

pub const ImportDecl = struct {
    spec: []const u8,
    span: Span,
};

pub const PageDecl = struct {
    name: []const u8,
    statements: std.ArrayList(Statement),
};

pub const FunctionDecl = struct {
    name: []const u8,
    span: Span,
    params: std.ArrayList(ParamDecl),
    result_sort: core.SemanticSort,
    statements: std.ArrayList(Statement),

    pub fn deinit(self: *FunctionDecl, allocator: Allocator) void {
        for (self.params.items) |*param| param.deinit(allocator);
        self.params.deinit(allocator);
        for (self.statements.items) |*stmt| stmt.deinit(allocator);
        self.statements.deinit(allocator);
    }
};

pub const ParamDecl = struct {
    name: []const u8,
    sort: core.SemanticSort,
    default_value: ?*Expr = null,

    pub fn deinit(self: *ParamDecl, allocator: Allocator) void {
        if (self.default_value) |expr| {
            expr.deinit(allocator);
            allocator.destroy(expr);
        }
    }
};

pub const CallExpr = struct {
    name: []const u8,
    args: std.ArrayList(Expr),

    pub fn deinit(self: *CallExpr, allocator: Allocator) void {
        for (self.args.items) |*arg| arg.deinit(allocator);
        self.args.deinit(allocator);
    }
};

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const Expr = union(enum) {
    ident: []const u8,
    string: []const u8,
    number: f32,
    call: CallExpr,

    pub fn deinit(self: *Expr, allocator: Allocator) void {
        switch (self.*) {
            .call => |*call| call.deinit(allocator),
            else => {},
        }
    }
};

pub const AnchorRef = struct {
    kind: enum {
        page,
        node,
    },
    anchor: core.Anchor,
    node_name: ?[]const u8 = null,
};

pub const ConstraintDecl = struct {
    target: AnchorRef,
    source: AnchorRef,
    offset: ?Expr = null,

    pub fn deinit(self: *ConstraintDecl, allocator: Allocator) void {
        if (self.offset) |*offset| offset.deinit(allocator);
    }
};

pub const Statement = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        title: []const u8,
        subtitle: []const u8,
        math: []const u8,
        mathtex: []const u8,
        figure: []const u8,
        image: []const u8,
        pdf_ref: []const u8,
        code: []const u8,
        page_number: void,
        toc: void,
        let_binding: struct {
            name: []const u8,
            expr: Expr,
        },
        bind_binding: struct {
            name: []const u8,
            expr: Expr,
        },
        return_expr: Expr,
        constrain: ConstraintDecl,
        property_set: struct {
            object_name: []const u8,
            property_name: []const u8,
            value: Expr,
        },
        expr_stmt: Expr,
        highlight: []const u8,
    };

    pub fn deinit(self: *Statement, allocator: Allocator) void {
        switch (self.kind) {
            .let_binding => |*binding| binding.expr.deinit(allocator),
            .bind_binding => |*binding| binding.expr.deinit(allocator),
            .return_expr => |*expr| expr.deinit(allocator),
            .constrain => |*decl| decl.deinit(allocator),
            .property_set => |*property_set| property_set.value.deinit(allocator),
            .expr_stmt => |*expr| expr.deinit(allocator),
            else => {},
        }
    }
};
