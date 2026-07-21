const std = @import("std");
const model = @import("model");
const DocumentState = @import("document_state.zig").DocumentState;
const layout_model = @import("../layout/root.zig");
const markdown = @import("markdown.zig");
const render_env = @import("render_env.zig");
const render_policy = @import("render_policy.zig");

pub const PreparedObject = struct {
    node_id: model.NodeId,
    content: []const u8,
    content_provenance: []const model.ContentProvenance,
    link_id: ?[]const u8,
    render: render_policy.ResolvedRender,
    parse_mode: markdown.ParseMode,
    markdown_doc: ?markdown.MarkdownDocument = null,
    text_layout: ?markdown.TextLayout = null,
    asset_deps: []AssetDependency = &.{},
    asset_keys: []u64 = &.{},
    tex_preamble: []const render_env.TexPreambleEntry,
    tex_engine: render_env.TexEngine,
    origin: ?[]const u8,
    payload_kind: ?model.PayloadKind,
    attached: bool,

    pub fn deinit(self: *PreparedObject, allocator: std.mem.Allocator) void {
        for (self.asset_deps) |*dep| dep.deinit(allocator);
        allocator.free(self.asset_deps);
        allocator.free(self.asset_keys);
        if (self.markdown_doc) |*doc| doc.deinit();
        if (self.text_layout) |*layout| layout.deinit(allocator);
        allocator.free(self.tex_preamble);
    }

    pub fn markdownDocument(self: *const PreparedObject) ?*const markdown.MarkdownDocument {
        if (self.markdown_doc) |*doc| return doc;
        return null;
    }

    pub fn textLayout(self: *const PreparedObject) ?*const markdown.TextLayout {
        if (self.text_layout) |*layout| return layout;
        return null;
    }
};

pub const AssetDependency = struct {
    kind: Kind,
    source: []const u8,
    source_owned: bool = false,
    content_start: usize = 0,
    content_end: usize = 0,

    pub const Kind = enum {
        inline_math,
        display_math,
        block_math,
        icon,
        vector_pdf,
        raster_asset,
    };

    pub fn deinit(self: *AssetDependency, allocator: std.mem.Allocator) void {
        if (self.source_owned) allocator.free(self.source);
    }
};

pub const PreparedPage = struct {
    page_id: model.NodeId,
    index: usize,
    background: ?render_policy.Color,
    object_ids: []model.NodeId,
    constraints: []model.Constraint,
    objects: []PreparedObject,
    asset_keys: []u64 = &.{},

    pub fn deinit(self: *PreparedPage, allocator: std.mem.Allocator) void {
        allocator.free(self.object_ids);
        allocator.free(self.constraints);
        for (self.objects) |*object| object.deinit(allocator);
        allocator.free(self.objects);
        allocator.free(self.asset_keys);
    }
};

pub const PreparedPages = struct {
    pages: []PreparedPage,

    pub fn deinit(self: *PreparedPages, allocator: std.mem.Allocator) void {
        for (self.pages) |*page| page.deinit(allocator);
        allocator.free(self.pages);
    }
};

pub fn prepare(allocator: std.mem.Allocator, state: *DocumentState) !PreparedPages {
    var pages = std.ArrayList(PreparedPage).empty;
    errdefer {
        for (pages.items) |*page| page.deinit(allocator);
        pages.deinit(allocator);
    }

    for (state.page_order.items, 0..) |page_id, page_index| {
        const page = state.getNode(page_id) orelse continue;
        var object_ids = std.ArrayList(model.NodeId).empty;
        errdefer object_ids.deinit(allocator);
        try collectPageObjectIds(allocator, state, page_id, &object_ids);

        var constraints = std.ArrayList(model.Constraint).empty;
        errdefer constraints.deinit(allocator);
        try collectPageConstraints(allocator, state, page_id, &constraints);

        var objects = std.ArrayList(PreparedObject).empty;
        errdefer {
            for (objects.items) |*object| object.deinit(allocator);
            objects.deinit(allocator);
        }
        for (object_ids.items) |node_id| {
            const node = state.getNode(node_id) orelse continue;
            if (node.kind != .object) continue;
            var unit = try prepareObject(allocator, state, node);
            var unit_transferred = false;
            errdefer if (!unit_transferred) unit.deinit(allocator);
            try objects.append(allocator, unit);
            unit_transferred = true;
        }

        const ids_slice = try object_ids.toOwnedSlice(allocator);
        var ids_transferred = false;
        errdefer if (!ids_transferred) allocator.free(ids_slice);
        const constraint_slice = try constraints.toOwnedSlice(allocator);
        var constraints_transferred = false;
        errdefer if (!constraints_transferred) allocator.free(constraint_slice);
        const object_slice = try objects.toOwnedSlice(allocator);
        var objects_transferred = false;
        errdefer {
            if (!objects_transferred) {
                for (object_slice) |*object| object.deinit(allocator);
                allocator.free(object_slice);
            }
        }
        const page_asset_keys = try collectPageAssetKeys(allocator, object_slice);
        var page_asset_keys_transferred = false;
        errdefer if (!page_asset_keys_transferred) allocator.free(page_asset_keys);

        try pages.append(allocator, .{
            .page_id = page_id,
            .index = page_index,
            .background = render_policy.resolvePageBackground(state, page),
            .object_ids = ids_slice,
            .constraints = constraint_slice,
            .objects = object_slice,
            .asset_keys = page_asset_keys,
        });
        ids_transferred = true;
        constraints_transferred = true;
        objects_transferred = true;
        page_asset_keys_transferred = true;
    }

    return .{ .pages = try pages.toOwnedSlice(allocator) };
}

