const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const names = @import("names.zig");
const typecheck = @import("typecheck.zig");
const source_utils = @import("utils").source;

const Allocator = std.mem.Allocator;
const Program = ast.Program;
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
            if (try self.consumeKeyword("theme")) {
                program.theme_name = try self.parsePageName();
                try self.consumeStatementTerminator();
            } else if (try self.consumeKeyword("fn")) {
                const func = try self.parseFunctionAfterKeyword(item_start);
                try program.functions.append(self.allocator, func);
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
            const param_sort = try self.parseSortAnnotation();
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
        const result_sort = try self.parseSortAnnotation();

        const statements = try self.parseBodyStatements();
        if (!typecheck.functionBodyReturns(statements.items)) return self.fail(error.ExpectedReturn);
        return .{ .name = name, .span = .{ .start = start, .end = self.pos }, .params = params, .result_sort = result_sort, .statements = statements };
    }

    fn parseSortAnnotation(self: *Parser) !core.SemanticSort {
        const name = try self.parseIdentifier();
        if (std.mem.eql(u8, name, "document")) return .document;
        if (std.mem.eql(u8, name, "page")) return .page;
        if (std.mem.eql(u8, name, "object")) return .object;
        if (std.mem.eql(u8, name, "selection")) return .selection;
        if (std.mem.eql(u8, name, "anchor")) return .anchor;
        if (std.mem.eql(u8, name, "function")) return .function;
        if (std.mem.eql(u8, name, "style")) return .style;
        if (std.mem.eql(u8, name, "string")) return .string;
        if (std.mem.eql(u8, name, "number")) return .number;
        if (std.mem.eql(u8, name, "constraints")) return .constraints;
        if (std.mem.eql(u8, name, "fragment")) return .fragment;
        return self.fail(error.InvalidSemanticSort);
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

        if (try self.parseLegacyStatement(start)) |stmt| return stmt;
        return try self.parseCallSugarStatement(start);
    }

    fn parseLegacyStatement(self: *Parser, start: usize) !?Statement {
        const string_heads = [_]struct {
            name: []const u8,
            build: fn ([]const u8) Statement.Kind,
        }{
            .{ .name = "title", .build = legacyTitleKind },
            .{ .name = "subtitle", .build = legacySubtitleKind },
            .{ .name = "math", .build = legacyMathKind },
            .{ .name = "mathtex", .build = legacyMathTexKind },
            .{ .name = "figure", .build = legacyFigureKind },
            .{ .name = "image", .build = legacyImageKind },
            .{ .name = "pdf", .build = legacyPdfKind },
            .{ .name = "code", .build = legacyCodeKind },
            .{ .name = "highlight", .build = legacyHighlightKind },
        };

        inline for (string_heads) |entry| {
            if (try self.consumeLegacyStringHead(entry.name)) {
                const text = try self.parseTextArg();
                try self.consumeStatementTerminator();
                return .{ .span = .{ .start = start, .end = self.pos }, .kind = entry.build(text) };
            }
        }

        if (try self.consumeLegacyZeroHead("page_number")) {
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .page_number = {} } };
        }
        if (try self.consumeLegacyZeroHead("toc")) {
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .toc = {} } };
        }

        return null;
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

        if (self.atStatementBoundary()) {
            const call = try self.makeZeroArgCall(name);
            try self.consumeStatementTerminator();
            return .{ .span = .{ .start = start, .end = self.pos }, .kind = .{ .expr_stmt = .{ .call = call } } };
        }

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

    fn makeZeroArgCall(self: *Parser, name: []const u8) !ast.CallExpr {
        _ = self;
        return .{ .name = name, .args = std.ArrayList(Expr).empty };
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

    fn consumeLegacyStringHead(self: *Parser, keyword: []const u8) !bool {
        const checkpoint = self.pos;
        if (!try self.consumeKeyword(keyword)) return false;
        self.skipInlineSpaces();
        if (!self.eof() and self.source[self.pos] == '(') {
            self.pos = checkpoint;
            return false;
        }
        return true;
    }

    fn consumeLegacyZeroHead(self: *Parser, keyword: []const u8) !bool {
        const checkpoint = self.pos;
        if (!try self.consumeKeyword(keyword)) return false;
        if (!self.atStatementBoundary()) {
            self.pos = checkpoint;
            return false;
        }
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
        error.UnknownAnchor => "known anchor name",
        error.InvalidSemanticSort => "semantic sort",
        error.ExpectedTypeAnnotation => "type annotation",
        error.RequiredParameterAfterDefault => "defaulted parameters must trail required parameters",
        error.ExpectedReturn => "return statement",
        error.ExpectedEqualityOperator => "'=='",
        else => null,
    };
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

fn legacyTitleKind(text: []const u8) Statement.Kind {
    return .{ .title = text };
}

fn legacySubtitleKind(text: []const u8) Statement.Kind {
    return .{ .subtitle = text };
}

fn legacyMathKind(text: []const u8) Statement.Kind {
    return .{ .math = text };
}

fn legacyMathTexKind(text: []const u8) Statement.Kind {
    return .{ .mathtex = text };
}

fn legacyFigureKind(text: []const u8) Statement.Kind {
    return .{ .figure = text };
}

fn legacyImageKind(text: []const u8) Statement.Kind {
    return .{ .image = text };
}

fn legacyPdfKind(text: []const u8) Statement.Kind {
    return .{ .pdf_ref = text };
}

fn legacyCodeKind(text: []const u8) Statement.Kind {
    return .{ .code = text };
}

fn legacyHighlightKind(text: []const u8) Statement.Kind {
    return .{ .highlight = text };
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
