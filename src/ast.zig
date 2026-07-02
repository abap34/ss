const std = @import("std");
const core = @import("model");
pub const types = @import("language_type");

const Allocator = std.mem.Allocator;
pub const Type = types.Type;
pub const HoleId = u32;

pub const Program = struct {
    imports: std.ArrayList(ImportDecl),
    top_level_items: std.ArrayList(TopLevelItem),
    types: std.ArrayList(TypeDecl),
    records: std.ArrayList(RecordDecl),
    objects: std.ArrayList(ObjectDecl),
    object_extensions: std.ArrayList(ObjectExtensionDecl),
    constants: std.ArrayList(ConstDecl),
    functions: std.ArrayList(FunctionDecl),
    document_blocks: std.ArrayList(DocumentBlockDecl),
    document_statements: std.ArrayList(Statement),
    pages: std.ArrayList(PageDecl),

    pub fn init() Program {
        return .{ .imports = .empty, .top_level_items = .empty, .types = .empty, .records = .empty, .objects = .empty, .object_extensions = .empty, .constants = .empty, .functions = .empty, .document_blocks = .empty, .document_statements = .empty, .pages = .empty };
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
        for (self.records.items) |*record| record.deinit(allocator);
        self.records.deinit(allocator);
        for (self.objects.items) |*object| object.deinit(allocator);
        self.objects.deinit(allocator);
        for (self.object_extensions.items) |*extension| extension.deinit(allocator);
        self.object_extensions.deinit(allocator);
        for (self.constants.items) |*constant| constant.deinit(allocator);
        self.constants.deinit(allocator);
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
    spec_span: Span,
    mode: Mode,
    alias_span: ?Span = null,
    span: Span,
};

pub const TypeDecl = struct {
    name: []const u8,
    name_span: ?Span = null,
    cases: std.ArrayList(EnumCaseDecl),
    span: Span,

    pub fn deinit(self: *TypeDecl, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.cases.items) |*case_decl| case_decl.deinit(allocator);
        self.cases.deinit(allocator);
    }
};

pub const EnumCaseDecl = struct {
    name: []const u8,
    name_span: ?Span = null,

    pub fn deinit(self: *EnumCaseDecl, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

pub const ObjectFieldDecl = struct {
    name: []const u8,
    name_span: ?Span = null,
    value_type: Type,
    default_value: ?*Expr = null,
    default_property_value: ?[]const u8 = null,
    span: Span,

    pub fn deinit(self: *ObjectFieldDecl, allocator: Allocator) void {
        allocator.free(self.name);
        self.value_type.deinit(allocator);
        if (self.default_value) |expr| {
            expr.deinit(allocator);
            allocator.destroy(expr);
        }
        if (self.default_property_value) |value| allocator.free(value);
    }
};

pub const ObjectDecl = struct {
    name: []const u8,
    name_span: ?Span = null,
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

pub const RecordDecl = struct {
    name: []const u8,
    name_span: ?Span = null,
    fields: std.ArrayList(ObjectFieldDecl),
    span: Span,

    pub fn deinit(self: *RecordDecl, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.fields.items) |*field| field.deinit(allocator);
        self.fields.deinit(allocator);
    }
};

pub const ObjectExtensionDecl = struct {
    target: []const u8,
    target_span: ?Span = null,
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
    name_span: ?Span = null,
    statements: std.ArrayList(Statement),
    span: Span,
};

pub const DocumentBlockDecl = struct {
    statement_start: usize,
    statement_count: usize,
    span: Span,
};

pub const ConstDecl = struct {
    name: []const u8,
    name_span: ?Span = null,
    span: Span,
    value_type: Type,
    value: Expr,

    pub fn deinit(self: *ConstDecl, allocator: Allocator) void {
        allocator.free(self.name);
        self.value_type.deinit(allocator);
        self.value.deinit(allocator);
    }
};

pub const FunctionDecl = struct {
    name: []const u8,
    name_span: ?Span = null,
    span: Span,
    params: std.ArrayList(ParamDecl),
    result_type: Type,
    statements: std.ArrayList(Statement),

    pub fn deinit(self: *FunctionDecl, allocator: Allocator) void {
        allocator.free(self.name);
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
            .name = try allocator.dupe(u8, name),
            .name_span = self.name_span,
            .span = span,
            .params = params,
            .result_type = try self.result_type.clone(allocator),
            .statements = .empty,
        };
    }
};

pub const ParamDecl = struct {
    name: []const u8,
    name_span: ?Span = null,
    ty: Type,
    default_value: ?*Expr = null,

    pub fn deinit(self: *ParamDecl, allocator: Allocator) void {
        allocator.free(self.name);
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
            .name_span = self.name_span,
            .ty = try self.ty.clone(allocator),
            .default_value = default_value,
        };
    }
};