pub fn prepareObject(allocator: std.mem.Allocator, state: *DocumentState, node: *const model.Node) !PreparedObject {
    return try prepareObjectWithRender(allocator, state, node, render_policy.resolve(state, node));
}

pub fn prepareObjectWithRender(
    allocator: std.mem.Allocator,
    state: *DocumentState,
    node: *const model.Node,
    render: render_policy.ResolvedRender,
) !PreparedObject {
    var env = try render_env.resolveForNode(allocator, state, node);
    defer env.deinit(allocator);
    const uses_asset_content = switch (node.payload_kind orelse .text) {
        .image_ref, .pdf_ref => true,
        else => false,
    };
    var markdown_doc: ?markdown.MarkdownDocument = null;
    var text_layout: ?markdown.TextLayout = null;
    var asset_deps = std.ArrayList(AssetDependency).empty;
    errdefer {
        for (asset_deps.items) |*dep| dep.deinit(allocator);
        asset_deps.deinit(allocator);
        if (markdown_doc) |*doc| doc.deinit();
        if (text_layout) |*layout| layout.deinit(allocator);
    }
    const parse_mode = markdown.parseModeForNode(state, node);
    const content = if (uses_asset_content) node.content orelse "" else model.nodeDisplayContent(node);
    switch (render.kind) {
        .text => switch (parse_mode) {
            .none => {},
            .block => {
                markdown_doc = try markdown.parseMarkdownContent(allocator, content);
                try collectMarkdownBlockAssetDeps(allocator, markdown_doc.?.blocks.items, &asset_deps);
            },
            .@"inline" => {
                text_layout = try markdown.parseTextLayoutContent(allocator, content);
                try collectLineAssetDeps(allocator, text_layout.?.lines.items, &asset_deps);
            },
        },
        .vector_math => try asset_deps.append(allocator, .{
            .kind = .block_math,
            .source = content,
            .content_start = 0,
            .content_end = content.len,
        }),
        .vector_asset => {
            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(content), ".pdf")) {
                try asset_deps.append(allocator, .{
                    .kind = .vector_pdf,
                    .source = content,
                    .content_start = 0,
                    .content_end = content.len,
                });
            }
        },
        .raster_asset => try asset_deps.append(allocator, .{
            .kind = .raster_asset,
            .source = content,
            .content_start = 0,
            .content_end = content.len,
        }),
        .code, .vector_path, .connector, .chrome_only => {},
    }
    const asset_dep_slice = try asset_deps.toOwnedSlice(allocator);
    asset_deps = .empty;
    var asset_deps_transferred = false;
    errdefer {
        if (!asset_deps_transferred) {
            for (asset_dep_slice) |*dep| dep.deinit(allocator);
            allocator.free(asset_dep_slice);
        }
    }
    const tex_preamble = try cloneTexPreambleEntries(allocator, env.tex_preamble.items);
    var tex_preamble_transferred = false;
    errdefer if (!tex_preamble_transferred) allocator.free(tex_preamble);
    const asset_key_slice = try assetKeysForObject(allocator, asset_dep_slice, tex_preamble, env.tex_engine);
    var asset_keys_transferred = false;
    errdefer if (!asset_keys_transferred) allocator.free(asset_key_slice);
    asset_deps_transferred = true;
    tex_preamble_transferred = true;
    asset_keys_transferred = true;
    return .{
        .node_id = node.id,
        .content = content,
        .content_provenance = if (uses_asset_content) node.content_provenance.items else model.nodeDisplayContentProvenance(node),
        .link_id = nodeStringField(node, "link_id"),
        .render = render,
        .parse_mode = parse_mode,
        .markdown_doc = markdown_doc,
        .text_layout = text_layout,
        .asset_deps = asset_dep_slice,
        .asset_keys = asset_key_slice,
        .tex_preamble = tex_preamble,
        .tex_engine = env.tex_engine,
        .origin = node.origin,
        .payload_kind = node.payload_kind,
        .attached = node.attached,
    };
}

