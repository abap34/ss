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
    document_blocks: std.ArrayList(DocumentBlockDecl),
    document_statements: std.ArrayList(Statement),
    pages: std.ArrayList(PageDecl),

    pub fn init() Program {
        return .{ .imports = .empty, .top_level_items = .empty, .types = .empty, .objects = .empty, .object_extensions = .empty, .functions = .empty, .document_blocks = .empty, .document_statements = .empty, .pages = .empty };
    }

    pub fn deinit(self: *Program, allocator: Allocator) void {
        for (self.imports.items) |import_decl| {
            allocator.free(import_decl.spec);
            if (import_decl.mode.alias) |alias| allocator.free(alias);
        }
        self.imports.deinit(allocator);
        self.top_level_items.deinit(allocator);
        for (self.types.items) |*type_decl| type_decl.deinit(allocator);
        self.types.deinit(allocator);
        for (self.objects.items) |*object| object.deinit(allocator);
        self.objects.deinit(allocator);
        for (self.object_extensions.items) |*extension| extension.deinit(allocator);
        self.object_extensions.deinit(allocator);
        for (self.functions.items) |*func| func.deinit(allocator);
        self.functions.deinit(allocator);
        self.document_blocks.deinit(allocator);
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
    document: usize,
    page: usize,
};

pub const ImportDecl = struct {
    pub const Mode = struct {
        alias: ?[]const u8 = null,
        unqualified: bool = false,
    };

    spec: []const u8,
    mode: Mode,
    span: Span,
};

pub const TypeDecl = struct {
    name: []const u8,
    cases: std.ArrayList([]const u8),
    span: Span,

    pub fn deinit(self: *TypeDecl, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.cases.items) |case_name| allocator.free(case_name);
        self.cases.deinit(allocator);
    }
};

