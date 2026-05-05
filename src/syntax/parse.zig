const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const names = @import("../language/names.zig");
const utils = @import("utils");
const source_utils = utils.source;
const color_utils = utils.color;

const Allocator = std.mem.Allocator;
const Program = ast.Program;
const TypeDecl = ast.TypeDecl;
const ObjectDecl = ast.ObjectDecl;
const ObjectExtensionDecl = ast.ObjectExtensionDecl;
const PropertyDecl = ast.PropertyDecl;
const FunctionDecl = ast.FunctionDecl;
const PageDecl = ast.PageDecl;
const Statement = ast.Statement;
const Expr = ast.Expr;
const ConstraintDecl = ast.ConstraintDecl;
const AnchorRef = ast.AnchorRef;

pub const ParseDiagnostic = struct {
    err: anyerror,
    span: ast.Span,
    expected: ?[]const u8 = null,
    found: ?[]const u8 = null,
};

var last_diagnostic: ?ParseDiagnostic = null;

pub fn parse(allocator: Allocator, source: []const u8) !Program {
    var parser = Parser{
        .allocator = allocator,
        .source = source,
        .pos = 0,
        .error_pos = 0,
    };
    last_diagnostic = null;
    return parser.parseProgram() catch |err| {
        const pos = @min(parser.error_pos, source.len);
        last_diagnostic = .{
            .err = err,
            .span = .{ .start = pos, .end = @min(pos + 1, source.len) },
            .expected = parseExpected(err),
            .found = foundToken(source, pos),
        };
        return err;
    };
}

pub fn lastDiagnostic() ?ParseDiagnostic {
    return last_diagnostic;
}

