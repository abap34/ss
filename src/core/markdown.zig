const std = @import("std");
const class_fields = @import("class_fields.zig");

const c = @cImport({
    @cInclude("md4c.h");
});

const Allocator = std.mem.Allocator;

pub const ParseMode = enum {
    none,
    inline_text,
    block,
};

pub const RunKind = enum {
    text,
    bold,
    italic,
    code,
    link,
    math,
    display_math,
    icon,
};

pub const Run = struct {
    kind: RunKind,
    text: []const u8,
    url: ?[]const u8 = null,
    icon: ?[]const u8 = null,
};

pub const Line = struct {
    runs: std.ArrayList(Run) = .empty,
};

pub const TextLayout = struct {
    lines: std.ArrayList(Line) = .empty,

    pub fn deinit(self: *TextLayout, allocator: Allocator) void {
        for (self.lines.items) |*line| {
            line.runs.deinit(allocator);
        }
        self.lines.deinit(allocator);
    }
};

pub const BlockKind = enum {
    paragraph,
    code_block,
    bullet_list,
    ordered_list,
    table,
};

pub const Paragraph = struct {
    lines: std.ArrayList(Line) = .empty,
};

pub const ListItem = struct {
    blocks: std.ArrayList(*Block) = .empty,
};

pub const ListData = struct {
    start: usize = 1,
    items: std.ArrayList(*ListItem) = .empty,
};

pub const Align = enum {
    default,
    left,
    center,
    right,
};

pub const TableCell = struct {
    alignment: Align = .default,
    lines: std.ArrayList(Line) = .empty,
};

pub const TableRow = struct {
    header: bool = false,
    cells: std.ArrayList(*TableCell) = .empty,
};

pub const TableData = struct {
    columns: usize = 0,
    rows: std.ArrayList(*TableRow) = .empty,
};

pub const Block = struct {
    kind: BlockKind,
    paragraph: ?Paragraph = null,
    list: ?ListData = null,
    table: ?TableData = null,
    language: ?[]const u8 = null,
};

pub const MarkdownDocument = struct {
    arena: std.heap.ArenaAllocator,
    blocks: std.ArrayList(*Block) = .empty,

    pub fn init(backing_allocator: Allocator) MarkdownDocument {
        const arena = std.heap.ArenaAllocator.init(backing_allocator);
        return .{
            .arena = arena,
            .blocks = .empty,
        };
    }

    pub fn allocator(self: *MarkdownDocument) Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *MarkdownDocument) void {
        self.arena.deinit();
    }
};

