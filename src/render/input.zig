const std = @import("std");
const core = @import("core");

pub const DocumentInput = struct {
    asset_base_dir: []const u8,
    pages: std.ArrayList(PageInput) = .empty,

    pub fn deinit(self: *DocumentInput, allocator: std.mem.Allocator) void {
        for (self.pages.items) |*page| page.deinit(allocator);
        self.pages.deinit(allocator);
    }
};

pub const PageInput = struct {
    page_id: core.NodeId,
    index: usize,
    label: []const u8,
    frame: core.Frame,
    background: ?core.render_policy.Color,
    objects: std.ArrayList(ObjectInput) = .empty,

    pub fn deinit(self: *PageInput, allocator: std.mem.Allocator) void {
        for (self.objects.items) |*object| object.deinit(allocator);
        self.objects.deinit(allocator);
    }
};

pub const ObjectInput = struct {
    node_id: core.NodeId,
    frame: core.Frame,
    content: []const u8,
    link_id: ?[]const u8,
    render: core.render_policy.ResolvedRender,
    parse_mode: core.markdown.ParseMode,
    tex_preamble: []core.render_env.TexPreambleEntry,
    math_kind: MathMode,

    pub fn deinit(self: *ObjectInput, allocator: std.mem.Allocator) void {
        allocator.free(self.tex_preamble);
    }
};

pub const MathMode = enum {
    @"inline",
    display,
    block,
    raw_block,
};

pub fn build(allocator: std.mem.Allocator, ir: *core.Ir, sema: anytype) !DocumentInput {
    var document = DocumentInput{
        .asset_base_dir = if (ir.asset_base_dir.len == 0) "." else ir.asset_base_dir,
    };
    errdefer document.deinit(allocator);

    for (ir.page_order.items, 0..) |page_id, page_index| {
        const page = ir.getNode(page_id) orelse continue;
        var page_input = PageInput{
            .page_id = page.id,
            .index = page_index,
            .label = page.name,
            .frame = page.frame,
            .background = core.render_policy.resolvePageBackgroundWithEnv(ir, page, sema),
        };
        errdefer page_input.deinit(allocator);

        if (ir.contains.get(page.id)) |children| {
            for (children.items) |child_id| {
                const node = ir.getNode(child_id) orelse continue;
                if (node.kind != .object or !node.attached) continue;
                var env = try core.render_env.resolveForNode(allocator, ir, node);
                defer env.deinit(allocator);
                try page_input.objects.append(allocator, .{
                    .node_id = node.id,
                    .frame = node.frame,
                    .content = node.content orelse "",
                    .link_id = core.nodeProperty(node, "link_id"),
                    .render = core.render_policy.resolveWithEnv(ir, node, sema),
                    .parse_mode = core.markdown.parseModeForNode(ir, node),
                    .tex_preamble = try cloneTexPreambleEntries(allocator, env.tex_preamble.items),
                    .math_kind = mathModeForNode(node),
                });
            }
        }

        try document.pages.append(allocator, page_input);
    }

    return document;
}

pub fn cloneTexPreambleEntries(allocator: std.mem.Allocator, entries: []const core.render_env.TexPreambleEntry) ![]core.render_env.TexPreambleEntry {
    const result = try allocator.alloc(core.render_env.TexPreambleEntry, entries.len);
    errdefer allocator.free(result);
    for (entries, 0..) |entry, index| {
        result[index] = .{ .source = entry.source, .value = entry.value };
    }
    return result;
}

fn mathModeForNode(node: *const core.Node) MathMode {
    return switch (node.payload_kind orelse .text) {
        .math_tex => .raw_block,
        .math_text => .block,
        else => .block,
    };
}