const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    pos: usize,
    error_pos: usize,

    fn parseProgram(self: *Parser) !Program {
        var program = Program.init();
        errdefer program.deinit(self.allocator);

        self.skipTrivia();
        while (!self.eof()) {
            const item_start = self.pos;
            if (try self.consumeKeyword("import")) {
                const spec = try self.parseImportSpec();
                try self.consumeStatementTerminator();
                try program.imports.append(self.allocator, .{
                    .spec = spec,
                    .span = .{ .start = item_start, .end = self.pos },
                });
            } else if (try self.consumeKeyword("fn")) {
                const func = try self.parseFunctionAfterKeyword(item_start);
                try program.functions.append(self.allocator, func);
            } else if (try self.consumeKeyword("const")) {
                const constant = try self.parseConstAfterKeyword(item_start);
                try program.functions.append(self.allocator, constant);
            } else if (try self.consumeKeyword("type")) {
                const type_item = try self.parseTypeItemAfterKeyword(item_start);
                switch (type_item) {
                    .alias => |type_decl| {
                        try self.consumeStatementTerminator();
                        try program.types.append(self.allocator, type_decl);
                    },
                    .object => |object_decl| try program.objects.append(self.allocator, object_decl),
                }
            } else if (try self.consumeKeyword("extend")) {
                const extension = try self.parseObjectExtensionAfterKeyword(item_start);
                try program.object_extensions.append(self.allocator, extension);
            } else if (try self.consumeKeyword("property")) {
                const property = try self.parsePropertyAfterKeyword(item_start);
                try program.properties.append(self.allocator, property);
            } else {
                const page = try self.parsePage();
                try program.pages.append(self.allocator, page);
            }
            self.skipTrivia();
        }
        return program;
    }

    fn parseFunctionAfterKeyword(self: *Parser, start: usize) !FunctionDecl {
        const name = try self.parseIdentifier();
        self.skipInlineSpaces();
        try self.expectChar('(');

        var params = std.ArrayList(ast.ParamDecl).empty;
        errdefer {
            for (params.items) |*param| param.deinit(self.allocator);
            params.deinit(self.allocator);
        }
        var seen_default = false;
        self.skipTrivia();
        while (!self.eof() and !self.peekChar(')')) {
            const param_name = try self.parseIdentifier();
            self.skipInlineSpaces();
            if (self.eof() or self.source[self.pos] != ':') return self.fail(error.ExpectedTypeAnnotation);
            self.pos += 1;
            self.skipInlineSpaces();
            const param_type = try self.parseTypeAnnotation();
            const param_sort = try self.runtimeSortForType(param_type);
            self.skipInlineSpaces();
            var default_value: ?*Expr = null;
            if (!self.eof() and self.source[self.pos] == '=') {
                self.pos += 1;
                const expr = try self.allocator.create(Expr);
                errdefer self.allocator.destroy(expr);
                expr.* = try self.parseExpr();
                default_value = expr;
                seen_default = true;
            } else if (seen_default) {
                return self.fail(error.RequiredParameterAfterDefault);
            }
            try params.append(self.allocator, .{
                .name = param_name,
                .ty = param_type,
                .sort = param_sort,
                .default_value = default_value,
            });
            self.skipTrivia();
            if (!self.eof() and self.source[self.pos] == ',') {
                self.pos += 1;
                self.skipTrivia();
                continue;
            }
            break;
        }
        try self.expectChar(')');
        self.skipInlineSpaces();
        if (!self.startsWith("->")) return self.fail(error.ExpectedTypeAnnotation);
        self.pos += 2;
        self.skipInlineSpaces();
        const result_type = try self.parseTypeAnnotation();
        const result_sort = try self.runtimeSortForType(result_type);
        const annotations = try self.parseAnnotations();

        const bodyless = annotationsAllowBodyless(annotations.items);
        var statements = std.ArrayList(Statement).empty;
        if (bodyless and self.atStatementBoundary()) {
            try self.consumeStatementTerminator();
        } else {
            statements = try self.parseBodyStatements();
            if (!functionBodyReturns(statements.items)) return self.fail(error.ExpectedReturn);
        }
        return .{ .name = name, .span = .{ .start = start, .end = self.pos }, .params = params, .result_type = result_type, .result_sort = result_sort, .annotations = annotations, .statements = statements };
    }

    fn parseConstAfterKeyword(self: *Parser, start: usize) !FunctionDecl {
        const name = try self.parseIdentifier();
        self.skipInlineSpaces();
        if (self.eof() or self.source[self.pos] != ':') return self.fail(error.ExpectedTypeAnnotation);
        self.pos += 1;
        self.skipInlineSpaces();
        const result_type = try self.parseTypeAnnotation();
        const result_sort = try self.runtimeSortForType(result_type);
        self.skipTrivia();
        try self.expectChar('=');
        const expr_start = self.pos;
        const expr = try self.parseExpr();
        try self.consumeStatementTerminator();

        var statements = std.ArrayList(Statement).empty;
        errdefer statements.deinit(self.allocator);
        try statements.append(self.allocator, .{
            .span = .{ .start = expr_start, .end = self.pos },
            .kind = .{ .return_expr = expr },
        });

        return .{
            .kind = .constant,
            .name = name,
            .span = .{ .start = start, .end = self.pos },
            .params = std.ArrayList(ast.ParamDecl).empty,
            .result_type = result_type,
            .result_sort = result_sort,
            .annotations = std.ArrayList(ast.Annotation).empty,
            .statements = statements,
        };
    }

    const TypeItem = union(enum) {
        alias: TypeDecl,
        object: ObjectDecl,
    };

    fn parseTypeItemAfterKeyword(self: *Parser, start: usize) !TypeItem {
        const name = try self.parseIdentifier();
        self.skipInlineSpaces();
        try self.expectChar('=');
        self.skipInlineSpaces();
        if (try self.consumeKeyword("object")) {
            return .{ .object = try self.parseObjectDeclBody(start, name) };
        }
        if (try self.consumeKeyword("protocol")) {
            return .{ .object = try self.parseObjectDeclBody(start, name) };
        }
        const body_start = self.pos;
        while (!self.eof() and self.source[self.pos] != '\n' and self.source[self.pos] != '@') {
            if (self.lineCommentStart()) break;
            self.pos += 1;
        }
        const body = trimRightSpaces(self.source[body_start..self.pos]);
        if (body.len == 0) return self.fail(error.ExpectedTypeAnnotation);
        var annotations = try self.parseAnnotations();
        defer {
            for (annotations.items) |*annotation| annotation.deinit(self.allocator);
            annotations.deinit(self.allocator);
        }
        const refinement = try self.refinementFromAnnotations(annotations.items);
        return .{ .alias = .{
            .name = name,
            .body = try self.allocator.dupe(u8, body),
            .refinement = refinement,
            .span = .{ .start = start, .end = self.pos },
        } };
    }

    fn parseObjectExtensionAfterKeyword(self: *Parser, start: usize) !ObjectExtensionDecl {
        const target = try self.parseIdentifier();
        self.skipTrivia();
        try self.expectChar('{');
        var extension = ObjectExtensionDecl{
            .target = target,
            .roles = .empty,
            .fields = .empty,
            .span = .{ .start = start, .end = start },
        };
        errdefer extension.deinit(self.allocator);
        try self.parseObjectMembers(null, &extension.implements, &extension.roles, &extension.fields);
        extension.span.end = self.pos;
        return extension;
    }

    fn parseObjectDeclBody(self: *Parser, start: usize, name: []const u8) !ObjectDecl {
        self.skipTrivia();
        try self.expectChar('{');
        var decl = ObjectDecl{
            .name = name,
            .roles = .empty,
            .fields = .empty,
            .span = .{ .start = start, .end = start },
        };
        errdefer decl.deinit(self.allocator);
        try self.parseObjectMembers(&decl.base, null, &decl.roles, &decl.fields);
        decl.span.end = self.pos;
        return decl;
    }

    fn parseObjectMembers(
        self: *Parser,
        maybe_base: ?*?[]const u8,
        maybe_implements: ?*?[]const u8,
        roles: *std.ArrayList([]const u8),
        fields: *std.ArrayList(ast.ObjectFieldDecl),
    ) !void {
        self.skipTrivia();
        while (!self.eof() and !self.peekChar('}')) {
            const member_start = self.pos;
            const name = try self.parseIdentifier();
            self.skipInlineSpaces();
            if (!self.eof() and self.source[self.pos] == '=') {
                self.pos += 1;
                self.skipTrivia();
                if (std.mem.eql(u8, name, "base")) {
                    if (maybe_base) |base| {
                        if (base.*) |existing| self.allocator.free(existing);
                        base.* = try self.parseIdentifier();
                    } else {
                        return self.fail(error.ExpectedIdentifier);
                    }
                } else if (std.mem.eql(u8, name, "implements")) {
                    if (maybe_implements) |implements| {
                        if (implements.*) |existing| self.allocator.free(existing);
                        implements.* = try self.parseIdentifier();
                    } else {
                        return self.fail(error.ExpectedIdentifier);
                    }
                } else if (std.mem.eql(u8, name, "roles")) {
                    try self.parseStringListInto(roles);
                } else {
                    return self.fail(error.ExpectedTypeAnnotation);
                }
                self.allocator.free(name);
                try self.consumeStatementTerminator();
                self.skipTrivia();
                continue;
            }
            if (self.eof() or self.source[self.pos] != ':') return self.fail(error.ExpectedTypeAnnotation);
            self.pos += 1;
            self.skipInlineSpaces();
            const type_start = self.pos;
            while (!self.eof() and self.source[self.pos] != '=' and self.source[self.pos] != '\n' and self.source[self.pos] != '}') {
                if (self.lineCommentStart()) break;
                self.pos += 1;
            }
            const type_text = trimRightSpaces(self.source[type_start..self.pos]);
            if (type_text.len == 0) return self.fail(error.ExpectedTypeAnnotation);
            var default_value: ?[]const u8 = null;
            self.skipInlineSpaces();
            if (!self.eof() and self.source[self.pos] == '=') {
                self.pos += 1;
                const default_start = self.pos;
                while (!self.eof() and self.source[self.pos] != '\n' and self.source[self.pos] != '}') {
                    if (self.lineCommentStart()) break;
                    self.pos += 1;
                }
                const default_text = trimRightSpaces(trimLeftSpaces(self.source[default_start..self.pos]));
                default_value = try self.allocator.dupe(u8, default_text);
            }
            try fields.append(self.allocator, .{
                .name = name,
                .value_type = try self.allocator.dupe(u8, type_text),
                .default_value = default_value,
                .span = .{ .start = member_start, .end = self.pos },
            });
            try self.consumeStatementTerminator();
            self.skipTrivia();
        }
        try self.expectChar('}');
        try self.consumeStatementTerminator();
    }

    fn parseStringListInto(self: *Parser, out: *std.ArrayList([]const u8)) !void {
        self.skipTrivia();
        try self.expectChar('[');
        self.skipTrivia();
        while (!self.eof() and !self.peekChar(']')) {
            try out.append(self.allocator, try self.parseString());
            self.skipTrivia();
            if (!self.eof() and self.source[self.pos] == ',') {
                self.pos += 1;
                self.skipTrivia();
                continue;
            }
            break;
        }
        try self.expectChar(']');
    }

    fn parseAnnotations(self: *Parser) !std.ArrayList(ast.Annotation) {
        var annotations = std.ArrayList(ast.Annotation).empty;
        errdefer {
            for (annotations.items) |*annotation| annotation.deinit(self.allocator);
            annotations.deinit(self.allocator);
        }
        while (true) {
            self.skipInlineSpaces();
            if (self.eof() or self.source[self.pos] != '@') break;
            const start = self.pos;
            self.pos += 1;
            const name = try self.parseIdentifier();
            self.skipInlineSpaces();
            var args: ?[]const u8 = null;
            if (!self.eof() and self.source[self.pos] == '(') {
                args = try self.parseAnnotationArgs();
            }
            try annotations.append(self.allocator, .{
                .name = name,
                .args = args,
                .span = .{ .start = start, .end = self.pos },
            });
        }
        return annotations;
    }

    fn parseAnnotationArgs(self: *Parser) ![]const u8 {
        try self.expectChar('(');
        const start = self.pos;
        var depth: usize = 1;
        while (!self.eof()) {
            const ch = self.source[self.pos];
            if (ch == '"') {
                const ignored = try self.parseString();
                self.allocator.free(ignored);
                continue;
            }
            self.pos += 1;
            if (ch == '(') {
                depth += 1;
            } else if (ch == ')') {
                depth -= 1;
                if (depth == 0) {
                    const raw = trimRightSpaces(self.source[start .. self.pos - 1]);
                    return self.allocator.dupe(u8, raw);
                }
            }
        }
        return self.fail(error.ExpectedChar);
    }

    fn refinementFromAnnotations(self: *Parser, annotations: []const ast.Annotation) !?[]const u8 {
        for (annotations) |annotation| {
            if (!std.mem.eql(u8, annotation.name, "refine")) continue;
            return try self.allocator.dupe(u8, annotation.args orelse "");
        }
        return null;
    }

    fn parsePropertyAfterKeyword(self: *Parser, start: usize) !PropertyDecl {
        const key = try self.parseIdentifier();
        self.skipInlineSpaces();
        try self.expectChar(':');
        const value_type = try self.parseIdentifier();
        self.skipTrivia();
        try self.expectChar('{');
        self.skipTrivia();
        try self.expectKeyword("target");
        self.skipInlineSpaces();
        try self.expectChar(':');

        var shapes = std.ArrayList([]const u8).empty;
        errdefer {
            for (shapes.items) |shape| self.allocator.free(shape);
            shapes.deinit(self.allocator);
        }
        while (true) {
            try shapes.append(self.allocator, try self.parseIdentifier());
            self.skipInlineSpaces();
            if (self.eof() or self.source[self.pos] != '|') break;
            self.pos += 1;
            self.skipInlineSpaces();
        }
        self.skipTrivia();
        try self.expectChar('}');
        try self.consumeStatementTerminator();

        return .{
            .key = key,
            .value_type = value_type,
            .shapes = shapes,
            .span = .{ .start = start, .end = self.pos },
        };
    }

    fn parseTypeAnnotation(self: *Parser) anyerror!ast.Type {
        const name = try self.parseIdentifier();
        if (std.mem.eql(u8, name, "document")) return ast.Type.document;
        if (std.mem.eql(u8, name, "page")) return ast.Type.page;
        if (std.mem.eql(u8, name, "object")) return try self.parseObjectType(name);
        if (std.mem.eql(u8, name, "anchor")) return ast.Type.anchor;
        if (std.mem.eql(u8, name, "function")) return ast.Type.function;
        if (std.mem.eql(u8, name, "style")) return ast.Type.style;
        if (std.mem.eql(u8, name, "string")) return ast.Type.string;
        if (std.mem.eql(u8, name, "number")) return ast.Type.number;
        if (std.mem.eql(u8, name, "constraints")) return ast.Type.constraints;
        if (std.mem.eql(u8, name, "selection")) return ast.Type.selectionType(try self.parseOptionalTypeParam());
        if (std.mem.eql(u8, name, "fragment")) return ast.Type.fragment((try self.parseOptionalTypeParam()).tag);
        if (std.mem.eql(u8, name, "code")) return ast.Type.code(try self.parseRequiredTypeParam());
        if (std.mem.eql(u8, name, "list")) return ast.Type.list(try self.parseRequiredTypeParam());
        return self.fail(error.InvalidSemanticSort);
    }

    fn parseObjectType(self: *Parser, object_name: []const u8) anyerror!ast.Type {
        self.skipInlineSpaces();
        if (self.eof() or self.source[self.pos] != '<') return ast.Type.object;
        try self.expectChar('<');
        const class_name = try self.parseIdentifier();
        try self.expectChar('>');
        self.allocator.free(object_name);
        return ast.Type.objectClass(class_name);
    }

    fn parseOptionalTypeParam(self: *Parser) anyerror!ast.Type {
        self.skipInlineSpaces();
        if (self.eof() or self.source[self.pos] != '<') return ast.Type.any;
        return try self.parseTypeParam();
    }

    fn parseRequiredTypeParam(self: *Parser) anyerror!ast.Type.Tag {
        self.skipInlineSpaces();
        if (self.eof() or self.source[self.pos] != '<') return self.fail(error.ExpectedTypeAnnotation);
        return (try self.parseTypeParam()).tag;
    }

    fn parseTypeParam(self: *Parser) anyerror!ast.Type {
        try self.expectChar('<');
        const inner = try self.parseTypeAnnotation();
        try self.expectChar('>');
        return inner;
    }

    fn runtimeSortForType(self: *Parser, ty: ast.Type) anyerror!core.SemanticSort {
        return ty.toRuntimeSort() orelse self.fail(error.InvalidSemanticSort);
    }

    fn parsePage(self: *Parser) !PageDecl {
        try self.expectKeyword("page");
        const name = try self.parsePageName();
        const statements = try self.parseBodyStatements();
        return .{
            .name = name,
            .statements = statements,
        };
    }

    fn parsePageName(self: *Parser) ![]const u8 {
        self.skipInlineSpaces();
        if (!self.eof() and self.source[self.pos] == '"') {
            return self.parseString();
        }

        const start = self.pos;
        while (!self.eof()) {
            const ch = self.source[self.pos];
            if (isInlineSpace(ch) or ch == '\n') break;
            if (ch == '#') break;
            if (ch == ';' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == ';') break;
            if (ch == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') break;
            self.pos += 1;
        }
        if (start == self.pos) return self.fail(error.ExpectedString);
        return self.allocator.dupe(u8, self.source[start..self.pos]);
    }

    fn parseImportSpec(self: *Parser) ![]const u8 {
        self.skipInlineSpaces();
        if (!self.eof() and (self.source[self.pos] == '"' or self.startsWith("\"\"\""))) {
            return self.parseString();
        }
        const start = self.pos;
        while (!self.eof()) {
            const ch = self.source[self.pos];
            if (isInlineSpace(ch) or ch == '\n') break;
            if (ch == '#') break;
            if (ch == ';' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == ';') break;
            if (ch == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') break;
            self.pos += 1;
        }
        if (start == self.pos) return self.fail(error.ExpectedString);
        return self.allocator.dupe(u8, self.source[start..self.pos]);
    }

    fn parseBodyStatements(self: *Parser) !std.ArrayList(Statement) {
        self.skipInlineSpaces();
        try self.expectLineBreakAfterHeader();
        return try self.parseStatementsUntilEnd();
    }

    fn parseStatementsUntilEnd(self: *Parser) !std.ArrayList(Statement) {
        var statements = std.ArrayList(Statement).empty;
        errdefer {
            for (statements.items) |*stmt| stmt.deinit(self.allocator);
            statements.deinit(self.allocator);
        }

        self.skipTrivia();
        while (!self.eof()) {
            if (self.peekStandaloneKeyword("end")) {
                try self.consumeStandaloneKeyword("end");
                return statements;
            }
            try statements.append(self.allocator, try self.parseStatement());
            self.skipTrivia();
        }
        return self.fail(error.ExpectedEnd);
    }

    fn parseStatement(self: *Parser) !Statement {
        self.skipTrivia();
        const start = self.pos;

        if (try self.consumeKeyword("return")) {
            const expr = try self.parseExpr();
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .return_expr = expr } };
        }
        if (try self.consumeKeyword("let")) {
            const name = try self.parseIdentifier();
            self.skipTrivia();
            try self.expectChar('=');
            const expr = try self.parseExpr();
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .let_binding = .{ .name = name, .expr = expr } } };
        }
        if (try self.consumeKeyword("bind")) {
            const name = try self.parseIdentifier();
            self.skipTrivia();
            try self.expectChar('=');
            const expr = try self.parseExpr();
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .bind_binding = .{ .name = name, .expr = expr } } };
        }
        if (try self.consumeKeyword("constrain")) {
            const decl = try self.parseConstraintDecl();
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .constrain = decl } };
        }
        if (self.peekAnchorAssignment()) {
            const decl = try self.parseMemberConstraintDecl();
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .constrain = decl } };
        }
        if (self.peekPropertyAssignment()) {
            const object_name = try self.parseIdentifier();
            self.skipInlineSpaces();
            try self.expectChar('.');
            const property_name = try self.parseIdentifier();
            self.skipTrivia();
            try self.expectChar('=');
            if (!self.eof() and self.source[self.pos] == '=') return self.fail(error.ExpectedChar);
            const value = try self.parseExpr();
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .property_set = .{
                .object_name = object_name,
                .property_name = property_name,
                .value = value,
            } } };
        }
        if (self.peekSimpleAssignment()) {
            return self.fail(error.AssignmentRequiresLet);
        }

        return try self.parseCallSugarStatement(start);
    }

    fn parseCallSugarStatement(self: *Parser, start: usize) !Statement {
        const name = try self.parseIdentifier();
        self.skipInlineSpaces();

        if (!self.eof() and self.source[self.pos] == '(') {
            const call = try self.parseCallAfterName(name);
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .expr_stmt = .{ .call = call } } };
        }

        if (self.startsWith("<<")) {
            const text = try self.parseChevronBlockString();
            const call = try self.makeUnaryStringCall(name, text);
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .expr_stmt = .{ .call = call } } };
        }

        if (!self.eof() and (self.source[self.pos] == '"' or self.startsWith("\"\"\""))) {
            const text = try self.parseString();
            const call = try self.makeUnaryStringCall(name, text);
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .expr_stmt = .{ .call = call } } };
        }

        if (self.atStatementBoundary()) return self.fail(error.ZeroArgCallRequiresParens);

        const text = try self.parseLineText();
        const call = try self.makeUnaryStringCall(name, text);
        try self.consumeStatementTerminator();
        return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .expr_stmt = .{ .call = call } } };
    }

    fn parseExpr(self: *Parser) anyerror!Expr {
        return self.parseAddSubExpr();
    }

    fn parseAddSubExpr(self: *Parser) anyerror!Expr {
        var left = try self.parseMulDivExpr();
        while (true) {
            self.skipTrivia();
            if (self.eof()) return left;
            const op = self.source[self.pos];
            if (op != '+' and op != '-') return left;
            self.pos += 1;
            const right = try self.parseMulDivExpr();
            left = try self.makeBinaryCall(if (op == '+') "add" else "sub", left, right);
        }
    }

    fn parseMulDivExpr(self: *Parser) anyerror!Expr {
        var left = try self.parseUnaryExpr();
        while (true) {
            self.skipTrivia();
            if (self.eof()) return left;
            const op = self.source[self.pos];
            if (op != '*' and op != '/') return left;
            self.pos += 1;
            const right = try self.parseUnaryExpr();
            left = try self.makeBinaryCall(if (op == '*') "mul" else "div", left, right);
        }
    }

    fn parseUnaryExpr(self: *Parser) anyerror!Expr {
        self.skipTrivia();
        if (!self.eof() and self.source[self.pos] == '-') {
            self.pos += 1;
            var args = std.ArrayList(Expr).empty;
            errdefer args.deinit(self.allocator);
            try args.append(self.allocator, try self.parseUnaryExpr());
            return .{ .call = .{ .name = "neg", .args = args } };
        }
        return self.parsePrimaryExpr();
    }

    fn parsePrimaryExpr(self: *Parser) anyerror!Expr {
        self.skipTrivia();
        if (!self.eof() and self.source[self.pos] == '(') {
            self.pos += 1;
            const expr = try self.parseExpr();
            try self.expectChar(')');
            return expr;
        }
        if (self.startsColorLiteral()) {
            return .{ .string = try self.parseColorLiteralString() };
        }
        if (!self.eof() and (self.source[self.pos] == '"' or self.startsWith("\"\"\""))) {
            return .{ .string = try self.parseString() };
        }
        if (self.startsWith("<<")) {
            return .{ .string = try self.parseChevronBlockString() };
        }
        if (self.startsNumberLiteral()) {
            return .{ .number = try self.parseNumber() };
        }
        const name = try self.parseIdentifier();
        self.skipInlineSpaces();
        if (!self.eof() and self.source[self.pos] == '.') {
            return try self.parseAnchorMemberExprAfterObjectName(name);
        }
        if (!self.eof() and self.source[self.pos] == '(') {
            return .{ .call = try self.parseCallAfterName(name) };
        }
        if (self.startsWith("<<")) {
            return .{ .call = try self.makeUnaryStringCall(name, try self.parseChevronBlockString()) };
        }
        if (!self.eof() and (self.source[self.pos] == '"' or self.startsWith("\"\"\""))) {
            return .{ .call = try self.makeUnaryStringCall(name, try self.parseString()) };
        }
        if (!self.eof() and self.source[self.pos] != '(') {
            return .{ .ident = name };
        }
        return .{ .ident = name };
    }

    fn makeBinaryCall(self: *Parser, name: []const u8, left: Expr, right: Expr) !Expr {
        var args = std.ArrayList(Expr).empty;
        errdefer args.deinit(self.allocator);
        try args.append(self.allocator, left);
        try args.append(self.allocator, right);
        return .{ .call = .{ .name = name, .args = args } };
    }

    fn parseCallAfterName(self: *Parser, name: []const u8) anyerror!ast.CallExpr {
        try self.expectChar('(');
        var args = std.ArrayList(Expr).empty;
        errdefer args.deinit(self.allocator);

        self.skipTrivia();
        while (!self.eof() and self.source[self.pos] != ')') {
            try args.append(self.allocator, try self.parseExpr());
            self.skipTrivia();
            if (!self.eof() and self.source[self.pos] == ',') {
                self.pos += 1;
                self.skipTrivia();
                continue;
            }
            break;
        }
        if (self.eof() or self.source[self.pos] != ')') return self.fail(error.ExpectedChar);
        self.pos += 1;
        return .{ .name = name, .args = args };
    }

    fn makeUnaryStringCall(self: *Parser, name: []const u8, text: []const u8) !ast.CallExpr {
        var args = std.ArrayList(Expr).empty;
        errdefer args.deinit(self.allocator);
        try args.append(self.allocator, .{ .string = text });
        return .{ .name = name, .args = args };
    }

    fn parseConstraintDecl(self: *Parser) !ConstraintDecl {
        const target = try self.parseAnchorRef();
        try self.expectEqualityOperator();
        const source = try self.parseAnchorRef();
        var offset: ?Expr = null;
        self.skipTrivia();
        if (!self.eof() and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
            const sign = self.source[self.pos];
            self.pos += 1;
            var expr = try self.parseExpr();
            if (sign == '-') expr = try self.makeNegCall(expr);
            offset = expr;
        }
        return .{ .target = target, .source = source, .offset = offset };
    }

    fn parseMemberConstraintDecl(self: *Parser) !ConstraintDecl {
        const target = try self.parseConstraintMemberRef(true);
        try self.expectEqualityOperator();
        if (target.dimension) |dimension| {
            if (target.anchor_ref.kind == .page) return self.fail(error.PageCannotBeConstraintTarget);
            const offset = try self.parseExpr();
            return .{
                .target = .{ .kind = .node, .anchor = dimension.target_anchor, .node_name = target.anchor_ref.node_name },
                .source = .{ .kind = .node, .anchor = dimension.source_anchor, .node_name = target.anchor_ref.node_name },
                .offset = offset,
            };
        }
        const target_anchor = target.anchor_ref;
        const source = try self.parseAnchorMemberRef();
        var offset: ?Expr = null;
        self.skipTrivia();
        if (!self.eof() and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
            const sign = self.source[self.pos];
            self.pos += 1;
            var expr = try self.parseExpr();
            if (sign == '-') expr = try self.makeNegCall(expr);
            offset = expr;
        }
        return .{ .target = target_anchor, .source = source, .offset = offset };
    }

    const ConstraintMemberRef = struct {
        anchor_ref: AnchorRef,
        dimension: ?struct {
            target_anchor: core.Anchor,
            source_anchor: core.Anchor,
        } = null,
    };

    fn parseAnchorRef(self: *Parser) !AnchorRef {
        const name = try self.parseIdentifier();
        const anchor = names.parseAnchorName(name) orelse return self.fail(error.UnknownAnchor);
        self.skipTrivia();
        try self.expectChar('(');
        self.skipTrivia();
        if (try self.consumeKeyword("page")) {
            try self.expectChar(')');
            return .{ .kind = .page, .anchor = anchor };
        }
        const node_name = try self.parseIdentifier();
        self.skipTrivia();
        try self.expectChar(')');
        return .{ .kind = .node, .anchor = anchor, .node_name = node_name };
    }

    fn parseAnchorMemberRef(self: *Parser) !AnchorRef {
        return (try self.parseConstraintMemberRef(false)).anchor_ref;
    }

    fn parseConstraintMemberRef(self: *Parser, allow_dimension: bool) !ConstraintMemberRef {
        const object_name = try self.parseIdentifier();
        self.skipInlineSpaces();
        try self.expectChar('.');
        const member_name = try self.parseIdentifier();
        if (allow_dimension) {
            if (std.mem.eql(u8, member_name, "width")) {
                return .{
                    .anchor_ref = .{ .kind = if (std.mem.eql(u8, object_name, "page")) .page else .node, .anchor = .right, .node_name = if (std.mem.eql(u8, object_name, "page")) null else object_name },
                    .dimension = .{ .target_anchor = .right, .source_anchor = .left },
                };
            }
            if (std.mem.eql(u8, member_name, "height")) {
                return .{
                    .anchor_ref = .{ .kind = if (std.mem.eql(u8, object_name, "page")) .page else .node, .anchor = .top, .node_name = if (std.mem.eql(u8, object_name, "page")) null else object_name },
                    .dimension = .{ .target_anchor = .top, .source_anchor = .bottom },
                };
            }
        }
        const anchor = names.parseAnchorName(member_name) orelse return self.fail(error.UnknownAnchor);
        if (std.mem.eql(u8, object_name, "page")) return .{ .anchor_ref = .{ .kind = .page, .anchor = anchor } };
        return .{ .anchor_ref = .{ .kind = .node, .anchor = anchor, .node_name = object_name } };
    }

    fn parseAnchorMemberExprAfterObjectName(self: *Parser, object_name: []const u8) !Expr {
        try self.expectChar('.');
        const anchor_name = try self.parseIdentifier();
        _ = names.parseAnchorName(anchor_name) orelse return self.fail(error.UnknownAnchor);
        var args = std.ArrayList(Expr).empty;
        errdefer args.deinit(self.allocator);
        if (std.mem.eql(u8, object_name, "page")) {
            try args.append(self.allocator, .{ .string = anchor_name });
            return .{ .call = .{ .name = "page_anchor", .args = args } };
        }
        try args.append(self.allocator, .{ .ident = object_name });
        try args.append(self.allocator, .{ .string = anchor_name });
        return .{ .call = .{ .name = "anchor", .args = args } };
    }

    fn makeNegCall(self: *Parser, expr: Expr) !Expr {
        var args = std.ArrayList(Expr).empty;
        errdefer args.deinit(self.allocator);
        try args.append(self.allocator, expr);
        return .{ .call = .{ .name = "neg", .args = args } };
    }

    fn parseTextArg(self: *Parser) ![]const u8 {
        self.skipInlineSpaces();
        if (self.startsWith("<<")) return self.parseChevronBlockString();
        if (!self.eof() and (self.source[self.pos] == '"' or self.startsWith("\"\"\""))) {
            return self.parseString();
        }
        return self.parseLineText();
    }

    fn parseLineText(self: *Parser) ![]const u8 {
        self.skipInlineSpaces();
        const start = self.pos;
        while (!self.eof() and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
        const raw = trimRightSpaces(self.source[start..self.pos]);
        return self.allocator.dupe(u8, raw);
    }

    fn parseChevronBlockString(self: *Parser) ![]const u8 {
        self.skipInlineSpaces();
        if (!self.startsWith("<<")) return self.fail(error.ExpectedString);
        self.pos += 2;
        self.skipInlineSpaces();
        try self.expectLineBreak();

        const content_start = self.pos;
        while (!self.eof()) {
            if (self.isChevronTerminatorAtCurrentLine()) {
                const raw = self.source[content_start..self.pos];
                self.consumeChevronTerminatorLine();
                return self.allocator.dupe(u8, normalizeBlockString(raw));
            }
            self.pos += 1;
        }
        return self.fail(error.UnterminatedString);
    }

    fn isChevronTerminatorAtCurrentLine(self: *Parser) bool {
        var line_start = self.pos;
        while (line_start > 0 and self.source[line_start - 1] != '\n') line_start -= 1;
        var probe = line_start;
        while (probe < self.source.len and isInlineSpace(self.source[probe])) probe += 1;
        if (probe + 2 > self.source.len) return false;
        if (!std.mem.eql(u8, self.source[probe .. probe + 2], ">>")) return false;
        probe += 2;
        while (probe < self.source.len and isInlineSpace(self.source[probe])) probe += 1;
        if (probe + 1 < self.source.len and std.mem.eql(u8, self.source[probe .. probe + 2], ";;")) {
            return true;
        }
        if (probe + 1 < self.source.len and std.mem.eql(u8, self.source[probe .. probe + 2], "//")) {
            return true;
        }
        if (probe < self.source.len and self.source[probe] == '#') {
            return true;
        }
        return probe == self.source.len or self.source[probe] == '\n';
    }

    fn consumeChevronTerminatorLine(self: *Parser) void {
        while (!self.eof() and self.source[self.pos] != '\n') self.pos += 1;
        if (!self.eof() and self.source[self.pos] == '\n') self.pos += 1;
    }

    fn parseNumber(self: *Parser) !f32 {
        self.skipTrivia();
        const start = self.pos;
        var saw_dot = false;
        while (!self.eof()) {
            const ch = self.source[self.pos];
            if (std.ascii.isDigit(ch)) {
                self.pos += 1;
                continue;
            }
            if (ch == '.' and !saw_dot) {
                saw_dot = true;
                self.pos += 1;
                continue;
            }
            break;
        }
        if (start == self.pos) return self.fail(error.ExpectedNumber);
        const token = self.source[start..self.pos];
        return std.fmt.parseFloat(f32, token);
    }

    fn parseSignedNumber(self: *Parser) !f32 {
        self.skipTrivia();
        var sign: f32 = 1;
        if (!self.eof() and self.source[self.pos] == '-') {
            sign = -1;
            self.pos += 1;
        }
        return sign * try self.parseNumber();
    }

    fn startsNumberLiteral(self: *Parser) bool {
        if (self.eof()) return false;
        const ch = self.source[self.pos];
        return std.ascii.isDigit(ch);
    }

    fn parseString(self: *Parser) ![]const u8 {
        self.skipTrivia();
        if (self.startsWith("\"\"\"")) {
            self.pos += 3;
            const start = self.pos;
            while (!self.eof() and !self.startsWith("\"\"\"")) {
                self.pos += 1;
            }
            if (self.eof()) return self.fail(error.UnterminatedString);
            const raw = self.source[start..self.pos];
            self.pos += 3;
            return self.allocator.dupe(u8, normalizeBlockString(raw));
        }

        if (self.eof() or self.source[self.pos] != '"') return self.fail(error.ExpectedString);
        self.pos += 1;

        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);

        while (!self.eof()) {
            const ch = self.source[self.pos];
            self.pos += 1;
            if (ch == '"') {
                return out.toOwnedSlice(self.allocator);
            }
            if (ch == '\\') {
                if (self.eof()) return self.fail(error.UnterminatedEscape);
                const esc = self.source[self.pos];
                self.pos += 1;
                switch (esc) {
                    'n' => try out.append(self.allocator, '\n'),
                    'r' => try out.append(self.allocator, '\r'),
                    't' => try out.append(self.allocator, '\t'),
                    '\\' => try out.append(self.allocator, '\\'),
                    '"' => try out.append(self.allocator, '"'),
                    else => return self.fail(error.InvalidEscape),
                }
            } else {
                try out.append(self.allocator, ch);
            }
        }
        return self.fail(error.UnterminatedString);
    }

    fn startsColorLiteral(self: *Parser) bool {
        return self.pos + 1 < self.source.len and self.source[self.pos] == 'c' and self.source[self.pos + 1] == '"';
    }

    fn parseColorLiteralString(self: *Parser) ![]const u8 {
        if (!self.startsColorLiteral()) return self.fail(error.ExpectedString);
        self.pos += 1;
        const raw = try self.parseString();
        errdefer self.allocator.free(raw);
        const normalized = (try color_utils.normalizeAlloc(self.allocator, raw)) orelse return self.fail(error.InvalidColorLiteral);
        self.allocator.free(raw);
        return normalized;
    }

    fn parseIdentifier(self: *Parser) ![]const u8 {
        self.skipTrivia();
        if (self.eof()) return self.fail(error.ExpectedIdentifier);
        const start = self.pos;
        if (!source_utils.isIdentifierStart(self.source[self.pos])) return self.fail(error.ExpectedIdentifier);
        self.pos += 1;
        while (!self.eof() and source_utils.isIdentifierContinue(self.source[self.pos])) {
            self.pos += 1;
        }
        return self.allocator.dupe(u8, self.source[start..self.pos]);
    }

    fn expectKeyword(self: *Parser, keyword: []const u8) !void {
        if (!try self.consumeKeyword(keyword)) return self.fail(error.ExpectedKeyword);
    }

    fn consumeKeyword(self: *Parser, keyword: []const u8) !bool {
        self.skipTrivia();
        return self.consumeKeywordNoTrivia(keyword);
    }

    fn consumeKeywordNoTrivia(self: *Parser, keyword: []const u8) bool {
        if (!self.startsWith(keyword)) return false;
        const end = self.pos + keyword.len;
        if (end < self.source.len and source_utils.isIdentifierContinue(self.source[end])) return false;
        self.pos = end;
        return true;
    }

    fn expectChar(self: *Parser, ch: u8) !void {
        self.skipTrivia();
        if (self.eof() or self.source[self.pos] != ch) return self.fail(error.ExpectedChar);
        self.pos += 1;
    }

    fn expectEqualityOperator(self: *Parser) !void {
        self.skipTrivia();
        if (self.startsWith("==")) {
            self.pos += 2;
            return;
        }
        return self.fail(error.ExpectedEqualityOperator);
    }

    fn expectLineBreakAfterHeader(self: *Parser) !void {
        self.skipInlineSpaces();
        if (self.lineCommentStart()) self.skipLineComment();
        try self.expectLineBreak();
    }

    fn expectLineBreak(self: *Parser) !void {
        if (self.eof()) return;
        if (self.source[self.pos] != '\n') return self.fail(error.ExpectedLineBreak);
        self.pos += 1;
    }

    fn consumeStatementTerminator(self: *Parser) !void {
        self.skipInlineSpaces();
        if (self.lineCommentStart()) {
            self.skipLineComment();
            return;
        }
        if (!self.eof() and self.source[self.pos] == ';') {
            self.pos += 1;
            self.skipInlineSpaces();
        }
        if (self.lineCommentStart()) self.skipLineComment();
    }

    fn atStatementBoundary(self: *Parser) bool {
        var probe = self.pos;
        while (probe < self.source.len and isInlineSpace(self.source[probe])) probe += 1;
        if (probe >= self.source.len) return true;
        return self.source[probe] == '\n';
    }

    fn peekAnchorAssignment(self: *Parser) bool {
        var probe = self.pos;
        source_utils.skipTriviaFrom(self.source, &probe);
        if (!scanIdentifier(self.source, &probe)) return false;
        while (probe < self.source.len and isInlineSpace(self.source[probe])) probe += 1;
        if (probe >= self.source.len or self.source[probe] != '.') return false;
        probe += 1;
        while (probe < self.source.len and isInlineSpace(self.source[probe])) probe += 1;
        const member_start = probe;
        if (!scanIdentifier(self.source, &probe)) return false;
        const member_name = self.source[member_start..probe];
        if (names.parseAnchorName(member_name) == null and
            !std.mem.eql(u8, member_name, "width") and
            !std.mem.eql(u8, member_name, "height")) return false;
        while (probe < self.source.len and isInlineSpace(self.source[probe])) probe += 1;
        return probe < self.source.len and self.source[probe] == '=';
    }

    fn peekPropertyAssignment(self: *Parser) bool {
        var probe = self.pos;
        source_utils.skipTriviaFrom(self.source, &probe);
        if (!scanIdentifier(self.source, &probe)) return false;
        while (probe < self.source.len and isInlineSpace(self.source[probe])) probe += 1;
        if (probe >= self.source.len or self.source[probe] != '.') return false;
        probe += 1;
        while (probe < self.source.len and isInlineSpace(self.source[probe])) probe += 1;
        const member_start = probe;
        if (!scanIdentifier(self.source, &probe)) return false;
        const member_name = self.source[member_start..probe];
        if (names.parseAnchorName(member_name) != null or
            std.mem.eql(u8, member_name, "width") or
            std.mem.eql(u8, member_name, "height")) return false;
        source_utils.skipTriviaFrom(self.source, &probe);
        if (probe >= self.source.len or self.source[probe] != '=') return false;
        if (probe + 1 < self.source.len and self.source[probe + 1] == '=') return false;
        return true;
    }

    fn peekSimpleAssignment(self: *Parser) bool {
        var probe = self.pos;
        source_utils.skipTriviaFrom(self.source, &probe);
        if (!scanIdentifier(self.source, &probe)) return false;
        while (probe < self.source.len and isInlineSpace(self.source[probe])) probe += 1;
        if (probe >= self.source.len or self.source[probe] != '=') return false;
        if (probe + 1 < self.source.len and self.source[probe + 1] == '=') return false;
        return true;
    }

    fn peekStandaloneKeyword(self: *Parser, keyword: []const u8) bool {
        var probe = self.pos;
        source_utils.skipTriviaFrom(self.source, &probe);
        if (probe + keyword.len > self.source.len) return false;
        if (!std.mem.eql(u8, self.source[probe .. probe + keyword.len], keyword)) return false;
        const end = probe + keyword.len;
        if (end < self.source.len and source_utils.isIdentifierContinue(self.source[end])) return false;
        probe = end;
        while (probe < self.source.len and isInlineSpace(self.source[probe])) probe += 1;
        return probe == self.source.len or self.source[probe] == '\n';
    }

    fn consumeStandaloneKeyword(self: *Parser, keyword: []const u8) !void {
        self.skipTrivia();
        if (!self.consumeKeywordNoTrivia(keyword)) return self.fail(error.ExpectedKeyword);
        self.skipInlineSpaces();
        if (self.lineCommentStart()) self.skipLineComment();
        if (!self.eof() and self.source[self.pos] == '\n') self.pos += 1;
    }

    fn skipInlineSpaces(self: *Parser) void {
        while (!self.eof() and isInlineSpace(self.source[self.pos])) self.pos += 1;
    }

    fn lineCommentStart(self: *Parser) bool {
        if (self.eof()) return false;
        if (self.startsWith("//")) return true;
        if (self.startsWith(";;")) return true;
        return self.source[self.pos] == '#';
    }

    fn skipLineComment(self: *Parser) void {
        while (!self.eof() and self.source[self.pos] != '\n') self.pos += 1;
    }

    fn skipTrivia(self: *Parser) void {
        while (!self.eof()) {
            const ch = self.source[self.pos];
            if (std.ascii.isWhitespace(ch)) {
                self.pos += 1;
                continue;
            }
            if (self.startsWith("//")) {
                self.pos += 2;
                while (!self.eof() and self.source[self.pos] != '\n') self.pos += 1;
                continue;
            }
            if (self.startsWith(";;")) {
                self.pos += 2;
                while (!self.eof() and self.source[self.pos] != '\n') self.pos += 1;
                continue;
            }
            if (ch == '#') {
                while (!self.eof() and self.source[self.pos] != '\n') self.pos += 1;
                continue;
            }
            break;
        }
    }

    fn startsWith(self: *Parser, text: []const u8) bool {
        if (self.pos + text.len > self.source.len) return false;
        return std.mem.eql(u8, self.source[self.pos .. self.pos + text.len], text);
    }

    fn peekChar(self: *Parser, ch: u8) bool {
        self.skipTrivia();
        return !self.eof() and self.source[self.pos] == ch;
    }

    fn eof(self: *Parser) bool {
        return self.pos >= self.source.len;
    }

    fn fail(self: *Parser, err: anyerror) anyerror {
        self.error_pos = @min(self.pos, self.source.len);
        return err;
    }
};