pub const CallableName = struct {
    qualifier: ?[]const u8 = null,
    name: []const u8,
    name_hole: ?HoleId = null,
    qualifier_span: ?Span = null,
    name_span: ?Span = null,
    span: ?Span = null,

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
        if (self.name_hole != null) {
            if (self.qualifier) |qualifier| return std.fmt.allocPrint(allocator, "{s}::<hole>", .{qualifier});
            return allocator.dupe(u8, "<hole>");
        }
        if (self.qualifier) |qualifier| {
            return std.fmt.allocPrint(allocator, "{s}::{s}", .{ qualifier, self.name });
        }
        return allocator.dupe(u8, self.name);
    }

    pub fn clone(self: CallableName, allocator: Allocator) !CallableName {
        return .{
            .qualifier = if (self.qualifier) |qualifier| try allocator.dupe(u8, qualifier) else null,
            .name = try allocator.dupe(u8, self.name),
            .name_hole = self.name_hole,
            .qualifier_span = self.qualifier_span,
            .name_span = self.name_span,
            .span = self.span,
        };
    }
};

pub const CallExpr = struct {
    callee: CallableName,
    args: std.ArrayList(Expr),
    arg_spans: std.ArrayList(Span) = .empty,

    pub fn deinit(self: *CallExpr, allocator: Allocator) void {
        for (self.args.items) |*arg| arg.deinit(allocator);
        self.args.deinit(allocator);
        self.arg_spans.deinit(allocator);
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
        var arg_spans = std.ArrayList(Span).empty;
        errdefer arg_spans.deinit(allocator);
        try arg_spans.appendSlice(allocator, self.arg_spans.items);
        return .{
            .callee = try self.callee.clone(allocator),
            .args = args,
            .arg_spans = arg_spans,
        };
    }
};

pub const ApplyExpr = struct {
    callee: *Expr,
    args: std.ArrayList(Expr),
    arg_spans: std.ArrayList(Span) = .empty,

    pub fn deinit(self: *ApplyExpr, allocator: Allocator) void {
        self.callee.deinit(allocator);
        allocator.destroy(self.callee);
        for (self.args.items) |*arg| arg.deinit(allocator);
        self.args.deinit(allocator);
        self.arg_spans.deinit(allocator);
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
        var arg_spans = std.ArrayList(Span).empty;
        errdefer arg_spans.deinit(allocator);
        try arg_spans.appendSlice(allocator, self.arg_spans.items);

        return .{
            .callee = callee,
            .args = args,
            .arg_spans = arg_spans,
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
    name_span: ?Span = null,
    name_hole: ?HoleId = null,

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
            .name_span = self.name_span,
            .name_hole = self.name_hole,
        };
    }
};

pub const RecordFieldExpr = struct {
    name: []const u8,
    name_span: ?Span = null,
    value: Expr,

    pub fn deinit(self: *RecordFieldExpr, allocator: Allocator) void {
        allocator.free(self.name);
        self.value.deinit(allocator);
    }

    pub fn clone(self: RecordFieldExpr, allocator: Allocator) anyerror!RecordFieldExpr {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .name_span = self.name_span,
            .value = try self.value.clone(allocator),
        };
    }
};