const ParserState = struct {
    temp_allocator: Allocator,
    doc: *MarkdownDocument,
    containers: std.ArrayList(*std.ArrayList(*Block)),
    lists: std.ArrayList(*ListData),
    current_paragraph: ?*Paragraph = null,
    current_table: ?*TableData = null,
    current_row: ?*TableRow = null,
    current_cell: ?*TableCell = null,
    current_table_header: bool = false,
    current_line: Line = .{},
    strong_depth: usize = 0,
    italic_depth: usize = 0,
    code_depth: usize = 0,
    math_depth: usize = 0,
    display_math_depth: usize = 0,
    link_url: ?[]const u8 = null,
    image: ?ImageState = null,

    fn arenaAllocator(self: *ParserState) Allocator {
        return self.doc.allocator();
    }

    fn currentContainer(self: *ParserState) *std.ArrayList(*Block) {
        return self.containers.items[self.containers.items.len - 1];
    }

    fn appendBlock(self: *ParserState, block: *Block) !void {
        try self.currentContainer().append(self.arenaAllocator(), block);
    }

    fn newBlock(self: *ParserState, kind: BlockKind) !*Block {
        const arena = self.arenaAllocator();
        const block = try arena.create(Block);
        block.* = .{ .kind = kind };
        switch (kind) {
            .paragraph => block.paragraph = .{},
            .code_block => block.paragraph = .{},
            .bullet_list => block.list = .{ .start = 1 },
            .ordered_list => block.list = .{ .start = 1 },
            .table => block.table = .{},
        }
        return block;
    }

    fn newListItem(self: *ParserState) !*ListItem {
        const arena = self.arenaAllocator();
        const item = try arena.create(ListItem);
        item.* = .{};
        return item;
    }

    fn newTableRow(self: *ParserState, header: bool) !*TableRow {
        const arena = self.arenaAllocator();
        const row = try arena.create(TableRow);
        row.* = .{ .header = header };
        return row;
    }

    fn newTableCell(self: *ParserState, alignment: Align) !*TableCell {
        const arena = self.arenaAllocator();
        const cell = try arena.create(TableCell);
        cell.* = .{ .alignment = alignment };
        return cell;
    }

    fn startParagraph(self: *ParserState) !void {
        if (self.current_paragraph != null) return;
        const block = try self.newBlock(.paragraph);
        try self.appendBlock(block);
        self.current_paragraph = &block.paragraph.?;
        self.current_line = .{};
    }

    fn ensureParagraph(self: *ParserState) !void {
        if (self.current_paragraph == null) try self.startParagraph();
    }

    fn flushCurrentLine(self: *ParserState, force_empty: bool) !void {
        const paragraph = self.current_paragraph orelse return;
        const has_runs = self.current_line.runs.items.len > 0;
        const should_append = has_runs or force_empty or paragraph.lines.items.len == 0;
        if (!should_append) return;
        try paragraph.lines.append(self.arenaAllocator(), self.current_line);
        self.current_line = .{};
    }

    fn endParagraph(self: *ParserState) !void {
        if (self.current_paragraph == null) return;
        try self.flushCurrentLine(true);
        self.current_paragraph = null;
    }

    fn flushCurrentTableLine(self: *ParserState, force_empty: bool) !void {
        const cell = self.current_cell orelse return;
        const has_runs = self.current_line.runs.items.len > 0;
        const should_append = has_runs or force_empty or cell.lines.items.len == 0;
        if (!should_append) return;
        try cell.lines.append(self.arenaAllocator(), self.current_line);
        self.current_line = .{};
    }

    fn endTableCell(self: *ParserState) !void {
        if (self.current_cell == null) return;
        try self.flushCurrentTableLine(true);
        self.current_cell = null;
    }
};

const ImageState = struct {
    src: []const u8,
};

pub fn parseModeForNode(ir: anytype, node: anytype) ParseMode {
    if (class_fields.property(ir, node, "text_parse")) |mode| {
        if (std.mem.eql(u8, mode, "none")) return .none;
        if (std.mem.eql(u8, mode, "block")) return .block;
        if (std.mem.eql(u8, mode, "inline")) return .inline_text;
    }
    return .inline_text;
}

pub fn shouldParseInlineNode(ir: anytype, node: anytype) bool {
    return parseModeForNode(ir, node) != .none;
}

pub fn shouldParseBlocksNode(ir: anytype, node: anytype) bool {
    return parseModeForNode(ir, node) == .block;
}

pub fn parseMarkdownDocumentForNode(
    allocator: Allocator,
    ir: anytype,
    node: anytype,
    content: []const u8,
) !MarkdownDocument {
    if (!shouldParseBlocksNode(ir, node)) {
        return MarkdownDocument.init(allocator);
    }
    return parseMarkdownContent(allocator, content);
}

fn parseMarkdownContent(
    allocator: Allocator,
    content: []const u8,
) !MarkdownDocument {
    var doc = MarkdownDocument.init(allocator);
    errdefer doc.deinit();

    var state = ParserState{
        .temp_allocator = allocator,
        .doc = &doc,
        .containers = .empty,
        .lists = .empty,
    };
    defer {
        state.containers.deinit(allocator);
        state.lists.deinit(allocator);
    }

    try state.containers.append(allocator, &doc.blocks);

    var parser = std.mem.zeroes(c.MD_PARSER);
    parser.abi_version = 0;
    parser.flags = c.MD_DIALECT_GITHUB | c.MD_FLAG_LATEXMATHSPANS;
    parser.enter_block = enterBlock;
    parser.leave_block = leaveBlock;
    parser.enter_span = enterSpan;
    parser.leave_span = leaveSpan;
    parser.text = textCallback;

    const result = c.md_parse(@ptrCast(content.ptr), @intCast(content.len), &parser, &state);
    if (state.link_url) |url| state.arenaAllocator().free(url);
    if (result != 0) return error.MarkdownParseFailed;
    return doc;
}

