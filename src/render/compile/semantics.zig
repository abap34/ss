const std = @import("std");
const core = @import("core");
const render = @import("render");

const Allocator = std.mem.Allocator;
const MarkdownBlock = core.markdown.Block;
const MarkdownLine = core.markdown.Line;

pub fn build(
    allocator: Allocator,
    state: *core.DocumentState,
    prepared_pages: *const core.prepared.PreparedPages,
    pages: []render.Page,
) !render.SemanticTree {
    var builder = Builder{ .allocator = allocator };
    errdefer builder.deinit();
    const root = try builder.append(.document);
    var page_ids = std.ArrayList(render.SemanticId).empty;
    defer page_ids.deinit(allocator);

    for (pages) |*page| {
        const prepared_page = core.prepared.pageById(prepared_pages, page.page_id) orelse return error.MissingPreparedPage;
        var item_indices_by_node = std.AutoHashMap(core.NodeId, std.ArrayList(usize)).init(allocator);
        defer {
            var values = item_indices_by_node.valueIterator();
            while (values.next()) |indices| indices.deinit(allocator);
            item_indices_by_node.deinit();
        }
        for (page.items.items, 0..) |item, item_index| {
            const node_id = item.nodeId() orelse continue;
            const entry = try item_indices_by_node.getOrPut(node_id);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(allocator, item_index);
        }
        const page_id = try builder.append(.page);
        const page_node_index = builder.index(page_id);
        const page_name = if (state.getNode(page.page_id)) |node| node.name else "Page";
        builder.nodes.items[page_node_index].text = try allocator.dupe(u8, page_name);
        try page_ids.append(allocator, page_id);

        var object_ids = std.ArrayList(render.SemanticId).empty;
        defer object_ids.deinit(allocator);
        for (prepared_page.objects) |*prepared_object| {
            const item_indices = item_indices_by_node.get(prepared_object.node_id) orelse continue;
            const semantic_id = try builder.object(state, prepared_object);
            const semantic_index = builder.index(semantic_id);
            var parent_items = std.ArrayList(render.ItemId).empty;
            defer parent_items.deinit(allocator);
            var math_semantics = std.ArrayList(render.SemanticId).empty;
            defer math_semantics.deinit(allocator);
            try builder.collectMathNodes(semantic_id, &math_semantics, 0);
            var next_math: usize = 0;
            for (item_indices.items) |item_index| {
                const item = &page.items.items[item_index];
                var item_semantic_id = semantic_id;
                if (item.* == .math) {
                    if (next_math >= math_semantics.items.len) return error.MissingMathSemantics;
                    item_semantic_id = math_semantics.items[next_math];
                    next_math += 1;
                    const math_node = &builder.nodes.items[builder.index(item_semantic_id)];
                    math_node.math_tree = item.math.tree;
                    if (item_semantic_id != semantic_id) {
                        if (math_node.items.len != 0) return error.DuplicateMathSemantics;
                        math_node.items = try allocator.dupe(render.ItemId, &.{item.header().item_id});
                    }
                }
                item.setSemanticId(item_semantic_id);
                if (item_semantic_id == semantic_id) try parent_items.append(allocator, item.header().item_id);
            }
            if (next_math != math_semantics.items.len) return error.MissingMathItem;
            builder.nodes.items[semantic_index].items = try parent_items.toOwnedSlice(allocator);
            try object_ids.append(allocator, semantic_id);
        }
        builder.nodes.items[page_node_index].children = try object_ids.toOwnedSlice(allocator);
        page.reading_order = try allocator.dupe(render.SemanticId, builder.nodes.items[page_node_index].children);
    }
    builder.nodes.items[builder.index(root)].children = try page_ids.toOwnedSlice(allocator);
    return try builder.take(root);
}

