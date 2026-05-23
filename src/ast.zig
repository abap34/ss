const std = @import("std");
const core = @import("model");
pub const types = @import("language_type");

const Allocator = std.mem.Allocator;
pub const Type = types.Type;

pub const Program = struct {
    imports: std.ArrayList(ImportDecl),
    top_level_items: std.ArrayList(TopLevelItem),
    types: std.ArrayList(TypeDecl),
    objects: std.ArrayList(ObjectDecl),
    object_extensions: std.ArrayList(ObjectExtensionDecl),
    functions: std.ArrayList(FunctionDecl),
    document_statements: std.ArrayList(Statement),
    pages: std.ArrayList(PageDecl),

    pub fn init() Program {
        return .{ .imports = .empty, .top_level_items = .empty, .types = .empty, .objects = .empty, .object_extensions = .empty, .functions = .empty, .document_statements = .empty, .pages = .empty };
    }

    pub fn deinit(self: *Program, allocator: Allocator) void {
        for (self.imports.items) |import_decl| allocator.free(import_decl.spec);
        self.imports.deinit(allocator);
        self.top_level_items.deinit(allocator);
        for (self.types.items) |type_decl| type_decl.deinit(allocator);
        self.types.deinit(allocator);
        for (self.objects.items) |*object| object.deinit(allocator);
        self.objects.deinit(allocator);
        for (self.object_extensions.items) |*extension| extension.deinit(allocator);
        self.object_extensions.deinit(allocator);
        for (self.functions.items) |*func| func.deinit(allocator);
        self.functions.deinit(allocator);
        for (self.document_statements.items) |*stmt| stmt.deinit(allocator);
        self.document_statements.deinit(allocator);
        for (self.pages.items) |*page| {
            allocator.free(page.name);
            for (page.statements.items) |*stmt| stmt.deinit(allocator);
            page.statements.deinit(allocator);
        }
        self.pages.deinit(allocator);
    }
};

pub const TopLevelItem = union(enum) {
    import: usize,
    page: usize,
};

pub const ImportDecl = struct {
    spec: []const u8,
    span: Span,
};

pub const TypeDecl = struct {
    name: []const u8,
    body: []const u8,
    refinement: ?[]const u8 = null,
    span: Span,

    pub fn deinit(self: TypeDecl, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.body);
        if (self.refinement) |refinement| allocator.free(refinement);
    }
};

pub const ObjectFieldDecl = struct {
    name: []const u8,
    value_type: []const u8,
    default_value: ?[]const u8 = null,
    span: Span,

    pub fn deinit(self: *ObjectFieldDecl, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value_type);
        if (self.default_value) |default_value| allocator.free(default_value);
    }
};

pub const ObjectDecl = struct {
    name: []const u8,
    base: ?[]const u8 = null,
    roles: std.ArrayList([]const u8),
    fields: std.ArrayList(ObjectFieldDecl),
    span: Span,

    pub fn deinit(self: *ObjectDecl, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.base) |base| allocator.free(base);
        for (self.roles.items) |role| allocator.free(role);
        self.roles.deinit(allocator);
        for (self.fields.items) |*field| field.deinit(allocator);
        self.fields.deinit(allocator);
    }
};

pub const ObjectExtensionDecl = struct {
    target: []const u8,
    implements: ?[]const u8 = null,
    roles: std.ArrayList([]const u8),
    fields: std.ArrayList(ObjectFieldDecl),
    span: Span,

    pub fn deinit(self: *ObjectExtensionDecl, allocator: Allocator) void {
        allocator.free(self.target);
        if (self.implements) |implements| allocator.free(implements);
        for (self.roles.items) |role| allocator.free(role);
        self.roles.deinit(allocator);
        for (self.fields.items) |*field| field.deinit(allocator);
        self.fields.deinit(allocator);
    }
};

pub const PageDecl = struct {
    name: []const u8,
    statements: std.ArrayList(Statement),
    span: Span,
};