pub fn parseTextLayoutForNode(
    allocator: Allocator,
    ir: anytype,
    node: anytype,
    content: []const u8,
) !TextLayout {
    var layout = TextLayout{};
    errdefer layout.deinit(allocator);

    if (!shouldParseInlineNode(ir, node)) {
        return layout;
    }

    try parsePlainLines(allocator, &layout, content);
    return layout;
}

pub fn codeBlockPhysicalLineCount(block: *const Block) usize {
    const paragraph = block.paragraph orelse return 1;
    var total: usize = 0;
    for (paragraph.lines.items) |line| {
        if (line.runs.items.len == 0) {
            total += 1;
            continue;
        }

        var newlines: usize = 0;
        var ends_with_newline = false;
        var saw_text = false;
        for (line.runs.items) |run| {
            if (run.text.len == 0) continue;
            saw_text = true;
            for (run.text) |ch| {
                if (ch == '\n') newlines += 1;
            }
            ends_with_newline = run.text[run.text.len - 1] == '\n';
        }
        if (!saw_text) {
            total += 1;
            continue;
        }

        var count = newlines + 1;
        if (ends_with_newline and count > 1) count -= 1;
        total += @max(@as(usize, 1), count);
    }
    return @max(@as(usize, 1), total);
}

fn parsePlainLines(allocator: Allocator, layout: *TextLayout, content: []const u8) !void {
    var it = std.mem.splitScalar(u8, content, '\n');
    var saw_any = false;
    while (it.next()) |line_text| {
        saw_any = true;
        const line = try parseInlineLine(allocator, line_text);
        try layout.lines.append(allocator, line);
    }
    if (!saw_any) {
        try layout.lines.append(allocator, .{});
    }
}

fn parseInlineLine(allocator: Allocator, line_text: []const u8) !Line {
    var line = Line{};
    errdefer line.runs.deinit(allocator);
    if (line_text.len == 0) return line;

    var state = InlineParserState{
        .allocator = allocator,
        .runs = &line.runs,
    };

    var parser = std.mem.zeroes(c.MD_PARSER);
    parser.abi_version = 0;
    parser.flags = c.MD_DIALECT_GITHUB | c.MD_FLAG_LATEXMATHSPANS;
    parser.enter_block = inlineBlockNoop;
    parser.leave_block = inlineBlockNoop;
    parser.enter_span = inlineEnterSpan;
    parser.leave_span = inlineLeaveSpan;
    parser.text = inlineTextCallback;

    const result = c.md_parse(@ptrCast(line_text.ptr), @intCast(line_text.len), &parser, &state);
    if (state.link_url) |url| allocator.free(url);
    if (result != 0) return error.MarkdownParseFailed;
    return line;
}

const InlineParserState = struct {
    allocator: Allocator,
    runs: *std.ArrayList(Run),
    strong_depth: usize = 0,
    italic_depth: usize = 0,
    code_depth: usize = 0,
    math_depth: usize = 0,
    display_math_depth: usize = 0,
    link_url: ?[]const u8 = null,
    image: ?ImageState = null,
};

fn inlineBlockNoop(
    block_type: c.MD_BLOCKTYPE,
    detail: ?*anyopaque,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    _ = block_type;
    _ = detail;
    _ = userdata;
    return 0;
}

