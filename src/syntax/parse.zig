const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const diagnostics = @import("diagnostics.zig");
const hole = @import("hole.zig");
const scanner = @import("scanner.zig");
const names = @import("../language/names.zig");
const utils = @import("utils");
const source = utils.source;
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

pub const ParseResult = struct {
    program: Program,
    holes: hole.Result,

    pub fn deinit(self: *ParseResult, allocator: Allocator) void {
        self.program.deinit(allocator);
        self.holes.deinit(allocator);
    }
};

pub fn parse(allocator: Allocator, text: []const u8) !Program {
    return parseWithSourceName(allocator, text, "");
}

pub fn parseWithSourceName(allocator: Allocator, text: []const u8, source_name: []const u8) !Program {
    var parser = initParser(allocator, text, source_name);
    last_diagnostic = null;
    return parser.parseProgram() catch |err| {
        const pos = @min(parser.error_pos, text.len);
        const span = if (parser.error_span) |span|
            ast.Span{
                .start = @min(span.start, text.len),
                .end = @min(@max(span.end, span.start + 1), text.len),
            }
        else
            ast.Span{ .start = pos, .end = @min(pos + 1, text.len) };
        last_diagnostic = .{
            .err = err,
            .span = span,
            .expected = diagnostics.expected(err),
            .found = diagnostics.foundToken(text, pos),
        };
        return err;
    };
}

pub fn parseRecovering(allocator: Allocator, text: []const u8) !ParseResult {
    return parseRecoveringWithSourceName(allocator, text, "");
}

pub fn parseRecoveringWithSourceName(allocator: Allocator, text: []const u8, source_name: []const u8) !ParseResult {
    var builder = hole.Builder{ .allocator = allocator };
    errdefer builder.deinit();

    var parser = initParser(allocator, text, source_name);
    parser.recovering = true;
    parser.reject_empty_args = true;
    parser.holes = &builder;
    last_diagnostic = null;

    var program = try parser.parseProgram();
    errdefer program.deinit(allocator);
    const holes = try builder.finish();
    return .{ .program = program, .holes = holes };
}

pub fn lastDiagnostic() ?ParseDiagnostic {
    return last_diagnostic;
}

fn initParser(allocator: Allocator, text: []const u8, source_name: []const u8) Parser {
    return .{
        .allocator = allocator,
        .source = text,
        .source_name = source_name,
        .pos = 0,
        .error_pos = 0,
        .error_span = null,
        .generated_page_count = 0,
        .recovering = false,
        .reject_empty_args = false,
        .holes = null,
    };
}

