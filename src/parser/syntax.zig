const std = @import("std");
const ast = @import("ast.zig");
const names = @import("names.zig");

const Allocator = std.mem.Allocator;
const Program = ast.Program;
const FunctionDecl = ast.FunctionDecl;
const PageDecl = ast.PageDecl;
const Statement = ast.Statement;
const Expr = ast.Expr;
const ConstraintDecl = ast.ConstraintDecl;
const AnchorRef = ast.AnchorRef;

pub fn parse(allocator: Allocator, source: []const u8) !Program {
    var parser = Parser{
        .allocator = allocator,
        .source = source,
        .pos = 0,
    };
    return parser.parseProgram();
}

const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    pos: usize,

    fn parseProgram(self: *Parser) !Program {
        var program = Program.init();
        errdefer program.deinit(self.allocator);

        self.skipTrivia();
        while (!self.eof()) {
            if (try self.consumeKeyword("theme")) {
                program.theme_name = try self.parsePageName();
                try self.consumeStatementTerminator();
            } else if (try self.consumeKeyword("fn")) {
                const func = try self.parseFunctionAfterKeyword();
                try program.functions.append(self.allocator, func);
            } else {
                const page = try self.parsePage();
                try program.pages.append(self.allocator, page);
            }
            self.skipTrivia();
        }
        return program;
    }

    fn parseFunctionAfterKeyword(self: *Parser) !FunctionDecl {
        const name = try self.parseIdentifier();
        self.skipInlineSpaces();
        try self.expectChar('(');

        var params = std.ArrayList([]const u8).empty;
        errdefer params.deinit(self.allocator);
        self.skipTrivia();
        while (!self.eof() and !self.peekChar(')')) {
            try params.append(self.allocator, try self.parseIdentifier());
            self.skipTrivia();
            if (!self.eof() and self.source[self.pos] == ',') {
                self.pos += 1;
                self.skipTrivia();
                continue;
            }
            break;
        }
        try self.expectChar(')');

        const statements = try self.parseBodyStatements();
        return .{ .name = name, .params = params, .statements = statements };
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
        if (start == self.pos) return error.ExpectedString;
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
        return error.ExpectedEnd;
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
        self.skipTrivia();
        if (!self.eof() and (self.source[self.pos] == '"' or self.startsWith("\"\"\""))) {
            return .{ .string = try self.parseString() };
        }
        if (self.startsWith("<<")) {
            return .{ .string = try self.parseChevronBlockString() };
        }
        if (self.startsNumberLiteral()) {
            return .{ .number = try self.parseSignedNumber() };
        }
        const name = try self.parseIdentifier();
        self.skipInlineSpaces();
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
        if (self.eof() or self.source[self.pos] != ')') return error.ExpectedChar;
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
        try self.expectChar('=');
        const source = try self.parseAnchorRef();
        var offset: f32 = 0;
        self.skipTrivia();
        if (!self.eof() and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
            const sign: f32 = if (self.source[self.pos] == '-') -1 else 1;
            self.pos += 1;
            self.skipTrivia();
            const magnitude = try self.parseNumber();
            offset = sign * magnitude;
        }
        return .{ .target = target, .source = source, .offset = offset };
    }

    fn parseAnchorRef(self: *Parser) !AnchorRef {
        const name = try self.parseIdentifier();
        const anchor = names.parseAnchorName(name) orelse return error.UnknownAnchor;
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
        if (!self.startsWith("<<")) return error.ExpectedString;
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
        return error.UnterminatedString;
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
        if (start == self.pos) return error.ExpectedNumber;
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
        if (std.ascii.isDigit(ch)) return true;
        if (ch != '-') return false;
        if (self.pos + 1 >= self.source.len) return false;
        return std.ascii.isDigit(self.source[self.pos + 1]);
    }

    fn parseString(self: *Parser) ![]const u8 {
        self.skipTrivia();
        if (self.startsWith("\"\"\"")) {
            self.pos += 3;
            const start = self.pos;
            while (!self.eof() and !self.startsWith("\"\"\"")) {
                self.pos += 1;
            }
            if (self.eof()) return error.UnterminatedString;
            const raw = self.source[start..self.pos];
            self.pos += 3;
            return self.allocator.dupe(u8, normalizeBlockString(raw));
        }

        if (self.eof() or self.source[self.pos] != '"') return error.ExpectedString;
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
                if (self.eof()) return error.UnterminatedEscape;
                const esc = self.source[self.pos];
                self.pos += 1;
                switch (esc) {
                    'n' => try out.append(self.allocator, '\n'),
                    'r' => try out.append(self.allocator, '\r'),
                    't' => try out.append(self.allocator, '\t'),
                    '\\' => try out.append(self.allocator, '\\'),
                    '"' => try out.append(self.allocator, '"'),
                    else => return error.InvalidEscape,
                }
            } else {
                try out.append(self.allocator, ch);
            }
        }
        return error.UnterminatedString;
    }

    fn parseIdentifier(self: *Parser) ![]const u8 {
        self.skipTrivia();
        if (self.eof()) return error.ExpectedIdentifier;
        const start = self.pos;
        if (!isIdentifierStart(self.source[self.pos])) return error.ExpectedIdentifier;
        self.pos += 1;
        while (!self.eof() and isIdentifierContinue(self.source[self.pos])) {
            self.pos += 1;
        }
        return self.allocator.dupe(u8, self.source[start..self.pos]);
    }

    fn expectKeyword(self: *Parser, keyword: []const u8) !void {
        if (!try self.consumeKeyword(keyword)) return error.ExpectedKeyword;
    }

    fn consumeKeyword(self: *Parser, keyword: []const u8) !bool {
        self.skipTrivia();
        return self.consumeKeywordNoTrivia(keyword);
    }

    fn consumeKeywordNoTrivia(self: *Parser, keyword: []const u8) bool {
        if (!self.startsWith(keyword)) return false;
        const end = self.pos + keyword.len;
        if (end < self.source.len and isIdentifierContinue(self.source[end])) return false;
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
        if (self.eof() or self.source[self.pos] != ch) return error.ExpectedChar;
        self.pos += 1;
    }

    fn expectLineBreakAfterHeader(self: *Parser) !void {
        self.skipInlineSpaces();
        if (self.lineCommentStart()) self.skipLineComment();
        try self.expectLineBreak();
    }

    fn expectLineBreak(self: *Parser) !void {
        if (self.eof()) return;
        if (self.source[self.pos] != '\n') return error.ExpectedLineBreak;
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

    fn peekStandaloneKeyword(self: *Parser, keyword: []const u8) bool {
        var probe = self.pos;
        skipTriviaFrom(self.source, &probe);
        if (probe + keyword.len > self.source.len) return false;
        if (!std.mem.eql(u8, self.source[probe .. probe + keyword.len], keyword)) return false;
        const end = probe + keyword.len;
        if (end < self.source.len and isIdentifierContinue(self.source[end])) return false;
        probe = end;
        while (probe < self.source.len and isInlineSpace(self.source[probe])) probe += 1;
        return probe == self.source.len or self.source[probe] == '\n';
    }

    fn consumeStandaloneKeyword(self: *Parser, keyword: []const u8) !void {
        self.skipTrivia();
        if (!self.consumeKeywordNoTrivia(keyword)) return error.ExpectedKeyword;
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
};

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

fn skipTriviaFrom(source: []const u8, pos: *usize) void {
    while (pos.* < source.len) {
        switch (source[pos.*]) {
            ' ', '\t', '\r', '\n' => pos.* += 1,
            '/' => {
                if (pos.* + 1 < source.len and source[pos.* + 1] == '/') {
                    pos.* += 2;
                    while (pos.* < source.len and source[pos.*] != '\n') pos.* += 1;
                } else {
                    return;
                }
            },
            ';' => {
                if (pos.* + 1 < source.len and source[pos.* + 1] == ';') {
                    pos.* += 2;
                    while (pos.* < source.len and source[pos.*] != '\n') pos.* += 1;
                } else {
                    return;
                }
            },
            '#' => {
                while (pos.* < source.len and source[pos.*] != '\n') pos.* += 1;
            },
            else => return,
        }
    }
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentifierContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
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
