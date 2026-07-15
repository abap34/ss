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
        const page_id = try builder.append(.page);
        const page_node_index = builder.index(page_id);
        const page_name = if (state.getNode(page.page_id)) |node| node.name else "Page";
        builder.nodes.items[page_node_index].text = try allocator.dupe(u8, page_name);
        try page_ids.append(allocator, page_id);

        var object_ids = std.ArrayList(render.SemanticId).empty;
        defer object_ids.deinit(allocator);
        for (prepared_page.objects) |*prepared_object| {
            const item_count = countItemsForNode(page, prepared_object.node_id);
            if (item_count == 0) continue;
            const semantic_id = try builder.object(state, prepared_object);
            const semantic_index = builder.index(semantic_id);
            const item_ids = try allocator.alloc(render.ItemId, item_count);
            var next_item: usize = 0;
            for (page.items.items) |*item| {
                if (item.nodeId() != prepared_object.node_id) continue;
                item.setSemanticId(semantic_id);
                item_ids[next_item] = item.header().item_id;
                next_item += 1;
            }
            builder.nodes.items[semantic_index].items = item_ids;
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

    fn object(self: *Builder, state: *core.DocumentState, prepared_object: *const core.prepared.PreparedObject) !render.SemanticId {
        const node = state.getNode(prepared_object.node_id);
        const role = if (node) |value| value.role orelse "" else "";
        if (std.mem.eql(u8, role, "title") or std.mem.eql(u8, role, "subtitle")) {
            const id = try self.append(.heading);
            const index_value = self.index(id);
            self.nodes.items[index_value].heading_level = if (std.mem.eql(u8, role, "title")) 1 else 2;
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
            for (line.runs.items) |run| {
                const child = switch (run.kind) {
                    .link => try self.link(run),
                    .math, .display_math => try self.leaf(.math, run.text),
                    .text, .bold, .italic, .code, .icon => try self.text(run.text),
                };
                try children.append(self.allocator, child);
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

fn countItemsForNode(page: *const render.Page, node_id: core.NodeId) usize {
    var count: usize = 0;
    for (page.items.items) |item| if (item.nodeId() == node_id) {
        count += 1;
    };
    return count;
}

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