fn parseExpected(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ExpectedString => "string or page name",
        error.ExpectedIdentifier => "identifier",
        error.ExpectedKeyword => "keyword",
        error.ExpectedChar => "punctuation",
        error.ExpectedLineBreak => "line break after block header",
        error.ExpectedEnd => "'end'",
        error.ExpectedNumber => "number",
        error.UnterminatedString => "closing string delimiter",
        error.UnterminatedEscape => "escape target",
        error.InvalidEscape => "valid escape sequence",
        error.InvalidColorLiteral => "valid color literal",
        error.UnknownAnchor => "known anchor name",
        error.InvalidSemanticSort => "semantic sort",
        error.ExpectedTypeAnnotation => "type annotation",
        error.AssignmentRequiresLet => "'let name = expr' for variable bindings",
        error.ZeroArgCallRequiresParens => "'name()' for zero-argument calls",
        error.RequiredParameterAfterDefault => "defaulted parameters must trail required parameters",
        error.ExpectedReturn => "return statement",
        error.ExpectedEqualityOperator => "'=='",
        else => null,
    };
}

fn functionBodyReturns(statements: []const Statement) bool {
    for (statements) |stmt| {
        if (statementReturns(stmt)) return true;
    }
    return false;
}

fn statementReturns(stmt: Statement) bool {
    return switch (stmt.kind) {
        .return_expr => true,
        else => false,
    };
}