const Builder = struct {
    allocator: Allocator,
    nodes: std.ArrayList(render.SemanticNode) = .empty,

    fn deinit(self: *Builder) void {
        for (self.nodes.items) |*node| node.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
    }

    fn take(self: *Builder, root: render.SemanticId) !render.SemanticTree {
        const nodes = try self.nodes.toOwnedSlice(self.allocator);
        self.* = .{ .allocator = self.allocator };
        return .{ .root = root, .nodes = nodes };
    }

    fn append(self: *Builder, role: render.SemanticRole) !render.SemanticId {
        const id: render.SemanticId = @intCast(self.nodes.items.len + 1);
        try self.nodes.append(self.allocator, .{ .id = id, .role = role });
        return id;
    }

    fn index(_: *const Builder, id: render.SemanticId) usize {
        return @intCast(id - 1);
    }

    fn collectMathNodes(self: *Builder, id: render.SemanticId, result: *std.ArrayList(render.SemanticId), depth: usize) !void {
        if (id == 0 or id > self.nodes.items.len or depth > self.nodes.items.len) return error.InvalidSemantics;
        const node = self.nodes.items[self.index(id)];
        if (node.role == .math) {
            try result.append(self.allocator, id);
            return;
        }
        for (node.children) |child| try self.collectMathNodes(child, result, depth + 1);
    }

    fn object(self: *Builder, state: *core.DocumentState, prepared_object: *const core.prepared.PreparedObject) !render.SemanticId {
        const node = state.getNode(prepared_object.node_id);
        const role = if (node) |value| value.role orelse "" else "";
        if (std.mem.eql(u8, role, "title") or std.mem.eql(u8, role, "subtitle")) {
            const level: u8 = if (std.mem.eql(u8, role, "title")) 1 else 2;
            if (prepared_object.textLayout()) |layout| return try self.lines(.heading, level, layout.lines.items);
            if (prepared_object.markdownDocument()) |document| {
                if (document.blocks.items.len == 1) {
                    const block_value = document.blocks.items[0];
                    if (block_value.paragraph) |paragraph| return try self.lines(.heading, level, paragraph.lines.items);
                }
            }
            const id = try self.append(.heading);
            const index_value = self.index(id);
            self.nodes.items[index_value].heading_level = level;
            self.nodes.items[index_value].text = try self.objectText(prepared_object);
            return id;
        }
        if (std.mem.eql(u8, role, "code") or prepared_object.render.kind == .code) {
            const id = try self.append(.code);
            self.nodes.items[self.index(id)].text = try self.objectText(prepared_object);
            return id;
        }
        if (std.mem.eql(u8, role, "figure") or prepared_object.render.kind == .vector_asset or prepared_object.render.kind == .raster_asset) {
            const id = try self.append(.figure);
            const label = if (node) |value| value.name else prepared_object.content;
            self.nodes.items[self.index(id)].alt_text = try duplicateOptional(self.allocator, label);
            return id;
        }
        if (prepared_object.render.kind == .vector_math) {
            const id = try self.append(.math);
            self.nodes.items[self.index(id)].text = try duplicateOptional(self.allocator, prepared_object.content);
            return id;
        }
        if (prepared_object.textLayout()) |layout| {
            return try self.lines(if (std.mem.eql(u8, role, "caption")) .caption else .paragraph, null, layout.lines.items);
        }
        if (prepared_object.markdownDocument()) |document| {
            if (document.blocks.items.len == 1) return try self.block(document.blocks.items[0]);
            const id = try self.append(.group);
            var children = std.ArrayList(render.SemanticId).empty;
            defer children.deinit(self.allocator);
            for (document.blocks.items) |markdown_block| try children.append(self.allocator, try self.block(markdown_block));
            self.nodes.items[self.index(id)].children = try children.toOwnedSlice(self.allocator);
            return id;
        }
        const id = try self.append(if (std.mem.eql(u8, role, "caption")) .caption else .paragraph);
        self.nodes.items[self.index(id)].text = try self.objectText(prepared_object);
        return id;
    }

    fn objectText(self: *Builder, prepared_object: *const core.prepared.PreparedObject) !?[]u8 {
        if (prepared_object.textLayout()) |layout| return try plainLines(self.allocator, layout.lines.items);
        if (prepared_object.markdownDocument()) |document| return try plainBlocks(self.allocator, document.blocks.items);
        return try duplicateOptional(self.allocator, prepared_object.content);
    }

    fn block(self: *Builder, block_value: *const MarkdownBlock) anyerror!render.SemanticId {
        return switch (block_value.kind) {
            .paragraph => try self.lines(.paragraph, null, block_value.paragraph.?.lines.items),
            .heading => try self.lines(.heading, block_value.heading_level orelse 2, block_value.paragraph.?.lines.items),
            .code_block => blk: {
                const id = try self.lines(.code, null, block_value.paragraph.?.lines.items);
                self.nodes.items[self.index(id)].code_language = try duplicateOptional(self.allocator, block_value.language orelse "");
                break :blk id;
            },
            .bullet_list, .ordered_list => try self.list(block_value),
            .table => try self.table(block_value),
        };
    }

    fn lines(self: *Builder, role: render.SemanticRole, heading_level: ?u8, line_values: []const MarkdownLine) !render.SemanticId {
        const id = try self.append(role);
        const node_index = self.index(id);
        self.nodes.items[node_index].heading_level = heading_level;
        var children = std.ArrayList(render.SemanticId).empty;
        defer children.deinit(self.allocator);
        for (line_values, 0..) |line, line_index| {
            if (line_index != 0) try children.append(self.allocator, try self.text("\n"));
            var run_index: usize = 0;
            while (run_index < line.runs.items.len) {
                const run = line.runs.items[run_index];
                if (run.kind == .display_math) {
                    var source = std.ArrayList(u8).empty;
                    defer source.deinit(self.allocator);
                    while (run_index < line.runs.items.len and line.runs.items[run_index].kind == .display_math) : (run_index += 1) {
                        try source.appendSlice(self.allocator, line.runs.items[run_index].text);
                    }
                    const trimmed = std.mem.trim(u8, source.items, " \t\r\n");
                    if (trimmed.len != 0) try children.append(self.allocator, try self.leaf(.math, trimmed));
                    continue;
                }
                const child = switch (run.kind) {
                    .link => try self.link(run),
                    .math => try self.leaf(.math, run.text),
                    .text, .bold, .italic, .code, .icon => try self.text(run.text),
                    .display_math => unreachable,
                };
                try children.append(self.allocator, child);
                run_index += 1;
            }
        }
        self.nodes.items[node_index].children = try children.toOwnedSlice(self.allocator);
        return id;
    }

    fn text(self: *Builder, value: []const u8) !render.SemanticId {
        return try self.leaf(.text, value);
    }

    fn leaf(self: *Builder, role: render.SemanticRole, value: []const u8) !render.SemanticId {
        const id = try self.append(role);
        self.nodes.items[self.index(id)].text = try duplicateOptional(self.allocator, value);
        return id;
    }

    fn link(self: *Builder, run: core.markdown.Run) !render.SemanticId {
        const target = run.url orelse return error.MissingLinkTarget;
        const id = try self.leaf(.link, run.text);
        const node_index = self.index(id);
        const destination = std.mem.startsWith(u8, target, "#");
        self.nodes.items[node_index].link_target = try self.allocator.dupe(u8, if (destination) target[1..] else target);
        self.nodes.items[node_index].link_kind = if (destination) .destination else .uri;
        return id;
    }

    fn list(self: *Builder, block_value: *const MarkdownBlock) anyerror!render.SemanticId {
        const list_value = block_value.list.?;
        const id = try self.append(.list);
        const node_index = self.index(id);
        const ordered = block_value.kind == .ordered_list;
        self.nodes.items[node_index].list_ordered = ordered;
        self.nodes.items[node_index].list_start = if (ordered) list_value.start else null;
        var children = std.ArrayList(render.SemanticId).empty;
        defer children.deinit(self.allocator);
        for (list_value.items.items) |item| {
            const child = try self.append(.list_item);
            var block_ids = std.ArrayList(render.SemanticId).empty;
            defer block_ids.deinit(self.allocator);
            for (item.blocks.items) |block_value_child| try block_ids.append(self.allocator, try self.block(block_value_child));
            self.nodes.items[self.index(child)].children = try block_ids.toOwnedSlice(self.allocator);
            try children.append(self.allocator, child);
        }
        self.nodes.items[node_index].children = try children.toOwnedSlice(self.allocator);
        return id;
    }

    fn table(self: *Builder, block_value: *const MarkdownBlock) !render.SemanticId {
        const id = try self.append(.table);
        var rows = std.ArrayList(render.SemanticId).empty;
        defer rows.deinit(self.allocator);
        for (block_value.table.?.rows.items) |row| {
            const row_id = try self.append(.table_row);
            var cells = std.ArrayList(render.SemanticId).empty;
            defer cells.deinit(self.allocator);
            for (row.cells.items) |cell| {
                const cell_id = try self.lines(if (row.header) .table_header else .table_cell, null, cell.lines.items);
                try cells.append(self.allocator, cell_id);
            }
            self.nodes.items[self.index(row_id)].children = try cells.toOwnedSlice(self.allocator);
            try rows.append(self.allocator, row_id);
        }
        self.nodes.items[self.index(id)].children = try rows.toOwnedSlice(self.allocator);
        return id;
    }
};