fn enterBlock(
    block_type: c.MD_BLOCKTYPE,
    detail: ?*anyopaque,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const state = getState(userdata) orelse return 1;
    if (state.current_cell != null and (block_type == c.MD_BLOCK_P or block_type == c.MD_BLOCK_H)) {
        return 0;
    }
    switch (block_type) {
        c.MD_BLOCK_P, c.MD_BLOCK_H => state.startParagraph() catch return 1,
        c.MD_BLOCK_CODE => {
            state.endParagraph() catch return 1;
            const block = state.newBlock(.code_block) catch return 1;
            if (detail) |ptr| {
                const code_detail: *const c.MD_BLOCK_CODE_DETAIL = @ptrCast(@alignCast(ptr));
                if (code_detail.lang.size > 0) {
                    block.language = duplicateAttribute(state.arenaAllocator(), code_detail.lang) catch return 1;
                } else if (code_detail.info.size > 0) {
                    block.language = duplicateAttribute(state.arenaAllocator(), code_detail.info) catch return 1;
                }
            }
            state.appendBlock(block) catch return 1;
            state.current_paragraph = &block.paragraph.?;
            state.current_line = .{};
        },
        c.MD_BLOCK_UL => {
            state.endParagraph() catch return 1;
            const block = state.newBlock(.bullet_list) catch return 1;
            trySetTightProperty(block, detail);
            state.appendBlock(block) catch return 1;
            state.lists.append(state.temp_allocator, &block.list.?) catch return 1;
        },
        c.MD_BLOCK_OL => {
            state.endParagraph() catch return 1;
            const block = state.newBlock(.ordered_list) catch return 1;
            if (detail) |ptr| {
                const list_detail: *const c.MD_BLOCK_OL_DETAIL = @ptrCast(@alignCast(ptr));
                block.list.?.start = list_detail.start;
            }
            state.appendBlock(block) catch return 1;
            state.lists.append(state.temp_allocator, &block.list.?) catch return 1;
        },
        c.MD_BLOCK_LI => {
            state.endParagraph() catch return 1;
            if (state.lists.items.len == 0) return 1;
            const item = state.newListItem() catch return 1;
            const list = state.lists.items[state.lists.items.len - 1];
            list.items.append(state.arenaAllocator(), item) catch return 1;
            state.containers.append(state.temp_allocator, &item.blocks) catch return 1;
        },
        c.MD_BLOCK_TABLE => {
            state.endParagraph() catch return 1;
            const block = state.newBlock(.table) catch return 1;
            if (detail) |ptr| {
                const table_detail: *const c.MD_BLOCK_TABLE_DETAIL = @ptrCast(@alignCast(ptr));
                block.table.?.columns = @intCast(table_detail.col_count);
            }
            state.appendBlock(block) catch return 1;
            state.current_table = &block.table.?;
            state.current_table_header = false;
        },
        c.MD_BLOCK_THEAD => {
            state.current_table_header = true;
        },
        c.MD_BLOCK_TBODY => {
            state.current_table_header = false;
        },
        c.MD_BLOCK_TR => {
            const table = state.current_table orelse return 1;
            const row = state.newTableRow(state.current_table_header) catch return 1;
            table.rows.append(state.arenaAllocator(), row) catch return 1;
            state.current_row = row;
        },
        c.MD_BLOCK_TH, c.MD_BLOCK_TD => {
            const row = state.current_row orelse return 1;
            const cell = state.newTableCell(tableCellAlign(detail)) catch return 1;
            row.cells.append(state.arenaAllocator(), cell) catch return 1;
            state.current_cell = cell;
            state.current_line = .{};
        },
        else => {},
    }
    return 0;
}