fn annotationsAllowBodyless(annotations: []const ast.Annotation) bool {
    for (annotations) |annotation| {
        if (std.mem.eql(u8, annotation.name, "host") or std.mem.eql(u8, annotation.name, "op")) return true;
    }
    return false;
}

fn foundToken(source: []const u8, pos: usize) []const u8 {
    if (pos >= source.len) return "end of file";
    return switch (source[pos]) {
        '\n' => "line break",
        '\r' => "carriage return",
        '\t' => "tab",
        ' ' => "space",
        else => blk: {
            const len = std.unicode.utf8ByteSequenceLength(source[pos]) catch 1;
            break :blk source[pos..@min(pos + len, source.len)];
        },
    };
}

fn scanIdentifier(source: []const u8, pos: *usize) bool {
    if (pos.* >= source.len or !source_utils.isIdentifierStart(source[pos.*])) return false;
    pos.* += 1;
    while (pos.* < source.len and source_utils.isIdentifierContinue(source[pos.*])) pos.* += 1;
    return true;
}

fn isInlineSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r';
}

fn normalizeBlockString(raw: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = raw.len;
    if (start < end and raw[start] == '\n') start += 1;
    if (start < end and raw[end - 1] == '\n') end -= 1;
    return raw[start..end];
}

fn trimRightSpaces(raw: []const u8) []const u8 {
    var end = raw.len;
    while (end > 0 and isInlineSpace(raw[end - 1])) end -= 1;
    return raw[0..end];
}

fn trimLeftSpaces(raw: []const u8) []const u8 {
    var start: usize = 0;
    while (start < raw.len and isInlineSpace(raw[start])) start += 1;
    return raw[start..];
}