pub const FunctionDecl = struct {
    pub const Kind = enum {
        function,
        constant,
    };

    kind: Kind = .function,
    name: []const u8,
    span: Span,
    params: std.ArrayList(ParamDecl),
    result_type: Type,
    result_sort: core.SemanticSort,
    effects: ?[]const u8 = null,
    annotations: std.ArrayList(Annotation),
    statements: std.ArrayList(Statement),

    pub fn deinit(self: *FunctionDecl, allocator: Allocator) void {
        for (self.params.items) |*param| param.deinit(allocator);
        self.params.deinit(allocator);
        self.result_type.deinit(allocator);
        if (self.effects) |effects| allocator.free(effects);
        for (self.annotations.items) |*annotation| annotation.deinit(allocator);
        self.annotations.deinit(allocator);
        for (self.statements.items) |*stmt| stmt.deinit(allocator);
        self.statements.deinit(allocator);
    }
};

pub const Annotation = struct {
    name: []const u8,
    args: std.ArrayList(AnnotationArg),
    span: Span,

    pub fn deinit(self: *Annotation, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.args.items) |*arg| arg.deinit(allocator);
        self.args.deinit(allocator);
    }
};

pub const AnnotationArg = union(enum) {
    positional: AnnotationValue,
    named: struct {
        name: []const u8,
        value: AnnotationValue,
    },

    pub fn deinit(self: *AnnotationArg, allocator: Allocator) void {
        switch (self.*) {
            .positional => |*value| value.deinit(allocator),
            .named => |*named| {
                allocator.free(named.name);
                named.value.deinit(allocator);
            },
        }
    }
};

pub const AnnotationValue = union(enum) {
    ident: []const u8,
    string: []const u8,
    expr: Expr,
    list: std.ArrayList(AnnotationValue),

    pub fn deinit(self: *AnnotationValue, allocator: Allocator) void {
        switch (self.*) {
            .ident, .string => |text| allocator.free(text),
            .expr => |*expr| expr.deinit(allocator),
            .list => |*items| {
                for (items.items) |*item| item.deinit(allocator);
                items.deinit(allocator);
            },
        }
    }
};

pub const ParamDecl = struct {
    name: []const u8,
    ty: Type,
    sort: core.SemanticSort,
    default_value: ?*Expr = null,

    pub fn deinit(self: *ParamDecl, allocator: Allocator) void {
        self.ty.deinit(allocator);
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

pub const ApplyExpr = struct {
    callee: *Expr,
    args: std.ArrayList(Expr),

    pub fn deinit(self: *ApplyExpr, allocator: Allocator) void {
        self.callee.deinit(allocator);
        allocator.destroy(self.callee);
        for (self.args.items) |*arg| arg.deinit(allocator);
        self.args.deinit(allocator);
    }
};

pub const LambdaExpr = struct {
    params: std.ArrayList(ParamDecl),
    body: *Expr,
    span: Span,

    pub fn deinit(self: *LambdaExpr, allocator: Allocator) void {
        for (self.params.items) |*param| param.deinit(allocator);
        self.params.deinit(allocator);
        self.body.deinit(allocator);
        allocator.destroy(self.body);
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
    boolean: bool,
    call: CallExpr,
    apply: ApplyExpr,
    lambda: LambdaExpr,

    pub fn deinit(self: *Expr, allocator: Allocator) void {
        switch (self.*) {
            .call => |*call| call.deinit(allocator),
            .apply => |*apply| apply.deinit(allocator),
            .lambda => |*lambda| lambda.deinit(allocator),
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
        let_binding: struct {
            name: []const u8,
            expr: Expr,
        },
        return_expr: Expr,
        return_void,
        constrain: ConstraintDecl,
        property_set: struct {
            object_name: []const u8,
            property_name: []const u8,
            value: Expr,
        },
        if_stmt: struct {
            condition: Expr,
            then_statements: std.ArrayList(Statement),
            else_statements: std.ArrayList(Statement),
        },
        expr_stmt: Expr,
    };

    pub fn deinit(self: *Statement, allocator: Allocator) void {
        switch (self.kind) {
            .let_binding => |*binding| binding.expr.deinit(allocator),
            .return_expr => |*expr| expr.deinit(allocator),
            .return_void => {},
            .constrain => |*decl| decl.deinit(allocator),
            .property_set => |*property_set| property_set.value.deinit(allocator),
            .if_stmt => |*if_stmt| {
                if_stmt.condition.deinit(allocator);
                for (if_stmt.then_statements.items) |*stmt| stmt.deinit(allocator);
                if_stmt.then_statements.deinit(allocator);
                for (if_stmt.else_statements.items) |*stmt| stmt.deinit(allocator);
                if_stmt.else_statements.deinit(allocator);
            },
            .expr_stmt => |*expr| expr.deinit(allocator),
        }
    }
};