fn plainBlocks(allocator: Allocator, blocks: []const *MarkdownBlock) !?[]u8 {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    for (blocks, 0..) |block_value, index| {
        if (index != 0) try text.append(allocator, '\n');
        switch (block_value.kind) {
            .paragraph, .heading, .code_block => try appendLines(allocator, &text, block_value.paragraph.?.lines.items),
            .bullet_list, .ordered_list => for (block_value.list.?.items.items) |item| {
                if (try plainBlocks(allocator, item.blocks.items)) |value| {
                    defer allocator.free(value);
                    try text.appendSlice(allocator, value);
                }
            },
            .table => for (block_value.table.?.rows.items) |row| for (row.cells.items) |cell| {
                try appendLines(allocator, &text, cell.lines.items);
            },
        }
    }
    return if (text.items.len == 0) null else try text.toOwnedSlice(allocator);
}

fn plainLines(allocator: Allocator, lines: []const MarkdownLine) !?[]u8 {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    try appendLines(allocator, &text, lines);
    return if (text.items.len == 0) null else try text.toOwnedSlice(allocator);
}

fn appendLines(allocator: Allocator, output: *std.ArrayList(u8), lines: []const MarkdownLine) !void {
    for (lines, 0..) |line, line_index| {
        if (line_index != 0) try output.append(allocator, '\n');
        for (line.runs.items) |run| try output.appendSlice(allocator, run.text);
    }
}

fn duplicateOptional(allocator: Allocator, value: []const u8) !?[]u8 {
    return if (value.len == 0) null else try allocator.dupe(u8, value);
}