pub const RecordExpr = struct {
    type_name: []const u8,
    type_name_span: ?Span = null,
    fields: std.ArrayList(RecordFieldExpr),

    pub fn deinit(self: *RecordExpr, allocator: Allocator) void {
        allocator.free(self.type_name);
        for (self.fields.items) |*field| field.deinit(allocator);
        self.fields.deinit(allocator);
    }

    pub fn clone(self: RecordExpr, allocator: Allocator) anyerror!RecordExpr {
        var fields = std.ArrayList(RecordFieldExpr).empty;
        errdefer {
            for (fields.items) |*field| field.deinit(allocator);
            fields.deinit(allocator);
        }
        for (self.fields.items) |field| {
            try fields.append(allocator, try field.clone(allocator));
        }
        return .{
            .type_name = try allocator.dupe(u8, self.type_name),
            .type_name_span = self.type_name_span,
            .fields = fields,
        };
    }
};

pub const RecordPathSegment = struct {
    name: []const u8,
    span: Span,
    name_hole: ?HoleId = null,

    pub fn deinit(self: *RecordPathSegment, allocator: Allocator) void {
        allocator.free(self.name);
    }

    pub fn clone(self: RecordPathSegment, allocator: Allocator) !RecordPathSegment {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .span = self.span,
            .name_hole = self.name_hole,
        };
    }
};

pub fn formatRecordPath(allocator: Allocator, path: []const RecordPathSegment) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (path, 0..) |segment, index| {
        if (index > 0) try out.append(allocator, '.');
        try out.appendSlice(allocator, segment.name);
    }
    return try out.toOwnedSlice(allocator);
}

pub fn recordPathsOverlap(left: []const RecordPathSegment, right: []const RecordPathSegment) bool {
    const shared = @min(left.len, right.len);
    for (0..shared) |index| {
        if (!std.mem.eql(u8, left[index].name, right[index].name)) return false;
    }
    return true;
}

pub const RecordUpdateFieldExpr = struct {
    path: std.ArrayList(RecordPathSegment),
    path_span: Span,
    value: Expr,
    value_span: Span,

    pub fn deinit(self: *RecordUpdateFieldExpr, allocator: Allocator) void {
        for (self.path.items) |*segment| segment.deinit(allocator);
        self.path.deinit(allocator);
        self.value.deinit(allocator);
    }

    pub fn clone(self: RecordUpdateFieldExpr, allocator: Allocator) anyerror!RecordUpdateFieldExpr {
        var path = std.ArrayList(RecordPathSegment).empty;
        errdefer {
            for (path.items) |*segment| segment.deinit(allocator);
            path.deinit(allocator);
        }
        for (self.path.items) |segment| {
            try path.append(allocator, try segment.clone(allocator));
        }
        return .{
            .path = path,
            .path_span = self.path_span,
            .value = try self.value.clone(allocator),
            .value_span = self.value_span,
        };
    }
};

pub const RecordUpdateExpr = struct {
    target: *Expr,
    fields: std.ArrayList(RecordUpdateFieldExpr),
    body_span: Span,

    pub fn deinit(self: *RecordUpdateExpr, allocator: Allocator) void {
        self.target.deinit(allocator);
        allocator.destroy(self.target);
        for (self.fields.items) |*field| field.deinit(allocator);
        self.fields.deinit(allocator);
    }

    pub fn clone(self: RecordUpdateExpr, allocator: Allocator) anyerror!RecordUpdateExpr {
        const target = try allocator.create(Expr);
        errdefer allocator.destroy(target);
        target.* = try self.target.clone(allocator);

        var fields = std.ArrayList(RecordUpdateFieldExpr).empty;
        errdefer {
            for (fields.items) |*field| field.deinit(allocator);
            fields.deinit(allocator);
        }
        for (self.fields.items) |field| {
            try fields.append(allocator, try field.clone(allocator));
        }
        return .{
            .target = target,
            .fields = fields,
            .body_span = self.body_span,
        };
    }
};