fn leaveBlock(
    block_type: c.MD_BLOCKTYPE,
    detail: ?*anyopaque,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    _ = detail;
    const state = getState(userdata) orelse return 1;
    if (state.current_cell != null and (block_type == c.MD_BLOCK_P or block_type == c.MD_BLOCK_H)) {
        return 0;
    }
    switch (block_type) {
        c.MD_BLOCK_P, c.MD_BLOCK_H, c.MD_BLOCK_CODE => state.endParagraph() catch return 1,
        c.MD_BLOCK_UL, c.MD_BLOCK_OL => {
            if (state.lists.items.len > 0) _ = state.lists.pop();
        },
        c.MD_BLOCK_LI => {
            state.endParagraph() catch return 1;
            if (state.containers.items.len > 1) _ = state.containers.pop();
        },
        c.MD_BLOCK_TH, c.MD_BLOCK_TD => state.endTableCell() catch return 1,
        c.MD_BLOCK_TR => {
            state.endTableCell() catch return 1;
            state.current_row = null;
        },
        c.MD_BLOCK_THEAD, c.MD_BLOCK_TBODY => {
            state.current_table_header = false;
        },
        c.MD_BLOCK_TABLE => {
            state.current_cell = null;
            state.current_row = null;
            state.current_table = null;
            state.current_table_header = false;
        },
        else => {},
    }
    return 0;
}

fn inlineEnterSpan(
    span_type: c.MD_SPANTYPE,
    detail: ?*anyopaque,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const state = getInlineState(userdata) orelse return 1;
    handleEnterSpan(InlineParserState, state, span_type, detail) catch return 1;
    return 0;
}

fn enterSpan(
    span_type: c.MD_SPANTYPE,
    detail: ?*anyopaque,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const state = getState(userdata) orelse return 1;
    handleEnterSpan(ParserState, state, span_type, detail) catch return 1;
    return 0;
}

fn inlineLeaveSpan(
    span_type: c.MD_SPANTYPE,
    detail: ?*anyopaque,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    _ = detail;
    const state = getInlineState(userdata) orelse return 1;
    handleLeaveSpan(InlineParserState, state, span_type, state.runs) catch return 1;
    return 0;
}

fn leaveSpan(
    span_type: c.MD_SPANTYPE,
    detail: ?*anyopaque,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    _ = detail;
    const state = getState(userdata) orelse return 1;
    handleLeaveSpan(ParserState, state, span_type, &state.current_line.runs) catch return 1;
    return 0;
}

fn handleEnterSpan(comptime T: type, state: *T, span_type: c.MD_SPANTYPE, detail: ?*anyopaque) !void {
    switch (span_type) {
        c.MD_SPAN_EM => state.italic_depth += 1,
        c.MD_SPAN_STRONG => state.strong_depth += 1,
        c.MD_SPAN_CODE => state.code_depth += 1,
        c.MD_SPAN_LATEXMATH => state.math_depth += 1,
        c.MD_SPAN_LATEXMATH_DISPLAY => {
            state.math_depth += 1;
            state.display_math_depth += 1;
        },
        c.MD_SPAN_A => {
            if (detail) |ptr| {
                const link_detail: *const c.MD_SPAN_A_DETAIL = @ptrCast(@alignCast(ptr));
                const duped = try duplicateAttribute(allocatorForState(T, state), link_detail.href);
                state.link_url = duped;
            }
        },
        c.MD_SPAN_IMG => {
            if (detail) |ptr| {
                const image_detail: *const c.MD_SPAN_IMG_DETAIL = @ptrCast(@alignCast(ptr));
                const duped = try duplicateAttribute(allocatorForState(T, state), image_detail.src);
                state.image = .{ .src = duped };
            }
        },
        else => {},
    }
}