pub fn attachAssetKeys(
    allocator: std.mem.Allocator,
    document: *layout_model.Document,
    pages: *const PreparedPages,
) !void {
    for (document.pages) |*result| {
        const page = pageById(pages, result.page_id) orelse continue;
        const keys = try allocator.dupe(u64, page.asset_keys);
        errdefer allocator.free(keys);
        allocator.free(result.asset_keys);
        result.asset_keys = keys;
    }
}

pub fn pageById(pages: *const PreparedPages, page_id: model.NodeId) ?*const PreparedPage {
    for (pages.pages) |*page| {
        if (page.page_id == page_id) return page;
    }
    return null;
}

pub fn assetDependencyKey(
    dep: AssetDependency,
    tex_preamble: []const render_env.TexPreambleEntry,
    tex_engine: render_env.TexEngine,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, "ss-prepared-asset-v2");
    hashString(&hasher, @tagName(dep.kind));
    hashString(&hasher, dep.source);
    switch (dep.kind) {
        .inline_math, .display_math, .block_math => {
            hashString(&hasher, @tagName(tex_engine));
            hashTexPreamble(&hasher, tex_preamble);
        },
        .icon, .vector_pdf, .raster_asset => {},
    }
    return hasher.final();
}

fn assetKeysForObject(
    allocator: std.mem.Allocator,
    deps: []const AssetDependency,
    tex_preamble: []const render_env.TexPreambleEntry,
    tex_engine: render_env.TexEngine,
) ![]u64 {
    var keys = std.ArrayList(u64).empty;
    errdefer keys.deinit(allocator);
    for (deps) |dep| try appendUniqueKey(allocator, &keys, assetDependencyKey(dep, tex_preamble, tex_engine));
    return try keys.toOwnedSlice(allocator);
}

fn collectPageAssetKeys(allocator: std.mem.Allocator, objects: []const PreparedObject) ![]u64 {
    var keys = std.ArrayList(u64).empty;
    errdefer keys.deinit(allocator);
    for (objects) |object| {
        for (object.asset_keys) |key| try appendUniqueKey(allocator, &keys, key);
    }
    return try keys.toOwnedSlice(allocator);
}

fn collectMarkdownBlockAssetDeps(
    allocator: std.mem.Allocator,
    blocks: []const *markdown.Block,
    deps: *std.ArrayList(AssetDependency),
) !void {
    for (blocks) |block| {
        switch (block.kind) {
            .paragraph, .heading, .code_block => if (block.paragraph) |paragraph| {
                try collectLineAssetDeps(allocator, paragraph.lines.items, deps);
            },
            .block_quote => if (block.quote) |quote| {
                try collectMarkdownBlockAssetDeps(allocator, quote.blocks.items, deps);
            },
            .bullet_list, .ordered_list => if (block.list) |list| {
                for (list.items.items) |item| {
                    try collectMarkdownBlockAssetDeps(allocator, item.blocks.items, deps);
                }
            },
            .table => if (block.table) |table| {
                for (table.rows.items) |row| {
                    for (row.cells.items) |cell| {
                        try collectLineAssetDeps(allocator, cell.lines.items, deps);
                    }
                }
            },
        }
    }
}