pub const ObjectFieldDecl = struct {
    name: []const u8,
    value_type: []const u8,
    default_value: ?*Expr = null,
    default_property_value: ?[]const u8 = null,
    span: Span,

    pub fn deinit(self: *ObjectFieldDecl, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value_type);
        if (self.default_value) |expr| {
            expr.deinit(allocator);
            allocator.destroy(expr);
        }
        if (self.default_property_value) |value| allocator.free(value);
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

pub const DocumentBlockDecl = struct {
    statement_start: usize,
    statement_count: usize,
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
    statements: std.ArrayList(Statement),

    pub fn deinit(self: *FunctionDecl, allocator: Allocator) void {
        for (self.params.items) |*param| param.deinit(allocator);
        self.params.deinit(allocator);
        self.result_type.deinit(allocator);
        for (self.statements.items) |*stmt| stmt.deinit(allocator);
        self.statements.deinit(allocator);
    }

    pub fn cloneSignature(self: FunctionDecl, allocator: Allocator, name: []const u8, span: Span) anyerror!FunctionDecl {
        var params = std.ArrayList(ParamDecl).empty;
        errdefer {
            for (params.items) |*param| param.deinit(allocator);
            params.deinit(allocator);
        }
        for (self.params.items) |param| {
            try params.append(allocator, try param.clone(allocator));
        }

        return .{
            .kind = self.kind,
            .name = try allocator.dupe(u8, name),
            .span = span,
            .params = params,
            .result_type = try self.result_type.clone(allocator),
            .statements = .empty,
        };
    }
};

pub const ParamDecl = struct {
    name: []const u8,
    ty: Type,
    default_value: ?*Expr = null,

    pub fn deinit(self: *ParamDecl, allocator: Allocator) void {
        self.ty.deinit(allocator);
        if (self.default_value) |expr| {
            expr.deinit(allocator);
            allocator.destroy(expr);
        }
    }

    pub fn clone(self: ParamDecl, allocator: Allocator) anyerror!ParamDecl {
        var default_value: ?*Expr = null;
        if (self.default_value) |expr| {
            const copied = try allocator.create(Expr);
            errdefer allocator.destroy(copied);
            copied.* = try expr.clone(allocator);
            default_value = copied;
        }
        return .{
            .name = try allocator.dupe(u8, self.name),
            .ty = try self.ty.clone(allocator),
            .default_value = default_value,
        };
    }
};

pub const CallableName = struct {
    qualifier: ?[]const u8 = null,
    name: []const u8,

    pub fn bare(name: []const u8) CallableName {
        return .{ .name = name };
    }

    pub fn qualified(qualifier: []const u8, name: []const u8) CallableName {
        return .{ .qualifier = qualifier, .name = name };
    }

    pub fn isQualified(self: CallableName) bool {
        return self.qualifier != null;
    }

    pub fn displayAlloc(self: CallableName, allocator: Allocator) ![]const u8 {
        if (self.qualifier) |qualifier| {
            return std.fmt.allocPrint(allocator, "{s}::{s}", .{ qualifier, self.name });
        }
        return allocator.dupe(u8, self.name);
    }

    pub fn clone(self: CallableName, allocator: Allocator) !CallableName {
        return .{
            .qualifier = if (self.qualifier) |qualifier| try allocator.dupe(u8, qualifier) else null,
            .name = try allocator.dupe(u8, self.name),
        };
    }
};

pub const CallExpr = struct {
    callee: CallableName,
    args: std.ArrayList(Expr),

    pub fn deinit(self: *CallExpr, allocator: Allocator) void {
        for (self.args.items) |*arg| arg.deinit(allocator);
        self.args.deinit(allocator);
    }

    pub fn clone(self: CallExpr, allocator: Allocator) anyerror!CallExpr {
        var args = std.ArrayList(Expr).empty;
        errdefer {
            for (args.items) |*arg| arg.deinit(allocator);
            args.deinit(allocator);
        }
        for (self.args.items) |arg| {
            try args.append(allocator, try arg.clone(allocator));
        }
        return .{
            .callee = try self.callee.clone(allocator),
            .args = args,
        };
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

    pub fn clone(self: ApplyExpr, allocator: Allocator) anyerror!ApplyExpr {
        const callee = try allocator.create(Expr);
        errdefer allocator.destroy(callee);
        callee.* = try self.callee.clone(allocator);

        var args = std.ArrayList(Expr).empty;
        errdefer {
            for (args.items) |*arg| arg.deinit(allocator);
            args.deinit(allocator);
        }
        for (self.args.items) |arg| {
            try args.append(allocator, try arg.clone(allocator));
        }

        return .{
            .callee = callee,
            .args = args,
        };
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

    pub fn clone(self: LambdaExpr, allocator: Allocator) anyerror!LambdaExpr {
        var params = std.ArrayList(ParamDecl).empty;
        errdefer {
            for (params.items) |*param| param.deinit(allocator);
            params.deinit(allocator);
        }
        for (self.params.items) |param| {
            try params.append(allocator, try param.clone(allocator));
        }

        const body = try allocator.create(Expr);
        errdefer allocator.destroy(body);
        body.* = try self.body.clone(allocator);

        return .{
            .params = params,
            .body = body,
            .span = self.span,
        };
    }
};

pub const MemberExpr = struct {
    target: *Expr,
    name: []const u8,

    pub fn deinit(self: *MemberExpr, allocator: Allocator) void {
        self.target.deinit(allocator);
        allocator.destroy(self.target);
        allocator.free(self.name);
    }

    pub fn clone(self: MemberExpr, allocator: Allocator) anyerror!MemberExpr {
        const target = try allocator.create(Expr);
        errdefer allocator.destroy(target);
        target.* = try self.target.clone(allocator);
        return .{
            .target = target,
            .name = try allocator.dupe(u8, self.name),
        };
    }
};

pub const EnumCaseExpr = struct {
    enum_name: []const u8,
    case_name: []const u8,

    pub fn deinit(self: *EnumCaseExpr, allocator: Allocator) void {
        allocator.free(self.enum_name);
        allocator.free(self.case_name);
    }

    pub fn clone(self: EnumCaseExpr, allocator: Allocator) anyerror!EnumCaseExpr {
        return .{
            .enum_name = try allocator.dupe(u8, self.enum_name),
            .case_name = try allocator.dupe(u8, self.case_name),
        };
    }
};

pub const OptionalCheckExpr = struct {
    target: *Expr,

    pub fn deinit(self: *OptionalCheckExpr, allocator: Allocator) void {
        self.target.deinit(allocator);
        allocator.destroy(self.target);
    }

    pub fn clone(self: OptionalCheckExpr, allocator: Allocator) anyerror!OptionalCheckExpr {
        const target = try allocator.create(Expr);
        errdefer allocator.destroy(target);
        target.* = try self.target.clone(allocator);
        return .{ .target = target };
    }
};

pub const CoalesceExpr = struct {
    target: *Expr,
    fallback: *Expr,

    pub fn deinit(self: *CoalesceExpr, allocator: Allocator) void {
        self.target.deinit(allocator);
        allocator.destroy(self.target);
        self.fallback.deinit(allocator);
        allocator.destroy(self.fallback);
    }

    pub fn clone(self: CoalesceExpr, allocator: Allocator) anyerror!CoalesceExpr {
        const target = try allocator.create(Expr);
        errdefer allocator.destroy(target);
        target.* = try self.target.clone(allocator);

        const fallback = try allocator.create(Expr);
        errdefer allocator.destroy(fallback);
        fallback.* = try self.fallback.clone(allocator);

        return .{
            .target = target,
            .fallback = fallback,
        };
    }
};

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const Expr = union(enum) {
    ident: []const u8,
    string: []const u8,
    color: []const u8,
    number: f32,
    boolean: bool,
    none,
    call: CallExpr,
    apply: ApplyExpr,
    lambda: LambdaExpr,
    member: MemberExpr,
    enum_case: EnumCaseExpr,
    optional_check: OptionalCheckExpr,
    coalesce: CoalesceExpr,

    pub fn deinit(self: *Expr, allocator: Allocator) void {
        switch (self.*) {
            .ident, .string, .color => |text| allocator.free(text),
            .call => |*call| call.deinit(allocator),
            .apply => |*apply| apply.deinit(allocator),
            .lambda => |*lambda| lambda.deinit(allocator),
            .member => |*member| member.deinit(allocator),
            .enum_case => |*enum_case| enum_case.deinit(allocator),
            .optional_check => |*check| check.deinit(allocator),
            .coalesce => |*coalesce| coalesce.deinit(allocator),
            else => {},
        }
    }

    pub fn clone(self: Expr, allocator: Allocator) anyerror!Expr {
        return switch (self) {
            .ident => |text| .{ .ident = try allocator.dupe(u8, text) },
            .string => |text| .{ .string = try allocator.dupe(u8, text) },
            .color => |text| .{ .color = try allocator.dupe(u8, text) },
            .number => |value| .{ .number = value },
            .boolean => |value| .{ .boolean = value },
            .none => .none,
            .call => |call| .{ .call = try call.clone(allocator) },
            .apply => |apply| .{ .apply = try apply.clone(allocator) },
            .lambda => |lambda| .{ .lambda = try lambda.clone(allocator) },
            .member => |member| .{ .member = try member.clone(allocator) },
            .enum_case => |enum_case| .{ .enum_case = try enum_case.clone(allocator) },
            .optional_check => |check| .{ .optional_check = try check.clone(allocator) },
            .coalesce => |coalesce| .{ .coalesce = try coalesce.clone(allocator) },
        };
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