fn handleLeaveSpan(comptime T: type, state: *T, span_type: c.MD_SPANTYPE, runs: *std.ArrayList(Run)) !void {
    switch (span_type) {
        c.MD_SPAN_EM => {
            if (state.italic_depth > 0) state.italic_depth -= 1;
        },
        c.MD_SPAN_STRONG => {
            if (state.strong_depth > 0) state.strong_depth -= 1;
        },
        c.MD_SPAN_CODE => {
            if (state.code_depth > 0) state.code_depth -= 1;
        },
        c.MD_SPAN_LATEXMATH => {
            if (state.math_depth > 0) state.math_depth -= 1;
        },
        c.MD_SPAN_LATEXMATH_DISPLAY => {
            if (state.math_depth > 0) state.math_depth -= 1;
            if (state.display_math_depth > 0) state.display_math_depth -= 1;
        },
        c.MD_SPAN_A => {
            if (state.link_url) |url| allocatorForState(T, state).free(url);
            state.link_url = null;
        },
        c.MD_SPAN_IMG => {
            if (state.image) |image| {
                if (std.mem.startsWith(u8, image.src, "fa:") or
                    std.mem.startsWith(u8, image.src, "fab:") or
                    std.mem.startsWith(u8, image.src, "fas:") or
                    std.mem.startsWith(u8, image.src, "far:") or
                    std.mem.startsWith(u8, image.src, "fa-brands:") or
                    std.mem.startsWith(u8, image.src, "fa-solid:") or
                    std.mem.startsWith(u8, image.src, "fa-regular:"))
                {
                    try ensureParagraphForState(T, state);
                    try appendIconRun(T, state, runs, image.src);
                }
                allocatorForState(T, state).free(image.src);
            }
            state.image = null;
        },
        else => {},
    }
}

fn inlineTextCallback(
    text_type: c.MD_TEXTTYPE,
    text_ptr: [*c]const c.MD_CHAR,
    size: c.MD_SIZE,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const state = getInlineState(userdata) orelse return 1;
    appendTextRun(InlineParserState, state, state.runs, text_type, text_ptr, size) catch return 1;
    return 0;
}

fn textCallback(
    text_type: c.MD_TEXTTYPE,
    text_ptr: [*c]const c.MD_CHAR,
    size: c.MD_SIZE,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const state = getState(userdata) orelse return 1;
    if (state.current_cell != null) {
        if (text_type == c.MD_TEXT_BR) {
            state.flushCurrentTableLine(false) catch return 1;
            return 0;
        }
        appendTextRun(ParserState, state, &state.current_line.runs, text_type, text_ptr, size) catch return 1;
        return 0;
    }
    switch (text_type) {
        c.MD_TEXT_BR => {
            state.ensureParagraph() catch return 1;
            state.flushCurrentLine(false) catch return 1;
            return 0;
        },
        else => {},
    }
    state.ensureParagraph() catch return 1;
    appendTextRun(ParserState, state, &state.current_line.runs, text_type, text_ptr, size) catch return 1;
    return 0;
}

fn appendTextRun(
    comptime T: type,
    state: *T,
    runs: *std.ArrayList(Run),
    text_type: c.MD_TEXTTYPE,
    text_ptr: [*c]const c.MD_CHAR,
    size: c.MD_SIZE,
) !void {
    if (state.image != null) {
        return;
    }
    const bytes: []const u8 = if (size == 0)
        ""
    else
        @as([*]const u8, @ptrCast(text_ptr))[0..size];
    const kind = activeKind(state, text_type);
    const normalized = switch (text_type) {
        c.MD_TEXT_SOFTBR => if (kind == .display_math) "\n" else " ",
        c.MD_TEXT_BR => "\n",
        else => bytes,
    };

    const alloc = allocatorForState(T, state);
    const text_copy = try alloc.dupe(u8, normalized);
    var run = Run{
        .kind = kind,
        .text = text_copy,
    };
    if (run.kind == .link and state.link_url != null) {
        run.url = try alloc.dupe(u8, state.link_url.?);
    }
    try runs.append(alloc, run);
}

fn appendIconRun(comptime T: type, state: *T, runs: *std.ArrayList(Run), src: []const u8) !void {
    const alloc = allocatorForState(T, state);
    const src_copy = try alloc.dupe(u8, src);
    const text_copy = try alloc.dupe(u8, "");
    try runs.append(alloc, .{
        .kind = .icon,
        .text = text_copy,
        .icon = src_copy,
    });
}

fn ensureParagraphForState(comptime T: type, state: *T) !void {
    if (T == ParserState) {
        if (state.current_cell == null) try state.ensureParagraph();
    }
}