fn collectLineAssetDeps(
    allocator: std.mem.Allocator,
    lines: []const markdown.Line,
    deps: *std.ArrayList(AssetDependency),
) !void {
    for (lines) |line| {
        const runs = line.runs.items;
        var index: usize = 0;
        while (index < runs.len) {
            const run = runs[index];
            switch (run.kind) {
                .display_math => {
                    const start = index;
                    while (index < runs.len and runs[index].kind == .display_math) : (index += 1) {}
                    const source = try displayMathSource(allocator, runs[start..index]);
                    errdefer allocator.free(source);
                    if (source.len > 0) {
                        const span = runSpan(runs[start..index]);
                        try deps.append(allocator, .{
                            .kind = .display_math,
                            .source = source,
                            .source_owned = true,
                            .content_start = span.start,
                            .content_end = span.end,
                        });
                    } else {
                        allocator.free(source);
                    }
                    continue;
                },
                .math => try deps.append(allocator, .{
                    .kind = .inline_math,
                    .source = run.text,
                    .content_start = run.source_start,
                    .content_end = run.source_end,
                }),
                .icon => if (run.icon) |source| try deps.append(allocator, .{
                    .kind = .icon,
                    .source = source,
                    .content_start = run.source_start,
                    .content_end = run.source_end,
                }),
                else => {},
            }
            index += 1;
        }
    }
}

const RunSpan = struct {
    start: usize,
    end: usize,
};

fn runSpan(runs: []const markdown.Run) RunSpan {
    if (runs.len == 0) return .{ .start = 0, .end = 0 };
    var start = runs[0].source_start;
    var end = runs[0].source_end;
    for (runs[1..]) |run| {
        start = @min(start, run.source_start);
        end = @max(end, run.source_end);
    }
    return .{ .start = start, .end = end };
}

fn displayMathSource(allocator: std.mem.Allocator, runs: []const markdown.Run) ![]const u8 {
    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(allocator);
    for (runs) |run| {
        try joined.appendSlice(allocator, run.text);
    }
    const trimmed = std.mem.trim(u8, joined.items, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

fn collectPageObjectIds(
    allocator: std.mem.Allocator,
    state: *DocumentState,
    page_id: model.NodeId,
    object_ids: *std.ArrayList(model.NodeId),
) !void {
    if (state.childrenOf(page_id)) |children| {
        for (children) |child_id| try appendUniqueNodeId(allocator, object_ids, child_id);
    }
    for (state.constraints.items) |constraint| {
        if (state.layoutPageOf(constraint.target_node) == page_id) {
            try appendUniqueNodeId(allocator, object_ids, constraint.target_node);
        }
        switch (constraint.source) {
            .page => {},
            .node => |source| {
                if (state.layoutPageOf(source.node_id) == page_id) {
                    try appendUniqueNodeId(allocator, object_ids, source.node_id);
                }
            },
        }
    }
}

fn collectPageConstraints(
    allocator: std.mem.Allocator,
    state: *DocumentState,
    page_id: model.NodeId,
    constraints: *std.ArrayList(model.Constraint),
) !void {
    for (state.constraints.items) |constraint| {
        if (state.layoutPageOf(constraint.target_node) != page_id) continue;
        try constraints.append(allocator, constraint);
    }
}

fn appendUniqueNodeId(allocator: std.mem.Allocator, items: *std.ArrayList(model.NodeId), node_id: model.NodeId) !void {
    for (items.items) |existing| {
        if (existing == node_id) return;
    }
    try items.append(allocator, node_id);
}

fn appendUniqueKey(allocator: std.mem.Allocator, items: *std.ArrayList(u64), key: u64) !void {
    for (items.items) |existing| {
        if (existing == key) return;
    }
    try items.append(allocator, key);
}

fn cloneTexPreambleEntries(allocator: std.mem.Allocator, preamble: []const render_env.TexPreambleEntry) ![]const render_env.TexPreambleEntry {
    const cloned = try allocator.alloc(render_env.TexPreambleEntry, preamble.len);
    @memcpy(cloned, preamble);
    return cloned;
}

fn nodeStringField(node: *const model.Node, key: []const u8) ?[]const u8 {
    const value = model.nodeField(node, key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn hashTexPreamble(hasher: *std.hash.Wyhash, preamble: []const render_env.TexPreambleEntry) void {
    hashUsize(hasher, preamble.len);
    for (preamble) |entry| {
        hashString(hasher, @tagName(entry.source));
        hashString(hasher, entry.value);
    }
}

fn hashString(hasher: *std.hash.Wyhash, value: []const u8) void {
    hashUsize(hasher, value.len);
    hasher.update(value);
}

fn hashUsize(hasher: *std.hash.Wyhash, value: usize) void {
    const normalized: u64 = @intCast(value);
    hasher.update(std.mem.asBytes(&normalized));
}