pub const EnumCaseExpr = struct {
    enum_name: []const u8,
    enum_name_span: ?Span = null,
    case_name: []const u8,
    case_name_span: ?Span = null,

    pub fn deinit(self: *EnumCaseExpr, allocator: Allocator) void {
        allocator.free(self.enum_name);
        allocator.free(self.case_name);
    }

    pub fn clone(self: EnumCaseExpr, allocator: Allocator) anyerror!EnumCaseExpr {
        return .{
            .enum_name = try allocator.dupe(u8, self.enum_name),
            .enum_name_span = self.enum_name_span,
            .case_name = try allocator.dupe(u8, self.case_name),
            .case_name_span = self.case_name_span,
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

pub const Span = types.SourceSpan;

pub const StringLiteral = struct {
    text: []const u8,
    source_span: ?Span = null,

    pub fn deinit(self: *StringLiteral, allocator: Allocator) void {
        allocator.free(self.text);
    }

    pub fn clone(self: StringLiteral, allocator: Allocator) !StringLiteral {
        return .{
            .text = try allocator.dupe(u8, self.text),
            .source_span = self.source_span,
        };
    }
};

pub const IdentifierExpr = struct {
    name: []const u8,
    name_span: ?Span = null,

    pub fn deinit(self: *IdentifierExpr, allocator: Allocator) void {
        allocator.free(self.name);
    }

    pub fn clone(self: IdentifierExpr, allocator: Allocator) !IdentifierExpr {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .name_span = self.name_span,
        };
    }
};

pub const Expr = union(enum) {
    ident: IdentifierExpr,
    hole: HoleId,
    string: StringLiteral,
    color: []const u8,
    number: f32,
    boolean: bool,
    none,
    call: CallExpr,
    apply: ApplyExpr,
    lambda: LambdaExpr,
    member: MemberExpr,
    record: RecordExpr,
    record_update: RecordUpdateExpr,
    enum_case: EnumCaseExpr,
    optional_check: OptionalCheckExpr,
    coalesce: CoalesceExpr,

    pub fn deinit(self: *Expr, allocator: Allocator) void {
        switch (self.*) {
            .ident => |*ident| ident.deinit(allocator),
            .color => |text| allocator.free(text),
            .string => |*literal| literal.deinit(allocator),
            .call => |*call| call.deinit(allocator),
            .apply => |*apply| apply.deinit(allocator),
            .lambda => |*lambda| lambda.deinit(allocator),
            .member => |*member| member.deinit(allocator),
            .record => |*record| record.deinit(allocator),
            .record_update => |*update| update.deinit(allocator),
            .enum_case => |*enum_case| enum_case.deinit(allocator),
            .optional_check => |*check| check.deinit(allocator),
            .coalesce => |*coalesce| coalesce.deinit(allocator),
            else => {},
        }
    }

    pub fn clone(self: Expr, allocator: Allocator) anyerror!Expr {
        return switch (self) {
            .ident => |ident| .{ .ident = try ident.clone(allocator) },
            .hole => |id| .{ .hole = id },
            .string => |literal| .{ .string = try literal.clone(allocator) },
            .color => |text| .{ .color = try allocator.dupe(u8, text) },
            .number => |value| .{ .number = value },
            .boolean => |value| .{ .boolean = value },
            .none => .none,
            .call => |call| .{ .call = try call.clone(allocator) },
            .apply => |apply| .{ .apply = try apply.clone(allocator) },
            .lambda => |lambda| .{ .lambda = try lambda.clone(allocator) },
            .member => |member| .{ .member = try member.clone(allocator) },
            .record => |record| .{ .record = try record.clone(allocator) },
            .record_update => |update| .{ .record_update = try update.clone(allocator) },
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
    node_path: ?[]const u8 = null,

    pub fn withAnchor(self: AnchorRef, anchor: core.Anchor) AnchorRef {
        return .{
            .kind = self.kind,
            .anchor = anchor,
            .node_name = self.node_name,
            .node_path = self.node_path,
        };
    }
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
        hole: HoleId,
        let_binding: struct {
            name: []const u8,
            name_span: ?Span = null,
            type_annotation: ?Type = null,
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
            .hole => {},
            .let_binding => |*binding| {
                allocator.free(binding.name);
                if (binding.type_annotation) |*annotation| annotation.deinit(allocator);
                binding.expr.deinit(allocator);
            },
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