fn allocatorForState(comptime T: type, state: *T) Allocator {
    if (T == ParserState) return state.arenaAllocator();
    return state.allocator;
}

fn activeKind(state: anytype, text_type: c.MD_TEXTTYPE) RunKind {
    if (state.display_math_depth > 0) return .display_math;
    if (text_type == c.MD_TEXT_LATEXMATH or state.math_depth > 0) return .math;
    if (text_type == c.MD_TEXT_CODE or state.code_depth > 0) return .code;
    if (state.strong_depth > 0) return .bold;
    if (state.italic_depth > 0) return .italic;
    if (state.link_url != null) return .link;
    return .text;
}

fn getState(userdata: ?*anyopaque) ?*ParserState {
    const ptr = userdata orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn getInlineState(userdata: ?*anyopaque) ?*InlineParserState {
    const ptr = userdata orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn duplicateAttribute(allocator: Allocator, attr: c.MD_ATTRIBUTE) ![]const u8 {
    if (attr.size == 0) return allocator.dupe(u8, "");
    const bytes: []const u8 = @as([*]const u8, @ptrCast(attr.text))[0..attr.size];
    return allocator.dupe(u8, bytes);
}

fn trySetTightProperty(block: *Block, detail: ?*anyopaque) void {
    _ = block;
    _ = detail;
}

fn tableCellAlign(detail: ?*anyopaque) Align {
    const ptr = detail orelse return .default;
    const cell_detail: *const c.MD_BLOCK_TD_DETAIL = @ptrCast(@alignCast(ptr));
    return switch (cell_detail.@"align") {
        c.MD_ALIGN_LEFT => .left,
        c.MD_ALIGN_CENTER => .center,
        c.MD_ALIGN_RIGHT => .right,
        else => .default,
    };
}

test "parse markdown table block" {
    const allocator = std.testing.allocator;
    var doc = try parseMarkdownContent(allocator,
        \\| Name | Score |
        \\| :--- | ---: |
        \\| Ada | **10** |
        \\| Ken | 8 |
    );
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.items.len);
    const block = doc.blocks.items[0];
    try std.testing.expectEqual(BlockKind.table, block.kind);
    try std.testing.expectEqual(@as(usize, 2), block.table.?.columns);
    try std.testing.expectEqual(@as(usize, 3), block.table.?.rows.items.len);
    try std.testing.expect(block.table.?.rows.items[0].header);
    try std.testing.expectEqual(Align.left, block.table.?.rows.items[0].cells.items[0].alignment);
    try std.testing.expectEqual(Align.right, block.table.?.rows.items[0].cells.items[1].alignment);
    try std.testing.expectEqual(RunKind.bold, block.table.?.rows.items[1].cells.items[1].lines.items[0].runs.items[0].kind);
}

test "fenced code block counts embedded physical lines" {
    const allocator = std.testing.allocator;
    var doc = try parseMarkdownContent(allocator,
        \\before
        \\
        \\```shape
        \\program ::= init <polygon> ; <command>
        \\command ::= <op> | <command> ; <command>
        \\           | while <cond> do <command> end
        \\```
        \\
        \\after
    );
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 3), doc.blocks.items.len);
    const block = doc.blocks.items[1];
    try std.testing.expectEqual(BlockKind.code_block, block.kind);
    try std.testing.expectEqualStrings("shape", block.language.?);
    try std.testing.expectEqual(@as(usize, 3), codeBlockPhysicalLineCount(block));
}

test "fenced code block preserves blank physical lines without trailing phantom line" {
    const allocator = std.testing.allocator;
    var doc = try parseMarkdownContent(allocator,
        \\```
        \\alpha
        \\
        \\beta
        \\```
    );
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.items.len);
    const block = doc.blocks.items[0];
    try std.testing.expectEqual(BlockKind.code_block, block.kind);
    try std.testing.expectEqual(@as(usize, 3), codeBlockPhysicalLineCount(block));
}