const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    source_name: []const u8,
    pos: usize,
    error_pos: usize,
    error_span: ?ast.Span,
    generated_page_count: usize,
    recovering: bool,
    reject_empty_args: bool,
    holes: ?*hole.Builder,

    fn parseProgram(self: *Parser) !Program {
        var program = Program.init();
        errdefer program.deinit(self.allocator);
        var imports_allowed = true;

        source.skipTriviaFrom(self.source, &self.pos);
        while (!self.eof()) {
            const item_start = self.pos;
            self.parseTopLevelItem(&program, &imports_allowed) catch |err| {
                if (!self.recovering) return err;
                try self.addTopLevelHole(err, item_start);
                self.synchronizeTopLevelItem(item_start);
            };
            source.skipTriviaFrom(self.source, &self.pos);
        }
        return program;
    }

    fn parseTopLevelItem(self: *Parser, program: *Program, imports_allowed: *bool) !void {
        const item_start = self.pos;
        if (self.source[self.pos] == '@') return self.fail(error.ExpectedKeyword);

        if (try self.consumeKeyword("import")) {
            if (!imports_allowed.*) return self.failAt(item_start, error.ImportMustBeAtTop);
            const spec = try self.parseImportSpec();
            errdefer self.allocator.free(spec.text);
            try self.validateImportSpec(spec.text);
            const mode = try self.parseImportMode(spec.text);
            errdefer if (mode.mode.alias) |alias| self.allocator.free(alias);
            try self.consumeStatementTerminator();
            const import_index = program.imports.items.len;
            try program.imports.append(self.allocator, .{
                .spec = spec.text,
                .spec_span = spec.span,
                .mode = mode.mode,
                .alias_span = mode.alias_span,
                .span = .{ .start = item_start, .end = self.pos },
            });
            try program.top_level_items.append(self.allocator, .{ .import = import_index });
        } else if (try self.consumeKeyword("fn")) {
            imports_allowed.* = false;
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
            imports_allowed.* = false;
            const constant = try self.parseConstAfterKeyword(item_start);
            try program.constants.append(self.allocator, constant);
        } else if (try self.consumeKeyword("type")) {
            imports_allowed.* = false;
            const type_item = try self.parseTypeItemAfterKeyword(item_start);
            switch (type_item) {
                .enum_decl => |type_decl| {
                    try self.consumeStatementTerminator();
                    try program.types.append(self.allocator, type_decl);
                },
                .object => |object_decl| try program.objects.append(self.allocator, object_decl),
            }
        } else if (try self.consumeKeyword("record")) {
            imports_allowed.* = false;
            const record_decl = try self.parseRecordDeclAfterKeyword(item_start);
            try program.records.append(self.allocator, record_decl);
        } else if (try self.consumeKeyword("extend")) {
            imports_allowed.* = false;
            const extension = try self.parseObjectExtensionAfterKeyword(item_start);
            try program.object_extensions.append(self.allocator, extension);
        } else if (try self.consumeKeyword("document")) {
            imports_allowed.* = false;
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
            imports_allowed.* = false;
            const page = try self.parsePage();
            const page_index = program.pages.items.len;
            try program.pages.append(self.allocator, page);
            try program.top_level_items.append(self.allocator, .{ .page = page_index });
        }
    }

    fn currentErrorSpan(self: *Parser) ast.Span {
        if (self.error_span) |span| return .{
            .start = @min(span.start, self.source.len),
            .end = @min(@max(span.end, span.start), self.source.len),
        };
        const pos = @min(self.error_pos, self.source.len);
        return pointSpan(pos);
    }

    fn addTopLevelHole(self: *Parser, err: anyerror, item_start: usize) !void {
        const span = self.currentErrorSpan();
        const line = source.lineAt(self.source, span.start);
        if (err == error.InvalidImportSpec or err == error.ExpectedString) {
            _ = try self.addHole(.import_spec, .import_spec, span, if (err == error.ExpectedString) error.InvalidImportSpec else err, foundAt(self.source, span.start, line.span.end));
            return;
        }
        _ = try self.addHole(.block, .block, .{ .start = item_start, .end = @max(item_start, span.end) }, err, foundAt(self.source, span.start, line.span.end));
    }

    fn makeHoleStatementForError(self: *Parser, err: anyerror, statement_start: usize) !Statement {
        const span = self.currentErrorSpan();
        const line = source.lineAt(self.source, span.start);
        const id = try self.addHoleForParseError(err, span, line.span);
        return .{
            .span = .{ .start = statement_start, .end = @max(statement_start, span.end) },
            .kind = .{ .hole = id },
        };
    }

    fn addHoleForParseError(self: *Parser, err: anyerror, span: ast.Span, line_span: source.ByteSpan) !ast.HoleId {
        const pos = span.start;
        if (previousSignificantByte(self.source, pos, line_span.start) == '.') {
            return try self.addHole(.member_name, .member_name, pointSpan(pos), error.ExpectedMemberName, foundAt(self.source, pos, line_span.end));
        }
        if (isCallArgumentHole(self.source, pos, line_span.start)) {
            return try self.addHole(.call_arg, .call_arg, pointSpan(pos), error.ExpectedExpression, foundAt(self.source, pos, line_span.end));
        }
        if (err == error.ExpectedExpression or err == error.ExpectedIdentifier or err == error.ExpectedString) {
            return try self.addHole(.expr, .expression, pointSpan(pos), error.ExpectedExpression, foundAt(self.source, pos, line_span.end));
        }
        return try self.addHole(.stmt, .statement, pointSpan(pos), err, foundAt(self.source, pos, line_span.end));
    }

    fn makeHoleExpr(self: *Parser, kind: hole.HoleKind, expected: hole.ExpectedSyntax, span: ast.Span, err: anyerror, found: ?[]const u8) !Expr {
        const id = try self.addHole(kind, expected, span, err, found);
        return .{ .hole = id };
    }

    fn addHole(self: *Parser, kind: hole.HoleKind, expected: hole.ExpectedSyntax, span: ast.Span, err: anyerror, found: ?[]const u8) !ast.HoleId {
        const builder = self.holes orelse return err;
        return try builder.add(kind, expected, span, err, found);
    }

    fn synchronizeTopLevelItem(self: *Parser, start: usize) void {
        self.synchronizeToLineEnd(start);
    }

    fn synchronizeStatement(self: *Parser, start: usize) void {
        if (self.pos <= start and self.pos < self.source.len) self.pos += 1;
        while (self.pos < self.source.len) {
            if (self.source[self.pos] == '\n') {
                self.pos += 1;
                return;
            }
            if (standaloneKeywordAt(self.source, self.pos, "end") or standaloneKeywordAt(self.source, self.pos, "else")) return;
            self.pos += 1;
        }
    }

    fn synchronizeToLineEnd(self: *Parser, start: usize) void {
        if (self.pos <= start and self.pos < self.source.len) self.pos += 1;
        while (self.pos < self.source.len) : (self.pos += 1) {
            if (self.source[self.pos] == '\n') {
                self.pos += 1;
                return;
            }
        }
    }

    const FunctionParseOptions = struct {
        paired: bool = false,
    };

    fn parseFunctionAfterKeyword(self: *Parser, start: usize, options: FunctionParseOptions) !FunctionDecl {
        const parsed_name = try self.parseCallableDeclNameWithSpan();
        if (options.paired and names.hasBangSuffix(parsed_name.text)) {
            defer self.allocator.free(parsed_name.text);
            return self.failAt(self.pos - 1, error.PairedFunctionNameCannotEndWithBang);
        }
        source.skipInlineSpaces(self.source, &self.pos);
        try self.expectChar('(');

        var params = std.ArrayList(ast.ParamDecl).empty;
        errdefer {
            for (params.items) |*param| param.deinit(self.allocator);
            params.deinit(self.allocator);
        }
        var seen_default = false;
        source.skipTriviaFrom(self.source, &self.pos);
        while (!self.eof() and !self.peekChar(')')) {
            const param_name = try self.parseIdentifierWithSpan();
            source.skipInlineSpaces(self.source, &self.pos);
            if (self.eof() or self.source[self.pos] != ':') return self.fail(error.ExpectedTypeAnnotation);
            self.pos += 1;
            source.skipInlineSpaces(self.source, &self.pos);
            const param_type = try self.parseTypeAnnotation();
            source.skipInlineSpaces(self.source, &self.pos);
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
                .name = param_name.text,
                .name_span = param_name.span,
                .ty = param_type,
                .default_value = default_value,
            });
            source.skipTriviaFrom(self.source, &self.pos);
            if (!self.eof() and self.source[self.pos] == ',') {
                self.pos += 1;
                source.skipTriviaFrom(self.source, &self.pos);
                continue;
            }
            break;
        }
        try self.expectChar(')');
        source.skipInlineSpaces(self.source, &self.pos);
        if (!source.startsWithAt(self.source, self.pos, "->")) return self.fail(error.ExpectedTypeAnnotation);
        self.pos += 2;
        source.skipInlineSpaces(self.source, &self.pos);
        const result_type = try self.parseTypeAnnotation();
        const statements = try self.parseFunctionBody(result_type);
        if (result_type.kind != .void and !functionBodyReturns(statements.items)) return self.fail(error.ExpectedReturn);
        return .{ .name = parsed_name.text, .name_span = parsed_name.span, .span = .{ .start = start, .end = self.pos }, .params = params, .result_type = result_type, .statements = statements };
    }

    fn parseFunctionBody(self: *Parser, result_type: ast.Type) !std.ArrayList(Statement) {
        source.skipInlineSpaces(self.source, &self.pos);
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
        source.skipTriviaFrom(self.source, &self.pos);
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
            try inner_args.append(self.allocator, .{ .ident = .{ .name = try self.allocator.dupe(u8, param.name) } });
        }

        var outer_args = std.ArrayList(Expr).empty;
        errdefer {
            for (outer_args.items) |*arg| arg.deinit(self.allocator);
            outer_args.deinit(self.allocator);
        }
        try outer_args.append(self.allocator, .{ .call = .{
            .callee = .{ .name = try self.allocator.dupe(u8, "pagectx") },
            .args = .empty,
        } });
        try outer_args.append(self.allocator, .{ .call = .{
            .callee = .{ .name = try self.allocator.dupe(u8, func.name) },
            .args = inner_args,
        } });
        inner_args = .empty;

        const return_expr = Expr{ .call = .{
            .callee = .{ .name = try self.allocator.dupe(u8, "place_on!") },
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
        const parsed_name = try self.parseIdentifierWithSpan();
        source.skipInlineSpaces(self.source, &self.pos);
        if (self.eof() or self.source[self.pos] != ':') return self.fail(error.ExpectedTypeAnnotation);
        self.pos += 1;
        source.skipInlineSpaces(self.source, &self.pos);
        const result_type = try self.parseTypeAnnotation();
        source.skipTriviaFrom(self.source, &self.pos);
        try self.expectChar('=');
        const expr = try self.parseExpr();
        try self.consumeStatementTerminator();

        return .{
            .name = parsed_name.text,
            .name_span = parsed_name.span,
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
        const parsed_name = try self.parseIdentifierWithSpan();
        source.skipInlineSpaces(self.source, &self.pos);
        try self.expectChar('=');
        source.skipInlineSpaces(self.source, &self.pos);
        if (try self.consumeKeyword("object")) {
            return .{ .object = try self.parseObjectDeclBody(start, parsed_name) };
        }
        if (try self.consumeKeyword("protocol")) {
            return .{ .object = try self.parseObjectDeclBody(start, parsed_name) };
        }
        var cases = std.ArrayList(ast.EnumCaseDecl).empty;
        var needs_case = true;
        errdefer {
            for (cases.items) |*case_decl| case_decl.deinit(self.allocator);
            cases.deinit(self.allocator);
            self.allocator.free(parsed_name.text);
        }
        while (true) {
            source.skipInlineSpaces(self.source, &self.pos);
            if (self.eof() or self.source[self.pos] == '\n' or self.source[self.pos] == '@' or source.lineCommentMarkerLength(self.source, self.pos) != null) {
                if (needs_case) return self.fail(error.ExpectedTypeAnnotation);
                break;
            }
            const case_name = try self.parseIdentifierWithSpan();
            try cases.append(self.allocator, .{
                .name = case_name.text,
                .name_span = case_name.span,
            });
            needs_case = false;
            source.skipInlineSpaces(self.source, &self.pos);
            if (self.eof() or self.source[self.pos] == '\n' or self.source[self.pos] == '@' or source.lineCommentMarkerLength(self.source, self.pos) != null) break;
            if (self.source[self.pos] != '|') return self.fail(error.ExpectedTypeAnnotation);
            self.pos += 1;
            needs_case = true;
        }
        if (cases.items.len == 0) return self.fail(error.ExpectedTypeAnnotation);
        return .{ .enum_decl = .{
            .name = parsed_name.text,
            .name_span = parsed_name.span,
            .cases = cases,
            .span = .{ .start = start, .end = self.pos },
        } };
    }

    fn parseObjectExtensionAfterKeyword(self: *Parser, start: usize) !ObjectExtensionDecl {
        const target = try self.parseIdentifierWithSpan();
        source.skipTriviaFrom(self.source, &self.pos);
        try self.expectChar('{');
        var extension = ObjectExtensionDecl{
            .target = target.text,
            .target_span = target.span,
            .roles = .empty,
            .fields = .empty,
            .span = .{ .start = start, .end = start },
        };
        errdefer extension.deinit(self.allocator);
        try self.parseObjectMembers(null, &extension.implements, &extension.roles, &extension.fields);
        extension.span.end = self.pos;
        return extension;
    }

    fn parseObjectDeclBody(self: *Parser, start: usize, name: ParsedName) !ObjectDecl {
        source.skipTriviaFrom(self.source, &self.pos);
        try self.expectChar('{');
        var decl = ObjectDecl{
            .name = name.text,
            .name_span = name.span,
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
        const name = try self.parseIdentifierWithSpan();
        return try self.parseRecordDeclBody(start, name);
    }

    fn parseRecordDeclBody(self: *Parser, start: usize, name: ParsedName) !RecordDecl {
        source.skipTriviaFrom(self.source, &self.pos);
        try self.expectChar('{');
        var decl = RecordDecl{
            .name = name.text,
            .name_span = name.span,
            .fields = .empty,
            .span = .{ .start = start, .end = start },
        };
        errdefer decl.deinit(self.allocator);
        try self.parseRecordMembers(&decl.fields);
        decl.span.end = self.pos;
        return decl;
    }

    fn parseRecordMembers(self: *Parser, fields: *std.ArrayList(ast.ObjectFieldDecl)) !void {
        source.skipTriviaFrom(self.source, &self.pos);
        while (!self.eof() and !self.peekChar('}')) {
            const member_start = self.pos;
            const name = try self.parseIdentifierWithSpan();
            source.skipInlineSpaces(self.source, &self.pos);
            if (self.eof() or self.source[self.pos] != ':') return self.fail(error.ExpectedTypeAnnotation);
            self.pos += 1;
            source.skipInlineSpaces(self.source, &self.pos);
            var field_type = try self.parseTypeAnnotation();
            errdefer field_type.deinit(self.allocator);
            var default_value: ?*Expr = null;
            var default_property_value: ?[]const u8 = null;
            source.skipInlineSpaces(self.source, &self.pos);
            if (!self.eof() and self.source[self.pos] == '=') {
                self.pos += 1;
                source.skipInlineSpaces(self.source, &self.pos);
                const parsed_default = try self.parseObjectFieldDefault();
                default_value = parsed_default.expr;
                default_property_value = parsed_default.property_value;
            }
            try fields.append(self.allocator, .{
                .name = name.text,
                .name_span = name.span,
                .value_type = field_type,
                .default_value = default_value,
                .default_property_value = default_property_value,
                .span = .{ .start = member_start, .end = self.pos },
            });
            field_type = ast.Type.none;
            try self.consumeStatementTerminator();
            source.skipTriviaFrom(self.source, &self.pos);
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
        source.skipTriviaFrom(self.source, &self.pos);
        while (!self.eof() and !self.peekChar('}')) {
            const member_start = self.pos;
            const name = try self.parseIdentifierWithSpan();
            source.skipInlineSpaces(self.source, &self.pos);
            if (!self.eof() and self.source[self.pos] == '=') {
                self.pos += 1;
                source.skipTriviaFrom(self.source, &self.pos);
                if (std.mem.eql(u8, name.text, "base")) {
                    if (maybe_base) |base| {
                        if (base.*) |existing| self.allocator.free(existing);
                        base.* = try self.parseIdentifier();
                    } else {
                        return self.fail(error.ExpectedIdentifier);
                    }
                } else if (std.mem.eql(u8, name.text, "implements")) {
                    if (maybe_implements) |implements| {
                        if (implements.*) |existing| self.allocator.free(existing);
                        implements.* = try self.parseIdentifier();
                    } else {
                        return self.fail(error.ExpectedIdentifier);
                    }
                } else if (std.mem.eql(u8, name.text, "roles")) {
                    try self.parseStringListInto(roles);
                } else {
                    return self.fail(error.ExpectedTypeAnnotation);
                }
                self.allocator.free(name.text);
                try self.consumeStatementTerminator();
                source.skipTriviaFrom(self.source, &self.pos);
                continue;
            }
            if (self.eof() or self.source[self.pos] != ':') return self.fail(error.ExpectedTypeAnnotation);
            self.pos += 1;
            source.skipInlineSpaces(self.source, &self.pos);
            var field_type = try self.parseTypeAnnotation();
            errdefer field_type.deinit(self.allocator);
            var default_value: ?*Expr = null;
            var default_property_value: ?[]const u8 = null;
            source.skipInlineSpaces(self.source, &self.pos);
            if (!self.eof() and self.source[self.pos] == '=') {
                self.pos += 1;
                source.skipInlineSpaces(self.source, &self.pos);
                const parsed_default = try self.parseObjectFieldDefault();
                default_value = parsed_default.expr;
                default_property_value = parsed_default.property_value;
            }
            try fields.append(self.allocator, .{
                .name = name.text,
                .name_span = name.span,
                .value_type = field_type,
                .default_value = default_value,
                .default_property_value = default_property_value,
                .span = .{ .start = member_start, .end = self.pos },
            });
            field_type = ast.Type.none;
            try self.consumeStatementTerminator();
            source.skipTriviaFrom(self.source, &self.pos);
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
        source.skipTriviaFrom(self.source, &self.pos);
        try self.expectChar('[');
        source.skipTriviaFrom(self.source, &self.pos);
        while (!self.eof() and !self.peekChar(']')) {
            try out.append(self.allocator, try self.parseString());
            source.skipTriviaFrom(self.source, &self.pos);
            if (!self.eof() and self.source[self.pos] == ',') {
                self.pos += 1;
                source.skipTriviaFrom(self.source, &self.pos);
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
        if (try self.parseTypeHoleAtBoundary()) |ty| return ty;
        var ty = try self.parseFunctionTypeAnnotation();
        errdefer ty.deinit(self.allocator);
        source.skipInlineSpaces(self.source, &self.pos);
        if (!self.eof() and self.source[self.pos] == '?') {
            self.pos += 1;
            const optional_ty = try ast.Type.optional(self.allocator, ty);
            ty.deinit(self.allocator);
            return optional_ty;
        }
        return ty;
    }

    fn parseTypeHoleAtBoundary(self: *Parser) !?ast.Type {
        if (!self.recovering) return null;
        source.skipInlineSpaces(self.source, &self.pos);
        if (self.eof()) return try self.makeHoleType(pointSpan(self.pos), "end of file");
        if (!isTypeAnnotationBoundary(self.source, self.pos)) return null;
        const line = source.lineAt(self.source, self.pos);
        return try self.makeHoleType(pointSpan(self.pos), foundAt(self.source, self.pos, line.span.end));
    }

    fn makeHoleType(self: *Parser, span: ast.Span, found: ?[]const u8) !ast.Type {
        const id = try self.addHole(.type_expr, .type_expr, span, error.ExpectedTypeAnnotation, found);
        return ast.Type.hole(id);
    }

    fn parseFunctionTypeAnnotation(self: *Parser) anyerror!ast.Type {
        source.skipInlineSpaces(self.source, &self.pos);
        if (!self.eof() and self.source[self.pos] == '(') {
            const start = self.pos;
            try self.expectChar('(');
            var params = std.ArrayList(ast.Type).empty;
            errdefer {
                for (params.items) |*param| param.deinit(self.allocator);
                params.deinit(self.allocator);
            }
            source.skipInlineSpaces(self.source, &self.pos);
            while (!self.eof() and !self.peekChar(')')) {
                const param_type = try self.parseTypeAnnotation();
                try params.append(self.allocator, param_type);
                source.skipInlineSpaces(self.source, &self.pos);
                if (!self.eof() and self.source[self.pos] == ',') {
                    self.pos += 1;
                    source.skipInlineSpaces(self.source, &self.pos);
                    continue;
                }
                break;
            }
            try self.expectChar(')');
            source.skipInlineSpaces(self.source, &self.pos);
            if (source.startsWithAt(self.source, self.pos, "->")) {
                self.pos += 2;
                source.skipInlineSpaces(self.source, &self.pos);
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
        source.skipInlineSpaces(self.source, &self.pos);
        if (!source.startsWithAt(self.source, self.pos, "->")) return left;
        self.pos += 2;
        source.skipInlineSpaces(self.source, &self.pos);
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
        const name = try self.parseQualifiedTypeNameWithSpan();
        if (std.mem.eql(u8, name.text, "Document")) {
            self.allocator.free(name.text);
            return ast.Type.document;
        }
        if (std.mem.eql(u8, name.text, "Page")) {
            self.allocator.free(name.text);
            return ast.Type.page;
        }
        if (std.mem.eql(u8, name.text, "Object")) return try self.parseObjectType(name);
        if (std.mem.eql(u8, name.text, "Anchor")) {
            self.allocator.free(name.text);
            return ast.Type.anchor;
        }
        if (std.mem.eql(u8, name.text, "Function")) {
            self.allocator.free(name.text);
            return self.fail(error.InvalidTypeAnnotation);
        }
        if (std.mem.eql(u8, name.text, "String")) {
            self.allocator.free(name.text);
            return ast.Type.string;
        }
        if (std.mem.eql(u8, name.text, "Color")) {
            self.allocator.free(name.text);
            return ast.Type.color;
        }
        if (std.mem.eql(u8, name.text, "Number")) {
            self.allocator.free(name.text);
            return ast.Type.number;
        }
        if (std.mem.eql(u8, name.text, "Bool")) {
            self.allocator.free(name.text);
            return ast.Type.boolean;
        }
        if (std.mem.eql(u8, name.text, "Constraints")) {
            self.allocator.free(name.text);
            return ast.Type.constraints;
        }
        if (std.mem.eql(u8, name.text, "Void")) {
            self.allocator.free(name.text);
            return .{ .kind = .void };
        }
        if (std.mem.eql(u8, name.text, "None")) {
            self.allocator.free(name.text);
            return ast.Type.none;
        }
        if (std.mem.eql(u8, name.text, "Selection")) {
            self.allocator.free(name.text);
            return ast.Type.selectionType(try self.parseOptionalTypeParam());
        }
        return ast.Type.objectClassAt(name.text, name.span);
    }

    fn parseQualifiedTypeName(self: *Parser) anyerror![]const u8 {
        return (try self.parseQualifiedTypeNameWithSpan()).text;
    }

    fn parseQualifiedTypeNameWithSpan(self: *Parser) anyerror!ParsedName {
        const first = try self.parseIdentifierWithSpan();
        errdefer self.allocator.free(first.text);
        if (!source.startsWithAt(self.source, self.pos, "::")) return first;
        self.pos += 2;
        const second = try self.parseIdentifierWithSpan();
        defer {
            self.allocator.free(first.text);
            self.allocator.free(second.text);
        }
        return .{
            .text = try std.fmt.allocPrint(self.allocator, "{s}::{s}", .{ first.text, second.text }),
            .span = .{ .start = first.span.start, .end = second.span.end },
        };
    }

    fn parseObjectType(self: *Parser, object_name: ParsedName) anyerror!ast.Type {
        defer self.allocator.free(object_name.text);
        source.skipInlineSpaces(self.source, &self.pos);
        if (self.eof() or self.source[self.pos] != '<') return ast.Type.object;
        try self.expectChar('<');
        const class_name = try self.parseQualifiedTypeNameWithSpan();
        errdefer self.allocator.free(class_name.text);
        try self.expectChar('>');
        return ast.Type.objectClassAt(class_name.text, class_name.span);
    }

    fn parseOptionalTypeParam(self: *Parser) anyerror!ast.Type {
        source.skipInlineSpaces(self.source, &self.pos);
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
        const name = try self.parsePageNameWithSpan();
        const statements = try self.parseBodyStatements();
        return .{
            .name = name.text,
            .name_span = name.span,
            .statements = statements,
            .span = .{ .start = start, .end = self.pos },
        };
    }

    fn parsePageNameWithSpan(self: *Parser) !ParsedName {
        source.skipInlineSpaces(self.source, &self.pos);
        if (!self.eof() and self.source[self.pos] == '"') {
            const name_start = self.pos;
            const name = try self.parseString();
            return .{
                .text = try self.resolvePageName(name, name_start),
                .span = .{ .start = name_start, .end = self.pos },
            };
        }
        if (!self.eof() and self.source[self.pos] == '#') return self.fail(error.ReservedPageNamePrefix);

        const start = self.pos;
        while (!self.eof()) {
            const ch = self.source[self.pos];
            if (source.isInlineSpace(ch) or ch == '\n') break;
            if (ch == '#') break;
            if (ch == ';' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == ';') break;
            if (ch == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') break;
            self.pos += 1;
        }
        if (start == self.pos) return self.fail(error.ExpectedString);
        const name = try self.allocator.dupe(u8, self.source[start..self.pos]);
        return .{
            .text = try self.resolvePageName(name, start),
            .span = .{ .start = start, .end = self.pos },
        };
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

    const ParsedImportSpec = struct {
        text: []const u8,
        span: ast.Span,
    };

    const ParsedImportMode = struct {
        mode: ast.ImportDecl.Mode,
        alias_span: ?ast.Span = null,
    };

    fn parseImportSpec(self: *Parser) !ParsedImportSpec {
        source.skipInlineSpaces(self.source, &self.pos);
        if (!self.eof() and (self.source[self.pos] == '"' or source.startsWithAt(self.source, self.pos, "\"\"\""))) {
            const literal = try self.parseStringLiteral();
            return .{ .text = literal.text, .span = literal.source_span.? };
        }
        const start = self.pos;
        while (!self.eof()) {
            const ch = self.source[self.pos];
            if (source.isInlineSpace(ch) or ch == '\n') break;
            if (ch == '#') break;
            if (ch == ';' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == ';') break;
            if (ch == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') break;
            self.pos += 1;
        }
        if (start == self.pos) return self.fail(error.ExpectedString);
        return .{
            .text = try self.allocator.dupe(u8, self.source[start..self.pos]),
            .span = .{ .start = start, .end = self.pos },
        };
    }

    fn parseImportMode(self: *Parser, spec: []const u8) !ParsedImportMode {
        source.skipInlineSpaces(self.source, &self.pos);
        if (self.consumeKeywordNoTrivia("as")) {
            source.skipInlineSpaces(self.source, &self.pos);
            if (!self.eof() and self.source[self.pos] == '*') {
                self.pos += 1;
                return .{ .mode = .{ .unqualified = true } };
            }
            const alias_start = self.pos;
            const alias = try self.parseIdentifier();
            return .{
                .mode = .{ .alias = alias },
                .alias_span = .{ .start = alias_start, .end = self.pos },
            };
        }
        return .{ .mode = .{ .alias = try self.defaultImportAlias(spec), .unqualified = true } };
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
        source.skipInlineSpaces(self.source, &self.pos);
        try self.expectLineBreakAfterHeader();
        return try self.parseStatementsUntilEnd();
    }

    fn parseStatementsUntilEnd(self: *Parser) !std.ArrayList(Statement) {
        var statements = std.ArrayList(Statement).empty;
        errdefer {
            for (statements.items) |*stmt| stmt.deinit(self.allocator);
            statements.deinit(self.allocator);
        }

        source.skipTriviaFrom(self.source, &self.pos);
        while (!self.eof()) {
            if (self.peekStandaloneKeyword("end")) {
                try self.consumeStandaloneKeyword("end");
                return statements;
            }
            const statement_start = self.pos;
            const statement = self.parseStatement() catch |err| {
                if (!self.recovering) return err;
                try statements.append(self.allocator, try self.makeHoleStatementForError(err, statement_start));
                self.synchronizeStatement(statement_start);
                source.skipTriviaFrom(self.source, &self.pos);
                continue;
            };
            try statements.append(self.allocator, statement);
            source.skipTriviaFrom(self.source, &self.pos);
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

        source.skipTriviaFrom(self.source, &self.pos);
        while (!self.eof()) {
            if (self.peekStandaloneKeyword("else")) {
                try self.consumeStandaloneKeyword("else");
                return .{ .statements = statements, .terminator = .@"else" };
            }
            if (self.peekStandaloneKeyword("end")) {
                try self.consumeStandaloneKeyword("end");
                return .{ .statements = statements, .terminator = .end };
            }
            const statement_start = self.pos;
            const statement = self.parseStatement() catch |err| {
                if (!self.recovering) return err;
                try statements.append(self.allocator, try self.makeHoleStatementForError(err, statement_start));
                self.synchronizeStatement(statement_start);
                source.skipTriviaFrom(self.source, &self.pos);
                continue;
            };
            try statements.append(self.allocator, statement);
            source.skipTriviaFrom(self.source, &self.pos);
        }
        return self.fail(error.ExpectedEnd);
    }

    fn parseStatement(self: *Parser) anyerror!Statement {
        source.skipTriviaFrom(self.source, &self.pos);
        const start = self.pos;

        if (try self.consumeKeyword("if")) {
            const condition = try self.parseExpr();
            source.skipInlineSpaces(self.source, &self.pos);
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
            const name = try self.parseIdentifierWithSpan();
            errdefer self.allocator.free(name.text);
            var type_annotation: ?ast.Type = null;
            errdefer if (type_annotation) |*annotation| annotation.deinit(self.allocator);
            source.skipInlineSpaces(self.source, &self.pos);
            if (!self.eof() and self.source[self.pos] == ':') {
                self.pos += 1;
                type_annotation = try self.parseTypeAnnotation();
            }
            source.skipTriviaFrom(self.source, &self.pos);
            try self.expectChar('=');
            const expr = try self.parseExpr();
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .let_binding = .{ .name = name.text, .name_span = name.span, .type_annotation = type_annotation, .expr = expr } } };
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
        source.skipInlineSpaces(self.source, &self.pos);

        if (!self.eof() and self.source[self.pos] == '(') {
            const call = try self.parseCallAfterName(name);
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .expr_stmt = .{ .call = call } } };
        }

        if (source.startsWithAt(self.source, self.pos, "<<")) {
            const text = try self.parseChevronBlockStringLiteral();
            const call = try self.makeUnaryStringCall(name, text);
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .expr_stmt = .{ .call = call } } };
        }

        if (!self.eof() and (self.source[self.pos] == '"' or source.startsWithAt(self.source, self.pos, "\"\"\""))) {
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
            source.skipInlineSpaces(self.source, &self.pos);
            if (!source.startsWithAt(self.source, self.pos, "++")) return left;
            self.pos += 2;
            const right = try self.parseAddSubExpr();
            left = try self.makeBinaryCall("concat", left, right);
        }
    }

    fn parseAddSubExpr(self: *Parser) anyerror!Expr {
        var left = try self.parseMulDivExpr();
        while (true) {
            source.skipInlineSpaces(self.source, &self.pos);
            if (self.eof()) return left;
            if (source.startsWithAt(self.source, self.pos, "++")) return left;
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
            source.skipInlineSpaces(self.source, &self.pos);
            if (self.eof()) return left;
            const op = self.source[self.pos];
            if (op != '*' and op != '/') return left;
            self.pos += 1;
            const right = try self.parseUnaryExpr();
            left = try self.makeBinaryCall(if (op == '*') "mul" else "div", left, right);
        }
    }

    fn parseUnaryExpr(self: *Parser) anyerror!Expr {
        source.skipInlineSpaces(self.source, &self.pos);
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
            source.skipInlineSpaces(self.source, &self.pos);
            if (self.eof()) return expr;
            if (self.consumeKeywordNoTrivia("with")) {
                expr = try self.parseRecordUpdateAfterTarget(expr);
                continue;
            }
            if (source.startsWithAt(self.source, self.pos, "??")) {
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
        const body_start = self.pos;
        var fields = std.ArrayList(ast.RecordUpdateFieldExpr).empty;
        errdefer {
            for (fields.items) |*field| field.deinit(self.allocator);
            fields.deinit(self.allocator);
        }

        source.skipTriviaFrom(self.source, &self.pos);
        while (!self.eof() and !self.peekChar('}')) {
            const path_start = self.pos;
            var path = std.ArrayList(ast.RecordPathSegment).empty;
            errdefer {
                for (path.items) |*segment| segment.deinit(self.allocator);
                path.deinit(self.allocator);
            }
            try path.append(self.allocator, try self.parseRecordPathSegment());
            while (true) {
                source.skipInlineSpaces(self.source, &self.pos);
                if (self.eof() or self.source[self.pos] != '.') break;
                self.pos += 1;
                source.skipInlineSpaces(self.source, &self.pos);
                try path.append(self.allocator, try self.parseRecordPathSegment());
            }
            const path_span: ast.Span = .{ .start = path_start, .end = self.pos };
            source.skipInlineSpaces(self.source, &self.pos);
            const ParsedRecordUpdateValue = struct {
                expr: Expr,
                span: ast.Span,
            };
            const value: ParsedRecordUpdateValue = if (!self.eof() and self.source[self.pos] == '=') blk: {
                self.pos += 1;
                const value_start = self.pos;
                const parsed_value = try self.parseExpr();
                break :blk .{
                    .expr = parsed_value,
                    .span = ast.Span{ .start = value_start, .end = self.pos },
                };
            } else blk: {
                if (!self.recovering) return self.fail(error.ExpectedChar);
                const span = pointSpan(self.pos);
                _ = try self.addHole(.record_field_path, .record_field_path, span, error.ExpectedChar, foundAt(self.source, self.pos, source.lineAt(self.source, self.pos).span.end));
                break :blk .{
                    .expr = try self.makeHoleExpr(.expr, .expression, span, error.ExpectedExpression, foundAt(self.source, self.pos, source.lineAt(self.source, self.pos).span.end)),
                    .span = span,
                };
            };
            try fields.append(self.allocator, .{
                .path = path,
                .path_span = path_span,
                .value = value.expr,
                .value_span = value.span,
            });
            if (self.recovering and fields.items[fields.items.len - 1].value == .hole) {
                var close_probe = self.pos;
                source.skipTriviaFrom(self.source, &close_probe);
                if (close_probe >= self.source.len or self.source[close_probe] == '}') {
                    self.pos = close_probe;
                    break;
                }
                const before_recovery_skip = self.pos;
                source.skipTriviaFrom(self.source, &self.pos);
                if (!self.eof() and self.source[self.pos] == ',') {
                    self.pos += 1;
                    source.skipTriviaFrom(self.source, &self.pos);
                    continue;
                }
                if (self.pos != before_recovery_skip) continue;
                break;
            }
            source.skipTriviaFrom(self.source, &self.pos);
            if (!self.eof() and self.source[self.pos] == ',') {
                self.pos += 1;
                source.skipTriviaFrom(self.source, &self.pos);
                continue;
            }
        }
        const body_end = self.pos;
        if (self.eof() or !self.peekChar('}')) {
            if (!self.recovering) return self.fail(error.ExpectedChar);
        } else {
            try self.expectChar('}');
        }
        return .{ .record_update = .{
            .target = target,
            .fields = fields,
            .body_span = .{ .start = body_start, .end = body_end },
        } };
    }

    fn parseRecordPathSegment(self: *Parser) !ast.RecordPathSegment {
        if (!self.recovering or (!self.eof() and source.isIdentifierStart(self.source[self.pos]))) {
            const name = try self.parseIdentifierWithSpan();
            return .{ .name = name.text, .span = name.span };
        }
        const span = pointSpan(self.pos);
        const line = source.lineAt(self.source, self.pos);
        const id = try self.addHole(.record_field_path, .record_field_path, span, error.ExpectedIdentifier, foundAt(self.source, self.pos, line.span.end));
        return .{
            .name = try self.allocator.dupe(u8, ""),
            .span = span,
            .name_hole = id,
        };
    }

    fn parseApplyAfterCallee(self: *Parser, expr: Expr) !Expr {
        const callee = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(callee);
        callee.* = expr;
        var args = std.ArrayList(Expr).empty;
        var arg_spans = std.ArrayList(ast.Span).empty;
        errdefer {
            args.deinit(self.allocator);
            arg_spans.deinit(self.allocator);
        }
        try self.expectChar('(');
        source.skipInlineSpaces(self.source, &self.pos);
        while (!self.eof() and !self.peekChar(')')) {
            if (self.reject_empty_args and self.source[self.pos] == ',') {
                if (!self.recovering) return self.failAt(self.pos, error.ExpectedExpression);
                const span = pointSpan(self.pos);
                try args.append(self.allocator, try self.makeHoleExpr(.call_arg, .call_arg, span, error.ExpectedExpression, foundAt(self.source, self.pos, source.lineAt(self.source, self.pos).span.end)));
                try arg_spans.append(self.allocator, span);
                self.pos += 1;
                source.skipInlineSpaces(self.source, &self.pos);
                continue;
            }
            const arg_start = self.pos;
            try args.append(self.allocator, try self.parseExpr());
            try arg_spans.append(self.allocator, .{ .start = arg_start, .end = self.pos });
            source.skipInlineSpaces(self.source, &self.pos);
            if (!self.eof() and self.source[self.pos] == ',') {
                self.pos += 1;
                source.skipInlineSpaces(self.source, &self.pos);
                if (self.reject_empty_args and (self.eof() or self.source[self.pos] == ')')) {
                    if (!self.recovering) return self.failAt(self.pos, error.ExpectedExpression);
                    const span = pointSpan(self.pos);
                    try args.append(self.allocator, try self.makeHoleExpr(.call_arg, .call_arg, span, error.ExpectedExpression, foundAt(self.source, self.pos, source.lineAt(self.source, self.pos).span.end)));
                    try arg_spans.append(self.allocator, span);
                }
                continue;
            }
            break;
        }
        if (self.eof() or self.source[self.pos] != ')') {
            if (!self.recovering) return self.fail(error.ExpectedChar);
            return .{ .apply = .{ .callee = callee, .args = args, .arg_spans = arg_spans } };
        }
        self.pos += 1;
        return .{ .apply = .{ .callee = callee, .args = args, .arg_spans = arg_spans } };
    }

    fn parsePrimaryExpr(self: *Parser) anyerror!Expr {
        source.skipInlineSpaces(self.source, &self.pos);
        if (self.reject_empty_args) {
            if (self.eof()) {
                if (self.recovering) return try self.makeHoleExpr(.expr, .expression, pointSpan(self.pos), error.ExpectedExpression, "end of file");
                return self.fail(error.ExpectedExpression);
            }
            if (self.source[self.pos] == '\n' or self.source[self.pos] == ',' or self.source[self.pos] == ')' or self.source[self.pos] == '}') {
                if (self.recovering) return try self.makeHoleExpr(.expr, .expression, pointSpan(self.pos), error.ExpectedExpression, foundAt(self.source, self.pos, source.lineAt(self.source, self.pos).span.end));
                return self.fail(error.ExpectedExpression);
            }
            if (source.lineCommentMarkerLength(self.source, self.pos) != null) {
                if (self.recovering) return try self.makeHoleExpr(.expr, .expression, pointSpan(self.pos), error.ExpectedExpression, foundAt(self.source, self.pos, source.lineAt(self.source, self.pos).span.end));
                return self.fail(error.ExpectedExpression);
            }
        }
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
        if (!self.eof() and (self.source[self.pos] == '"' or source.startsWithAt(self.source, self.pos, "\"\"\""))) {
            return .{ .string = try self.parseStringLiteral() };
        }
        if (source.startsWithAt(self.source, self.pos, "<<")) {
            return .{ .string = try self.parseChevronBlockStringLiteral() };
        }
        if (self.startsNumberLiteral()) {
            return .{ .number = try self.parseNumber() };
        }
        const name = try self.parseCallableName();
        source.skipInlineSpaces(self.source, &self.pos);
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
        if (!self.eof() and self.source[self.pos] == '{') {
            return try self.parseRecordLiteralAfterName(try self.qualifiedNameText(name), name.span);
        }
        if (!self.eof() and self.source[self.pos] == '(') {
            return .{ .call = try self.parseCallAfterName(name) };
        }
        if (source.startsWithAt(self.source, self.pos, "<<")) {
            return .{ .call = try self.makeUnaryStringCall(name, try self.parseChevronBlockStringLiteral()) };
        }
        if (!self.eof() and (self.source[self.pos] == '"' or source.startsWithAt(self.source, self.pos, "\"\"\""))) {
            return .{ .call = try self.makeUnaryStringCall(name, try self.parseStringLiteral()) };
        }
        if (name.isQualified()) {
            if (!self.eof() and self.source[self.pos] == '.') return .{ .ident = .{ .name = try self.qualifiedNameText(name), .name_span = name.span } };
            return self.fail(error.ExpectedChar);
        }
        if (std.mem.endsWith(u8, name.name, "!")) return self.fail(error.ExpectedChar);
        if (!self.eof() and self.source[self.pos] != '(') {
            return .{ .ident = .{ .name = name.name, .name_span = name.name_span } };
        }
        return .{ .ident = .{ .name = name.name, .name_span = name.name_span } };
    }

    fn qualifiedNameText(self: *Parser, name: ast.CallableName) ![]const u8 {
        if (name.qualifier) |qualifier| {
            return try std.fmt.allocPrint(self.allocator, "{s}::{s}", .{ qualifier, name.name });
        }
        return name.name;
    }

    fn parseRecordLiteralAfterName(self: *Parser, type_name: []const u8, type_name_span: ?ast.Span) !Expr {
        try self.expectChar('{');
        var fields = std.ArrayList(ast.RecordFieldExpr).empty;
        errdefer {
            self.allocator.free(type_name);
            for (fields.items) |*field| field.deinit(self.allocator);
            fields.deinit(self.allocator);
        }
        source.skipTriviaFrom(self.source, &self.pos);
        while (!self.eof() and !self.peekChar('}')) {
            const field_name = try self.parseIdentifierWithSpan();
            source.skipInlineSpaces(self.source, &self.pos);
            try self.expectChar('=');
            const value = try self.parseExpr();
            try fields.append(self.allocator, .{
                .name = field_name.text,
                .name_span = field_name.span,
                .value = value,
            });
            source.skipTriviaFrom(self.source, &self.pos);
            if (!self.eof() and self.source[self.pos] == ',') {
                self.pos += 1;
                source.skipTriviaFrom(self.source, &self.pos);
                continue;
            }
        }
        try self.expectChar('}');
        return .{ .record = .{
            .type_name = type_name,
            .type_name_span = type_name_span,
            .fields = fields,
        } };
    }

    fn startsLambdaExpr(self: *Parser) bool {
        if (self.eof() or self.source[self.pos] != '(') return false;
        var probe = self.pos + 1;
        source.skipTriviaFrom(self.source, &probe);
        if (probe < self.source.len and self.source[probe] == ')') {
            probe += 1;
            source.skipTriviaFrom(self.source, &probe);
            return source.startsWithAt(self.source, probe, "|->");
        }
        if (!scanner.scanIdentifier(self.source, &probe)) return false;
        source.skipInlineSpaces(self.source, &probe);
        if (probe < self.source.len and self.source[probe] == ':') return true;

        var depth: usize = 1;
        while (probe < self.source.len) : (probe += 1) {
            switch (self.source[probe]) {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) {
                        probe += 1;
                        source.skipTriviaFrom(self.source, &probe);
                        return source.startsWithAt(self.source, probe, "|->");
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
        source.skipTriviaFrom(self.source, &self.pos);
        while (!self.eof() and !self.peekChar(')')) {
            const param_name = try self.parseIdentifierWithSpan();
            source.skipInlineSpaces(self.source, &self.pos);
            if (self.eof() or self.source[self.pos] != ':') return self.fail(error.ExpectedTypeAnnotation);
            self.pos += 1;
            source.skipInlineSpaces(self.source, &self.pos);
            const param_type = try self.parseTypeAnnotation();
            try params.append(self.allocator, .{
                .name = param_name.text,
                .name_span = param_name.span,
                .ty = param_type,
                .default_value = null,
            });
            source.skipTriviaFrom(self.source, &self.pos);
            if (!self.eof() and self.source[self.pos] == ',') {
                self.pos += 1;
                source.skipTriviaFrom(self.source, &self.pos);
                continue;
            }
            break;
        }
        try self.expectChar(')');
        source.skipTriviaFrom(self.source, &self.pos);
        if (!source.startsWithAt(self.source, self.pos, "|->")) return self.fail(error.ExpectedChar);
        self.pos += 3;
        source.skipTriviaFrom(self.source, &self.pos);
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
        var arg_spans = std.ArrayList(ast.Span).empty;
        errdefer {
            args.deinit(self.allocator);
            arg_spans.deinit(self.allocator);
        }

        source.skipTriviaFrom(self.source, &self.pos);
        while (!self.eof() and self.source[self.pos] != ')') {
            if (self.reject_empty_args and self.source[self.pos] == ',') {
                if (!self.recovering) return self.failAt(self.pos, error.ExpectedExpression);
                const span = pointSpan(self.pos);
                try args.append(self.allocator, try self.makeHoleExpr(.call_arg, .call_arg, span, error.ExpectedExpression, foundAt(self.source, self.pos, source.lineAt(self.source, self.pos).span.end)));
                try arg_spans.append(self.allocator, span);
                self.pos += 1;
                source.skipTriviaFrom(self.source, &self.pos);
                continue;
            }
            const arg_start = self.pos;
            try args.append(self.allocator, try self.parseExpr());
            try arg_spans.append(self.allocator, .{ .start = arg_start, .end = self.pos });
            source.skipTriviaFrom(self.source, &self.pos);
            if (!self.eof() and self.source[self.pos] == ',') {
                self.pos += 1;
                source.skipTriviaFrom(self.source, &self.pos);
                if (self.reject_empty_args and (self.eof() or self.source[self.pos] == ')')) {
                    if (!self.recovering) return self.failAt(self.pos, error.ExpectedExpression);
                    const span = pointSpan(self.pos);
                    try args.append(self.allocator, try self.makeHoleExpr(.call_arg, .call_arg, span, error.ExpectedExpression, foundAt(self.source, self.pos, source.lineAt(self.source, self.pos).span.end)));
                    try arg_spans.append(self.allocator, span);
                }
                continue;
            }
            break;
        }
        if (self.eof() or self.source[self.pos] != ')') {
            if (!self.recovering) return self.fail(error.ExpectedChar);
            return .{ .callee = name, .args = args, .arg_spans = arg_spans };
        }
        self.pos += 1;
        return .{ .callee = name, .args = args, .arg_spans = arg_spans };
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
            source.skipInlineSpaces(self.source, &self.pos);
            if (self.eof() or self.source[self.pos] != '.') {
                target.deinit(self.allocator);
                self.pos = saved;
                return null;
            }
            self.pos += 1;
            source.skipInlineSpaces(self.source, &self.pos);
            if (self.eof() or self.source[self.pos] == '\n' or source.lineCommentMarkerLength(self.source, self.pos) != null) {
                if (self.recovering) {
                    const span = pointSpan(self.pos);
                    const id = try self.addHole(.member_name, .member_name, span, error.ExpectedMemberName, foundAt(self.source, self.pos, source.lineAt(self.source, self.pos).span.end));
                    target = try self.makeMemberExpr(target, .{
                        .text = try self.allocator.dupe(u8, ""),
                        .span = span,
                    }, id);
                    try self.consumeStatementTerminator();
                    return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .expr_stmt = target } };
                }
                return self.failAt(self.pos, error.ExpectedMemberName);
            }
            const member_name = try self.parseIdentifierWithSpan();
            source.skipTriviaFrom(self.source, &self.pos);
            if (!self.eof() and self.source[self.pos] == '=' and (self.pos + 1 >= self.source.len or self.source[self.pos + 1] != '=')) {
                self.pos += 1;
                const value = try self.parseExpr();
                try self.consumeStatementTerminator();
                if (target == .ident) {
                    return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .property_set = .{
                        .object_name = target.ident.name,
                        .object_name_span = target.ident.name_span,
                        .property_name = member_name.text,
                        .property_name_span = member_name.span,
                        .value = value,
                    } } };
                }
                const call = if (std.mem.eql(u8, member_name.text, "content")) blk: {
                    self.allocator.free(member_name.text);
                    break :blk try self.makeCall2("set_content", target, value);
                } else try self.makeCall3("set_prop", target, .{ .string = .{ .text = member_name.text } }, value);
                return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .expr_stmt = .{ .call = call } } };
            }
            target = try self.makeMemberExpr(target, member_name, null);
        }
    }

    fn parseCallTargetExpr(self: *Parser) !Expr {
        var expr = try self.parsePrimaryExpr();
        errdefer expr.deinit(self.allocator);
        while (true) {
            source.skipInlineSpaces(self.source, &self.pos);
            if (self.eof() or self.source[self.pos] != '(') return expr;
            expr = try self.parseApplyAfterCallee(expr);
        }
    }

    fn parseMemberExprAfterTarget(self: *Parser, target: Expr) !Expr {
        try self.expectChar('.');
        const member_start = self.pos;
        source.skipInlineSpaces(self.source, &self.pos);
        if (self.eof() or self.source[self.pos] == '\n' or self.source[self.pos] == ',' or self.source[self.pos] == ')' or self.source[self.pos] == '}' or source.lineCommentMarkerLength(self.source, self.pos) != null) {
            if (self.recovering) {
                const span = pointSpan(member_start);
                const id = try self.addHole(.member_name, .member_name, span, error.ExpectedMemberName, foundAt(self.source, self.pos, source.lineAt(self.source, self.pos).span.end));
                return try self.makeMemberExpr(target, .{
                    .text = try self.allocator.dupe(u8, ""),
                    .span = span,
                }, id);
            }
            return self.failAt(self.pos, error.ExpectedMemberName);
        }
        const member_name = try self.parseIdentifierWithSpan();
        return try self.makeMemberExpr(target, member_name, null);
    }

    fn makeMemberExpr(self: *Parser, target: Expr, member_name: ParsedName, name_hole: ?ast.HoleId) !Expr {
        const target_ptr = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(target_ptr);
        target_ptr.* = target;
        return .{ .member = .{ .target = target_ptr, .name = member_name.text, .name_span = member_name.span, .name_hole = name_hole } };
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
        const source_anchor = try self.parseAnchorMemberRef();
        var offset: ?Expr = null;
        source.skipTriviaFrom(self.source, &self.pos);
        if (!self.eof() and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
            const sign = self.source[self.pos];
            self.pos += 1;
            var expr = try self.parseExpr();
            if (sign == '-') expr = try self.makeNegCall(expr);
            offset = expr;
        }
        return .{ .target = target_anchor, .source = source_anchor, .offset = offset };
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
        source.skipInlineSpaces(self.source, &self.pos);
        const path_start = self.pos;
        _ = try self.parseIdentifier();
        var member_name: []const u8 = "";
        var path_end: usize = path_start;
        while (true) {
            source.skipInlineSpaces(self.source, &self.pos);
            path_end = self.pos;
            try self.expectChar('.');
            member_name = try self.parseIdentifier();
            source.skipInlineSpaces(self.source, &self.pos);
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
        source.skipInlineSpaces(self.source, &self.pos);
        if (source.startsWithAt(self.source, self.pos, "<<")) return self.parseChevronBlockString();
        if (!self.eof() and (self.source[self.pos] == '"' or source.startsWithAt(self.source, self.pos, "\"\"\""))) {
            return self.parseString();
        }
        return self.parseLineText();
    }

    fn parseLineText(self: *Parser) ![]const u8 {
        const literal = try self.parseLineTextLiteral();
        return literal.text;
    }

    fn parseLineTextLiteral(self: *Parser) !ast.StringLiteral {
        source.skipInlineSpaces(self.source, &self.pos);
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
        source.skipInlineSpaces(self.source, &self.pos);
        if (!source.startsWithAt(self.source, self.pos, "<<")) return self.fail(error.ExpectedString);
        self.pos += 2;
        source.skipInlineSpaces(self.source, &self.pos);
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
        const line_span = source.lineAt(self.source, self.pos).span;
        var probe = line_span.start;
        while (probe < self.source.len and source.isInlineSpace(self.source[probe])) probe += 1;
        if (probe + 2 > self.source.len) return false;
        if (!std.mem.eql(u8, self.source[probe .. probe + 2], ">>")) return false;
        probe += 2;
        while (probe < self.source.len and source.isInlineSpace(self.source[probe])) probe += 1;
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
        const line = source.lineAt(self.source, self.pos);
        self.pos = if (line.raw_end < self.source.len) line.raw_end + 1 else line.raw_end;
    }

    fn parseNumber(self: *Parser) !f32 {
        source.skipTriviaFrom(self.source, &self.pos);
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
        source.skipTriviaFrom(self.source, &self.pos);
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
        source.skipTriviaFrom(self.source, &self.pos);
        if (source.startsWithAt(self.source, self.pos, "\"\"\"")) {
            self.pos += 3;
            const start = self.pos;
            while (!self.eof() and !source.startsWithAt(self.source, self.pos, "\"\"\"")) {
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

    const NameKind = enum {
        identifier,
        callable,
    };

    const ParsedName = struct {
        text: []const u8,
        span: ast.Span,
    };

    fn parseIdentifier(self: *Parser) ![]const u8 {
        return (try self.parseIdentifierWithSpan()).text;
    }

    fn parseIdentifierWithSpan(self: *Parser) !ParsedName {
        return self.parseNameWithSpan(.identifier);
    }

    fn parseCallableDeclName(self: *Parser) ![]const u8 {
        return (try self.parseCallableDeclNameWithSpan()).text;
    }

    fn parseCallableDeclNameWithSpan(self: *Parser) !ParsedName {
        return self.parseNameWithSpan(.callable);
    }

    fn parseCallableName(self: *Parser) !ast.CallableName {
        source.skipTriviaFrom(self.source, &self.pos);
        const first_start = self.pos;
        const first = try self.parseName(.identifier);
        errdefer self.allocator.free(first);
        const first_span: ast.Span = .{ .start = first_start, .end = self.pos };
        if (source.startsWithAt(self.source, self.pos, "::")) {
            self.pos += 2;
            source.skipTriviaFrom(self.source, &self.pos);
            const name_start = self.pos;
            if (self.recovering and (self.eof() or !source.isIdentifierStart(self.source[self.pos]))) {
                const line = source.lineAt(self.source, name_start);
                const hole_id = try self.addHole(.name, .name, pointSpan(name_start), error.ExpectedIdentifier, foundAt(self.source, name_start, line.span.end));
                return .{
                    .qualifier = first,
                    .name = "",
                    .name_hole = hole_id,
                    .qualifier_span = first_span,
                    .name_span = pointSpan(name_start),
                    .span = .{ .start = first_span.start, .end = name_start },
                };
            }
            const name = try self.parseName(.callable);
            return .{
                .qualifier = first,
                .name = name,
                .qualifier_span = first_span,
                .name_span = .{ .start = name_start, .end = self.pos },
                .span = .{ .start = first_span.start, .end = self.pos },
            };
        }
        if (!self.eof() and self.source[self.pos] == '!') {
            self.pos += 1;
            const name = try std.fmt.allocPrint(self.allocator, "{s}!", .{first});
            self.allocator.free(first);
            return .{
                .name = name,
                .name_span = .{ .start = first_span.start, .end = self.pos },
                .span = .{ .start = first_span.start, .end = self.pos },
            };
        }
        return .{
            .name = first,
            .name_span = first_span,
            .span = first_span,
        };
    }

    fn parseName(self: *Parser, kind: NameKind) ![]const u8 {
        return (try self.parseNameWithSpan(kind)).text;
    }

    fn parseNameWithSpan(self: *Parser, kind: NameKind) !ParsedName {
        source.skipTriviaFrom(self.source, &self.pos);
        if (self.eof()) return self.fail(error.ExpectedIdentifier);
        const start = self.pos;
        if (!source.isIdentifierStart(self.source[self.pos])) return self.fail(error.ExpectedIdentifier);
        self.pos += 1;
        while (!self.eof() and source.isIdentifierContinue(self.source[self.pos])) {
            self.pos += 1;
        }
        const ident_end = self.pos;
        if (kind == .callable and !self.eof() and self.source[self.pos] == '!') {
            self.pos += 1;
        }
        const base = self.source[start..ident_end];
        const ident = self.source[start..self.pos];
        if (isReservedKeyword(base)) return self.fail(error.ReservedIdentifier);
        return .{
            .text = try self.allocator.dupe(u8, ident),
            .span = .{ .start = start, .end = self.pos },
        };
    }

    fn isValidIdentifier(ident: []const u8) bool {
        if (ident.len == 0 or !source.isIdentifierStart(ident[0])) return false;
        for (ident[1..]) |ch| {
            if (!source.isIdentifierContinue(ch)) return false;
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
        source.skipTriviaFrom(self.source, &self.pos);
        return self.consumeKeywordNoTrivia(keyword);
    }

    fn consumeKeywordNoTrivia(self: *Parser, keyword: []const u8) bool {
        return scanner.consumeKeywordNoTrivia(self.source, &self.pos, keyword);
    }

    fn consumePairedFunctionMarker(self: *Parser) bool {
        if (!source.startsWithAt(self.source, self.pos, "/!")) return false;
        self.pos += 2;
        return true;
    }

    fn expectChar(self: *Parser, ch: u8) !void {
        source.skipTriviaFrom(self.source, &self.pos);
        if (self.eof() or self.source[self.pos] != ch) return self.fail(error.ExpectedChar);
        self.pos += 1;
    }

    fn expectEqualityOperator(self: *Parser) !void {
        source.skipTriviaFrom(self.source, &self.pos);
        if (source.startsWithAt(self.source, self.pos, "==")) {
            self.pos += 2;
            return;
        }
        return self.fail(error.ExpectedEqualityOperator);
    }

    fn consumeConstraintMarker(self: *Parser) bool {
        source.skipInlineSpaces(self.source, &self.pos);
        if (self.eof() or self.source[self.pos] != '~') return false;
        self.pos += 1;
        return true;
    }

    fn expectLineBreakAfterHeader(self: *Parser) !void {
        source.skipInlineSpaces(self.source, &self.pos);
        if (source.lineCommentMarkerLength(self.source, self.pos) != null) source.skipLineComment(self.source, &self.pos);
        try self.expectLineBreak();
    }

    fn expectLineBreak(self: *Parser) !void {
        if (self.eof()) return;
        if (self.source[self.pos] != '\n') return self.fail(error.ExpectedLineBreak);
        self.pos += 1;
    }

    fn consumeStatementTerminator(self: *Parser) !void {
        source.skipInlineSpaces(self.source, &self.pos);
        if (source.lineCommentMarkerLength(self.source, self.pos) != null) {
            source.skipLineComment(self.source, &self.pos);
            return;
        }
        if (!self.eof() and self.source[self.pos] == ';') {
            self.pos += 1;
            source.skipInlineSpaces(self.source, &self.pos);
        }
        if (source.lineCommentMarkerLength(self.source, self.pos) != null) source.skipLineComment(self.source, &self.pos);
    }

    fn atStatementBoundary(self: *Parser) bool {
        return scanner.atStatementBoundary(self.source, self.pos);
    }

    fn peekAnchorAssignment(self: *Parser) bool {
        var probe = self.pos;
        source.skipTriviaFrom(self.source, &probe);
        if (!scanner.scanIdentifier(self.source, &probe)) return false;
        while (probe < self.source.len and source.isInlineSpace(self.source[probe])) probe += 1;
        if (probe >= self.source.len or self.source[probe] != '.') return false;
        probe += 1;
        while (probe < self.source.len and source.isInlineSpace(self.source[probe])) probe += 1;
        const member_start = probe;
        if (!scanner.scanIdentifier(self.source, &probe)) return false;
        const member_name = self.source[member_start..probe];
        if (names.parseAnchorName(member_name) == null and
            !std.mem.eql(u8, member_name, "width") and
            !std.mem.eql(u8, member_name, "height")) return false;
        while (probe < self.source.len and source.isInlineSpace(self.source[probe])) probe += 1;
        return source.startsWithAt(self.source, probe, "==");
    }

    fn peekPropertyAssignment(self: *Parser) bool {
        var probe = self.pos;
        source.skipTriviaFrom(self.source, &probe);
        if (!scanner.scanIdentifier(self.source, &probe)) return false;
        while (probe < self.source.len and source.isInlineSpace(self.source[probe])) probe += 1;
        if (probe >= self.source.len or self.source[probe] != '.') return false;
        probe += 1;
        while (probe < self.source.len and source.isInlineSpace(self.source[probe])) probe += 1;
        if (!scanner.scanIdentifier(self.source, &probe)) return false;
        source.skipTriviaFrom(self.source, &probe);
        if (probe >= self.source.len or self.source[probe] != '=') return false;
        if (probe + 1 < self.source.len and self.source[probe + 1] == '=') return false;
        return true;
    }

    fn peekSimpleAssignment(self: *Parser) bool {
        var probe = self.pos;
        source.skipTriviaFrom(self.source, &probe);
        if (!scanner.scanIdentifier(self.source, &probe)) return false;
        while (probe < self.source.len and source.isInlineSpace(self.source[probe])) probe += 1;
        if (probe >= self.source.len or self.source[probe] != '=') return false;
        if (probe + 1 < self.source.len and self.source[probe + 1] == '=') return false;
        return true;
    }

    fn peekStandaloneKeyword(self: *Parser, keyword: []const u8) bool {
        var probe = self.pos;
        source.skipTriviaFrom(self.source, &probe);
        if (probe + keyword.len > self.source.len) return false;
        if (!std.mem.eql(u8, self.source[probe .. probe + keyword.len], keyword)) return false;
        const end = probe + keyword.len;
        if (end < self.source.len and source.isIdentifierContinue(self.source[end])) return false;
        probe = end;
        while (probe < self.source.len and source.isInlineSpace(self.source[probe])) probe += 1;
        return probe == self.source.len or self.source[probe] == '\n';
    }

    fn consumeStandaloneKeyword(self: *Parser, keyword: []const u8) !void {
        source.skipTriviaFrom(self.source, &self.pos);
        if (!self.consumeKeywordNoTrivia(keyword)) return self.fail(error.ExpectedKeyword);
        source.skipInlineSpaces(self.source, &self.pos);
        if (source.lineCommentMarkerLength(self.source, self.pos) != null) source.skipLineComment(self.source, &self.pos);
        if (!self.eof() and self.source[self.pos] == '\n') self.pos += 1;
    }

    fn peekChar(self: *Parser, ch: u8) bool {
        source.skipTriviaFrom(self.source, &self.pos);
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

fn standaloneKeywordAt(text: []const u8, pos: usize, keyword: []const u8) bool {
    if (pos + keyword.len > text.len) return false;
    if (pos > 0 and source.isIdentifierContinue(text[pos - 1])) return false;
    if (!std.mem.eql(u8, text[pos .. pos + keyword.len], keyword)) return false;
    const after = pos + keyword.len;
    return after >= text.len or !source.isIdentifierContinue(text[after]);
}

fn previousSignificantByte(text: []const u8, pos: usize, lower_bound: usize) ?u8 {
    var cursor = @min(pos, text.len);
    while (cursor > lower_bound) {
        cursor -= 1;
        if (source.isInlineSpace(text[cursor])) continue;
        return text[cursor];
    }
    return null;
}

fn isCallArgumentHole(text: []const u8, pos: usize, lower_bound: usize) bool {
    const previous = previousSignificantByte(text, pos, lower_bound) orelse return false;
    if (previous == '(' or previous == ',') return true;
    if (pos < text.len and (text[pos] == ',' or text[pos] == ')')) return true;
    return false;
}

fn isTypeAnnotationBoundary(text: []const u8, pos: usize) bool {
    if (pos >= text.len) return true;
    if (source.lineCommentMarkerLength(text, pos) != null) return true;
    return switch (text[pos]) {
        '\n', ',', ')', '}', '>', '=' => true,
        else => standaloneKeywordAt(text, pos, "end") or standaloneKeywordAt(text, pos, "else"),
    };
}

fn foundAt(text: []const u8, pos: usize, line_end: usize) []const u8 {
    if (pos >= line_end or pos >= text.len or text[pos] == '\n') return "line break";
    return diagnostics.foundToken(text, pos);
}

fn pointSpan(pos: usize) ast.Span {
    return .{ .start = pos, .end = pos };
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
    while (end > 0 and source.isInlineSpace(raw[end - 1])) end -= 1;
    return raw[0..end];
}

fn trimLeftSpaces(raw: []const u8) []const u8 {
    var start: usize = 0;
    while (start < raw.len and source.isInlineSpace(raw[start])) start += 1;
    return raw[start..];
}
