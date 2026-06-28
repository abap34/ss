const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const diagnostics = @import("diagnostics.zig");
const scanner = @import("scanner.zig");
const names = @import("../language/names.zig");
const utils = @import("utils");
const source_utils = utils.source;
const color_utils = utils.color;

const Allocator = std.mem.Allocator;
const Program = ast.Program;
const TypeDecl = ast.TypeDecl;
const RecordDecl = ast.RecordDecl;
const ObjectDecl = ast.ObjectDecl;
const ObjectExtensionDecl = ast.ObjectExtensionDecl;
const ConstDecl = ast.ConstDecl;
const FunctionDecl = ast.FunctionDecl;
const PageDecl = ast.PageDecl;
const Statement = ast.Statement;
const Expr = ast.Expr;
const ConstraintDecl = ast.ConstraintDecl;
const AnchorRef = ast.AnchorRef;

pub const ParseDiagnostic = diagnostics.ParseDiagnostic;

var last_diagnostic: ?ParseDiagnostic = null;

pub fn parse(allocator: Allocator, source: []const u8) !Program {
    return parseWithSourceName(allocator, source, "");
}

pub fn parseWithSourceName(allocator: Allocator, source: []const u8, source_name: []const u8) !Program {
    var parser = Parser{
        .allocator = allocator,
        .source = source,
        .source_name = source_name,
        .pos = 0,
        .error_pos = 0,
        .error_span = null,
        .generated_page_count = 0,
    };
    last_diagnostic = null;
    return parser.parseProgram() catch |err| {
        const pos = @min(parser.error_pos, source.len);
        const span = if (parser.error_span) |span|
            ast.Span{
                .start = @min(span.start, source.len),
                .end = @min(@max(span.end, span.start + 1), source.len),
            }
        else
            ast.Span{ .start = pos, .end = @min(pos + 1, source.len) };
        last_diagnostic = .{
            .err = err,
            .span = span,
            .expected = diagnostics.expected(err),
            .found = diagnostics.foundToken(source, pos),
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
    source_name: []const u8,
    pos: usize,
    error_pos: usize,
    error_span: ?ast.Span,
    generated_page_count: usize,

    fn parseProgram(self: *Parser) !Program {
        var program = Program.init();
        errdefer program.deinit(self.allocator);
        var imports_allowed = true;

        self.skipTrivia();
        while (!self.eof()) {
            const item_start = self.pos;
            if (self.source[self.pos] == '@') return self.fail(error.ExpectedKeyword);

            if (try self.consumeKeyword("import")) {
                if (!imports_allowed) return self.failAt(item_start, error.ImportMustBeAtTop);
                const spec = try self.parseImportSpec();
                errdefer self.allocator.free(spec);
                try self.validateImportSpec(spec);
                const mode = try self.parseImportMode(spec);
                try self.consumeStatementTerminator();
                const import_index = program.imports.items.len;
                try program.imports.append(self.allocator, .{
                    .spec = spec,
                    .mode = mode,
                    .span = .{ .start = item_start, .end = self.pos },
                });
                try program.top_level_items.append(self.allocator, .{ .import = import_index });
            } else if (try self.consumeKeyword("fn")) {
                imports_allowed = false;
                const paired = self.consumePairedFunctionMarker();
                var func = try self.parseFunctionAfterKeyword(item_start, .{ .paired = paired });
                if (paired) {
                    var placed_func = try self.makePairedPlacementFunction(func);
                    var func_moved = false;
                    var placed_func_moved = false;
                    errdefer {
                        if (!func_moved) func.deinit(self.allocator);
                        if (!placed_func_moved) placed_func.deinit(self.allocator);
                    }
                    try program.functions.append(self.allocator, func);
                    func_moved = true;
                    try program.functions.append(self.allocator, placed_func);
                    placed_func_moved = true;
                } else {
                    try program.functions.append(self.allocator, func);
                }
            } else if (try self.consumeKeyword("const")) {
                imports_allowed = false;
                const constant = try self.parseConstAfterKeyword(item_start);
                try program.constants.append(self.allocator, constant);
            } else if (try self.consumeKeyword("type")) {
                imports_allowed = false;
                const type_item = try self.parseTypeItemAfterKeyword(item_start);
                switch (type_item) {
                    .enum_decl => |type_decl| {
                        try self.consumeStatementTerminator();
                        try program.types.append(self.allocator, type_decl);
                    },
                    .object => |object_decl| try program.objects.append(self.allocator, object_decl),
                }
            } else if (try self.consumeKeyword("record")) {
                imports_allowed = false;
                const record_decl = try self.parseRecordDeclAfterKeyword(item_start);
                try program.records.append(self.allocator, record_decl);
            } else if (try self.consumeKeyword("extend")) {
                imports_allowed = false;
                const extension = try self.parseObjectExtensionAfterKeyword(item_start);
                try program.object_extensions.append(self.allocator, extension);
            } else if (try self.consumeKeyword("document")) {
                imports_allowed = false;
                var statements = try self.parseBodyStatements();
                var moved_statements = false;
                defer statements.deinit(self.allocator);
                errdefer {
                    if (!moved_statements) {
                        for (statements.items) |*stmt| stmt.deinit(self.allocator);
                    }
                }
                const statement_start = program.document_statements.items.len;
                try program.document_statements.appendSlice(self.allocator, statements.items);
                moved_statements = true;
                const document_index = program.document_blocks.items.len;
                try program.document_blocks.append(self.allocator, .{
                    .statement_start = statement_start,
                    .statement_count = statements.items.len,
                    .span = .{ .start = item_start, .end = self.pos },
                });
                try program.top_level_items.append(self.allocator, .{ .document = document_index });
            } else {
                imports_allowed = false;
                const page = try self.parsePage();
                const page_index = program.pages.items.len;
                try program.pages.append(self.allocator, page);
                try program.top_level_items.append(self.allocator, .{ .page = page_index });
            }
            self.skipTrivia();
        }
        return program;
    }

    const FunctionParseOptions = struct {
        paired: bool = false,
    };

    fn parseFunctionAfterKeyword(self: *Parser, start: usize, options: FunctionParseOptions) !FunctionDecl {
        const name = try self.parseCallableDeclName();
        if (options.paired and names.hasBangSuffix(name)) {
            defer self.allocator.free(name);
            return self.failAt(self.pos - 1, error.PairedFunctionNameCannotEndWithBang);
        }
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
        const statements = try self.parseFunctionBody(result_type);
        if (result_type.kind != .void and !functionBodyReturns(statements.items)) return self.fail(error.ExpectedReturn);
        return .{ .name = name, .span = .{ .start = start, .end = self.pos }, .params = params, .result_type = result_type, .statements = statements };
    }

    fn parseFunctionBody(self: *Parser, result_type: ast.Type) !std.ArrayList(Statement) {
        self.skipInlineSpaces();
        if (!self.eof() and self.source[self.pos] == '=') {
            return try self.parseInlineFunctionBody(result_type);
        }
        return try self.parseBodyStatements();
    }

    fn parseInlineFunctionBody(self: *Parser, result_type: ast.Type) !std.ArrayList(Statement) {
        var statements = std.ArrayList(Statement).empty;
        errdefer {
            for (statements.items) |*stmt| stmt.deinit(self.allocator);
            statements.deinit(self.allocator);
        }

        const start = self.pos;
        try self.expectChar('=');
        self.skipTrivia();
        var expr = try self.parseExpr();
        var expr_moved = false;
        errdefer if (!expr_moved) expr.deinit(self.allocator);
        try self.consumeStatementTerminator();
        try statements.append(self.allocator, .{
            .span = .{ .start = start, .end = self.pos },
            .kind = if (result_type.kind == .void)
                .{ .expr_stmt = expr }
            else
                .{ .return_expr = expr },
        });
        expr_moved = true;
        return statements;
    }

    fn makePairedPlacementFunction(self: *Parser, func: FunctionDecl) !FunctionDecl {
        const placed_name = try names.bangName(self.allocator, func.name);
        defer self.allocator.free(placed_name);

        var placed = try func.cloneSignature(self.allocator, placed_name, func.span);
        errdefer placed.deinit(self.allocator);

        var inner_args = std.ArrayList(Expr).empty;
        errdefer {
            for (inner_args.items) |*arg| arg.deinit(self.allocator);
            inner_args.deinit(self.allocator);
        }
        for (func.params.items) |param| {
            try inner_args.append(self.allocator, .{ .ident = try self.allocator.dupe(u8, param.name) });
        }

        var outer_args = std.ArrayList(Expr).empty;
        errdefer {
            for (outer_args.items) |*arg| arg.deinit(self.allocator);
            outer_args.deinit(self.allocator);
        }
        try outer_args.append(self.allocator, .{ .call = .{
            .callee = .{ .name = try self.allocator.dupe(u8, func.name) },
            .args = inner_args,
        } });
        inner_args = .empty;

        const return_expr = Expr{ .call = .{
            .callee = .{ .name = try self.allocator.dupe(u8, "place!") },
            .args = outer_args,
        } };
        outer_args = .empty;

        var return_stmt = Statement{
            .span = func.span,
            .kind = .{ .return_expr = return_expr },
        };
        errdefer return_stmt.deinit(self.allocator);
        try placed.statements.append(self.allocator, return_stmt);
        return placed;
    }

    fn parseConstAfterKeyword(self: *Parser, start: usize) !ConstDecl {
        const name = try self.parseIdentifier();
        self.skipInlineSpaces();
        if (self.eof() or self.source[self.pos] != ':') return self.fail(error.ExpectedTypeAnnotation);
        self.pos += 1;
        self.skipInlineSpaces();
        const result_type = try self.parseTypeAnnotation();
        self.skipTrivia();
        try self.expectChar('=');
        const expr = try self.parseExpr();
        try self.consumeStatementTerminator();

        return .{
            .name = name,
            .span = .{ .start = start, .end = self.pos },
            .value_type = result_type,
            .value = expr,
        };
    }

    const TypeItem = union(enum) {
        enum_decl: TypeDecl,
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
        var cases = std.ArrayList([]const u8).empty;
        var needs_case = true;
        errdefer {
            for (cases.items) |case_name| self.allocator.free(case_name);
            cases.deinit(self.allocator);
        }
        while (true) {
            self.skipInlineSpaces();
            if (self.eof() or self.source[self.pos] == '\n' or self.source[self.pos] == '@' or self.lineCommentStart()) {
                if (needs_case) return self.fail(error.ExpectedTypeAnnotation);
                break;
            }
            try cases.append(self.allocator, try self.parseIdentifier());
            needs_case = false;
            self.skipInlineSpaces();
            if (self.eof() or self.source[self.pos] == '\n' or self.source[self.pos] == '@' or self.lineCommentStart()) break;
            if (self.source[self.pos] != '|') return self.fail(error.ExpectedTypeAnnotation);
            self.pos += 1;
            needs_case = true;
        }
        if (cases.items.len == 0) return self.fail(error.ExpectedTypeAnnotation);
        return .{ .enum_decl = .{
            .name = name,
            .cases = cases,
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

    fn parseRecordDeclAfterKeyword(self: *Parser, start: usize) !RecordDecl {
        const name = try self.parseIdentifier();
        return try self.parseRecordDeclBody(start, name);
    }

    fn parseRecordDeclBody(self: *Parser, start: usize, name: []const u8) !RecordDecl {
        self.skipTrivia();
        try self.expectChar('{');
        var decl = RecordDecl{
            .name = name,
            .fields = .empty,
            .span = .{ .start = start, .end = start },
        };
        errdefer decl.deinit(self.allocator);
        try self.parseRecordMembers(&decl.fields);
        decl.span.end = self.pos;
        return decl;
    }

    fn parseRecordMembers(self: *Parser, fields: *std.ArrayList(ast.ObjectFieldDecl)) !void {
        self.skipTrivia();
        while (!self.eof() and !self.peekChar('}')) {
            const member_start = self.pos;
            const name = try self.parseIdentifier();
            self.skipInlineSpaces();
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
            var default_value: ?*Expr = null;
            var default_property_value: ?[]const u8 = null;
            self.skipInlineSpaces();
            if (!self.eof() and self.source[self.pos] == '=') {
                self.pos += 1;
                self.skipInlineSpaces();
                const parsed_default = try self.parseObjectFieldDefault();
                default_value = parsed_default.expr;
                default_property_value = parsed_default.property_value;
            }
            try fields.append(self.allocator, .{
                .name = name,
                .value_type = try self.allocator.dupe(u8, type_text),
                .default_value = default_value,
                .default_property_value = default_property_value,
                .span = .{ .start = member_start, .end = self.pos },
            });
            try self.consumeStatementTerminator();
            self.skipTrivia();
        }
        try self.expectChar('}');
        try self.consumeStatementTerminator();
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
            var default_value: ?*Expr = null;
            var default_property_value: ?[]const u8 = null;
            self.skipInlineSpaces();
            if (!self.eof() and self.source[self.pos] == '=') {
                self.pos += 1;
                self.skipInlineSpaces();
                const parsed_default = try self.parseObjectFieldDefault();
                default_value = parsed_default.expr;
                default_property_value = parsed_default.property_value;
            }
            try fields.append(self.allocator, .{
                .name = name,
                .value_type = try self.allocator.dupe(u8, type_text),
                .default_value = default_value,
                .default_property_value = default_property_value,
                .span = .{ .start = member_start, .end = self.pos },
            });
            try self.consumeStatementTerminator();
            self.skipTrivia();
        }
        try self.expectChar('}');
        try self.consumeStatementTerminator();
    }

    const ParsedObjectFieldDefault = struct {
        expr: *Expr,
        property_value: ?[]const u8,
    };

    fn parseObjectFieldDefault(self: *Parser) !ParsedObjectFieldDefault {
        const expr = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(expr);
        expr.* = try self.parseExpr();
        errdefer expr.deinit(self.allocator);
        return .{
            .expr = expr,
            .property_value = null,
        };
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

    fn peekKeyword(self: *Parser, keyword: []const u8) !bool {
        const saved = self.pos;
        defer self.pos = saved;
        return try self.consumeKeyword(keyword);
    }

    fn parseTypeAnnotation(self: *Parser) anyerror!ast.Type {
        var ty = try self.parseFunctionTypeAnnotation();
        errdefer ty.deinit(self.allocator);
        self.skipInlineSpaces();
        if (!self.eof() and self.source[self.pos] == '?') {
            self.pos += 1;
            const optional_ty = try ast.Type.optional(self.allocator, ty);
            ty.deinit(self.allocator);
            return optional_ty;
        }
        return ty;
    }

    fn parseFunctionTypeAnnotation(self: *Parser) anyerror!ast.Type {
        self.skipInlineSpaces();
        if (!self.eof() and self.source[self.pos] == '(') {
            const start = self.pos;
            try self.expectChar('(');
            var params = std.ArrayList(ast.Type).empty;
            errdefer {
                for (params.items) |*param| param.deinit(self.allocator);
                params.deinit(self.allocator);
            }
            self.skipInlineSpaces();
            while (!self.eof() and !self.peekChar(')')) {
                const param_type = try self.parseTypeAnnotation();
                try params.append(self.allocator, param_type);
                self.skipInlineSpaces();
                if (!self.eof() and self.source[self.pos] == ',') {
                    self.pos += 1;
                    self.skipInlineSpaces();
                    continue;
                }
                break;
            }
            try self.expectChar(')');
            self.skipInlineSpaces();
            if (self.startsWith("->")) {
                self.pos += 2;
                self.skipInlineSpaces();
                const result_type = try self.parseTypeAnnotation();
                defer {
                    for (params.items) |*param| param.deinit(self.allocator);
                    params.deinit(self.allocator);
                    var owned_result = result_type;
                    owned_result.deinit(self.allocator);
                }
                return try ast.Type.functionType(self.allocator, params.items, result_type);
            }
            if (params.items.len == 1) {
                const grouped = params.items[0];
                params.deinit(self.allocator);
                return grouped;
            }
            self.pos = start;
            return self.fail(error.ExpectedTypeAnnotation);
        }

        var left = try self.parsePrimaryTypeAnnotation();
        errdefer left.deinit(self.allocator);
        self.skipInlineSpaces();
        if (!self.startsWith("->")) return left;
        self.pos += 2;
        self.skipInlineSpaces();
        const result_type = try self.parseTypeAnnotation();
        defer {
            var owned_left = left;
            owned_left.deinit(self.allocator);
            var owned_result = result_type;
            owned_result.deinit(self.allocator);
        }
        return try ast.Type.functionType(self.allocator, &.{left}, result_type);
    }

    fn parsePrimaryTypeAnnotation(self: *Parser) anyerror!ast.Type {
        const name = try self.parseIdentifier();
        if (std.mem.eql(u8, name, "Document")) {
            self.allocator.free(name);
            return ast.Type.document;
        }
        if (std.mem.eql(u8, name, "Page")) {
            self.allocator.free(name);
            return ast.Type.page;
        }
        if (std.mem.eql(u8, name, "Object")) return try self.parseObjectType(name);
        if (std.mem.eql(u8, name, "Anchor")) {
            self.allocator.free(name);
            return ast.Type.anchor;
        }
        if (std.mem.eql(u8, name, "Function")) {
            self.allocator.free(name);
            return self.fail(error.InvalidTypeAnnotation);
        }
        if (std.mem.eql(u8, name, "String")) {
            self.allocator.free(name);
            return ast.Type.string;
        }
        if (std.mem.eql(u8, name, "Color")) {
            self.allocator.free(name);
            return ast.Type.color;
        }
        if (std.mem.eql(u8, name, "Number")) {
            self.allocator.free(name);
            return ast.Type.number;
        }
        if (std.mem.eql(u8, name, "Bool")) {
            self.allocator.free(name);
            return ast.Type.boolean;
        }
        if (std.mem.eql(u8, name, "Constraints")) {
            self.allocator.free(name);
            return ast.Type.constraints;
        }
        if (std.mem.eql(u8, name, "Void")) {
            self.allocator.free(name);
            return .{ .kind = .void };
        }
        if (std.mem.eql(u8, name, "None")) {
            self.allocator.free(name);
            return ast.Type.none;
        }
        if (std.mem.eql(u8, name, "Selection")) {
            self.allocator.free(name);
            return ast.Type.selectionType(try self.parseOptionalTypeParam());
        }
        return ast.Type.objectClass(name);
    }

    fn parseObjectType(self: *Parser, object_name: []const u8) anyerror!ast.Type {
        defer self.allocator.free(object_name);
        self.skipInlineSpaces();
        if (self.eof() or self.source[self.pos] != '<') return ast.Type.object;
        try self.expectChar('<');
        const class_name = try self.parseIdentifier();
        try self.expectChar('>');
        return ast.Type.objectClass(class_name);
    }

    fn parseOptionalTypeParam(self: *Parser) anyerror!ast.Type {
        self.skipInlineSpaces();
        if (self.eof() or self.source[self.pos] != '<') return ast.Type.any;
        return try self.parseTypeParam();
    }

    fn parseTypeParam(self: *Parser) anyerror!ast.Type {
        try self.expectChar('<');
        const inner = try self.parseTypeAnnotation();
        try self.expectChar('>');
        return inner;
    }

    fn parsePage(self: *Parser) !PageDecl {
        const start = self.pos;
        try self.expectKeyword("page");
        const name = try self.parsePageName();
        const statements = try self.parseBodyStatements();
        return .{
            .name = name,
            .statements = statements,
            .span = .{ .start = start, .end = self.pos },
        };
    }

    fn parsePageName(self: *Parser) ![]const u8 {
        self.skipInlineSpaces();
        if (!self.eof() and self.source[self.pos] == '"') {
            const name_start = self.pos;
            const name = try self.parseString();
            return self.resolvePageName(name, name_start);
        }
        if (!self.eof() and self.source[self.pos] == '#') return self.fail(error.ReservedPageNamePrefix);

        const start = self.pos;
        while (!self.eof()) {
            const ch = self.source[self.pos];
            if (scanner.isInlineSpace(ch) or ch == '\n') break;
            if (ch == '#') break;
            if (ch == ';' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == ';') break;
            if (ch == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') break;
            self.pos += 1;
        }
        if (start == self.pos) return self.fail(error.ExpectedString);
        const name = try self.allocator.dupe(u8, self.source[start..self.pos]);
        return self.resolvePageName(name, start);
    }

    fn resolvePageName(self: *Parser, name: []const u8, name_start: usize) ![]const u8 {
        errdefer self.allocator.free(name);
        if (names.isAnonymousPageName(name)) {
            self.allocator.free(name);
            return self.generatedPageName();
        }
        if (std.mem.startsWith(u8, name, "#")) return self.failAt(name_start, error.ReservedPageNamePrefix);
        return name;
    }

    fn generatedPageName(self: *Parser) ![]const u8 {
        self.generated_page_count += 1;
        var label = std.ArrayList(u8).empty;
        defer label.deinit(self.allocator);

        const raw = if (self.source_name.len != 0) self.source_name else "source";
        const base = std.fs.path.basename(raw);
        for (base) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') {
                try label.append(self.allocator, ch);
            } else {
                try label.append(self.allocator, '_');
            }
        }
        if (label.items.len == 0) try label.appendSlice(self.allocator, "source");
        const source_hash = std.hash.Wyhash.hash(0, raw);
        return std.fmt.allocPrint(self.allocator, "#gen_{s}_{x}_{d}", .{ label.items, source_hash, self.generated_page_count });
    }

    fn parseImportSpec(self: *Parser) ![]const u8 {
        self.skipInlineSpaces();
        if (!self.eof() and (self.source[self.pos] == '"' or self.startsWith("\"\"\""))) {
            return self.parseString();
        }
        const start = self.pos;
        while (!self.eof()) {
            const ch = self.source[self.pos];
            if (scanner.isInlineSpace(ch) or ch == '\n') break;
            if (ch == '#') break;
            if (ch == ';' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == ';') break;
            if (ch == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') break;
            self.pos += 1;
        }
        if (start == self.pos) return self.fail(error.ExpectedString);
        return self.allocator.dupe(u8, self.source[start..self.pos]);
    }

    fn parseImportMode(self: *Parser, spec: []const u8) !ast.ImportDecl.Mode {
        self.skipInlineSpaces();
        if (self.consumeKeywordNoTrivia("as")) {
            self.skipInlineSpaces();
            if (!self.eof() and self.source[self.pos] == '*') {
                self.pos += 1;
                return .{ .unqualified = true };
            }
            return .{ .alias = try self.parseIdentifier() };
        }
        return .{ .alias = try self.defaultImportAlias(spec), .unqualified = true };
    }

    fn validateImportSpec(self: *Parser, spec: []const u8) !void {
        if (names.importSpecHasFileExtension(spec)) return self.fail(error.InvalidImportSpec);
    }

    fn defaultImportAlias(self: *Parser, spec: []const u8) ![]const u8 {
        const base = names.defaultImportAlias(spec);
        if (!isValidIdentifier(base) or isReservedKeyword(base)) return self.fail(error.InvalidImportAlias);
        return self.allocator.dupe(u8, base);
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

    const StatementTerminator = enum {
        end,
        @"else",
    };

    const StatementBlock = struct {
        statements: std.ArrayList(Statement),
        terminator: StatementTerminator,
    };

    fn parseStatementsUntilElseOrEnd(self: *Parser) anyerror!StatementBlock {
        var statements = std.ArrayList(Statement).empty;
        errdefer {
            for (statements.items) |*stmt| stmt.deinit(self.allocator);
            statements.deinit(self.allocator);
        }

        self.skipTrivia();
        while (!self.eof()) {
            if (self.peekStandaloneKeyword("else")) {
                try self.consumeStandaloneKeyword("else");
                return .{ .statements = statements, .terminator = .@"else" };
            }
            if (self.peekStandaloneKeyword("end")) {
                try self.consumeStandaloneKeyword("end");
                return .{ .statements = statements, .terminator = .end };
            }
            try statements.append(self.allocator, try self.parseStatement());
            self.skipTrivia();
        }
        return self.fail(error.ExpectedEnd);
    }

    fn parseStatement(self: *Parser) anyerror!Statement {
        self.skipTrivia();
        const start = self.pos;

        if (try self.consumeKeyword("if")) {
            const condition = try self.parseExpr();
            self.skipInlineSpaces();
            try self.expectLineBreakAfterHeader();
            const then_block = try self.parseStatementsUntilElseOrEnd();
            var else_statements = std.ArrayList(Statement).empty;
            if (then_block.terminator == .@"else") {
                const else_block = try self.parseStatementsUntilElseOrEnd();
                if (else_block.terminator == .@"else") return self.fail(error.ExpectedEnd);
                else_statements = else_block.statements;
            }
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .if_stmt = .{
                .condition = condition,
                .then_statements = then_block.statements,
                .else_statements = else_statements,
            } } };
        }
        if (try self.consumeKeyword("return")) {
            if (self.atStatementBoundary()) {
                try self.consumeStatementTerminator();
                return .{ .span = .{ .start = start, .end = self.pos }, .kind = .return_void };
            }
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
            return self.failAt(start, error.BindRemoved);
        }
        if (self.consumeConstraintMarker()) {
            const decl = try self.parseMemberConstraintDecl();
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .constrain = decl } };
        }
        if (self.peekAnchorAssignment()) return self.fail(error.ExpectedConstraintMarker);
        if (try self.parseMemberAssignmentStatement(start)) |stmt| {
            return stmt;
        }
        if (self.peekSimpleAssignment()) {
            return self.fail(error.AssignmentRequiresLet);
        }

        return try self.parseCallSugarStatement(start);
    }

    fn parseCallSugarStatement(self: *Parser, start: usize) !Statement {
        const name = try self.parseCallableName();
        self.skipInlineSpaces();

        if (!self.eof() and self.source[self.pos] == '(') {
            const call = try self.parseCallAfterName(name);
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .expr_stmt = .{ .call = call } } };
        }

        if (self.startsWith("<<")) {
            const text = try self.parseChevronBlockStringLiteral();
            const call = try self.makeUnaryStringCall(name, text);
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .expr_stmt = .{ .call = call } } };
        }

        if (!self.eof() and (self.source[self.pos] == '"' or self.startsWith("\"\"\""))) {
            const text = try self.parseStringLiteral();
            const call = try self.makeUnaryStringCall(name, text);
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .expr_stmt = .{ .call = call } } };
        }

        if (self.atStatementBoundary()) return self.failSpan(.{ .start = start, .end = start + name.name.len }, error.ZeroArgCallRequiresParens);

        const text = try self.parseLineTextLiteral();
        const call = try self.makeUnaryStringCall(name, text);
        try self.consumeStatementTerminator();
        return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .expr_stmt = .{ .call = call } } };
    }

    fn parseExpr(self: *Parser) anyerror!Expr {
        return self.parseConcatExpr();
    }

    fn parseConcatExpr(self: *Parser) anyerror!Expr {
        var left = try self.parseAddSubExpr();
        while (true) {
            self.skipInlineSpaces();
            if (!self.startsWith("++")) return left;
            self.pos += 2;
            const right = try self.parseAddSubExpr();
            left = try self.makeBinaryCall("concat", left, right);
        }
    }

    fn parseAddSubExpr(self: *Parser) anyerror!Expr {
        var left = try self.parseMulDivExpr();
        while (true) {
            self.skipInlineSpaces();
            if (self.eof()) return left;
            if (self.startsWith("++")) return left;
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
            self.skipInlineSpaces();
            if (self.eof()) return left;
            const op = self.source[self.pos];
            if (op != '*' and op != '/') return left;
            self.pos += 1;
            const right = try self.parseUnaryExpr();
            left = try self.makeBinaryCall(if (op == '*') "mul" else "div", left, right);
        }
    }

    fn parseUnaryExpr(self: *Parser) anyerror!Expr {
        self.skipInlineSpaces();
        if (!self.eof() and self.source[self.pos] == '!') {
            self.pos += 1;
            var args = std.ArrayList(Expr).empty;
            errdefer args.deinit(self.allocator);
            try args.append(self.allocator, try self.parseUnaryExpr());
            return .{ .call = .{ .callee = ast.CallableName.bare("not"), .args = args } };
        }
        if (!self.eof() and self.source[self.pos] == '-') {
            self.pos += 1;
            var args = std.ArrayList(Expr).empty;
            errdefer args.deinit(self.allocator);
            try args.append(self.allocator, try self.parseUnaryExpr());
            return .{ .call = .{ .callee = ast.CallableName.bare("neg"), .args = args } };
        }
        return self.parsePostfixExpr();
    }

    fn parsePostfixExpr(self: *Parser) anyerror!Expr {
        var expr = try self.parsePrimaryExpr();
        errdefer expr.deinit(self.allocator);
        while (true) {
            self.skipInlineSpaces();
            if (self.eof()) return expr;
            if (self.consumeKeywordNoTrivia("with")) {
                expr = try self.parseRecordUpdateAfterTarget(expr);
                continue;
            }
            if (self.startsWith("??")) {
                self.pos += 2;
                const fallback = try self.parseExpr();
                expr = try self.makeCoalesceExpr(expr, fallback);
                return expr;
            }
            switch (self.source[self.pos]) {
                '(' => expr = try self.parseApplyAfterCallee(expr),
                '.' => expr = try self.parseMemberExprAfterTarget(expr),
                '?' => {
                    self.pos += 1;
                    expr = try self.makeOptionalCheckExpr(expr);
                },
                else => return expr,
            }
        }
    }

    fn parseRecordUpdateAfterTarget(self: *Parser, target_expr: Expr) !Expr {
        const target = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(target);
        target.* = target_expr;

        try self.expectChar('{');
        var fields = std.ArrayList(ast.RecordUpdateFieldExpr).empty;
        errdefer {
            for (fields.items) |*field| field.deinit(self.allocator);
            fields.deinit(self.allocator);
        }

        self.skipTrivia();
        while (!self.eof() and !self.peekChar('}')) {
            var path = std.ArrayList([]const u8).empty;
            errdefer {
                for (path.items) |segment| self.allocator.free(segment);
                path.deinit(self.allocator);
            }
            try path.append(self.allocator, try self.parseIdentifier());
            while (true) {
                self.skipInlineSpaces();
                if (self.eof() or self.source[self.pos] != '.') break;
                self.pos += 1;
                self.skipInlineSpaces();
                try path.append(self.allocator, try self.parseIdentifier());
            }
            self.skipInlineSpaces();
            try self.expectChar('=');
            const value = try self.parseExpr();
            try fields.append(self.allocator, .{
                .path = path,
                .value = value,
            });
            self.skipTrivia();
            if (!self.eof() and self.source[self.pos] == ',') {
                self.pos += 1;
                self.skipTrivia();
                continue;
            }
        }
        try self.expectChar('}');
        return .{ .record_update = .{
            .target = target,
            .fields = fields,
        } };
    }

    fn parseApplyAfterCallee(self: *Parser, expr: Expr) !Expr {
        const callee = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(callee);
        callee.* = expr;
        var args = std.ArrayList(Expr).empty;
        errdefer args.deinit(self.allocator);
        try self.expectChar('(');
        self.skipInlineSpaces();
        while (!self.eof() and !self.peekChar(')')) {
            try args.append(self.allocator, try self.parseExpr());
            self.skipInlineSpaces();
            if (!self.eof() and self.source[self.pos] == ',') {
                self.pos += 1;
                self.skipInlineSpaces();
                continue;
            }
            break;
        }
        try self.expectChar(')');
        return .{ .apply = .{ .callee = callee, .args = args } };
    }

    fn parsePrimaryExpr(self: *Parser) anyerror!Expr {
        self.skipInlineSpaces();
        if (!self.eof() and self.source[self.pos] == '(') {
            if (self.startsLambdaExpr()) return try self.parseLambdaExpr();
            self.pos += 1;
            const expr = try self.parseExpr();
            try self.expectChar(')');
            return expr;
        }
        if (self.startsColorLiteral()) {
            return .{ .color = try self.parseColorLiteralString() };
        }
        if (!self.eof() and (self.source[self.pos] == '"' or self.startsWith("\"\"\""))) {
            return .{ .string = try self.parseStringLiteral() };
        }
        if (self.startsWith("<<")) {
            return .{ .string = try self.parseChevronBlockStringLiteral() };
        }
        if (self.startsNumberLiteral()) {
            return .{ .number = try self.parseNumber() };
        }
        const name = try self.parseCallableName();
        self.skipInlineSpaces();
        if (!name.isQualified() and std.mem.eql(u8, name.name, "none")) {
            if (self.eof() or (self.source[self.pos] != '(' and self.source[self.pos] != '.')) {
                return .none;
            }
        }
        if (!name.isQualified() and (std.mem.eql(u8, name.name, "true") or std.mem.eql(u8, name.name, "false"))) {
            if (self.eof() or (self.source[self.pos] != '(' and self.source[self.pos] != '.')) {
                const value = std.mem.eql(u8, name.name, "true");
                return .{ .boolean = value };
            }
        }
        if (!name.isQualified() and !self.eof() and self.source[self.pos] == '{') {
            return try self.parseRecordLiteralAfterName(name.name);
        }
        if (!self.eof() and self.source[self.pos] == '(') {
            return .{ .call = try self.parseCallAfterName(name) };
        }
        if (self.startsWith("<<")) {
            return .{ .call = try self.makeUnaryStringCall(name, try self.parseChevronBlockStringLiteral()) };
        }
        if (!self.eof() and (self.source[self.pos] == '"' or self.startsWith("\"\"\""))) {
            return .{ .call = try self.makeUnaryStringCall(name, try self.parseStringLiteral()) };
        }
        if (name.isQualified() or std.mem.endsWith(u8, name.name, "!")) return self.fail(error.ExpectedChar);
        if (!self.eof() and self.source[self.pos] != '(') {
            return .{ .ident = name.name };
        }
        return .{ .ident = name.name };
    }

    fn parseRecordLiteralAfterName(self: *Parser, type_name: []const u8) !Expr {
        try self.expectChar('{');
        var fields = std.ArrayList(ast.RecordFieldExpr).empty;
        errdefer {
            self.allocator.free(type_name);
            for (fields.items) |*field| field.deinit(self.allocator);
            fields.deinit(self.allocator);
        }
        self.skipTrivia();
        while (!self.eof() and !self.peekChar('}')) {
            const field_name = try self.parseIdentifier();
            self.skipInlineSpaces();
            try self.expectChar('=');
            const value = try self.parseExpr();
            try fields.append(self.allocator, .{
                .name = field_name,
                .value = value,
            });
            self.skipTrivia();
            if (!self.eof() and self.source[self.pos] == ',') {
                self.pos += 1;
                self.skipTrivia();
                continue;
            }
        }
        try self.expectChar('}');
        return .{ .record = .{
            .type_name = type_name,
            .fields = fields,
        } };
    }

    fn startsLambdaExpr(self: *Parser) bool {
        if (self.eof() or self.source[self.pos] != '(') return false;
        var probe = self.pos + 1;
        scanner.skipTrivia(self.source, &probe);
        if (probe < self.source.len and self.source[probe] == ')') {
            probe += 1;
            scanner.skipTrivia(self.source, &probe);
            return scanner.startsWith(self.source, probe, "|->");
        }
        if (!scanner.scanIdentifier(self.source, &probe)) return false;
        scanner.skipInlineSpaces(self.source, &probe);
        if (probe < self.source.len and self.source[probe] == ':') return true;

        var depth: usize = 1;
        while (probe < self.source.len) : (probe += 1) {
            switch (self.source[probe]) {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) {
                        probe += 1;
                        scanner.skipTrivia(self.source, &probe);
                        return scanner.startsWith(self.source, probe, "|->");
                    }
                },
                '\n' => return false,
                else => {},
            }
        }
        return false;
    }

    fn parseLambdaExpr(self: *Parser) !Expr {
        const start = self.pos;
        try self.expectChar('(');
        var params = std.ArrayList(ast.ParamDecl).empty;
        errdefer {
            for (params.items) |*param| param.deinit(self.allocator);
            params.deinit(self.allocator);
        }
        self.skipTrivia();
        while (!self.eof() and !self.peekChar(')')) {
            const param_name = try self.parseIdentifier();
            self.skipInlineSpaces();
            if (self.eof() or self.source[self.pos] != ':') return self.fail(error.ExpectedTypeAnnotation);
            self.pos += 1;
            self.skipInlineSpaces();
            const param_type = try self.parseTypeAnnotation();
            try params.append(self.allocator, .{
                .name = param_name,
                .ty = param_type,
                .default_value = null,
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
        self.skipTrivia();
        if (!self.startsWith("|->")) return self.fail(error.ExpectedChar);
        self.pos += 3;
        self.skipTrivia();
        const body = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(body);
        body.* = try self.parseExpr();
        errdefer body.deinit(self.allocator);
        return .{ .lambda = .{
            .params = params,
            .body = body,
            .span = .{ .start = start, .end = self.pos },
        } };
    }

    fn makeBinaryCall(self: *Parser, name: []const u8, left: Expr, right: Expr) !Expr {
        var args = std.ArrayList(Expr).empty;
        errdefer args.deinit(self.allocator);
        try args.append(self.allocator, left);
        try args.append(self.allocator, right);
        return .{ .call = .{ .callee = ast.CallableName.bare(name), .args = args } };
    }

    fn parseCallAfterName(self: *Parser, name: ast.CallableName) anyerror!ast.CallExpr {
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
        return .{ .callee = name, .args = args };
    }

    fn makeUnaryStringCall(self: *Parser, name: ast.CallableName, text: ast.StringLiteral) !ast.CallExpr {
        var args = std.ArrayList(Expr).empty;
        errdefer args.deinit(self.allocator);
        try args.append(self.allocator, .{ .string = text });
        return .{ .callee = name, .args = args };
    }

    fn parseMemberAssignmentStatement(self: *Parser, start: usize) !?Statement {
        const saved = self.pos;
        var target = self.parseCallTargetExpr() catch {
            self.pos = saved;
            return null;
        };
        errdefer target.deinit(self.allocator);

        while (true) {
            self.skipInlineSpaces();
            if (self.eof() or self.source[self.pos] != '.') {
                target.deinit(self.allocator);
                self.pos = saved;
                return null;
            }
            self.pos += 1;
            self.skipInlineSpaces();
            const member_name = try self.parseIdentifier();
            self.skipTrivia();
            if (!self.eof() and self.source[self.pos] == '=' and (self.pos + 1 >= self.source.len or self.source[self.pos + 1] != '=')) {
                self.pos += 1;
                const value = try self.parseExpr();
                try self.consumeStatementTerminator();
                const call = if (std.mem.eql(u8, member_name, "content")) blk: {
                    self.allocator.free(member_name);
                    break :blk try self.makeCall2("set_content", target, value);
                } else try self.makeCall3("set_prop", target, .{ .string = .{ .text = member_name } }, value);
                return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .expr_stmt = .{ .call = call } } };
            }
            target = try self.makeMemberExpr(target, member_name);
        }
    }

    fn parseCallTargetExpr(self: *Parser) !Expr {
        var expr = try self.parsePrimaryExpr();
        errdefer expr.deinit(self.allocator);
        while (true) {
            self.skipInlineSpaces();
            if (self.eof() or self.source[self.pos] != '(') return expr;
            expr = try self.parseApplyAfterCallee(expr);
        }
    }

    fn parseMemberExprAfterTarget(self: *Parser, target: Expr) !Expr {
        try self.expectChar('.');
        const member_name = try self.parseIdentifier();
        return try self.makeMemberExpr(target, member_name);
    }

    fn makeMemberExpr(self: *Parser, target: Expr, member_name: []const u8) !Expr {
        const target_ptr = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(target_ptr);
        target_ptr.* = target;
        return .{ .member = .{ .target = target_ptr, .name = member_name } };
    }

    fn makeOptionalCheckExpr(self: *Parser, target: Expr) !Expr {
        const target_ptr = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(target_ptr);
        target_ptr.* = target;
        return .{ .optional_check = .{ .target = target_ptr } };
    }

    fn makeCoalesceExpr(self: *Parser, target: Expr, fallback: Expr) !Expr {
        const target_ptr = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(target_ptr);
        const fallback_ptr = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(fallback_ptr);
        target_ptr.* = target;
        fallback_ptr.* = fallback;
        return .{ .coalesce = .{ .target = target_ptr, .fallback = fallback_ptr } };
    }

    fn makeCall1(self: *Parser, name: []const u8, arg0: Expr) !ast.CallExpr {
        var args = std.ArrayList(Expr).empty;
        errdefer args.deinit(self.allocator);
        try args.append(self.allocator, arg0);
        return .{ .callee = ast.CallableName.bare(name), .args = args };
    }

    fn makeCall2(self: *Parser, name: []const u8, arg0: Expr, arg1: Expr) !ast.CallExpr {
        var args = std.ArrayList(Expr).empty;
        errdefer args.deinit(self.allocator);
        try args.append(self.allocator, arg0);
        try args.append(self.allocator, arg1);
        return .{ .callee = ast.CallableName.bare(name), .args = args };
    }

    fn makeCall3(self: *Parser, name: []const u8, arg0: Expr, arg1: Expr, arg2: Expr) !ast.CallExpr {
        var args = std.ArrayList(Expr).empty;
        errdefer args.deinit(self.allocator);
        try args.append(self.allocator, arg0);
        try args.append(self.allocator, arg1);
        try args.append(self.allocator, arg2);
        return .{ .callee = ast.CallableName.bare(name), .args = args };
    }

    fn parseMemberConstraintDecl(self: *Parser) !ConstraintDecl {
        const target = try self.parseConstraintMemberRef(true);
        try self.expectEqualityOperator();
        if (target.dimension) |dimension| {
            if (target.anchor_ref.kind == .page) return self.fail(error.PageCannotBeConstraintTarget);
            const offset = try self.parseExpr();
            return .{
                .target = target.anchor_ref.withAnchor(dimension.target_anchor),
                .source = target.anchor_ref.withAnchor(dimension.source_anchor),
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

    fn parseAnchorMemberRef(self: *Parser) !AnchorRef {
        return (try self.parseConstraintMemberRef(false)).anchor_ref;
    }

    fn parseConstraintMemberRef(self: *Parser, allow_dimension: bool) !ConstraintMemberRef {
        self.skipInlineSpaces();
        const path_start = self.pos;
        _ = try self.parseIdentifier();
        var member_name: []const u8 = "";
        var path_end: usize = path_start;
        while (true) {
            self.skipInlineSpaces();
            path_end = self.pos;
            try self.expectChar('.');
            member_name = try self.parseIdentifier();
            self.skipInlineSpaces();
            if (self.eof() or self.source[self.pos] != '.') break;
        }
        const object_path = std.mem.trim(u8, self.source[path_start..path_end], " \t\r\n");
        if (allow_dimension) {
            if (std.mem.eql(u8, member_name, "width")) {
                return .{
                    .anchor_ref = makeParsedAnchorRef(object_path, .right),
                    .dimension = .{ .target_anchor = .right, .source_anchor = .left },
                };
            }
            if (std.mem.eql(u8, member_name, "height")) {
                return .{
                    .anchor_ref = makeParsedAnchorRef(object_path, .top),
                    .dimension = .{ .target_anchor = .top, .source_anchor = .bottom },
                };
            }
        }
        const anchor = names.parseAnchorName(member_name) orelse return self.fail(error.UnknownAnchor);
        return .{ .anchor_ref = makeParsedAnchorRef(object_path, anchor) };
    }

    fn makeParsedAnchorRef(object_path: []const u8, anchor: core.Anchor) AnchorRef {
        if (std.mem.eql(u8, object_path, "page")) return .{ .kind = .page, .anchor = anchor };
        return .{
            .kind = .node,
            .anchor = anchor,
            .node_name = firstPathSegment(object_path),
            .node_path = object_path,
        };
    }

    fn firstPathSegment(path: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, path, '.')) |index| return path[0..index];
        return path;
    }

    fn makeNegCall(self: *Parser, expr: Expr) !Expr {
        var args = std.ArrayList(Expr).empty;
        errdefer args.deinit(self.allocator);
        try args.append(self.allocator, expr);
        return .{ .call = .{ .callee = ast.CallableName.bare("neg"), .args = args } };
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
        const literal = try self.parseLineTextLiteral();
        return literal.text;
    }

    fn parseLineTextLiteral(self: *Parser) !ast.StringLiteral {
        self.skipInlineSpaces();
        const start = self.pos;
        while (!self.eof() and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
        const raw = trimRightSpaces(self.source[start..self.pos]);
        return .{
            .text = try self.allocator.dupe(u8, raw),
            .source_span = .{ .start = start, .end = start + raw.len },
        };
    }

    fn parseChevronBlockString(self: *Parser) ![]const u8 {
        const literal = try self.parseChevronBlockStringLiteral();
        return literal.text;
    }

    fn parseChevronBlockStringLiteral(self: *Parser) !ast.StringLiteral {
        self.skipInlineSpaces();
        if (!self.startsWith("<<")) return self.fail(error.ExpectedString);
        self.pos += 2;
        self.skipInlineSpaces();
        try self.expectLineBreak();

        const content_start = self.pos;
        while (!self.eof()) {
            if (self.isChevronTerminatorAtCurrentLine()) {
                const raw = self.source[content_start..self.pos];
                const bounds = normalizedBlockStringBounds(raw);
                self.consumeChevronTerminatorLine();
                return .{
                    .text = try self.allocator.dupe(u8, raw[bounds.start..bounds.end]),
                    .source_span = .{
                        .start = content_start + bounds.start,
                        .end = content_start + bounds.end,
                    },
                };
            }
            self.pos += 1;
        }
        return self.fail(error.UnterminatedString);
    }

    fn isChevronTerminatorAtCurrentLine(self: *Parser) bool {
        var line_start = self.pos;
        while (line_start > 0 and self.source[line_start - 1] != '\n') line_start -= 1;
        var probe = line_start;
        while (probe < self.source.len and scanner.isInlineSpace(self.source[probe])) probe += 1;
        if (probe + 2 > self.source.len) return false;
        if (!std.mem.eql(u8, self.source[probe .. probe + 2], ">>")) return false;
        probe += 2;
        while (probe < self.source.len and scanner.isInlineSpace(self.source[probe])) probe += 1;
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
        const literal = try self.parseStringLiteral();
        return literal.text;
    }

    fn parseStringLiteral(self: *Parser) !ast.StringLiteral {
        self.skipTrivia();
        if (self.startsWith("\"\"\"")) {
            self.pos += 3;
            const start = self.pos;
            while (!self.eof() and !self.startsWith("\"\"\"")) {
                self.pos += 1;
            }
            if (self.eof()) return self.fail(error.UnterminatedString);
            const raw = self.source[start..self.pos];
            const bounds = normalizedBlockStringBounds(raw);
            self.pos += 3;
            return .{
                .text = try self.allocator.dupe(u8, raw[bounds.start..bounds.end]),
                .source_span = .{
                    .start = start + bounds.start,
                    .end = start + bounds.end,
                },
            };
        }

        if (self.eof() or self.source[self.pos] != '"') return self.fail(error.ExpectedString);
        self.pos += 1;

        const start = self.pos;
        while (!self.eof()) {
            const ch = self.source[self.pos];
            self.pos += 1;
            if (ch == '"') {
                const end = self.pos - 1;
                return .{
                    .text = try self.allocator.dupe(u8, self.source[start..end]),
                    .source_span = .{ .start = start, .end = end },
                };
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
        return self.parseName(.identifier);
    }

    const NameKind = enum {
        identifier,
        callable,
    };

    fn parseCallableDeclName(self: *Parser) ![]const u8 {
        return self.parseName(.callable);
    }

    fn parseCallableName(self: *Parser) !ast.CallableName {
        const first = try self.parseName(.identifier);
        if (self.startsWith("::")) {
            self.pos += 2;
            const name = try self.parseName(.callable);
            return ast.CallableName.qualified(first, name);
        }
        if (!self.eof() and self.source[self.pos] == '!') {
            self.pos += 1;
            return ast.CallableName.bare(try std.fmt.allocPrint(self.allocator, "{s}!", .{first}));
        }
        return ast.CallableName.bare(first);
    }

    fn parseName(self: *Parser, kind: NameKind) ![]const u8 {
        self.skipTrivia();
        if (self.eof()) return self.fail(error.ExpectedIdentifier);
        const start = self.pos;
        if (!source_utils.isIdentifierStart(self.source[self.pos])) return self.fail(error.ExpectedIdentifier);
        self.pos += 1;
        while (!self.eof() and source_utils.isIdentifierContinue(self.source[self.pos])) {
            self.pos += 1;
        }
        const ident_end = self.pos;
        if (kind == .callable and !self.eof() and self.source[self.pos] == '!') {
            self.pos += 1;
        }
        const base = self.source[start..ident_end];
        const ident = self.source[start..self.pos];
        if (isReservedKeyword(base)) return self.fail(error.ReservedIdentifier);
        return self.allocator.dupe(u8, ident);
    }

    fn isValidIdentifier(ident: []const u8) bool {
        if (ident.len == 0 or !source_utils.isIdentifierStart(ident[0])) return false;
        for (ident[1..]) |ch| {
            if (!source_utils.isIdentifierContinue(ch)) return false;
        }
        return true;
    }

    fn isReservedKeyword(ident: []const u8) bool {
        const reserved = [_][]const u8{
            "import",
            "fn",
            "const",
            "type",
            "record",
            "protocol",
            "extend",
            "if",
            "else",
            "end",
            "return",
            "let",
            "bind",
            "as",
            "with",
        };
        inline for (reserved) |keyword| {
            if (std.mem.eql(u8, ident, keyword)) return true;
        }
        return false;
    }

    fn expectKeyword(self: *Parser, keyword: []const u8) !void {
        if (!try self.consumeKeyword(keyword)) return self.fail(error.ExpectedKeyword);
    }

    fn consumeKeyword(self: *Parser, keyword: []const u8) !bool {
        self.skipTrivia();
        return self.consumeKeywordNoTrivia(keyword);
    }

    fn consumeKeywordNoTrivia(self: *Parser, keyword: []const u8) bool {
        return scanner.consumeKeywordNoTrivia(self.source, &self.pos, keyword);
    }

    fn consumePairedFunctionMarker(self: *Parser) bool {
        if (!self.startsWith("/!")) return false;
        self.pos += 2;
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

    fn consumeConstraintMarker(self: *Parser) bool {
        self.skipInlineSpaces();
        if (self.eof() or self.source[self.pos] != '~') return false;
        self.pos += 1;
        return true;
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
        return scanner.atStatementBoundary(self.source, self.pos);
    }

    fn peekAnchorAssignment(self: *Parser) bool {
        var probe = self.pos;
        source_utils.skipTriviaFrom(self.source, &probe);
        if (!scanner.scanIdentifier(self.source, &probe)) return false;
        while (probe < self.source.len and scanner.isInlineSpace(self.source[probe])) probe += 1;
        if (probe >= self.source.len or self.source[probe] != '.') return false;
        probe += 1;
        while (probe < self.source.len and scanner.isInlineSpace(self.source[probe])) probe += 1;
        const member_start = probe;
        if (!scanner.scanIdentifier(self.source, &probe)) return false;
        const member_name = self.source[member_start..probe];
        if (names.parseAnchorName(member_name) == null and
            !std.mem.eql(u8, member_name, "width") and
            !std.mem.eql(u8, member_name, "height")) return false;
        while (probe < self.source.len and scanner.isInlineSpace(self.source[probe])) probe += 1;
        return scanner.startsWith(self.source, probe, "==");
    }

    fn peekPropertyAssignment(self: *Parser) bool {
        var probe = self.pos;
        source_utils.skipTriviaFrom(self.source, &probe);
        if (!scanner.scanIdentifier(self.source, &probe)) return false;
        while (probe < self.source.len and scanner.isInlineSpace(self.source[probe])) probe += 1;
        if (probe >= self.source.len or self.source[probe] != '.') return false;
        probe += 1;
        while (probe < self.source.len and scanner.isInlineSpace(self.source[probe])) probe += 1;
        if (!scanner.scanIdentifier(self.source, &probe)) return false;
        source_utils.skipTriviaFrom(self.source, &probe);
        if (probe >= self.source.len or self.source[probe] != '=') return false;
        if (probe + 1 < self.source.len and self.source[probe + 1] == '=') return false;
        return true;
    }

    fn peekSimpleAssignment(self: *Parser) bool {
        var probe = self.pos;
        source_utils.skipTriviaFrom(self.source, &probe);
        if (!scanner.scanIdentifier(self.source, &probe)) return false;
        while (probe < self.source.len and scanner.isInlineSpace(self.source[probe])) probe += 1;
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
        while (probe < self.source.len and scanner.isInlineSpace(self.source[probe])) probe += 1;
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
        scanner.skipInlineSpaces(self.source, &self.pos);
    }

    fn lineCommentStart(self: *Parser) bool {
        return scanner.lineCommentStart(self.source, self.pos);
    }

    fn skipLineComment(self: *Parser) void {
        scanner.skipLineComment(self.source, &self.pos);
    }

    fn skipTrivia(self: *Parser) void {
        scanner.skipTrivia(self.source, &self.pos);
    }

    fn startsWith(self: *Parser, text: []const u8) bool {
        return scanner.startsWith(self.source, self.pos, text);
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
        self.error_span = null;
        return err;
    }

    fn failAt(self: *Parser, pos: usize, err: anyerror) anyerror {
        self.error_pos = @min(pos, self.source.len);
        self.error_span = null;
        return err;
    }

    fn failSpan(self: *Parser, span: ast.Span, err: anyerror) anyerror {
        self.error_pos = @min(span.start, self.source.len);
        self.error_span = span;
        return err;
    }
};

fn functionBodyReturns(statements: []const Statement) bool {
    for (statements) |stmt| {
        if (statementReturns(stmt)) return true;
    }
    return false;
}

fn statementReturns(stmt: Statement) bool {
    return switch (stmt.kind) {
        .return_expr => true,
        .if_stmt => |if_stmt| functionBodyReturns(if_stmt.then_statements.items) and functionBodyReturns(if_stmt.else_statements.items),
        else => false,
    };
}

fn normalizeBlockString(raw: []const u8) []const u8 {
    const bounds = normalizedBlockStringBounds(raw);
    return raw[bounds.start..bounds.end];
}

fn normalizedBlockStringBounds(raw: []const u8) ast.Span {
    var start: usize = 0;
    var end: usize = raw.len;
    if (start < end and raw[start] == '\n') start += 1;
    if (start < end and raw[end - 1] == '\n') end -= 1;
    return .{ .start = start, .end = end };
}

fn trimRightSpaces(raw: []const u8) []const u8 {
    var end = raw.len;
    while (end > 0 and scanner.isInlineSpace(raw[end - 1])) end -= 1;
    return raw[0..end];
}

fn trimLeftSpaces(raw: []const u8) []const u8 {
    var start: usize = 0;
    while (start < raw.len and scanner.isInlineSpace(raw[start])) start += 1;
    return raw[start..];
}
